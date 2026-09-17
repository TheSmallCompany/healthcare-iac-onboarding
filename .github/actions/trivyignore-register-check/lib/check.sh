#!/usr/bin/env bash
# check.sh — trivyignore-register-check (iac#2641).
#
# Binds every suppressed container-image finding in a consumer repository's
# .trivyignore / .trivyignore.yaml to an ISE-NNN entry in that repository's
# image-scan exceptions register (docs/security/image-scan-exceptions.md by
# default; healthcare-iac's copy of that file is the format reference).
#
# Why this runs consumer-side: the register's sibling — the gitleaks
# register — is enforced in healthcare-iac CI by
# scripts/check-gitleaks-exceptions.sh. The same shape cannot work here
# because .trivyignore lives in the CONSUMER repo, which healthcare-iac CI
# cannot read. So the check runs where the file is: the consumer-pipeline
# template invokes this action in every build job immediately before the
# Trivy scan, so an undocumented suppression fails the build before it can
# silence anything.
#
# Match key: the ADVISORY ID (CVE-…, GHSA-…, or any other ID Trivy accepts)
# within the consumer's OWN register. iac#2641 phrased the key as an
# (advisory-id, image) tuple; a .trivyignore has no image field, so that is
# unimplementable from the ignore side. One register per consumer repo and
# one advisory ID per entry is the sound key — the register's `Image / repo`
# row still records the image for the auditor, it just is not matched on.
#
# .trivyignore (plain) — semantics copied from trivy pkg/result/ignore.go:
#   - each line is TrimSpace'd; empty lines and lines starting with "#" skip
#   - strings.Fields(line): field[0] is the ID; the FIRST later field of the
#     form exp:YYYY-MM-DD is the expiry; every other field is ignored
#   - every ID is in scope — the plain format cannot say which finding
#     class an ID belongs to
#
# .trivyignore.yaml — top-level keys vulnerabilities / misconfigurations /
# secrets / licenses, each a list of { id, paths?, purls?, expired_at?,
# statement? }. Only `vulnerabilities` and `secrets` IDs are in scope:
# misconfiguration and licence IDs are not advisories. Parsed with yq.
#
# Trivy itself reads ONE ignore file (the yaml wins when both exist). This
# check reads the UNION, deduplicated by ID: an ID left in a stale plain
# file is still a suppression someone intended, and it must be documented
# or gone.
#
# Rules (exit 0 pass / 1 fail / 2 undetermined — undetermined never passes):
#   R1  no .trivyignore and no .trivyignore.yaml           -> pass
#   R2  ignore file(s) present but zero IDs                -> pass
#   R3  any ID with NO matching ISE entry                  -> FAIL, each named
#   R4  IDs present but the register file is absent        -> FAIL
#   R5  exp: / expired_at strictly before TODAY            -> FAIL — Trivy
#       already ignores an expired entry, so the line is dead and the
#       register entry is now misleading
#   R6  matching ISE entry whose Re-validate by < TODAY    -> ::warning only
#   R7  register exists but is unreadable / unparseable    -> exit 2
#   R8  malformed date in exp: / expired_at / Re-validate  -> exit 2
#
# Dates are YYYY-MM-DD only, and must be real calendar dates. Zero-padded
# ISO dates compare correctly as plain strings, so there is no date
# arithmetic and no wall clock: TODAY comes from the environment variable
# TODAY when set, else `date -u +%F`. Tests always set TODAY.
#
# Functions (all sourceable — bats sources this file):
#   parse_ignore_plain <file>   -> "ID<TAB><exp|->" per line          (2 on R8)
#   parse_ignore_yaml <file>    -> "ID<TAB><expired_at|->" per line   (2 on R7/R8)
#   parse_register <file>       -> "ISE-NNN<TAB>ID<TAB><revalidate>"  (2 on R7/R8)
#   check_trivyignore_register <register> <ignore> <ignore-yaml>      -> 0/1/2

# ── Diagnostics ───────────────────────────────────────────────────────
# All to stderr: the parse_* functions use stdout as their data channel.

trc_error() { echo "::error::$*" >&2; }
trc_warning() { echo "::warning::$*" >&2; }
trc_notice() { echo "::notice::$*" >&2; }

