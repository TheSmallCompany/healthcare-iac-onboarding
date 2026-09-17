# Consumer pipeline reference templates

These files are **starting points** that customer repositories copy into
their own application repo and then own. They are not reusable workflows
(no `workflow_call`) — copying-and-owning means customers can adapt the
pipeline to their needs without coupling to healthcare-iac's release
cadence.

| File                            | What it is                                                                                                                                                                                      |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build-and-promote.yml`         | The GitHub Actions workflow customers copy into `.github/workflows/`. Builds, **scans**, signs and pushes a container image, opens an overlay-bump PR, and gates promotion through `healthcare-iac-status`. |
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

## Pre-flight diagnostics

Each environment job in `build-and-promote.yml` runs a `Pre-flight: assert
AWS_ROLE_ARN_<ENV> is set` step before `configure-aws-credentials@v6`. If
you forget to set the corresponding repo variable (e.g., `AWS_ROLE_ARN_DEV`),
the dev build job fails fast with a precise pointer:

```
::error::AWS_ROLE_ARN_DEV repo variable is empty. Set it under
Settings → Secrets and variables → Actions → Variables → Repository
variables. ARN format: arn:aws:iam::<account>:role/hiac-<customer>-dev-deploy
```

— instead of the cryptic `Could not load credentials from any providers`
you'd otherwise see from the AWS SDK several steps later.

## Image scanning

Every build job scans the image with [Trivy][trivy] **between `docker build`
and `docker push`**. A HIGH or CRITICAL vulnerability that has a fix available
fails the job, so the vulnerable artifact never reaches ECR at all.

The threshold is `severity: HIGH,CRITICAL` with `ignore-unfixed: true`, so
everything it reports is actionable by rebuilding on a patched base image.
Measured 2026-09-11 with those exact flags: `alpine:latest` 2 findings,
`python:3.9-slim` 58, `gcr.io/distroless/static-debian12:nonroot` 0. The
threshold discriminates — it is neither theatre nor a blanket block.

### If the scan fails your build

In order of preference:

1. **Rebuild on a patched base image.** Most findings disappear here.
2. **Upgrade the offending package.**
3. **Drop the package** if your image does not need it. Distroless and static
   base images carry almost nothing.
4. **Suppress it, with an expiry.** Add the advisory to `.trivyignore` at the
   root of your repo — Trivy reads that path automatically, no workflow change
   needed — and give it an expiry date:

   ```
   # member-service ships no HTTP server; CVE is unreachable. Fix due in 1.4.
   CVE-2026-1234 exp:2026-12-31
   ```

   Record the decision in your exceptions register in the same PR — see
   [Suppressing a finding](#suppressing-a-finding). The build fails without
   it.

**Do not** suppress by lowering `severity` or setting `exit-code: "0"`. Either
one disables the gate for every future finding rather than the one you
accepted, and the scan still appears in your logs — so the pipeline looks
scanned while nothing can ever block.

### Suppressing a finding

A `.trivyignore` line is only half of a suppression. The other half is an
`ISE-NNN` entry in your repository's image-scan exceptions register at
`docs/security/image-scan-exceptions.md` — the audit record of what was
suppressed, why it is safe, who accepted it, and when it must be re-validated.
The entry format (one `## ISE-NNN — <title>` heading per entry, with
`**Advisory ID**` and `**Re-validate by**` table rows) is defined in
[healthcare-iac's copy of the register][register]; copy its "Entry format"
section into yours.

Every build job runs the [`trivyignore-register-check`][register-check] action
**immediately before the Trivy scan**. It reads `.trivyignore` and
`.trivyignore.yaml` and fails the build when:

- a suppressed advisory ID (`vulnerabilities` and `secrets` IDs in the YAML
  form; every ID in the plain form) has no matching `ISE-NNN` entry, or the
  register file does not exist;
- a suppression has already expired (`exp:` / `expired_at` before today) but is
  still present — Trivy already ignores it, so the line is dead and the register
  entry is misleading;
- the register exists but cannot be read or parsed, or any date is malformed —
  undeterminable is not the same as valid.

An entry that is past its `Re-validate by` date produces a warning, not a
failure. Because the check runs before the scan, an undocumented suppression
fails the build before it can silence anything — which is why the
`.trivyignore` line and the register entry belong in the same PR.

### This does not replace runtime scanning

Amazon Inspector runs against what is already in ECR and rescans continuously.
The two cover different windows: no build-time gate can find a CVE that did
not exist when it ran, and Inspector only sees images that already reached the
registry. This gate's win is that Inspector goes quiet, not that it becomes
unnecessary.

[trivy]: https://trivy.dev/
[register]: https://github.com/TheSmallCompany/healthcare-iac/blob/main/docs/security/image-scan-exceptions.md
[register-check]: ../../.github/actions/trivyignore-register-check/

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
