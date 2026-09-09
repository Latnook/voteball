# Security policy

**Reporting a vulnerability.** Use GitHub's private vulnerability reporting on this repository
(Security tab → "Report a vulnerability"). Please do not open a public issue for anything that
could be exploited before it is fixed.

**What is in scope.** The application at the deployed domain, the Helm charts under `charts/`, the
Terraform under `terraform/`, the CI/CD pipelines (`Jenkinsfile-*`, `ci/`) and the scripts under
`scripts/`.

**What the project already does** — the threat model, what is deliberately public and why, the
secrets path, vote-integrity controls and the browser/transport hardening — is documented in
[`docs/security.md`](docs/security.md). Read that before reporting something it already records as a
deliberate decision (the AWS account id in git history, for instance, is analysed there with a
measured check rather than being an oversight).
