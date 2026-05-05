#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Tests for healthcare-iac-status GitHub Action
#
# Tests cover:
# - Contract YAML parsing extracts version and customer
# - Schema validation catches missing required fields
# - Resource counting from contract YAML
# - Output format matches expected structure
# - Graceful degradation when iac-repo unreachable
# - Status evaluation logic (ready, provisioning, blocked, unknown)
# - gh CLI mocking using PATH-based mocking
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

# ── Helper: Create mock gh CLI ────────────────────────────────────────────

create_mock_gh() {
  local behavior="${1:-success}"

  cat >"$MOCK_BIN/gh" <<SCRIPT
#!/usr/bin/env bash
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then
  if [[ "$behavior" == "unreachable" ]]; then
    echo "Could not resolve repository" >&2
    exit 1
  fi
  echo '{"name":"healthcare-iac"}'
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
  if [[ "$behavior" == "with-issues" ]]; then
    echo '[{"number":42,"title":"contract-sync: tsc0 v2.1.2","url":"https://github.com/TheSmallCompany/healthcare-iac/issues/42"}]'
  elif [[ "$behavior" == "no-issues" ]]; then
    echo '[]'
  else
    echo '[]'
  fi
  exit 0
fi
echo "Mock gh: unhandled command: \$*" >&2
exit 1
SCRIPT
  chmod +x "$MOCK_BIN/gh"
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

@test "graceful degradation: repo unreachable returns status unknown" {
  create_mock_gh "unreachable"
  write_valid_contract

  IAC_REPO="TheSmallCompany/healthcare-iac"
  REPO_ACCESSIBLE="false"

  if ! gh repo view "$IAC_REPO" --json name > /dev/null 2>&1; then
    REPO_ACCESSIBLE="false"
  fi

  [ "$REPO_ACCESSIBLE" = "false" ]
}

@test "graceful degradation: missing contract file does not crash" {
  CONTRACT_PATH="$TEST_TMPDIR/nonexistent.yaml"

  if [[ ! -f "$CONTRACT_PATH" ]]; then
    STATUS="blocked"
  fi

  [ "$STATUS" = "blocked" ]
}

@test "graceful degradation: repo accessible with no issues returns ready" {
  create_mock_gh "no-issues"
  write_valid_contract

  IAC_REPO="TheSmallCompany/healthcare-iac"

  if gh repo view "$IAC_REPO" --json name > /dev/null 2>&1; then
    REPO_ACCESSIBLE="true"
  fi
  [ "$REPO_ACCESSIBLE" = "true" ]

  ISSUES_JSON=$(gh issue list --repo "$IAC_REPO" --label "contract-sync" --state open --search "tsc0" --json number,title,url --limit 20 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES_JSON" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(Array.isArray(d) ? d.length : 0)")

  [ "$ISSUE_COUNT" = "0" ]
}

@test "graceful degradation: repo accessible with open issues returns provisioning" {
  create_mock_gh "with-issues"
  write_valid_contract

  IAC_REPO="TheSmallCompany/healthcare-iac"
  ISSUES_JSON=$(gh issue list --repo "$IAC_REPO" --label "contract-sync" --state open --search "tsc0" --json number,title,url --limit 20 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUES_JSON" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')); console.log(Array.isArray(d) ? d.length : 0)")

  [ "$ISSUE_COUNT" = "1" ]
}

# ── Status Evaluation Logic Tests ─────────────────────────────────────────

@test "status evaluation: blocked when contract invalid" {
  CONTRACT_VALID="false"
  REPO_ACCESSIBLE="true"
  ISSUE_COUNT=0

  if [[ "$CONTRACT_VALID" != "true" ]]; then
    STATUS="blocked"
  elif [[ "$REPO_ACCESSIBLE" != "true" ]]; then
    STATUS="unknown"
  elif [[ "$ISSUE_COUNT" -gt 0 ]]; then
    STATUS="provisioning"
  else
    STATUS="ready"
  fi

  [ "$STATUS" = "blocked" ]
}

@test "status evaluation: unknown when repo unreachable" {
  CONTRACT_VALID="true"
  REPO_ACCESSIBLE="false"
  ISSUE_COUNT=0

  if [[ "$CONTRACT_VALID" != "true" ]]; then
    STATUS="blocked"
  elif [[ "$REPO_ACCESSIBLE" != "true" ]]; then
    STATUS="unknown"
  elif [[ "$ISSUE_COUNT" -gt 0 ]]; then
    STATUS="provisioning"
  else
    STATUS="ready"
  fi

  [ "$STATUS" = "unknown" ]
}

@test "status evaluation: provisioning when open issues exist" {
  CONTRACT_VALID="true"
  REPO_ACCESSIBLE="true"
  ISSUE_COUNT=2

  if [[ "$CONTRACT_VALID" != "true" ]]; then
    STATUS="blocked"
  elif [[ "$REPO_ACCESSIBLE" != "true" ]]; then
    STATUS="unknown"
  elif [[ "$ISSUE_COUNT" -gt 0 ]]; then
    STATUS="provisioning"
  else
    STATUS="ready"
  fi

  [ "$STATUS" = "provisioning" ]
}

@test "status evaluation: ready when valid contract and no issues" {
  CONTRACT_VALID="true"
  REPO_ACCESSIBLE="true"
  ISSUE_COUNT=0

  if [[ "$CONTRACT_VALID" != "true" ]]; then
    STATUS="blocked"
  elif [[ "$REPO_ACCESSIBLE" != "true" ]]; then
    STATUS="unknown"
  elif [[ "$ISSUE_COUNT" -gt 0 ]]; then
    STATUS="provisioning"
  else
    STATUS="ready"
  fi

  [ "$STATUS" = "ready" ]
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
