#!/usr/bin/env bash
# validate-owner.sh — F58 part 2.
#
# Validates the GitHub owner segment derived from GITHUB_REPOSITORY_OWNER.
# Two-step: regex pass over GitHub's username/org grammar, then explicit
# negations for the cases bash =~ can't express (trailing hyphen,
# consecutive hyphens). Each failure mode produces a distinct ::error::
# so a future regression names the right axis instead of getting lumped
# into "regex mismatch".
#
# Inputs (positional):
#   $1 — owner value
#
# Exit:
#   0 if valid, 1 on any failure mode

validate_owner() {
  local val="$1"
  local re='^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$'

  if [[ -z "$val" ]]; then
    echo "::error::owner is required" >&2
    return 1
  fi

  if [[ ! "$val" =~ $re ]]; then
    echo "::error::owner '$val' does not match required regex $re" >&2
    return 1
  fi

  if [[ "$val" == *--* ]]; then
    echo "::error::owner '$val' cannot contain consecutive hyphens" >&2
    return 1
  fi

  if [[ "$val" == *- ]]; then
    echo "::error::owner '$val' cannot end with hyphen" >&2
    return 1
  fi

  echo "::notice::owner '$val' validated" >&2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  validate_owner "$@"
fi
