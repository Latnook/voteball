# Voteball

A public poll correlating football fandom with Israeli political-party voting,
timed to the runup to the next Knesset election. Deployed on a single-EC2 k3s
cluster at https://voteball.latnook.com.

Bootstrapped from infra patterns proven in the `Rolling AWS Project files`
(S3App) repo — see that repo's `docs/superpowers/specs/2026-07-11-voteball-design.md`
for the full design rationale. From this initial commit onward, this repo is
fully independent: no shared code, no shared Terraform state, no shared
Ansible roles.

See `docs/plan.md` (copied from the design repo's implementation plan) for
the build sequence.
