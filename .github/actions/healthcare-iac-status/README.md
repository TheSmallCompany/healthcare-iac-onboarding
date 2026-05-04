# healthcare-iac-status GitHub Action

Checks infrastructure readiness for a customer's infra-contract. Used by
consumer repos (e.g., `healthcare-platform`) to gate deployments on
infrastructure provisioning status.

**Reference:** [ADR-35 Section 7](../../../docs/design/infra-contract-product-interface.md)

## Inputs

| Input             | Required | Default                          | Description                                  |
| ----------------- | -------- | -------------------------------- | -------------------------------------------- |
| `customer-code`   | ✅       |                                  | Customer short code (e.g., `tsc0`)           |
| `contract-path`   | ✅       |                                  | Path to infra-contract YAML                  |
| `environment`     | ✅       |                                  | Target environment: `dev`, `staging`, `prod` |
| `iac-repo`        |          | `TheSmallCompany/healthcare-iac` | Healthcare-IAC repository (owner/repo)       |
| `app-id`          |          |                                  | GitHub App ID for cross-repo auth            |
| `app-private-key` |          |                                  | GitHub App private key (PEM)                 |

## Outputs

| Output              | Description                       | Example                 |
| ------------------- | --------------------------------- | ----------------------- |
| `status`            | Overall readiness status          | `ready`, `provisioning` |
| `contract-version`  | Contract version being validated  | `2.1.2`                 |
| `resources-ready`   | Count of provisioned resources    | `15`                    |
| `resources-pending` | Count of pending resources        | `3`                     |
| `blocking-issues`   | JSON array of blocking issue URLs | `["https://..."]`       |
| `details`           | Full JSON validation details      | `{...}`                 |

## Status Values

| Status         | Meaning                                                  |
| -------------- | -------------------------------------------------------- |
| `ready`        | All contract resources are provisioned and available     |
| `provisioning` | Open contract-sync issues exist; resources being created |
| `partial`      | Some resources ready, some pending                       |
| `blocked`      | Contract validation failed; cannot proceed               |
| `unknown`      | Cannot determine status (repo unreachable, etc.)         |

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

```yaml
- name: Check infrastructure readiness
  id: infra-check
  uses: TheSmallCompany/healthcare-iac-onboarding/.github/actions/healthcare-iac-status@v1
  with:
    customer-code: tsc0
    contract-path: infra-contracts/tsc0.yaml
    environment: dev
    iac-repo: TheSmallCompany/healthcare-iac
    app-id: ${{ vars.CROSS_REPO_APP_ID }}
    app-private-key: ${{ secrets.CROSS_REPO_APP_PRIVATE_KEY }}
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
