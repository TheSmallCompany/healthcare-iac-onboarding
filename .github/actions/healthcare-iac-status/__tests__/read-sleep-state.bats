#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Tests for healthcare-iac-status / lib/read-sleep-state.sh
# (ADR-47 P6 / D9 — sleep-state read helper)
#
# Strategy: source the helper, mock `aws` on PATH, and assert on stdout
# (the value emitted) plus stderr (the ::notice/::warning lines).
# ──────────────────────────────────────────────────────────────────────────────

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/read-sleep-state.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export ORIGINAL_PATH="$PATH"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

# Install an `aws` mock that records calls and emits a configurable value+rc.
install_aws_mock() {
  local value="$1"
  local rc="${2:-0}"
  cat > "$MOCK_BIN/aws" <<EOF
#!/usr/bin/env bash
echo "aws \$*" >> "$TEST_TMPDIR/aws-calls.log"
EOF
  if [[ -n "$value" ]]; then
    echo "echo '$value'" >> "$MOCK_BIN/aws"
  fi
  echo "exit $rc" >> "$MOCK_BIN/aws"
  chmod +x "$MOCK_BIN/aws"
}

# ── Empty role-arn path ────────────────────────────────────────────────────

@test "empty role-arn → unknown, AWS not called" {
  install_aws_mock "should-not-be-called" 0
  source "$LIB"
  run read_sleep_state "" "dev" "us-east-1"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  [ ! -f "$TEST_TMPDIR/aws-calls.log" ]
}

@test "empty role-arn emits a ::notice:: explaining the skip" {
  source "$LIB"
  output=$(read_sleep_state "" "dev" "us-east-1" 2>&1 1>/dev/null)
  [[ "$output" == *"::notice::aws-role-arn not provided"* ]]
}

# ── Happy path: AWS returns a valid value ──────────────────────────────────

@test "valid awake → returns awake" {
  install_aws_mock "awake" 0
  source "$LIB"
  run read_sleep_state "arn:aws:iam::123:role/r" "dev" "us-east-1"
  [ "$status" -eq 0 ]
  [ "$output" = "awake" ]
}

@test "valid light-sleep → returns light-sleep" {
  install_aws_mock "light-sleep" 0
  source "$LIB"
  run read_sleep_state "arn:aws:iam::123:role/r" "staging" "us-east-1"
  [ "$status" -eq 0 ]
  [ "$output" = "light-sleep" ]
}

@test "valid deep-sleep → returns deep-sleep" {
  install_aws_mock "deep-sleep" 0
  source "$LIB"
  run read_sleep_state "arn:aws:iam::123:role/r" "prod" "us-east-1"
  [ "$status" -eq 0 ]
  [ "$output" = "deep-sleep" ]
}

@test "queries the canonical /healthcare/<env>/sleep-state path" {
  # The boundary policy in stacks/foundation/src/consumer-cicd/policies.ts
  # grants ssm:GetParameter only on /healthcare/<env>/sleep-state. Pin the
  # path the helper actually queries so a typo here can't silently 404 +
  # fall back to `unknown` (which would then get treated as proceed-with-
  # warning by the gate — masking the bug).
  install_aws_mock "awake" 0
  source "$LIB"
  read_sleep_state "arn:aws:iam::123:role/r" "dev" "us-east-1" >/dev/null 2>&1
  grep -q -- '--name /healthcare/dev/sleep-state' "$TEST_TMPDIR/aws-calls.log"
}

@test "passes the requested region to the AWS CLI" {
  install_aws_mock "awake" 0
  source "$LIB"
  read_sleep_state "arn:aws:iam::123:role/r" "staging" "us-west-2" >/dev/null 2>&1
  grep -q -- '--region us-west-2' "$TEST_TMPDIR/aws-calls.log"
}

# ── Fail-open paths ────────────────────────────────────────────────────────

@test "AWS call fails (rc != 0) → unknown, never propagates the error" {
  install_aws_mock "AccessDenied: not allowed" 254
  source "$LIB"
  run read_sleep_state "arn:aws:iam::123:role/r" "dev" "us-east-1"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "AWS failure emits a ::warning:: with the rc" {
  install_aws_mock "denied" 254
  source "$LIB"
  output=$(read_sleep_state "arn:aws:iam::123:role/r" "dev" "us-east-1" 2>&1 1>/dev/null)
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"rc=254"* ]]
}

@test "unexpected param value → unknown + ::warning::" {
  # Defends against a Pulumi config typo silently propagating through to
  # the consumer pipeline. Anything outside awake|light-sleep|deep-sleep
  # is treated as drift and the gate falls open to `unknown`.
  install_aws_mock "asleep" 0
  source "$LIB"
  out_stderr=$(read_sleep_state "arn:aws:iam::123:role/r" "dev" "us-east-1" 2>&1 1>/dev/null)
  out_stdout=$(read_sleep_state "arn:aws:iam::123:role/r" "dev" "us-east-1")
  [ "$out_stdout" = "unknown" ]
  [[ "$out_stderr" == *"::warning::"* ]]
  [[ "$out_stderr" == *"unexpected sleep-state value 'asleep'"* ]]
}

@test "default region is us-east-1 when third arg omitted" {
  install_aws_mock "awake" 0
  source "$LIB"
  read_sleep_state "arn:aws:iam::123:role/r" "dev" >/dev/null 2>&1
  grep -q -- '--region us-east-1' "$TEST_TMPDIR/aws-calls.log"
}

# ── CLI invocation (not sourced) ───────────────────────────────────────────

@test "invokable as a standalone script" {
  install_aws_mock "deep-sleep" 0
  # Explicitly capture stdout only (the ::notice:: goes to stderr, but
  # bats `run` collapses both streams in $output).
  result=$("$LIB" "arn:aws:iam::123:role/r" "dev" "us-east-1" 2>/dev/null)
  [ "$result" = "deep-sleep" ]
}
