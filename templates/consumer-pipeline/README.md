# Consumer pipeline reference templates

These files are **starting points** that customer repositories copy into
their own application repo and then own. They are not reusable workflows
(no `workflow_call`) — copying-and-owning means customers can adapt the
pipeline to their needs without coupling to healthcare-iac's release
cadence.

| File                            | What it is                                                                                                                                                                                      |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build-and-promote.yml`         | The GitHub Actions workflow customers copy into `.github/workflows/`. Builds + signs + pushes a container image, opens an overlay-bump PR, and gates promotion through `healthcare-iac-status`. |
| `healthcare-iac-status.example` | A small snippet showing how to call the `healthcare-iac-status` composite action with the right inputs.                                                                                         |
| `kustomization-bump.example`    | What an auto-generated overlay-bump PR looks like — the diff customers will see when their image promotes through environments.                                                                 |
| `kyverno-image-signing.example` | The cluster-side Kyverno verify-image policy snippet that runs in the workload account. Reference only — the policy is applied by healthcare-iac, not the customer.                             |

## Placeholders

The reference workflow contains placeholders the maintainer fills in
during onboarding via the runbook:

| Placeholder               | Replaced with                                                       |
| ------------------------- | ------------------------------------------------------------------- |
| `{{ .CustomerCode }}`     | Your assigned customer code (e.g., `acme1`)                         |
| `{{ .OwnerRepo }}`        | Your `<owner>/<repo>` (e.g., `acme/healthcare-app`)                 |
| `{{ .EcrRepoPrefix }}`    | ECR repo prefix from `cicd.ecr_repo_prefix` (default `healthcare/`) |
| `{{ .DevAccountId }}`     | AWS account ID for the dev workloads account                        |
| `{{ .StagingAccountId }}` | AWS account ID for the staging workloads account                    |
| `{{ .ProdAccountId }}`    | AWS account ID for the prod workloads account                       |

You'll see the substituted values posted on your onboarding issue once
the contract PR merges and the foundation stack provisions your roles.

## How to use these files

1. The maintainer posts the filled-in versions of these files to your
   onboarding issue.
2. Copy the contents of `build-and-promote.yml` into
   `.github/workflows/build-and-promote.yml` in your application repo.
3. Configure repo + environment variables per
   [`ONBOARDING.md`](../../ONBOARDING.md).
4. Configure branch protection on `deploy/overlays/staging/**` and
   `deploy/overlays/prod/**`.
5. Push to `main` — first run should produce a green build, image push,
   and overlay-bump PR for `dev`.

## Environment variable convention

Each env job (`build-dev`, `promote-staging`, `promote-prod`) and the
`status` job declare a job-level `environment:`. The bot writes a single
env-scoped variable `AWS_ROLE_ARN` to each GitHub Environment on `/bind`
— GitHub's variable-scoping rules then ensure each job reads its own
environment's role. No suffix-by-string switching, no per-env variable
names. See `ONBOARDING.md` for the verification step (`gh variable list
--env <env>`) and the troubleshooting flow if a variable is missing.

The reference template assumes this convention. If you copied an
earlier version that used `vars.AWS_ROLE_ARN_DEV / _STAGING / _PROD`
plus `Pre-flight: assert AWS_ROLE_ARN_<ENV>` steps, see
[ADR-056 M7 / D1](https://github.com/TheSmallCompany/healthcare-iac/issues/1288)
for the migration.

## What's NOT in these templates

- **Application-specific build logic.** The `build-and-promote.yml`
  workflow builds a generic container; replace the `docker build` step
  with whatever your app needs (Go build, npm build, Maven, etc.).
- **Test orchestration.** The reference workflow doesn't run unit/integration
  tests — that's your repo's existing CI workflow. Wire `build-and-promote`
  to run after your tests pass (e.g., via `workflow_run`).
- **Deploy targets.** The workflow only builds + pushes images and bumps
  overlays. ArgoCD in the workload account does the actual deploy.

## References

- [`ONBOARDING.md`](../../ONBOARDING.md) — customer-facing walkthrough
- [`docs/runbooks/onboard-customer-cicd.md`](https://github.com/TheSmallCompany/healthcare-iac/blob/main/docs/runbooks/onboard-customer-cicd.md) — maintainer runbook (private repo)
- [`docs/design/consumer-cicd-onboarding.md`](https://github.com/TheSmallCompany/healthcare-iac/blob/main/docs/design/consumer-cicd-onboarding.md) — ADR-47 design doc (private repo)
- [`.github/actions/healthcare-iac-status/`](../../.github/actions/healthcare-iac-status/) — composite action source (vendored here per ADR-47 R21)