# ── Dates ─────────────────────────────────────────────────────────────

# valid_date YYYY-MM-DD — 0 if the string is a real calendar date.
valid_date() {
  local d="$1"
  [[ "$d" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]}))
  local m=$((10#${BASH_REMATCH[2]}))
  local day=$((10#${BASH_REMATCH[3]}))
  ((m >= 1 && m <= 12)) || return 1
  local dim
  case "$m" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) dim=31 ;;
    4 | 6 | 9 | 11) dim=30 ;;
    2)
      if (((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)); then
        dim=29
      else
        dim=28
      fi
      ;;
  esac
  ((day >= 1 && day <= dim))
}

# resolve_today — prints TODAY (env) or the UTC date; exit 2 if malformed.
resolve_today() {
  local today="${TODAY:-}"
  if [[ -z "$today" ]]; then
    today=$(date -u +%F)
  fi
  if ! valid_date "$today"; then
    trc_error "TODAY='${today}' is not a YYYY-MM-DD date — cannot evaluate expiries or re-validate dates."
    return 2
  fi
  printf '%s\n' "$today"
}

# A register value that is still the template's placeholder, not an ID.
# Matched EXACTLY against the two literals in the "Entry format" block plus
# unfilled <angle-bracket> slots — never by substring: `x` is a legal GHSA
# character, so a `*xxxx*` glob could swallow a real advisory ID.
is_placeholder_id() {
  case "$1" in
    CVE-YYYY-NNNNN | GHSA-xxxx-xxxx-xxxx | *"<"* | *">"*) return 0 ;;
  esac
  return 1
}

# ── .trivyignore (plain) ──────────────────────────────────────────────

parse_ignore_plain() {
  local file="$1"
  # A directory satisfies -r. macOS awk reads one as empty and the check would
  # report "nothing suppressed"; mawk on the runner exits non-zero and trips
  # errexit with no ::error::. parse_register already guarded this.
  if [[ -d "$file" ]]; then
    trc_error "${file} is a directory, not a file — cannot determine what it suppresses."
    return 2
  fi
  if [[ ! -r "$file" ]]; then
    trc_error "${file} exists but is not readable — cannot determine what it suppresses."
    return 2
  fi

  # `expiry`, not `exp` — exp() is an awk builtin.
  local lines
  lines=$(awk '
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    $0 == "" || substr($0, 1, 1) == "#" { next }
    {
      expiry = "-"
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 4) == "exp:") { expiry = substr($i, 5); break }
      }
      print $1 "\t" expiry "\t" NR
    }
  ' "$file")

  local id expiry lineno rc=0
  while IFS=$'\t' read -r id expiry lineno; do
    [[ -n "$id" ]] || continue
    if [[ "$expiry" != "-" ]] && ! valid_date "$expiry"; then
      trc_error "Malformed date '${expiry}' in ${file} line ${lineno}: exp: must be a real YYYY-MM-DD date. An undeterminable expiry is not a valid one (Trivy itself refuses this file)."
      rc=2
      continue
    fi
    printf '%s\t%s\n' "$id" "$expiry"
  done <<< "$lines"
  return "$rc"
}

# ── .trivyignore.yaml ─────────────────────────────────────────────────

