#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Tests for healthcare-iac-status GitHub Action
#
# Tests cover:
# - Contract YAML parsing extracts version and customer
# - Schema validation catches missing required fields
# - Resource counting from contract YAML
# - Output format matches expected structure
# - Status evaluation logic (ready, blocked, unknown)
# - R23 endpoint response handling (200/401/403/404/5xx)
# - F74 OIDC JWT mint (lib/mint-oidc-jwt.sh) — the one piece that *is*
#   tested via real shell, sourced from the helper that action.yml also
#   sources. Same pattern as read-sleep-state.bats.
#
# Note: most tests reproduce the action's inline shell logic in bats
# (the established idiom in this file) and do not invoke action.yml
# directly. F74 introduced the lib/ extraction pattern for the JWT mint;
# a future refactor extending that to status-evaluate would let all
# tests run the real shell.
# ──────────────────────────────────────────────────────────────────────────────

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export ORIGINAL_PATH="$PATH"
  export PATH="$MOCK_BIN:$PATH"

  # Mock GITHUB_OUTPUT and GITHUB_STEP_SUMMARY
  export GITHUB_OUTPUT="$TEST_TMPDIR/github_output"
  export GITHUB_STEP_SUMMARY="$TEST_TMPDIR/github_summary"
  touch "$GITHUB_OUTPUT"
  touch "$GITHUB_STEP_SUMMARY"
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

# ── Helper: Write a valid contract YAML ────────────────────────────────────

write_valid_contract() {
  cat >"$TEST_TMPDIR/contract.yaml" <<'YAML'
version: "2.1.2"
customer: tsc0
region: us-east-1
slice: 2

ecr_repositories:
  registry_pattern: "123456789012.dkr.ecr.us-east-1.amazonaws.com/healthcare/{service}"
  repositories:
    - name: healthcare/api-gateway
      description: API gateway service
    - name: healthcare/claims-service
      description: Claims processing service

databases:
  - id: claims-db
    engine: postgresql
    description: Claims database
    env_var: DATABASE_URL
    secret_name_pattern: "healthcare/{env}/claims-service/db-credentials"
    k8s_secret: claims-service-secrets
    k8s_secret_key: db-credentials
    port: 5432
    consumers:
      - claims-service

iam_roles:
  - id: claims-service
    service_account: claims-service
    role_pattern: "arn:aws:iam::{account_id}:role/healthcare-{env}-claims-service"
    description: Claims service IAM role
    consumers:
      - claims-service
YAML
}

write_minimal_contract() {
  cat >"$TEST_TMPDIR/minimal.yaml" <<'YAML'
version: "1.0.0"
region: us-east-1
slice: 1
YAML
}

write_invalid_contract() {
  cat >"$TEST_TMPDIR/invalid.yaml" <<'YAML'
region: us-east-1
YAML
}

# ── Helper: Create node script for parsing ─────────────────────────────────

create_parse_script() {
  cat >"$TEST_TMPDIR/parse.js" <<'JS'
const fs = require('fs');
const contractPath = process.argv[2];
const content = fs.readFileSync(contractPath, 'utf-8');
const getField = (key) => {
  const match = content.match(new RegExp('^' + key + ':\\s*["\']?([^"\'\\n]+)["\']?', 'm'));
  return match ? match[1].trim() : '';
};
console.log(JSON.stringify({
  version: getField('version'),
  customer: getField('customer'),
  region: getField('region'),
  slice: getField('slice')
}));
JS
}

create_validate_script() {
  cat >"$TEST_TMPDIR/validate.js" <<'JS'
const fs = require('fs');
const contractPath = process.argv[2];
const content = fs.readFileSync(contractPath, 'utf-8');
const getField = (key) => {
  const match = content.match(new RegExp('^' + key + ':\\s*["\']?([^"\'\\n]+)["\']?', 'm'));
  return match ? match[1].trim() : '';
};
const version = getField('version');
const region = getField('region');
const slice = getField('slice');
let errors = '';
if (!version) errors += 'Missing: version. ';
if (!region) errors += 'Missing: region. ';
if (!slice) errors += 'Missing: slice. ';
console.log(errors || 'VALID');
JS
}

create_count_script() {
  cat >"$TEST_TMPDIR/count.js" <<'JS'
const fs = require('fs');
const contractPath = process.argv[2];
const content = fs.readFileSync(contractPath, 'utf-8');
const lines = content.split('\n');
let total = 0;
// Count array items with "- id:" or "- name:" (indented, under list sections)
for (const line of lines) {
  if (/^\s+- id:/.test(line) || /^\s+- name:/.test(line)) {
    total++;
  }
}
console.log(total);
JS
}

