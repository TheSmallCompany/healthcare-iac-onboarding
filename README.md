# healthcare-iac-onboarding

Customer-facing onboarding artifacts for the **Healthcare IaC** consumer CI/CD platform.

If you are an external customer, **start here:** [`ONBOARDING.md`](ONBOARDING.md).

## What this repo is

This is the public companion repo for [`TheSmallCompany/healthcare-iac`](https://github.com/TheSmallCompany/healthcare-iac) (private). It hosts the customer-facing artifacts that an external repository owner needs to onboard their application to our managed AWS infrastructure platform:

- The full onboarding walkthrough — [`ONBOARDING.md`](ONBOARDING.md)
- The onboarding issue template — file an issue [here](https://github.com/TheSmallCompany/healthcare-iac-onboarding/issues/new?template=customer-onboarding-cicd.yml)
- The reference GitHub Actions workflow your repo will use — [`templates/consumer-pipeline/build-and-promote.yml`](templates/consumer-pipeline/build-and-promote.yml)
- Examples of cluster-side and CI-side artifacts you'll see — [`templates/consumer-pipeline/`](templates/consumer-pipeline/)

The actual infrastructure-as-code, the bot Lambda, the maintainer runbook, and the design docs live in the private companion repo — you don't need access to them.

## License

MIT — see [`LICENSE`](LICENSE). Covers the documentation and template content in this repo. The infrastructure platform itself is operated by The Small Company under a separate commercial relationship.

## Reporting an issue

- **Onboarding request?** Use the issue template above.
- **Bug in the reference workflow?** File an issue with the `bug` label.
- **Doc unclear?** File an issue with the `docs` label.

For drive-by spam: this repo limits interactions to existing GitHub users (>24 hours old). The maintainer team triages weekly and locks/closes off-topic issues.
