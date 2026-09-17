#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────
# Tests for trivyignore-register-check / lib/check.sh (iac#2641).
#
# The check binds every suppressed advisory ID in a consumer's
# .trivyignore / .trivyignore.yaml to an ISE-NNN entry in that
# consumer's image-scan exceptions register. Rules under test:
#
#   R1  no ignore file at all                         -> pass
#   R2  ignore file(s) present, zero IDs               -> pass
#   R3  an ID with no ISE entry                        -> exit 1, names it
#   R4  IDs present, register file absent              -> exit 1
#   R5  exp:/expired_at strictly before TODAY          -> exit 1
#   R6  matching entry past its Re-validate by date    -> ::warning, exit 0
#   R7  register present but unreadable/unparseable    -> exit 2
#   R8  malformed date anywhere                        -> exit 2
#
# Every test pins TODAY via the environment. A test that read the wall
# clock would flip from green to red on a calendar date with no code
# change — the exact silent-drift shape this check exists to catch.
#
# Every date fixture is measured against TODAY=2026-09-16.
# ──────────────────────────────────────────────────────────────────────

ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$ACTION_DIR/lib/check.sh"
ACTION_YML="$ACTION_DIR/action.yml"

setup() {
  # Ambient CI env must not leak into assertions.
  unset GITHUB_ACTIONS CI GITHUB_OUTPUT GITHUB_STEP_SUMMARY
  export TODAY="2026-09-16"

  TEST_TMPDIR="$(mktemp -d)"
  REGISTER="$TEST_TMPDIR/docs/security/image-scan-exceptions.md"
  IGNORE="$TEST_TMPDIR/.trivyignore"
  IGNORE_YAML="$TEST_TMPDIR/.trivyignore.yaml"
  mkdir -p "$(dirname "$REGISTER")"
  export ORIGINAL_PATH="$PATH"
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  chmod -R u+rwX "$TEST_TMPDIR" 2> /dev/null || true
  rm -rf "$TEST_TMPDIR"
}

# Run the real entry point exactly as action.yml does: source the lib,
# call the function. Args default to the fixture paths.
check() {
  # shellcheck disable=SC1090
  source "$LIB"
  check_trivyignore_register "${1:-$REGISTER}" "${2:-$IGNORE}" "${3:-$IGNORE_YAML}"
}