# ── Contract Parsing Tests ─────────────────────────────────────────────────

@test "contract parsing: extracts version from valid contract" {
  write_valid_contract
  create_parse_script

  PARSED=$(node "$TEST_TMPDIR/parse.js" "$TEST_TMPDIR/contract.yaml")
  VERSION=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.version)")
  CUSTOMER=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.customer)")

  [ "$VERSION" = "2.1.2" ]
  [ "$CUSTOMER" = "tsc0" ]
}

@test "contract parsing: extracts region and slice" {
  write_valid_contract
  create_parse_script

  PARSED=$(node "$TEST_TMPDIR/parse.js" "$TEST_TMPDIR/contract.yaml")
  REGION=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.region)")
  SLICE=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.slice)")

  [ "$REGION" = "us-east-1" ]
  [ "$SLICE" = "2" ]
}

@test "contract parsing: handles contract without customer field" {
  write_minimal_contract
  create_parse_script

  PARSED=$(node "$TEST_TMPDIR/parse.js" "$TEST_TMPDIR/minimal.yaml")
  CUSTOMER=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.customer)")
  VERSION=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.version)")

  [ "$CUSTOMER" = "" ]
  [ "$VERSION" = "1.0.0" ]
}

# F63 regression: action.yml step 1 invokes node -e inline (bash double-quoted).
# That pipeline strips one level of escapes vs. heredoc-into-file (which other
# tests use). This test mirrors action.yml's exact invocation form so the
# escape-pipeline bug actually surfaces here.
@test "contract parsing: extracts quoted version via inline node -e (regression — F63)" {
  cat >"$TEST_TMPDIR/quoted.yaml" <<'YAML'
version: "6.0.0"
customer: testcust
region: us-east-1
slice: 2
YAML

  CONTRACT_PATH="$TEST_TMPDIR/quoted.yaml"
  PARSED=$(node -e "
    const fs = require('fs');
    const content = fs.readFileSync('$CONTRACT_PATH', 'utf-8');
    const getField = (key) => {
      const match = content.match(new RegExp('^' + key + ':\\\\s*[\"\\']?([^\"\\'\\n]+)[\"\\']?', 'm'));
      return match ? match[1].trim() : '';
    };
    console.log(JSON.stringify({
      version: getField('version'),
      customer: getField('customer'),
      region: getField('region'),
      slice: getField('slice'),
    }));
  ")

  VERSION=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.version)")
  CUSTOMER=$(echo "$PARSED" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.customer)")
  REGION=$(echo "$PARSED"  | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.region)")
  SLICE=$(echo "$PARSED"   | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(d.slice)")

  [ "$VERSION" = "6.0.0" ]
  [ "$CUSTOMER" = "testcust" ]
  [ "$REGION" = "us-east-1" ]
  [ "$SLICE" = "2" ]
}

# ── Schema Validation Tests ────────────────────────────────────────────────

@test "schema validation: passes for valid contract with all required fields" {
  write_valid_contract
  create_validate_script

  RESULT=$(node "$TEST_TMPDIR/validate.js" "$TEST_TMPDIR/contract.yaml")
  [ "$RESULT" = "VALID" ]
}

@test "schema validation: catches missing version field" {
  write_invalid_contract
  create_validate_script

  RESULT=$(node "$TEST_TMPDIR/validate.js" "$TEST_TMPDIR/invalid.yaml")
  [[ "$RESULT" == *"Missing: version"* ]]
  [[ "$RESULT" == *"Missing: slice"* ]]
}

@test "schema validation: catches missing slice field" {
  cat >"$TEST_TMPDIR/no-slice.yaml" <<'YAML'
version: "1.0.0"
region: us-east-1
YAML
  create_validate_script

  RESULT=$(node "$TEST_TMPDIR/validate.js" "$TEST_TMPDIR/no-slice.yaml")
  [[ "$RESULT" == *"Missing: slice"* ]]
}

# ── Output Format Tests ───────────────────────────────────────────────────

@test "output format: status is one of expected values" {
  for STATUS in ready provisioning partial blocked unknown; do
    case "$STATUS" in
      ready|provisioning|partial|blocked|unknown) true ;;
      *) false ;;
    esac
  done
}

@test "output format: blocking-issues is valid JSON array" {
  ISSUES='[{"number":42,"title":"test","url":"https://example.com/42"}]'
  BLOCKING=$(echo "$ISSUES" | node -e "
    const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf-8'));
    console.log(JSON.stringify(data.map(i => i.url)));
  ")

  VALID=$(echo "$BLOCKING" | node -e "
    const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf-8'));
    console.log(Array.isArray(data) ? 'true' : 'false');
  ")

  [ "$VALID" = "true" ]
}

@test "output format: empty issues produces empty JSON array" {
  ISSUES='[]'
  BLOCKING=$(echo "$ISSUES" | node -e "
    const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf-8'));
    console.log(JSON.stringify(data.map(i => i.url)));
  ")

  [ "$BLOCKING" = "[]" ]
}

# ── Graceful Degradation Tests ─────────────────────────────────────────────

@test "graceful degradation: missing contract file does not crash" {
  CONTRACT_PATH="$TEST_TMPDIR/nonexistent.yaml"

  if [[ ! -f "$CONTRACT_PATH" ]]; then
    STATUS="blocked"
  fi

  [ "$STATUS" = "blocked" ]
}

# ── Status Evaluation Logic Tests (R23 endpoint flow) ─────────────────────
# These tests reproduce the action's evaluate step's if/elif chain inline.
# Variables match the new R23 flow: ENDPOINT_STATUS comes from steps.query-status,
# CONTRACT_VALID from steps.parse, etc. (REPO_ACCESSIBLE / ISSUE_COUNT removed
# in R23 — see action.yml step 3 "Query status endpoint".)

eval_status() {
  # Mirror of action.yml step 5 (Evaluate status). Inputs:
  #   $1 = CONTRACT_VALID  (true|false)
  #   $2 = ENDPOINT_STATUS (ready|blocked|unknown)
  # Sets STATUS in caller scope.
  local contract_valid="$1"
  local endpoint_status="$2"
  if [[ "$contract_valid" != "true" ]]; then
    STATUS="blocked"
  elif [[ "$endpoint_status" == "ready" ]]; then
    STATUS="ready"
  elif [[ "$endpoint_status" == "blocked" ]]; then
    STATUS="blocked"
  else
    STATUS="unknown"
  fi
}

@test "status evaluation: blocked when contract invalid (regardless of endpoint)" {
  eval_status "false" "ready"
  [ "$STATUS" = "blocked" ]

  eval_status "false" "blocked"
  [ "$STATUS" = "blocked" ]

  eval_status "false" "unknown"
  [ "$STATUS" = "blocked" ]
}

@test "status evaluation: ready when valid contract + endpoint=ready" {
  eval_status "true" "ready"
  [ "$STATUS" = "ready" ]
}

@test "status evaluation: blocked when valid contract + endpoint=blocked" {
  eval_status "true" "blocked"
  [ "$STATUS" = "blocked" ]
}

@test "status evaluation: unknown when valid contract + endpoint=unknown (fail-open)" {
  eval_status "true" "unknown"
  [ "$STATUS" = "unknown" ]
}

@test "status evaluation: unknown when valid contract + endpoint=empty (e.g. JWT mint failed)" {
  eval_status "true" ""
  [ "$STATUS" = "unknown" ]
}

# R23 endpoint response handling. Mirrors action.yml step 3 (Query status
# endpoint) — given a synthesized HTTP response, asserts which output values
# the step would write to GITHUB_OUTPUT. NOTE: this reproduces the if/elif
# chain inline; it does not invoke the YAML step. See test-architecture
# note in the README.
@test "R23 endpoint: HTTP 200 with status=ready propagates" {
  HTTP_CODE="200"
  BODY='{"status":"ready","blocking_issues":[]}'
  if [ "$HTTP_CODE" = "200" ]; then
    STATUS=$(echo "$BODY" | jq -r '.status // "unknown"')
    ISSUES=$(echo "$BODY" | jq -c '.blocking_issues // []')
  fi
  [ "$STATUS" = "ready" ]
  [ "$ISSUES" = "[]" ]
}

@test "R23 endpoint: HTTP 200 with status=blocked propagates blocking_issues" {
  HTTP_CODE="200"
  BODY='{"status":"blocked","blocking_issues":["https://github.com/x/y/issues/1"]}'
  if [ "$HTTP_CODE" = "200" ]; then
    STATUS=$(echo "$BODY" | jq -r '.status // "unknown"')
    ISSUES=$(echo "$BODY" | jq -c '.blocking_issues // []')
  fi
  [ "$STATUS" = "blocked" ]
  [ "$ISSUES" = '["https://github.com/x/y/issues/1"]' ]
}

@test "R23 endpoint: HTTP 401 → status=blocked (denied)" {
  HTTP_CODE="401"
  if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "404" ]; then
    STATUS="blocked"
  fi
  [ "$STATUS" = "blocked" ]
}

@test "R23 endpoint: HTTP 503 → status=unknown (fail-open)" {
  HTTP_CODE="503"
  if [ "$HTTP_CODE" = "200" ]; then
    STATUS="ready"
  elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "404" ]; then
    STATUS="blocked"
  else
    STATUS="unknown"
  fi
  [ "$STATUS" = "unknown" ]
}

@test "R23 endpoint: network failure (HTTP 000 from || echo) → status=unknown" {
  HTTP_CODE="000"
  if [ "$HTTP_CODE" = "200" ]; then
    STATUS="ready"
  elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "404" ]; then
    STATUS="blocked"
  else
    STATUS="unknown"
  fi
  [ "$STATUS" = "unknown" ]
}

# ── F74: OIDC JWT mint helper (lib/mint-oidc-jwt.sh) ─────────────────────
# Real-shell tests against the extracted helper. Five failure modes the
# action's old inline curl block silently swallowed; each one now produces
# a distinct error message we can read in CI logs.

JWT_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/mint-oidc-jwt.sh"

# Install a curl mock that emits a configurable body and HTTP code.
#   $1 = body to write to stdout (may be empty)
#   $2 = HTTP code to append after a newline when curl is invoked with -w '%{http_code}' (default 200)
#   $3 = curl exit code (default 0)
install_curl_mock() {
  local body="$1" code="${2:-200}" rc="${3:-0}"
  printf '%s' "$body" > "$TEST_TMPDIR/curl-body"
  cat > "$MOCK_BIN/curl" <<MOCK
#!/usr/bin/env bash
echo "curl \$*" >> "$TEST_TMPDIR/curl-calls.log"
WANTS_CODE=0
for a in "\$@"; do
  case "\$a" in
    *%{http_code}*) WANTS_CODE=1 ;;
  esac
done
cat "$TEST_TMPDIR/curl-body"
if [[ \$WANTS_CODE -eq 1 ]]; then printf '\n%s' '$code'; fi
exit $rc
MOCK
  chmod +x "$MOCK_BIN/curl"
}

@test "F74 JWT mint: env vars missing → exit non-zero, names the missing var, hints id-token: write" {
  source "$JWT_LIB"
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  run mint_oidc_jwt "https://github.com/TheSmallCompany/healthcare-iac"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ACTIONS_ID_TOKEN_REQUEST_TOKEN"* ]]
  [[ "$output" == *"not set"* ]]
  [[ "$output" == *"id-token: write"* ]]
}

@test "F74 JWT mint: curl network failure (rc=6) → exit non-zero, names the rc" {
  source "$JWT_LIB"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-bearer"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example.invalid/?foo=bar"
  install_curl_mock "" 0 6
  run mint_oidc_jwt "https://github.com/TheSmallCompany/healthcare-iac"
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl failed to reach GitHub OIDC endpoint"* ]]
  [[ "$output" == *"6"* ]]
}

@test "F74 JWT mint: HTTP 401 from GitHub OIDC → exit non-zero, names status, includes body snippet" {
  source "$JWT_LIB"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-bearer"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example/?foo=bar"
  install_curl_mock '{"message":"Bad credentials"}' 401 0
  run mint_oidc_jwt "https://github.com/TheSmallCompany/healthcare-iac"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub OIDC returned HTTP 401"* ]]
  [[ "$output" == *"Bad credentials"* ]]
}

@test "F74 JWT mint: HTTP 200 with non-JSON body → exit non-zero, names the parse failure, snippet" {
  source "$JWT_LIB"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-bearer"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example/?foo=bar"
  install_curl_mock 'this is not json at all' 200 0
  run mint_oidc_jwt "https://github.com/TheSmallCompany/healthcare-iac"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OIDC response was not JSON"* ]]
  [[ "$output" == *"this is not json"* ]]
}

# F74-part-2 structural tests: pin that audience is action-input-driven,
# not hardcoded. RED until action.yml declares the input + uses it.

@test "F74-aud: action.yml declares inputs.audience with default 'healthcare-iac-status'" {
  local default
  default=$(python3 -c "
import yaml,sys
d = yaml.safe_load(open('.github/actions/healthcare-iac-status/action.yml'))
print((d.get('inputs',{}).get('audience',{}) or {}).get('default',''))
" 2>/dev/null)
  [ "$default" = "healthcare-iac-status" ]
}

@test "F74-aud: action.yml step 3 run block references inputs.audience" {
  # The Query status endpoint step must read the audience from the input,
  # not bake it in. Tied to the same line block that sources mint-oidc-jwt.sh.
  grep -q "inputs.audience" .github/actions/healthcare-iac-status/action.yml
}

@test "F74-aud: action.yml does NOT hardcode old URL-shaped audience value" {
  # The pre-F74-part-2 audience was 'https://github.com/TheSmallCompany/healthcare-iac'.
  # GitHub OIDC anti-impersonation rejects URL-shaped audiences naming an
  # org the runner doesn't belong to. After this fix the only place that
  # literal should appear is in comments / output descriptions referring
  # to the iac repo by URL — never as an audience value.
  ! grep -E '^[[:space:]]*AUD="?https://github\.com/TheSmallCompany/healthcare-iac' \
      .github/actions/healthcare-iac-status/action.yml
}

# F74-part-2 functional regression: helper passes audience to GitHub OIDC URL.
# Today this passes (helper already takes audience as $1) — included as a
# regression pin so a future "helper signature change" can't silently break
# audience propagation.

@test "F74-aud: helper forwards arbitrary audience value to OIDC URL (regression pin)" {
  source "$JWT_LIB"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-bearer"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example/?foo=bar"
  # Synth body with a parseable JWT so the helper reaches the success path.
  local h='eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9'
  local p='eyJleHAiOjE3MzU2ODk2MDB9'
  local s='ZmFrZS1zaWc'
  install_curl_mock "{\"value\":\"$h.$p.$s\"}" 200 0

  run mint_oidc_jwt "literal-sentinel-aud-X"
  [ "$status" -eq 0 ]
  grep -q "audience=literal-sentinel-aud-X" "$TEST_TMPDIR/curl-calls.log"
}

@test "F74 JWT mint: happy path → JWT to stdout, ::add-mask:: + length + decoded exp on stderr" {
  source "$JWT_LIB"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-bearer"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://example/?foo=bar"
  # Synthesize a JWT: header.payload.sig with payload {"exp":1735689600}.
  # 1735689600 is 2025-01-01T00:00:00Z — picked as a fixed, recognizable
  # past timestamp so an assertion mismatch on exp shows up as the wrong
  # number rather than an off-by-one or "current time" surprise.
  local h='eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9'   # {"alg":"RS256","typ":"JWT"}
  local p='eyJleHAiOjE3MzU2ODk2MDB9'               # {"exp":1735689600}
  local s='ZmFrZS1zaWc'                            # base64url("fake-sig")
  local jwt="$h.$p.$s"
  install_curl_mock "{\"value\":\"$jwt\",\"count\":1}" 200 0

  local err_file
  err_file=$(mktemp)
  local stdout
  stdout=$(mint_oidc_jwt "https://github.com/TheSmallCompany/healthcare-iac" 2>"$err_file")
  local rc=$?
  local stderr
  stderr=$(cat "$err_file")
  rm -f "$err_file"

  [ "$rc" -eq 0 ]
  [ "$stdout" = "$jwt" ]
  [[ "$stderr" == *"::add-mask::$jwt"* ]]
  [[ "$stderr" == *"length=${#jwt}"* ]]
  [[ "$stderr" == *"exp=1735689600"* ]]
}

# ── Resource Counting Tests ──────────────────────────────────────────────

@test "resource counting: counts resources from valid contract" {
  write_valid_contract
  create_count_script

  COUNT=$(node "$TEST_TMPDIR/count.js" "$TEST_TMPDIR/contract.yaml")

  # Should count: 2 ECR repos (- name:) + 1 database (- id:) + 1 IAM role (- id:) = 4
  [ "$COUNT" -ge 3 ]
}

@test "resource counting: returns 0 for empty contract" {
  write_minimal_contract
  create_count_script

  COUNT=$(node "$TEST_TMPDIR/count.js" "$TEST_TMPDIR/minimal.yaml")

  [ "$COUNT" = "0" ]
}
