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

# ── D1: env-scoped vars.AWS_ROLE_ARN convention (healthcare-iac#1288) ─
# ADR-056 M7 retro decision: bot writes env-scoped `AWS_ROLE_ARN` (no
# suffix) to each GitHub Environment on /bind. The reference template
# must match the convention exactly — both for it to actually work, and
# so the convention is documented by the template itself. Pre-flight
# assertions in env jobs go away (env-scoped vars don't need them; the
# bot guarantees they're set).
#
# The status job (which runs without an env-scope by default) gets a
# job-level `environment: dev` so env-scoped vars resolve there too.
# Functionally fine — sleep-state SSM read just needs SOME OIDC role,
# any env's works.

TEMPLATE_YML="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.." && pwd)/templates/consumer-pipeline/build-and-promote.yml"
STATUS_EXAMPLE="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.." && pwd)/templates/consumer-pipeline/healthcare-iac-status.example"

@test "D1: build-and-promote.yml has zero legacy vars.AWS_ROLE_ARN_<ENV> refs" {
  ! grep -E 'vars\.AWS_ROLE_ARN_(DEV|STAGING|PROD)' "$TEMPLATE_YML"
}

@test "D1: build-and-promote.yml has exactly 4 vars.AWS_ROLE_ARN refs (1 status + 3 env jobs)" {
  # Anchor to actual ${{ }} expressions, not the literal in comments.
  local count
  count=$(grep -cE '\$\{\{[[:space:]]*vars\.AWS_ROLE_ARN([^_A-Z]|$)' "$TEMPLATE_YML")
  [ "$count" -eq 4 ]
}

@test "D1: build-and-promote.yml does not invoke assert-role-arn (pre-flight steps removed)" {
  ! grep -E 'uses:.*assert-role-arn' "$TEMPLATE_YML"
}

@test "D1: build-and-promote.yml status job declares environment: dev so env-scoped vars resolve" {
  # Scan the 'status:' job's block (until the next top-level job key) for
  # an `environment: dev` line at job-metadata indentation.
  awk '/^  status:/{f=1; next} /^  [a-z][a-zA-Z0-9_-]*:$/{f=0} f' "$TEMPLATE_YML" \
    | grep -qE '^[[:space:]]+environment:[[:space:]]+dev([[:space:]]|$|#)'
}

@test "D1: healthcare-iac-status.example uses env-scoped vars.AWS_ROLE_ARN (no legacy suffix)" {
  ! grep -E 'vars\.AWS_ROLE_ARN_(DEV|STAGING|PROD)' "$STATUS_EXAMPLE"
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
