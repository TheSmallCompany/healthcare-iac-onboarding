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

# ── Failure modes ────────────────────────────────────────────────────

@test "F58-pt3 assert: empty role-arn (env=dev) → exit 1 + AWS_ROLE_ARN_DEV-named empty error" {
  source "$LIB"
  run assert_role_arn "dev" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"AWS_ROLE_ARN_DEV repo variable is empty"* ]]
  [[ "$output" == *"Settings → Secrets and variables → Actions → Variables → Repository variables"* ]]
  [[ "$output" == *'arn:aws:iam::<account>:role/hiac-<customer>-dev-deploy'* ]]
}

@test "F58-pt3 assert: whitespace-only role-arn (env=staging) → exit 1 + AWS_ROLE_ARN_STAGING-named empty error" {
  source "$LIB"
  run assert_role_arn "staging" "   "
  [ "$status" -ne 0 ]
  [[ "$output" == *"AWS_ROLE_ARN_STAGING repo variable is empty"* ]]
  [[ "$output" == *"Settings → Secrets and variables → Actions → Variables → Repository variables"* ]]
  [[ "$output" == *'arn:aws:iam::<account>:role/hiac-<customer>-staging-deploy'* ]]
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
