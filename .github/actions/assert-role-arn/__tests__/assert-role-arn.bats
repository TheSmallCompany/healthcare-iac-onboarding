#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────
# Tests for assert-role-arn / lib/assert-role-arn.sh (F58 part 3).
#
# Pins the EXACT diagnostic-message literals — the diagnostic IS the
# kaizen here. A future "let me clean this up" PR that softens the
# wording must update tests, which forces a deliberate decision rather
# than silent drift.
# ──────────────────────────────────────────────────────────────────────

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/assert-role-arn.sh"
ACTION_YML="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/action.yml"

# ── Manifest-content regression (F58-pt3 hot-fix) ────────────────────
# Empirical correction: GitHub Actions runner DOES evaluate ${{ ... }}
# expressions inside composite-action manifest description fields, and
# rejects context refs not valid in composite scope (vars.*, secrets.*,
# needs.*). A description string with `${{ vars.AWS_ROLE_ARN_DEV }}` —
# meant as documentation — bricked the action's load.
#
# This test is a poor-man's, single-file manifest-context lint pinning
# the F58-pt3 fix specifically. The whole-repo manifest-lint kaizen is
# tracked separately as issue #3; that's where the real
# context-availability check will live. Until then, this regression
# catches the same class for THIS file.

@test "F58-pt3 manifest-lint: action.yml contains no GitHub-Actions expressions referencing vars.* (runner evaluates them in description fields too)" {
  ! grep -E '\$\{\{[^}]*vars\.' "$ACTION_YML"
}

# ── Failure modes ────────────────────────────────────────────────────

@test "F58-pt3 assert: empty role-arn (env=dev) → exit 1 + AWS_ROLE_ARN_DEV-named empty error" {
  source "$LIB"
  run assert_role_arn "dev" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"AWS_ROLE_ARN_DEV repo variable is empty"* ]]
  [[ "$output" == *"Settings → Secrets and variables → Actions → Variables → Repository variables"* ]]
  # ADR-056 M7 retro (hiac-demo#6): the format-hint literal previously
  # read 'hiac-<customer>-dev-deploy', but the actual platform role
  # suffix is '-github-actions'. The wrong suffix made every
  # assert-role-arn failure a wild goose chase. Pin the corrected
  # literal so the documentation matches reality.
  [[ "$output" == *'arn:aws:iam::<account>:role/hiac-<customer>-dev-github-actions'* ]]
}

@test "F58-pt3 assert: whitespace-only role-arn (env=staging) → exit 1 + AWS_ROLE_ARN_STAGING-named empty error" {
  source "$LIB"
  run assert_role_arn "staging" "   "
  [ "$status" -ne 0 ]
  [[ "$output" == *"AWS_ROLE_ARN_STAGING repo variable is empty"* ]]
  [[ "$output" == *"Settings → Secrets and variables → Actions → Variables → Repository variables"* ]]
  [[ "$output" == *'arn:aws:iam::<account>:role/hiac-<customer>-staging-github-actions'* ]]
}

# Belt-and-suspenders regression guard against the wrong-suffix literal
# reappearing. ADR-056 M7 retro found this had been wrong since the
# module was introduced and was a recurring source of confusion. The
# guard catches anyone who tries to "revert to legacy" without thinking
# it through.
@test "F58-pt3 assert: error message MUST NOT use the legacy '-deploy' suffix (ADR-056 M7 retro)" {
  source "$LIB"
  run assert_role_arn "dev" ""
  if [[ "$output" == *"-deploy"* ]]; then
    echo "Error message references the legacy '-deploy' suffix." >&2
    echo "Platform roles use '-github-actions'." >&2
    return 1
  fi
}

@test "F58-pt3 assert: non-ARN string (env=prod) → exit 1 + format-hint error (DISTINCT from empty)" {
  source "$LIB"
  run assert_role_arn "prod" "not-an-arn"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AWS_ROLE_ARN_PROD does not look like an IAM role ARN: 'not-an-arn'"* ]]
  [[ "$output" == *'Expected: arn:aws:iam::<account>:role/<name>'* ]]
  # And explicitly NOT the empty-error wording — keeps the two failure
  # axes diagnostically distinct.
  [[ "$output" != *"is empty"* ]]
}

# ── Happy paths ──────────────────────────────────────────────────────

@test "F58-pt3 assert: valid dev ARN → exit 0" {
  source "$LIB"
  run assert_role_arn "dev" "arn:aws:iam::123456789012:role/hiac-demo01-dev-deploy"
  [ "$status" -eq 0 ]
}

@test "F58-pt3 assert: valid staging ARN → exit 0" {
  source "$LIB"
  run assert_role_arn "staging" "arn:aws:iam::123456789012:role/hiac-demo01-staging-deploy"
  [ "$status" -eq 0 ]
}

@test "F58-pt3 assert: valid prod ARN → exit 0" {
  source "$LIB"
  run assert_role_arn "prod" "arn:aws:iam::123456789012:role/hiac-demo01-prod-deploy"
  [ "$status" -eq 0 ]
}