parse_ignore_yaml() {
  local file="$1"
  # A directory satisfies -r. macOS awk reads one as empty and the check would
  # report "nothing suppressed"; mawk on the runner exits non-zero and trips
  # errexit with no ::error::. parse_register already guarded this.
  if [[ -d "$file" ]]; then
    trc_error "${file} is a directory, not a file — cannot determine what it suppresses."
    return 2
  fi
  if [[ ! -r "$file" ]]; then
    trc_error "${file} exists but is not readable — cannot determine what it suppresses."
    return 2
  fi
  if ! command -v yq > /dev/null 2>&1; then
    trc_error "yq is required to read ${file} and is not on PATH — cannot determine what it suppresses. Install mikefarah/yq (GitHub-hosted runners ship it)."
    return 2
  fi
  # kislyuk's python `yq` accepts the same expression but pipes it through jq,
  # so every value comes back JSON-quoted and the failure surfaces as a
  # nonsense malformed-date message pointing at a date that is not there.
  local yq_banner
  yq_banner=$(yq --version 2>&1 | head -1)
  if [[ "$yq_banner" != *mikefarah* && "$yq_banner" != *"version v4"* && "$yq_banner" != *"version 4"* ]]; then
    trc_error "yq on PATH is not mikefarah/yq v4 (found: ${yq_banner}) — its output shape differs and ${file} cannot be read reliably. GitHub-hosted runners ship the right one."
    return 2
  fi

  # One "id|expired_at" line per vulnerabilities/secrets entry. `|` cannot
  # occur in an advisory ID or a date, and unlike whitespace it preserves an
  # empty leading field, which is how a missing id is detected below.
  # join() reads each node's text as-is (an unquoted YAML date, a numeric
  # id), so no stringify operator — whose spelling varies across yq
  # versions (tostring / to_string) — is needed.
  local raw
  if ! raw=$(yq '((.vulnerabilities // []) + (.secrets // []))[] | [(.id // ""), (.expired_at // "-")] | join("|")' "$file" 2>&1); then
    trc_error "${file} could not be parsed as a .trivyignore.yaml — cannot determine what it suppresses: ${raw}"
    return 2
  fi

  local id expiry rc=0
  while IFS='|' read -r id expiry; do
    if [[ -z "$id" && -z "$expiry" ]]; then
      continue
    fi
    if [[ -z "$id" ]]; then
      trc_error "${file}: an entry under vulnerabilities/secrets has no id — it cannot be matched to the register (nor by Trivy to a finding)."
      rc=2
      continue
    fi
    # Trivy declares expired_at as time.Time, so go-yaml accepts a full
    # RFC3339 timestamp as readily as a bare date. Rejecting the timestamp
    # form would fail a build on a file Trivy is perfectly happy with — so
    # accept it and compare on the date part (string compare still holds).
    if [[ "$expiry" != "-" ]]; then
      if [[ "$expiry" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})([T[:space:]].*)?$ ]]; then
        expiry="${BASH_REMATCH[1]}"
      fi
      if ! valid_date "$expiry"; then
        trc_error "Malformed date '${expiry}' for '${id}' in ${file}: expired_at must be a real YYYY-MM-DD date (a full RFC3339 timestamp is accepted). An undeterminable expiry is not a valid one."
        rc=2
        continue
      fi
    fi
    printf '%s\t%s\n' "$id" "$expiry"
  done <<< "$raw"
  return "$rc"
}

# ── Register ──────────────────────────────────────────────────────────
# Same approach as healthcare-iac's check-gitleaks-exceptions.sh: entries
# split on `## ISE-` headings; fenced ``` blocks are skipped so the
# register's own "Entry format" template never parses as an entry.

