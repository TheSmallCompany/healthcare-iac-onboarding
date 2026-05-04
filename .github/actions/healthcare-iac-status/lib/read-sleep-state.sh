#!/usr/bin/env bash
# read-sleep-state.sh — Resolve the consumer's sleep-state for an env.
#
# ADR-47 P6 / D9 helper used by the `healthcare-iac-status` composite
# action's `Read sleep-state SSM parameter` step. Extracted so bats can
# test the decision logic with a mocked `aws` CLI; action.yml sources
# this and calls `read_sleep_state` (no inline duplication).
#
# Inputs (via positional args):
#   $1 — aws-role-arn (string; empty means "skip the AWS call")
#   $2 — environment (dev|staging|prod)
#   $3 — aws-region (default us-east-1)
#
# Behavior — fail-open (per D9, the primary readiness gate is `status`):
#   - empty role-arn       → echo "unknown", rc 0
#   - aws CLI failure      → echo "unknown", rc 0 (and ::warning::)
#   - unexpected value     → echo "unknown", rc 0 (and ::warning::)
#   - awake|light|deep     → echo the value, rc 0
#
# Exit code is always 0 unless this script itself crashes — the consumer
# pipeline's `sleep-gate` job decides what to do with the value.

set +e # explicit: never exit non-zero on AWS-side problems

read_sleep_state() {
  local role_arn="$1"
  local env="$2"
  local region="${3:-us-east-1}"
  local param_name="/healthcare/${env}/sleep-state"

  if [[ -z "$role_arn" ]]; then
    echo "::notice::aws-role-arn not provided; sleep-state output will be 'unknown'" >&2
    echo "unknown"
    return 0
  fi

  local value rc
  value=$(aws ssm get-parameter \
    --name "$param_name" \
    --region "$region" \
    --query 'Parameter.Value' \
    --output text 2>&1)
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "::warning::aws ssm get-parameter --name $param_name failed (rc=$rc); emitting sleep-state=unknown" >&2
    echo "unknown"
    return 0
  fi

  case "$value" in
    awake | light-sleep | deep-sleep)
      echo "::notice::sleep-state for $env: $value" >&2
      echo "$value"
      ;;
    *)
      echo "::warning::unexpected sleep-state value '$value' from SSM; emitting unknown" >&2
      echo "unknown"
      ;;
  esac
  return 0
}

# When invoked as a script (not sourced), call the function with $@.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  read_sleep_state "$@"
fi
