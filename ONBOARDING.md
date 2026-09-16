# Consumer CI/CD onboarding — customer guide

This is the end-to-end walkthrough for connecting your application
repository to the healthcare-iac platform. By the end you'll have:

- A scoped IAM role per environment (`dev`, `staging`, `prod`) that
  your GitHub Actions pipeline can assume via OIDC — no static keys.
- A reference build-and-promote workflow that publishes signed
  container images to your customer-scoped ECR.
- An auto-merging overlay-bump PR flow to dev; gated reviewer flow for
  staging and prod.
- A `healthcare-iac-status` gate that blocks builds when the
  infrastructure isn't ready.

The flow is designed to be minimum-friction the second customer
onboards. The first customer (`tsc0`) IS TheSmallCompany, so most of
this is automation we built for ourselves and are now generalizing.

> **Audience.** Whoever owns CI/CD for your healthcare application
> repository. You'll need GitHub repo-admin privileges (to install the
> Healthcare IaC Cross-Repo App and configure Environments + branch
> protection) and the ability to commit a workflow file to your repo.

> **Prerequisites.** Your repository builds a container image, deploys
> via Kubernetes, and uses GitHub Actions. Non-GitHub CI systems aren't
> supported today (out of scope per ADR-47). If your app deploys via
> something other than container images on EKS, contact a
> healthcare-iac maintainer first.

---

## TL;DR — the 11-step flow