# Write a register in the real file's shape: prose header, the fenced
# ```markdown template block (which MUST NOT parse as an entry), then one
# ISE entry per "ADVISORY|REVALIDATE" argument.
write_register() {
  cat > "$REGISTER" << 'HEADER'
# Container Image-Scan Exceptions Register

**Status:** Active (test fixture)

## Entry format

```markdown
## ISE-NNN — <one-line title>

| Field              | Value                                     |
| ------------------ | ----------------------------------------- |
| **Advisory ID**    | `CVE-YYYY-NNNNN` or `GHSA-xxxx-xxxx-xxxx` |
| **Package**        | `<name>@<version>`                        |
| **Accepted date**  | YYYY-MM-DD                                |
| **Re-validate by** | YYYY-MM-DD                                |

**Why it is safe:** <justification>
```

## Entries

HEADER
  local n=1
  local spec adv reval
  for spec in "$@"; do
    IFS='|' read -r adv reval <<< "$spec"
    cat >> "$REGISTER" << EOF

## ISE-$(printf '%03d' "$n") — test entry ${n}

| Field              | Value                  |
| ------------------ | ---------------------- |
| **Advisory ID**    | \`${adv}\`             |
| **Package**        | \`pkg@1.0.0\`          |
| **Accepted date**  | 2026-09-01             |
| **Re-validate by** | ${reval}               |

**Why it is safe:** fixture.
EOF
    n=$((n + 1))
  done
}

count_in_output() {
  # grep -c exits 1 on zero matches; the count is still what we want.
  grep -c -F -e "$1" <<< "$output" || true
}

# ── Manifest pins (same shape as assert-role-arn) ────────────────────

@test "manifest: action.yml contains no GitHub-Actions expressions referencing vars.* (runner evaluates them in description fields too)" {
  run grep -E '\$\{\{[^}]*vars\.' "$ACTION_YML"
  [ "$status" -eq 1 ]
}

@test "manifest: action.yml sources lib/check.sh and calls check_trivyignore_register" {
  grep -q 'source "${{ github.action_path }}/lib/check.sh"' "$ACTION_YML"
  grep -q 'check_trivyignore_register ' "$ACTION_YML"
}

@test "manifest: input defaults are the paths Trivy and the register convention use" {
  [ "$(yq '.inputs.register-path.default' "$ACTION_YML")" = "docs/security/image-scan-exceptions.md" ]
  [ "$(yq '.inputs.ignore-path.default' "$ACTION_YML")" = ".trivyignore" ]
  [ "$(yq '.inputs.ignore-yaml-path.default' "$ACTION_YML")" = ".trivyignore.yaml" ]
  [ "$(yq '.runs.using' "$ACTION_YML")" = "composite" ]
}

# ── R1 / R2 — nothing suppressed ─────────────────────────────────────

@test "R1: no .trivyignore and no .trivyignore.yaml -> exit 0 'nothing suppressed' (register absence irrelevant)" {
  rm -f "$REGISTER"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing suppressed"* ]]
}

@test "R2: empty (0-byte) .trivyignore.yaml -> exit 0, zero IDs" {
  : > "$IGNORE_YAML"
  rm -f "$REGISTER"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"no advisory IDs"* ]]
}

@test "R2: comment-only .trivyignore.yaml -> exit 0, zero IDs" {
  printf '# nothing suppressed yet\n' > "$IGNORE_YAML"
  rm -f "$REGISTER"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"no advisory IDs"* ]]
}

@test "R2: plain file with only comments and blank lines -> exit 0, zero IDs" {
  printf '# nothing here\n\n   \n  # indented comment\n' > "$IGNORE"
  rm -f "$REGISTER"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"no advisory IDs"* ]]
}

@test "R2: yaml file whose lists are empty -> exit 0, zero IDs" {
  printf 'vulnerabilities: []\nsecrets:\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"no advisory IDs"* ]]
}

# ── R3 — undocumented ID ─────────────────────────────────────────────

@test "R3: an ID with no ISE entry -> exit 1 naming that ID and not the documented one" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111\nCVE-2026-2222\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'CVE-2026-2222' has no ISE-NNN entry"* ]]
  [[ "$output" != *"'CVE-2026-1111' has no ISE-NNN entry"* ]]
  [[ "$output" == *"documented: 'CVE-2026-1111'"* ]]
}

@test "R3: every undocumented ID is named, not just the first" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-2222\nCVE-2026-3333\nCVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'CVE-2026-2222' has no ISE-NNN entry"* ]]
  [[ "$output" == *"'CVE-2026-3333' has no ISE-NNN entry"* ]]
}

@test "R3: all IDs documented -> exit 0 with a summary count" {
  write_register "CVE-2026-1111|2026-12-31" "CVE-2026-2222|2026-11-30"
  printf 'CVE-2026-1111\nCVE-2026-2222\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 suppressed advisory ID(s) are documented"* ]]
}

@test "R3: a GHSA advisory is matched exactly like a CVE" {
  write_register "GHSA-abcd-efgh-ijkl|2026-12-31"
  printf 'GHSA-abcd-efgh-ijkl\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"documented: 'GHSA-abcd-efgh-ijkl'"* ]]

  printf 'GHSA-zzzz-zzzz-zzzz\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'GHSA-zzzz-zzzz-zzzz' has no ISE-NNN entry"* ]]
}

# ── R4 — register absent ─────────────────────────────────────────────

@test "R4: ignore file has IDs but the register file is absent -> exit 1, every ID reported undocumented" {
  rm -f "$REGISTER"
  printf 'CVE-2026-1111\nCVE-2026-2222\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  [[ "$output" == *"'CVE-2026-1111' has no ISE-NNN entry"* ]]
  [[ "$output" == *"'CVE-2026-2222' has no ISE-NNN entry"* ]]
}

# ── R5 — expired suppression still present ───────────────────────────

@test "R5: plain exp: strictly before TODAY -> exit 1 'expired suppression still present' even when documented" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111 exp:2026-09-15\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expired suppression still present"* ]]
  [[ "$output" == *"CVE-2026-1111"* ]]
  [[ "$output" == *"2026-09-15"* ]]
}

@test "R5: plain exp: equal to TODAY is not expired (strictly before)" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111 exp:2026-09-16\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Expired suppression"* ]]
}

@test "R5: yaml expired_at strictly before TODAY -> exit 1" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n    expired_at: 2026-01-01\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expired suppression still present"* ]]
  [[ "$output" == *"2026-01-01"* ]]
}

@test "R5 + R3 together: both failures are reported in one run" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111 exp:2020-01-01\nCVE-2026-9999\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expired suppression still present"* ]]
  [[ "$output" == *"'CVE-2026-9999' has no ISE-NNN entry"* ]]
}

# ── R6 — register entry past re-validate date ────────────────────────

@test "R6: matching ISE entry with Re-validate by before TODAY -> ::warning naming the entry, exit unaffected" {
  write_register "CVE-2026-1111|2026-09-01"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"ISE-001"* ]]
  [[ "$output" == *"past its re-validate-by date"* ]]
  [[ "$output" == *"2026-09-01"* ]]
}

@test "R6: Re-validate by equal to TODAY does not warn" {
  write_register "CVE-2026-1111|2026-09-16"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

@test "R6: a stale entry for an ID that is NOT suppressed does not warn (only matched entries are checked)" {
  write_register "CVE-2026-1111|2026-12-31" "CVE-2026-2222|2020-01-01"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" != *"past its re-validate-by date"* ]]
}

# ── R7 — register present but unusable ───────────────────────────────

@test "R7: register exists but is unreadable -> exit 2, never pass" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores file modes"
  fi
  write_register "CVE-2026-1111|2026-12-31"
  chmod 000 "$REGISTER"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"not readable"* ]]
}

@test "R7: register path is a directory -> exit 2" {
  rm -f "$REGISTER"
  mkdir -p "$REGISTER"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
}

@test "R7: a real ISE entry with no Advisory ID row is unparseable -> exit 2 naming the entry" {
  write_register "CVE-2026-1111|2026-12-31"
  cat >> "$REGISTER" << 'EOF'

## ISE-002 — broken entry

| Field              | Value        |
| ------------------ | ------------ |
| **Package**        | `pkg@1.0.0`  |
| **Re-validate by** | 2026-12-31   |
EOF
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ISE-002"* ]]
  [[ "$output" == *"no Advisory ID"* ]]
}

@test "R7: a real ISE entry with no Re-validate by row is unparseable -> exit 2 naming the entry" {
  write_register
  cat >> "$REGISTER" << 'EOF'

## ISE-001 — no revalidate row

| Field              | Value           |
| ------------------ | --------------- |
| **Advisory ID**    | `CVE-2026-1111` |
EOF
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ISE-001"* ]]
  [[ "$output" == *"no Re-validate by"* ]]
}

@test "R7: plain ignore file exists but is unreadable -> exit 2" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores file modes"
  fi
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  chmod 000 "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"not readable"* ]]
}

@test "R7: .trivyignore.yaml that is not valid YAML -> exit 2" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities: [\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 2 ]
}

@test "R7: .trivyignore.yaml present but yq is not on PATH -> exit 2 naming yq" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n' > "$IGNORE_YAML"
  local thin="$TEST_TMPDIR/thinbin"
  mkdir -p "$thin"
  local tool
  for tool in awk sort grep sed cat tr wc date chmod rm mkdir id; do
    ln -s "$(command -v "$tool")" "$thin/$tool"
  done
  export PATH="$thin"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"yq"* ]]
}

# ── R8 — malformed dates are undeterminable, never valid ─────────────

@test "R8: plain exp: with an impossible calendar date -> exit 2" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111 exp:2026-13-45\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"Malformed date"* ]]
  [[ "$output" == *"2026-13-45"* ]]
}

@test "R8: plain exp: in a non-ISO format -> exit 2" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111 exp:31/12/2026\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"Malformed date"* ]]
}

# This test previously asserted exit 2 and called it deliberate. It was
# encoding a defect: Trivy declares expired_at as time.Time, so go-yaml
# accepts a full RFC3339 timestamp, and rejecting it failed a build on a
# file Trivy is perfectly happy with. Corrected to the right behaviour.
@test "yaml expired_at as a full RFC3339 timestamp is accepted — Trivy declares the field as time.Time" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n    expired_at: 2026-12-31T00:00:00Z\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 0 ]
}

@test "an RFC3339 expired_at in the PAST still fails as expired — the date part is what is compared" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n    expired_at: 2026-01-01T00:00:00Z\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 1 ]
}

# ── Fixes from adversarial review (iac#2641) ──────────────────────────

@test "a level-2 section after the entries does not swallow them — the reference register has three" {
  write_register "CVE-2026-1111|2026-12-31"
  cat >> "$REGISTER" << 'TRAILER'

## Changelog

- 2026-09-16 — first entry; note the **Re-validate by** column is now 90 days max.
TRAILER
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
}

@test "prose bolding **Advisory ID** after the entries does not corrupt the last one" {
  write_register "CVE-2026-1111|2026-12-31"
  cat >> "$REGISTER" << 'TRAILER'

## Enforcement gap

Every entry needs an **Advisory ID** row; see above.
TRAILER
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
}

@test "an entry carrying CVE and GHSA aliases documents BOTH ids" {
  cat > "$REGISTER" << 'REG'
# Register

## Entries

## ISE-001 — alias pair

| Field              | Value                                         |
| ------------------ | --------------------------------------------- |
| **Advisory ID**    | `CVE-2026-1111` (alias `GHSA-abcd-efgh-ijkl`) |
| **Re-validate by** | 2026-12-31                                    |
REG
  printf 'CVE-2026-1111\nGHSA-abcd-efgh-ijkl\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
}

@test "an ISE entry at level 3 is rejected with a message naming the heading depth" {
  cat > "$REGISTER" << 'REG'
# Register

## Entries

### ISE-001 — nested too deep

| Field              | Value           |
| ------------------ | --------------- |
| **Advisory ID**    | `CVE-2026-1111` |
| **Re-validate by** | 2026-12-31      |
REG
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"level-2"* ]]
}

@test "a Re-validate by row whose cell cannot be read says so, not 'Malformed date ?'" {
  cat > "$REGISTER" << 'REG'
# Register

## Entries

## ISE-001 — pipe-less GFM table

**Advisory ID**|`CVE-2026-1111`
**Re-validate by**|2026-12-31
REG
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be read"* ]]
  [[ "$output" != *"Malformed date '?'"* ]]
}

@test "a .trivyignore that is a directory is an explicit error, not 'nothing suppressed'" {
  write_register "CVE-2026-1111|2026-12-31"
  rm -f "$IGNORE"; mkdir -p "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"is a directory"* ]]
}

@test "a .trivyignore.yaml that is a directory is an explicit error" {
  write_register "CVE-2026-1111|2026-12-31"
  rm -f "$IGNORE_YAML"; mkdir -p "$IGNORE_YAML"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"is a directory"* ]]
}

@test "a non-mikefarah yq is named as the cause instead of producing a nonsense date error" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n' > "$IGNORE_YAML"
  local shim="$TEST_TMPDIR/bin"; mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then echo "yq 3.4.3"; exit 0; fi\nexit 0\n' > "$shim/yq"
  chmod +x "$shim/yq"
  PATH="$shim:$PATH" run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"mikefarah"* ]]
}

@test "R8: yaml expired_at that is not YYYY-MM-DD -> exit 2" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n    expired_at: soon\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"Malformed date"* ]]
}

@test "R8: register Re-validate by that is not a date -> exit 2 naming the entry" {
  write_register "CVE-2026-1111|TBD"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"Malformed date"* ]]
  [[ "$output" == *"ISE-001"* ]]
}

@test "R8: register Re-validate by on an unmatched entry is still validated (a register that cannot be parsed is exit 2)" {
  write_register "CVE-2026-1111|2026-12-31" "CVE-2026-2222|2026-02-30"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ISE-002"* ]]
}

@test "R8: malformed TODAY in the environment -> exit 2" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  export TODAY="yesterday"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"TODAY"* ]]
}

# ── Plain-format parsing (trivy pkg/result/ignore.go semantics) ──────

@test "plain: comments, blank lines, leading whitespace and CRLF are handled; only IDs survive" {
  printf '# header comment\r\n\r\n   CVE-2026-1111\r\n\t# indented comment\n\nCVE-2026-2222 exp:2026-12-31\n' > "$IGNORE"
  source "$LIB"
  run parse_ignore_plain "$IGNORE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'CVE-2026-1111\t-\nCVE-2026-2222\t2026-12-31')" ]
}

@test "plain: fields after the ID that are not exp: are ignored, exactly as trivy ignores them" {
  printf 'CVE-2026-1111 some free-text note here\nCVE-2026-2222 note exp:2026-12-31 more\nCVE-2026-3333 # trailing comment\n' > "$IGNORE"
  source "$LIB"
  run parse_ignore_plain "$IGNORE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'CVE-2026-1111\t-\nCVE-2026-2222\t2026-12-31\nCVE-2026-3333\t-')" ]
}

@test "plain: the FIRST exp: field wins when several are present (trivy takes the first)" {
  printf 'CVE-2026-1111 exp:2026-12-31 exp:2000-01-01\n' > "$IGNORE"
  source "$LIB"
  run parse_ignore_plain "$IGNORE"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'CVE-2026-1111\t2026-12-31')" ]
}

# ── YAML-format parsing ──────────────────────────────────────────────

@test "yaml: vulnerabilities and secrets IDs are extracted with their expired_at; misconfigurations and licenses are not" {
  cat > "$IGNORE_YAML" << 'YAML'
vulnerabilities:
  - id: CVE-2026-1111
    paths:
      - "usr/local/lib/**"
    expired_at: 2026-12-31
    statement: unreachable in this deployment
  - id: GHSA-abcd-efgh-ijkl
misconfigurations:
  - id: AVD-AWS-0001
secrets:
  - id: aws-access-key-id
    expired_at: 2026-11-30
licenses:
  - id: GPL-3.0
YAML
  source "$LIB"
  run parse_ignore_yaml "$IGNORE_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'CVE-2026-1111\t2026-12-31\nGHSA-abcd-efgh-ijkl\t-\naws-access-key-id\t2026-11-30')" ]
}

@test "yaml: non-string scalars (numeric id, unquoted YAML date) are emitted as text" {
  # yq tags an unquoted 2026-12-31 as !!timestamp and 1234 as !!int. The
  # parser must not depend on a stringify operator whose spelling varies by
  # yq version (tostring / to_string) — join() reads the node's text as-is.
  printf 'vulnerabilities:\n  - id: 1234\n    expired_at: 2026-12-31\n' > "$IGNORE_YAML"
  source "$LIB"
  run parse_ignore_yaml "$IGNORE_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1234\t2026-12-31')" ]
}

@test "yaml: misconfiguration IDs are NOT required in the register (not advisories)" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\nmisconfigurations:\n  - id: AVD-AWS-0001\nlicenses:\n  - id: GPL-3.0\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" != *"AVD-AWS-0001"* ]]
}

@test "yaml: secrets IDs ARE required in the register" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\nsecrets:\n  - id: aws-access-key-id\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'aws-access-key-id' has no ISE-NNN entry"* ]]
}

@test "yaml: an entry with no id cannot be matched -> exit 2" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'vulnerabilities:\n  - statement: forgot the id\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"no id"* ]]
}

# ── Both formats present ─────────────────────────────────────────────

@test "both plain and yaml present with overlapping IDs -> IDs are deduped (each documented once), union is checked" {
  write_register "CVE-2026-1111|2026-12-31" "CVE-2026-2222|2026-12-31" "CVE-2026-3333|2026-12-31"
  printf 'CVE-2026-1111\nCVE-2026-2222\n' > "$IGNORE"
  printf 'vulnerabilities:\n  - id: CVE-2026-1111\n  - id: CVE-2026-3333\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 0 ]
  [ "$(count_in_output "documented: 'CVE-2026-1111'")" -eq 1 ]
  [ "$(count_in_output "documented: 'CVE-2026-2222'")" -eq 1 ]
  [ "$(count_in_output "documented: 'CVE-2026-3333'")" -eq 1 ]
  [[ "$output" == *"All 3 suppressed advisory ID(s) are documented"* ]]
}

@test "both present: an ID undocumented in the yaml file fails even when the plain file is clean" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  printf 'vulnerabilities:\n  - id: CVE-2026-4444\n' > "$IGNORE_YAML"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'CVE-2026-4444' has no ISE-NNN entry"* ]]
}

# ── Register parsing ─────────────────────────────────────────────────

@test "register: entries are emitted as ISE-id, advisory, re-validate date" {
  write_register "CVE-2026-1111|2026-12-31" "GHSA-abcd-efgh-ijkl|2026-10-01"
  source "$LIB"
  run parse_register "$REGISTER"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ISE-001\tCVE-2026-1111\t2026-12-31\nISE-002\tGHSA-abcd-efgh-ijkl\t2026-10-01')" ]
}

@test "register: the fenced \`\`\`markdown template block is NOT an entry — its placeholder never documents anything" {
  write_register # header + template block only, zero real entries
  source "$LIB"
  run parse_register "$REGISTER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # A .trivyignore that literally lists the placeholder must still fail:
  # the template is a format reference, not an accepted suppression.
  printf 'CVE-YYYY-NNNNN\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'CVE-YYYY-NNNNN' has no ISE-NNN entry"* ]]
}

@test "register: a template copied OUTSIDE the fence with ISE-NNN / placeholder values is skipped, not an error" {
  write_register "CVE-2026-1111|2026-12-31"
  cat >> "$REGISTER" << 'EOF'

## ISE-NNN — <one-line title>

| Field              | Value                                     |
| ------------------ | ----------------------------------------- |
| **Advisory ID**    | `CVE-YYYY-NNNNN` or `GHSA-xxxx-xxxx-xxxx` |
| **Re-validate by** | YYYY-MM-DD                                |
EOF
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1 suppressed advisory ID(s) are documented"* ]]
}

@test "register: an empty register (no entries) with IDs suppressed -> exit 1 (undocumented), not exit 2" {
  write_register
  printf 'CVE-2026-1111\n' > "$IGNORE"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'CVE-2026-1111' has no ISE-NNN entry"* ]]
}

@test "register: a real GHSA ID that happens to contain 'xxxx' is an entry, not the template placeholder ('x' is a legal GHSA character)" {
  write_register "GHSA-xxxx-2f7c-9q3v|2026-12-31"
  printf 'GHSA-xxxx-2f7c-9q3v\n' > "$IGNORE"
  run check
  [ "$status" -eq 0 ]
  [[ "$output" == *"documented: 'GHSA-xxxx-2f7c-9q3v' → ISE-001"* ]]
  [[ "$output" != *"template placeholder"* ]]
}

# ── TODAY injection ──────────────────────────────────────────────────

@test "TODAY: the same fixture flips between pass and fail purely on the injected TODAY (no wall clock)" {
  write_register "CVE-2026-1111|2030-12-31"
  printf 'CVE-2026-1111 exp:2026-12-31\n' > "$IGNORE"

  export TODAY="2026-01-01"
  run check
  [ "$status" -eq 0 ]

  export TODAY="2030-01-01"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expired suppression still present"* ]]
  [[ "$output" == *"today is 2030-01-01"* ]]
}

# ── Paths ────────────────────────────────────────────────────────────

@test "paths: relative paths resolve against the working directory, as they do in the action" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111\n' > "$IGNORE"
  cd "$TEST_TMPDIR"
  run check "docs/security/image-scan-exceptions.md" ".trivyignore" ".trivyignore.yaml"
  [ "$status" -eq 0 ]
}

@test "paths: a non-default ignore-path is honoured" {
  write_register "CVE-2026-1111|2026-12-31"
  printf 'CVE-2026-1111\nCVE-2026-5555\n' > "$TEST_TMPDIR/custom.ignore"
  run check "$REGISTER" "$TEST_TMPDIR/custom.ignore" "$IGNORE_YAML"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'CVE-2026-5555' has no ISE-NNN entry"* ]]
}
