#!/usr/bin/env bash
# validate-environment.sh — F58 part 2.
#
# Validates the `environment` action input against a strict allowlist
# (dev|staging|prod, case-sensitive). Case statement, not regex —
# regex on a 3-element allowlist obscures intent. If we ever expand
# environments, that's a deliberate change here.

validate_environment() {
  local val="$1"

  if [[ -z "$val" ]]; then
    echo "::error::environment is required" >&2
    return 1
  fi

  case "$val" in
    dev|staging|prod)
      echo "::notice::environment '$val' validated" >&2
      return 0
      ;;
    *)
      echo "::error::environment '$val' is not one of: dev|staging|prod" >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  validate_environment "$@"
fi
