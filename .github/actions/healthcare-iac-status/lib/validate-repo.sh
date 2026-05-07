#!/usr/bin/env bash
# validate-repo.sh — F58 part 2.
#
# Validates the GitHub repo name segment derived from GITHUB_REPOSITORY.
# Regex `^[a-zA-Z0-9._-]{1,100}$` plus explicit reject of "." and ".."
# (reserved per GitHub). Reserved-name check produces a distinct
# ::error:: from regex-mismatch — both "." and ".." would pass the
# regex (one period, two periods both fit the char class and length),
# so we have to special-case them.

validate_repo() {
  local val="$1"
  local re='^[a-zA-Z0-9._-]{1,100}$'

  if [[ -z "$val" ]]; then
    echo "::error::repo is required" >&2
    return 1
  fi

  if [[ "$val" == "." || "$val" == ".." ]]; then
    echo "::error::repo name '$val' is reserved by GitHub" >&2
    return 1
  fi

  if [[ ! "$val" =~ $re ]]; then
    echo "::error::repo '$val' does not match required regex $re" >&2
    return 1
  fi

  echo "::notice::repo '$val' validated" >&2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  validate_repo "$@"
fi
