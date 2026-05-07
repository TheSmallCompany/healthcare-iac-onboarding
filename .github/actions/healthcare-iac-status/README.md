# healthcare-iac-status GitHub Action

Checks infrastructure readiness for a customer's infra-contract. Used by
consumer repos (e.g., `healthcare-platform`) to gate deployments on
infrastructure provisioning status.

**Reference:** [ADR-35 Section 7](../../../docs/design/infra-contract-product-interface.md)

## Inputs

| Input                 | Required | Default                                                      | Description                                                                  |
| --------------------- | -------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `customer-code`       | ✅       |                                                              | Customer code matching `^[a-z][a-z0-9]{2,11}$` (3–12 chars, lowercase letters/digits, must start with a letter). Validated at the action boundary; mismatched values fail with a specific error before any network call. |
| `contract-path`       | ✅       | `infra-contract.yaml`                                        | Path to infra-contract YAML                                                  |
| `environment`         | ✅       |                                                              | Target environment: strict allowlist `dev` \| `staging` \| `prod` (case-sensitive). Validated at the action boundary. |
| `status-endpoint-url` |          | _maintainer-deployed status endpoint_                        | Override only for testing. Caller must grant `permissions: id-token: write`. |
| `audience`            |          | `healthcare-iac-status`                                      | Audience claim minted into the OIDC JWT. Must match the platform endpoint's `EXPECTED_AUDIENCE`. Non-URL by design (GitHub OIDC rejects URL audiences that name foreign orgs — F73). |
| `iac-repo`            |          | `TheSmallCompany/healthcare-iac`                             | _Deprecated; ignored since R23 (cross-repo lookups are server-side)._        |
| `aws-role-arn`        |          | `""`                                                         | OIDC role ARN for sleep-state SSM read (P6/D9). Empty = skip.                |
| `aws-region`          |          | `us-east-1`                                                  | AWS region for sleep-state read.                                             |

## Validated runtime context

Two values are **derived** from the runtime workflow context (not configurable as inputs) and are validated at the action boundary alongside the inputs above. A failure here typically means the action ran in an unexpected context — a rare condition, but the diagnostic is precise so you can tell.

| Value   | Source                     | Constraint                                                                                     |
| ------- | -------------------------- | ---------------------------------------------------------------------------------------------- |
| `owner` | `GITHUB_REPOSITORY_OWNER`  | `^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$`, plus no consecutive hyphens and no trailing hyphen.        |
| `repo`  | `GITHUB_REPOSITORY` (suffix after `/`) | `^[a-zA-Z0-9._-]{1,100}$`, plus `.` and `..` rejected (reserved by GitHub).        |

## Outputs

| Output              | Description                       | Example                 |
| ------------------- | --------------------------------- | ----------------------- |
| `status`            | Overall readiness status          | `ready`, `blocked`      |
| `contract-version`  | Contract version being validated  | `2.1.2`                 |
| `resources-ready`   | Count of provisioned resources    | `15`                    |
| `resources-pending` | Count of pending resources        | `3`                     |
| `blocking-issues`   | JSON array of blocking issue URLs | `["https://..."]`       |
| `details`           | Full JSON validation details      | `{...}`                 |
| `sleep-state`       | `awake` / `light-sleep` / `deep-sleep` / `unknown` | `awake` |

## Status Values

| Status    | Meaning                                                                                  |
| --------- | ---------------------------------------------------------------------------------------- |
| `ready`   | Contract is valid and the maintainer status endpoint reports the customer is ready       |
| `blocked` | Contract failed validation, OR the endpoint reports blocking issues / denies the request |
| `unknown` | Endpoint unreachable, OIDC mint failed, or transient 5xx (fail-open)                     |

## Usage

### Basic Usage (same repo)

```yaml
- name: Check infrastructure readiness
  id: infra-check
  uses: ./.github/actions/healthcare-iac-status
  with:
    customer-code: tsc0
    contract-path: infra-contract.yaml
    environment: dev
```

### Cross-Repo Usage (consumer repo → healthcare-iac)

The caller workflow must grant `id-token: write` so the action can mint
the OIDC JWT it sends to the maintainer status endpoint.

```yaml
permissions:
  contents: read
  id-token: write   # required: action mints an OIDC JWT for the status endpoint

steps:
  - name: Check infrastructure readiness
    id: infra-check
    uses: TheSmallCompany/healthcare-iac-onboarding/.github/actions/healthcare-iac-status@v1
    with:
      customer-code: tsc0
      contract-path: infra-contracts/tsc0.yaml
      environment: dev
```

### Gate Deployment on Infrastructure Readiness

```yaml
jobs:
  check-infra:
    runs-on: ubuntu-latest
    outputs:
      status: ${{ steps.infra-check.outputs.status }}
    steps:
      - uses: actions/checkout@v4

      - name: Check infrastructure readiness
        id: infra-check
        uses: TheSmallCompany/healthcare-iac-onboarding/.github/actions/healthcare-iac-status@v1
        with:
          customer-code: tsc0
          contract-path: infra-contract.yaml
          environment: dev

      - name: Gate on infrastructure
        if: steps.infra-check.outputs.status != 'ready'
        run: |
          echo "::error::Infrastructure not ready for deployment"
          echo "Status: ${{ steps.infra-check.outputs.status }}"
          echo "Pending: ${{ steps.infra-check.outputs.resources-pending }} resources"
          echo "Blocking issues: ${{ steps.infra-check.outputs.blocking-issues }}"
          exit 1

  deploy:
    needs: check-infra
    if: needs.check-infra.outputs.status == 'ready'
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying — infrastructure is ready!"
```

## Graceful Degradation

The action handles failure modes without blocking deployments unnecessarily:

| Scenario                         | Behavior                                         |
| -------------------------------- | ------------------------------------------------ |
| healthcare-iac repo unreachable  | Warning logged, status: `unknown`, no failure    |
| No Pulumi outputs available      | Status: `unknown`, does not fail                 |
| Contract version mismatch        | Warning with instructions to sync                |
| GitHub App token expired/missing | Falls back to `GITHUB_TOKEN` with reduced access |
| Contract file not found          | Error logged, status: `blocked`                  |
| Contract schema validation fails | Warning logged, status: `blocked`                |

## How It Works

1. **Parse contract YAML** — Extracts `version`, `customer`, `region`, `slice` fields
2. **Validate schema** — Checks required fields are present
3. **Count resources** — Counts contract resources across all sections
4. **Query healthcare-iac** — Searches for open `contract-sync` issues for this customer
5. **Evaluate status** — Determines overall readiness based on validation + issues
6. **Write summary** — Generates a markdown summary table in `$GITHUB_STEP_SUMMARY`

## Development

### Running Tests

```bash
npx bats .github/actions/healthcare-iac-status/__tests__/action.bats
```
