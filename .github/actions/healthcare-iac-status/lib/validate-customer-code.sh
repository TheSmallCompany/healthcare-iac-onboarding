#!/usr/bin/env bash
# validate-customer-code.sh — F58.
#
# Validates the customer-code action input against the same regex
# infra-contracts uses. Sourced by action.yml Step 1, runs BEFORE
# JWT mint and URL construction so a malformed value (e.g., FI #3's
# unsubstituted '{{ .CustomerCode }}') never reaches the network and
# gets mistaken for "endpoint unreachable".
#
# Empty input is treated distinctly from regex-mismatch — it's a
# missing-input failure, not a "your value didn't match a pattern"
# failure, and the operator-facing message says so.
#
# Inputs (positional):
#   $1 — the candidate customer-code value
#
# Outputs:
#   stderr — ::error:: on failure (with value + regex), ::notice:: on success
#   stdout — none
#
# Exit:
#   0 if valid, 1 on any failure mode

validate_customer_code() {
  local val="$1"
  local re='^[a-z][a-z0-9]{2,11}$'

  if [[ -z "$val" ]]; then
    echo "::error::customer-code is required (must match regex: $re)" >&2
    return 1
  fi

  if [[ ! "$val" =~ $re ]]; then
    echo "::error::customer-code '$val' does not match required regex $re" >&2
    return 1
  fi

  echo "::notice::customer-code '$val' validated" >&2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  validate_customer_code "$@"
fi
