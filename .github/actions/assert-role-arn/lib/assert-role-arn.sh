#!/usr/bin/env bash
# assert-role-arn.sh — F58 part 3.
#
# Pre-flight assertion that the AWS_ROLE_ARN_<ENV> repo variable is set
# and looks like an IAM role ARN. Used by the consumer-pipeline
# template's three env jobs to fail fast at the right step with a
# workflow-local error naming the variable + remediation location,
# instead of letting an empty value fall through to
# configure-aws-credentials@v5's generic "Could not load credentials".
#
# Inputs (positional):
#   $1 — env (dev|staging|prod)
#   $2 — the role-ARN value to assert
#
# Exit:
#   0 if valid, 1 on any failure mode

assert_role_arn() {
  local env="$1"
  local role_arn="$2"
  local upper_env
  upper_env=$(echo "$env" | tr '[:lower:]' '[:upper:]')
  local var_name="AWS_ROLE_ARN_${upper_env}"

  # Treat whitespace-only as empty — a customer who copy-pasted "  " or
  # left the variable visually-set-but-empty is the same failure shape.
  local trimmed
  trimmed=$(echo "$role_arn" | tr -d '[:space:]')

  if [[ -z "$trimmed" ]]; then
    echo "::error::${var_name} repo variable is empty. Set it under Settings → Secrets and variables → Actions → Variables → Repository variables. ARN format: arn:aws:iam::<account>:role/hiac-<customer>-${env}-deploy" >&2
    return 1
  fi

  if [[ ! "$role_arn" =~ ^arn:aws:iam:: ]]; then
    echo "::error::${var_name} does not look like an IAM role ARN: '${role_arn}'. Expected: arn:aws:iam::<account>:role/<name>" >&2
    return 1
  fi

  echo "::notice::${var_name} validated" >&2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  assert_role_arn "$@"
fi