parse_register() {
  local file="$1"
  if [[ -d "$file" ]]; then
    trc_error "Register ${file} is a directory, not a file — cannot determine whether suppressions are documented."
    return 2
  fi
  if [[ ! -r "$file" ]]; then
    trc_error "Register ${file} exists but is not readable — cannot determine whether suppressions are documented."
    return 2
  fi

  # Emits "ISE-id<TAB>advisory<TAB>revalidate" per heading. An absent row
  # emits "-"; a row that is present but has no value emits "?", so the two
  # are distinguishable in the messages below. Never an empty field: tab is
  # whitespace, so `IFS=$'\t' read` would collapse "a<TAB><TAB>c" into two
  # fields and shift the values.
  local rows
  rows=$(awk '
    function flush() {
      if (ise != "") {
        print ise "\t" (adv == "" ? "-" : adv) "\t" (reval == "" ? "-" : reval)
      }
      ise = ""; adv = ""; reval = ""
    }
    BEGIN { in_fence = 0; ise = ""; adv = ""; reval = "" }
    /^```/ { in_fence = 1 - in_fence; next }
    in_fence == 1 { next }
    /^##[[:space:]]+ISE-/ {
      flush()
      if (match($0, /ISE-[A-Za-z0-9]+/)) ise = substr($0, RSTART, RLENGTH)
      next
    }
    # An ISE heading at level 3+ is the obvious way to nest entries under
    # `## Entries`, and silently matching nothing would report every
    # suppression as undocumented while the entry sits there in plain view.
    /^#{3,6}[[:space:]]+ISE-[0-9]+/ {
      if (match($0, /ISE-[A-Za-z0-9]+/)) print "!DEPTH\t" substr($0, RSTART, RLENGTH) "\t-"
      next
    }
    # ANY other level-2 heading ends the current entry. Without this, a
    # `## Changelog` or `## Enforcement gap` section after the entries keeps
    # the last one open, and prose that bolds **Advisory ID** or
    # **Re-validate by** overwrites it — turning a register that renders
    # perfectly into "unparseable". The reference register itself has three
    # `##` sections after `## Entries`.
    /^##[[:space:]]/ { flush(); next }
    ise == "" { next }
    /\*\*Advisory ID\*\*/ {
      # Every backticked token, not just the first: Trivy reports the GHSA
      # form for library findings and the CVE form for OS packages, so one
      # entry carrying both aliases is the natural thing to write — and the
      # placeholder row in the template reads "`CVE-…` or `GHSA-…`".
      rest = $0; adv = ""
      while (match(rest, /`[^`]+`/)) {
        tok = substr(rest, RSTART + 1, RLENGTH - 2)
        adv = (adv == "" ? tok : adv " " tok)
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (adv == "") adv = "?"
      next
    }
    /\*\*Re-validate by\*\*/ {
      n = split($0, cells, "|")
      reval = (n >= 3) ? cells[3] : ""
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", reval)
      if (reval == "") reval = "?"
      next
    }
    END { flush() }
  ' "$file")

  local ise adv reval rc=0
  while IFS=$'\t' read -r ise adv reval; do
    [[ -n "$ise" ]] || continue
    if [[ "$ise" == "!DEPTH" ]]; then
      trc_error "Register ${file}: ${adv} is a level-3-or-deeper heading. ISE entries must be level-2 (\`## ${adv} — <title>\`), or the parser cannot find them."
      rc=2
      continue
    fi
    # `## ISE-NNN` is the template heading, never a real entry.
    if [[ ! "$ise" =~ ^ISE-[0-9]+$ ]]; then
      continue
    fi
    if [[ "$adv" == "-" ]]; then
      trc_error "Register ${file}: entry ${ise} has no Advisory ID row — the register cannot be parsed. Every entry needs a \`| **Advisory ID** | \\\`<id>\\\` |\` row."
      rc=2
      continue
    fi
    if [[ "$adv" == "?" ]]; then
      trc_error "Register ${file}: entry ${ise} has an Advisory ID row with no backticked value — the register cannot be parsed."
      rc=2
      continue
    fi
    if is_placeholder_id "${adv%% *}"; then
      trc_warning "Register ${file}: entry ${ise} still carries the template placeholder '${adv}' — it documents nothing until the real advisory ID is filled in."
      continue
    fi
    if [[ "$reval" == "?" ]]; then
      trc_error "Register ${file}: entry ${ise} ('${adv}') has a Re-validate by row whose value cell could not be read — expected \`| **Re-validate by** | YYYY-MM-DD |\`. (A GFM table without leading/trailing pipes produces this.)"
      rc=2
      continue
    fi
    if [[ "$reval" == "-" ]]; then
      trc_error "Register ${file}: entry ${ise} ('${adv}') has no Re-validate by row — the register cannot be parsed. Every entry needs a \`| **Re-validate by** | YYYY-MM-DD |\` row."
      rc=2
      continue
    fi
    if ! valid_date "$reval"; then
      trc_error "Malformed date '${reval}' in ${file} entry ${ise} ('${adv}'): Re-validate by must be a real YYYY-MM-DD date. An undeterminable re-validate date is not a valid one."
      rc=2
      continue
    fi
    # `adv` may hold several space-separated alias IDs (see the awk above);
    # emit one tuple per ID so each matches independently.
    local one
    for one in $adv; do
      printf '%s\t%s\t%s\n' "$ise" "$one" "$reval"
    done
  done <<< "$rows"
  return "$rc"
}

# ── Main ──────────────────────────────────────────────────────────────

check_trivyignore_register() {
  local register="${1:-docs/security/image-scan-exceptions.md}"
  local ignore="${2:-.trivyignore}"
  local ignore_yaml="${3:-.trivyignore.yaml}"

  local today
  today=$(resolve_today) || return 2

  # Collect "ID<TAB>expiry<TAB>source" from every ignore file that exists.
  local entries="" present="" parsed
  if [[ -e "$ignore" ]]; then
    present="${ignore}"
    parsed=$(parse_ignore_plain "$ignore") || return 2
    if [[ -n "$parsed" ]]; then
      entries+=$(awk -F'\t' -v OFS='\t' -v src="$ignore" '{ print $1, $2, src }' <<< "$parsed")$'\n'
    fi
  fi
  if [[ -e "$ignore_yaml" ]]; then
    present="${present:+${present} and }${ignore_yaml}"
    parsed=$(parse_ignore_yaml "$ignore_yaml") || return 2
    if [[ -n "$parsed" ]]; then
      entries+=$(awk -F'\t' -v OFS='\t' -v src="$ignore_yaml" '{ print $1, $2, src }' <<< "$parsed")$'\n'
    fi
  fi

  # R1
  if [[ -z "$present" ]]; then
    trc_notice "No ${ignore} or ${ignore_yaml} found — nothing suppressed, nothing to check."
    return 0
  fi

  # R2
  local ids
  ids=$(awk -F'\t' '$1 != "" && !seen[$1]++ { print $1 }' <<< "$entries")
  if [[ -z "$ids" ]]; then
    trc_notice "${present} present but listing no advisory IDs — nothing suppressed, nothing to check."
    return 0
  fi
  local n_ids
  n_ids=$(awk 'END { print NR }' <<< "$ids")

  local failures=0

  # R5 — every occurrence, not just the deduped ID: the expiry is per line.
  local id expiry src
  while IFS=$'\t' read -r id expiry src; do
    [[ -n "$id" ]] || continue
    if [[ "$expiry" != "-" && "$expiry" < "$today" ]]; then
      trc_error "Expired suppression still present: '${id}' expired ${expiry} (today is ${today}) in ${src}. Trivy already ignores an expired entry, so the line is dead and its register entry is now misleading — remove both, or renew with a new expiry and a new re-validate date."
      failures=$((failures + 1))
    fi
  done <<< "$entries"

  # R4
  if [[ ! -e "$register" ]]; then
    trc_error "Register ${register} not found, but ${n_ids} advisory ID(s) are suppressed in ${present}. Create it (healthcare-iac's docs/security/image-scan-exceptions.md is the format reference) and add an ISE-NNN entry per suppressed advisory — iac#2641."
    while read -r id; do
      [[ -n "$id" ]] || continue
      trc_error "Suppressed advisory '${id}' has no ISE-NNN entry in ${register}. Every .trivyignore entry needs a register entry (iac#2641) — see the register's \"Entry format\" section."
    done <<< "$ids"
    return 1
  fi

  # R7 / R8
  local reg
  reg=$(parse_register "$register") || return 2

  # R3 / R6
  local matches ise adv reval
  while read -r id; do
    [[ -n "$id" ]] || continue
    matches=$(awk -F'\t' -v id="$id" '$2 == id' <<< "$reg")
    if [[ -z "$matches" ]]; then
      trc_error "Suppressed advisory '${id}' has no ISE-NNN entry in ${register}. Every .trivyignore entry needs a register entry (iac#2641) — see the register's \"Entry format\" section."
      failures=$((failures + 1))
      continue
    fi
    while IFS=$'\t' read -r ise adv reval; do
      [[ -n "$ise" ]] || continue
      trc_notice "documented: '${id}' → ${ise} (re-validate by ${reval})"
      if [[ "$reval" < "$today" ]]; then
        trc_warning "${ise} for '${id}' is past its re-validate-by date (${reval}, today is ${today}) — re-validate the suppression and update the register, or retire both the .trivyignore line and the entry."
      fi
    done <<< "$matches"
  done <<< "$ids"

  if ((failures > 0)); then
    trc_error "${failures} problem(s) with suppressed image findings — see the errors above. Register: ${register}."
    return 1
  fi
  trc_notice "All ${n_ids} suppressed advisory ID(s) are documented in ${register}."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  check_trivyignore_register "$@"
fi
