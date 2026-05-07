#!/usr/bin/env bash
# mint-oidc-jwt.sh — Mint a GitHub Actions OIDC JWT for the maintainer status endpoint.
#
# F74 helper. Sourced by both action.yml's "Query status endpoint" step
# and __tests__/action.bats. Each of the four failure modes the previous
# inline curl block silently swallowed now produces a distinct ::error::
# line we can read from the workflow log.
#
# Inputs (env, set automatically by GitHub Actions when the calling
# workflow grants `permissions: id-token: write`):
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN — bearer for the OIDC mint endpoint
#   ACTIONS_ID_TOKEN_REQUEST_URL   — pre-signed URL with `?...` ready for &audience=
#
# Inputs (positional):
#   $1 — audience (e.g., https://github.com/TheSmallCompany/healthcare-iac)
#
# Outputs:
#   stdout — the JWT (single line) on success
#   stderr — workflow commands: ::notice::, ::error::, ::add-mask::
#
# Exit:
#   0 on success, 1 on any failure mode

mint_oidc_jwt() {
  local audience="$1"

  # 1. Env presence — log positively even on success (diagnostic-positive)
  local token_state url_state
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] && token_state="set" || token_state="MISSING"
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}"   ] && url_state="set"   || url_state="MISSING"
  echo "::notice::OIDC env: ACTIONS_ID_TOKEN_REQUEST_TOKEN=${token_state}, ACTIONS_ID_TOKEN_REQUEST_URL=${url_state}" >&2

  if [[ "$token_state" == "MISSING" || "$url_state" == "MISSING" ]]; then
    echo "::error::ACTIONS_ID_TOKEN_REQUEST_TOKEN/ACTIONS_ID_TOKEN_REQUEST_URL not set (token=${token_state}, url=${url_state}). The calling workflow needs 'permissions: id-token: write' at job (or workflow) level." >&2
    return 1
  fi

  # 2. Mint via GitHub OIDC. -w '\n%{http_code}' lets us split body from
  # status without a tempfile — last line is the code, everything else is body.
  local response rc http_code body
  response=$(curl -sS -w '\n%{http_code}' \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}")
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "::error::curl failed to reach GitHub OIDC endpoint (curl exit code: $rc)" >&2
    return 1
  fi

  http_code=$(printf '%s' "$response" | tail -n1)
  body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    local snippet="${body:0:500}"
    echo "::error::GitHub OIDC returned HTTP ${http_code}. Body snippet: ${snippet}" >&2
    return 1
  fi

  # 3. Extract .value. jq -e exits non-zero on null/missing, which is
  # what we want — that branch is the "200 but unexpected body shape" mode.
  local jwt
  jwt=$(printf '%s' "$body" | jq -er '.value' 2>/dev/null)
  rc=$?
  if [[ $rc -ne 0 || -z "$jwt" ]]; then
    local snippet="${body:0:500}"
    echo "::error::OIDC response was not JSON or missing .value field. Body snippet: ${snippet}" >&2
    return 1
  fi

  # 4. Mask BEFORE any echo that could leak the token, including the
  # length/exp diagnostic that follows.
  echo "::add-mask::$jwt" >&2

  # 5. Decode exp claim from the JWT payload (middle segment). Diagnostic
  # only — we do not verify the signature. Pad to a multiple of 4 and
  # convert URL-safe alphabet to standard before base64 -d.
  local payload_b64 payload exp
  payload_b64=$(printf '%s' "$jwt" | cut -d. -f2)
  while (( ${#payload_b64} % 4 != 0 )); do payload_b64+="="; done
  payload_b64=$(printf '%s' "$payload_b64" | tr '_-' '/+')
  payload=$(printf '%s' "$payload_b64" | base64 -d 2>/dev/null)
  exp=$(printf '%s' "$payload" | jq -r '.exp // "unknown"' 2>/dev/null)
  [[ -z "$exp" ]] && exp="unknown"

  echo "::notice::JWT minted (length=${#jwt}, exp=${exp})" >&2
  printf '%s\n' "$jwt"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  mint_oidc_jwt "$@"
fi