1. **File the onboarding issue** —
   [`Customer Onboarding — Consumer CI/CD`](https://github.com/TheSmallCompany/healthcare-iac-onboarding/issues/new?template=customer-onboarding-cicd.yml).
2. **A maintainer triages** the issue, assigns themselves, and tells
   you your assigned customer code (e.g., `acme1`).
3. **Install the Healthcare IaC Cross-Repo App** on your repository
   ([app page](https://github.com/apps/healthcare-iac-cross-repo)).
4. **Comment `/bind <code> <installation-id> <owner>/<repo>`** on the
   onboarding issue. The maintainer reviews and runs it (the bot only
   acts on maintainer comments).
5. **Maintainer opens a contract PR** adding your `cicd:` block to
   `infra-contracts/<your-customer>.yaml`.
6. **Contract PR merges** → foundation stack provisions your three
   OIDC roles. The maintainer posts the role ARNs back on the
   onboarding issue.
7. **You create GitHub Environments** (`staging`, `prod`) in your
   repo with required reviewers.
8. **You configure repo + environment variables** with the role ARNs.
9. **You copy** the reference
   [`templates/consumer-pipeline/build-and-promote.yml`](templates/consumer-pipeline/build-and-promote.yml)
   into `.github/workflows/` of your repo.
10. **You configure branch protection** on your repo's main branch and
    on the `deploy/overlays/{staging,prod}/**` paths in healthcare-iac.
11. **Push to main** — first build runs, image signs + pushes, overlay
    PR auto-merges to dev. Onboarding complete.

The rest of this doc is each step in detail with exact commands /
screenshots. If you're already familiar with GitHub OIDC federation
and just want the templates, skim to step 9.

---

## Step 1 — File the onboarding issue

Go to **Issues → New issue → "Customer Onboarding — Consumer CI/CD"**
and fill in:

| Field                 | What to put                                                                                                                                             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Customer code         | Lowercase, 3-12 chars, starts with letter, no hyphens. If you don't have one yet, leave a placeholder like `??????` and the maintainer will fill it in. |
| GitHub repository     | `<owner>/<repo>` you'll deploy from (e.g., `acme/healthcare-app`).                                                                                      |
| Primary contact email | Where the role ARNs land.                                                                                                                               |
| Environments needed   | Most customers want all three.                                                                                                                          |
| Permissions profile   | `ecr-push` for the default GitOps model. Anything else needs justification.                                                                             |

The issue is auto-labeled `onboarding` and shows up in the maintainers'
queue. You'll get a comment within one business day.

## Step 2 — Maintainer triage

A maintainer:

1. Confirms (or assigns) your customer code.
2. Verifies your `<owner>/<repo>` is well-formed and not already
   bound to another customer code.
3. Posts a comment on the issue with the next step (it'll just be
   "ready for you to install the App, then comment `/bind …`").

This is also when scope gets clarified: if you picked `push-deploy` but
GitOps would actually fit, the maintainer will suggest `ecr-push`
instead. Permissions are easier to widen later than to narrow.

## Step 3 — Install the Healthcare IaC Cross-Repo App

Go to <https://github.com/apps/healthcare-iac-cross-repo> and click
**Install**. On the install screen:

- **Choose**: "Only select repositories" — pick **only** the
  `<owner>/<repo>` you declared in the onboarding issue.
- **Permissions**: read-only access to repository metadata and issues.
  The App will request write-access to issues so it can post the
  bind-confirmation comment back on your onboarding issue.

After install, GitHub redirects you to a small landing page hosted by
healthcare-iac that confirms your installation ID and points you back
at your onboarding issue. **Copy the installation ID** — you'll need
it in the next step.

> **Why we ask for Cross-Repo and not just the workflow.** The App's
> install is "Factor 2" of our two-factor identity verification (the
> issue is Factor 1). On uninstall or repo-removal, your DynamoDB
> record flips to `unverified` and `healthcare-iac-status` returns
> `blocked` — which is the desired soft-revoke behavior per ADR-47 R12.

## Step 4 — Comment `/bind` on your onboarding issue

On the issue, comment **on its own line**:

```text
/bind <customer-code> <installation-id> <owner>/<repo>
```

For example:

```text
/bind acme1 12345678 acme/healthcare-app
```

Random commenters can't bind — only commenters with `OWNER`, `MEMBER`,
or `COLLABORATOR` association on healthcare-iac can. So you'll be
asking the maintainer to run the bind on your behalf, OR (if you've
been granted COLLABORATOR access for the duration of onboarding) you
can run it yourself.

The bot replies with confirmation:

> Bound `acme1` → installation `12345678` (`acme/healthcare-app`).
> Status: `verified`.

If the App isn't actually installed on the declared repo, the bot
posts a rejection comment instead — re-check Step 3.

## Step 5 — Maintainer opens contract PR

The maintainer adds your `cicd:` block to
`infra-contracts/<customer>.yaml`. Most fields are inherited from
`service-catalog/cicd-defaults.yaml` (maintained by the maintainer team in the private repo; you do not need to read it directly);
your contract just needs the deltas:

```yaml
customer: acme1
version: "6.0.0"
cicd:
  github_identity:
    owner: acme
    repo: healthcare-app
  # everything else inherited from defaults
```

You don't need to do anything during this step — review the PR if you
like, but the maintainer drives it.

## Step 6 — Contract PR merges; you get role ARNs

Once the contract PR merges, the next `pulumi up` on the foundation
stack provisions:

- `hiac-<customer>-dev-github-actions` — your dev role ARN
- `hiac-<customer>-staging-github-actions` — your staging role ARN
- `hiac-<customer>-prod-github-actions` — your prod role ARN

The maintainer posts the three ARNs as a comment on your onboarding
issue. You'll see something like:

| Environment | ARN                                                                |
| ----------- | ------------------------------------------------------------------ |
| dev         | `arn:aws:iam::111111111111:role/hiac-acme1-dev-github-actions`     |
| staging     | `arn:aws:iam::222222222222:role/hiac-acme1-staging-github-actions` |
| prod        | `arn:aws:iam::333333333333:role/hiac-acme1-prod-github-actions`    |

## Step 7 — Create GitHub Environments

In your repo: **Settings → Environments → New environment**.

Create **three**: `dev`, `staging`, `prod`.

### `dev`

- **Required reviewers**: leave empty.
- **Deployment branches**: "All branches" (the trust policy in your dev
  role accepts pushes from any branch; the Environment exists only to
  provide a scope for the `AWS_ROLE_ARN` variable — not to gate).

### `staging`

- **Required reviewers**: at least one. Your team's choice.
- **Wait timer**: optional. Useful if you want a "5-minute change
  window" between approval and deploy.
- **Deployment branches**: "Selected branches" → `main` only.

### `prod`

- **Required reviewers**: at least one. Same names or different — your
  call.
- **Deployment branches**: "Selected branches" → `main` only.

> Why a `dev` Environment when dev has no gating: the bot writes an
> env-scoped `AWS_ROLE_ARN` to each Environment on `/bind`, and the
> reference template's `status` and `build-dev` jobs declare
> `environment: dev` so they can read it. The Environment is purely a
> variable-scope; it doesn't add reviewer or branch friction.

## Step 8 — Verify env-scoped `AWS_ROLE_ARN` variables

The bot automatically wrote an env-scoped `AWS_ROLE_ARN` variable to
each Environment (`dev`, `staging`, `prod`) on `/bind` — one variable
name across all envs, with the per-env ARN value. **You don't configure
these manually.** Just verify they landed:

```sh
gh variable list --env dev
gh variable list --env staging
gh variable list --env prod
```

Each should show one variable `AWS_ROLE_ARN` whose value is the matching
ARN from Step 6. If any are missing, re-run `/bind` on your onboarding
issue.

> **Why env-scoped variables.** A variable scoped to the prod
> Environment is only readable by jobs that declare `environment: prod`
> — and those are the same jobs gated by required-reviewer approval. A
> compromised dev workflow can't read the prod ARN, which is half of
> what stops it from assuming the prod role; the OIDC sub-claim
> mismatch (your job didn't go through the `prod` Environment, so
> `sub` doesn't include `environment:prod`) is the other half.
> Using one suffix-free variable name (`AWS_ROLE_ARN`) lets the
> reference workflow read the right env's role without env-aware
> string switching.

## Step 9 — Copy the reference workflow

Copy [`templates/consumer-pipeline/build-and-promote.yml`](templates/consumer-pipeline/build-and-promote.yml)
into your repo at `.github/workflows/build-and-promote.yml`. The
maintainer will have already substituted the placeholders for your
customer; the version they post on your onboarding issue is the one
to copy.

Adapt the `Build image` step to whatever your application needs — the
template runs `docker build .` against the repo root, but most apps
need an explicit Dockerfile path, build args, or multi-stage builds.

## Step 10 — Configure branch protection

### On your repo (your responsibility)

**Settings → Branches → Add classic branch protection rule** (or the
equivalent ruleset):

- Branch name pattern: `main`
- ✅ Require a pull request before merging
- ✅ Require status checks to pass before merging
  - Add the `build-and-promote` workflow's status job once it's
    pushed.

### On healthcare-iac (we set this up)

The `deploy/overlays/staging/<customer>/**` and
`deploy/overlays/prod/<customer>/**` paths get CODEOWNERS rules
requiring a healthcare-iac platform reviewer plus your team. You
don't configure this — the maintainer will, when they merge the
contract PR.

## Step 11 — Push to main; verify

Push a small change to `main`. You should see:

1. **GitHub Actions** runs `build-and-promote.yml`.
2. **`status` job** passes (`status=ready`).
3. **`build-dev` job** builds the image, signs it with cosign keyless,
   and pushes to your customer-scoped ECR repo in the dev account.
4. **An overlay-bump PR** opens against
   TheSmallCompany/healthcare-iac, bumping
   `deploy/overlays/dev/<customer>/kustomization.yaml` to your new
   image tag.
5. **The PR auto-merges** for dev (CODEOWNERS allows the bot for
   `env:dev` paths).
6. **ArgoCD** in the dev workloads cluster reconciles within ~3
   minutes; your pod restarts on the new image.

You can confirm the deploy with:

```sh
CUSTOMER=acme1
# Paste the dev ARN from Step 6 directly (these CLI calls run on your
# laptop, not inside a GitHub Actions job, so the env-scoped variable
# isn't reachable here).
DEV_ROLE_ARN="arn:aws:iam::<dev-account>:role/hiac-${CUSTOMER}-dev-github-actions"
aws eks update-kubeconfig --name healthcare-dev --region us-east-1 \
  --role-arn "$DEV_ROLE_ARN"
kubectl -n "${CUSTOMER}-app" get pods -o wide
```

Welcome aboard.

---

## Promoting to staging and prod

Once dev is happy, promote via **Actions → build-and-promote → Run
workflow → target_env=staging**. This:

1. Triggers the `promote-staging` job, which is gated by the staging
   Environment's required reviewers.
2. After approval, opens an overlay-bump PR for
   `deploy/overlays/staging/<customer>/kustomization.yaml`. This PR
   does NOT auto-merge — it requires CODEOWNERS approval (your team
   plus a healthcare-iac platform reviewer).
3. After merge, ArgoCD reconciles staging.

Prod follows the same pattern with `target_env=prod`. The OIDC
sub-claim for the prod role has `environment:prod` in it, so this
gate has two independent checks: the GitHub Environment reviewer
(human) and the AWS-side trust-policy condition (token claim).

---

## Common issues + recovery

### "Status returns `blocked`"

Run the status check manually to see why:

```sh
OWNER_REPO=acme/healthcare-app
gh workflow run --ref main \
  --repo "${OWNER_REPO}" \
  build-and-promote.yml
```

Or invoke the action directly with `act` (or hand-run its parts) to
inspect `details` JSON. The `blocking-issues` field is a list of
GitHub issues to read.

### "Bot rejected my `/bind` because `App is not installed on …`"

You declared `<owner>/<repo>` but the App isn't installed there. Two
common causes:

1. You installed on a fork or a different repo — go re-install
   (Step 3).
2. You installed on "All repositories" but didn't include this one —
   from your install settings, change to "Only select repositories"
   and add the right repo.

After fixing, re-run `/bind` on the issue.

### "GitHub Actions can't assume the role: `AccessDenied`"

Three common causes:

1. **Wrong ARN for the environment.** Confirm the `staging`
   Environment's `AWS_ROLE_ARN` variable holds the staging ARN, not the
   dev one (run `gh variable list --env staging`). If the bot wrote the
   wrong value, re-run `/bind`.
2. **OIDC sub-claim mismatch.** Your job didn't run inside the right
   Environment. Add `environment: staging` (or `prod`) to the job.
3. **DynamoDB status flipped to `unverified`.** Look at the latest
   message in `#hiac-consumer-onboarding`. If your App was uninstalled
   or your repo was removed from the install scope, re-install and
   re-`/bind`.

### "Drift detected" alert

Means the deployed IAM trust policy in one of your workload accounts
no longer matches your contract — usually a manual IAM patch by an
operator. The maintainer will reach out via the onboarding issue.

---

## Off-boarding

If you're leaving the platform: comment "off-boarding" on your
onboarding issue (or a fresh issue tagged `offboarding`). The
maintainer team then runs an internal off-boarding flow that:

1. Removes your `cicd:` block from `infra-contracts/<customer>.yaml`.
2. The next `pulumi up` destroys your three OIDC roles.
3. You uninstall the App from your repo.
4. Your DynamoDB record flips to `unverified`. `healthcare-iac-status`
   returns `blocked` — your pipeline fails closed on next run, which
   is the intended terminal state.

---

## References

- [`templates/consumer-pipeline/`](templates/consumer-pipeline/) — reference workflow + examples.
