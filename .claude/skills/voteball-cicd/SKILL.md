---
name: voteball-cicd
description: Voteball's Jenkins CI/CD — the application-ci and application-cd pipelines (Jenkinsfile-ci, Jenkinsfile-cd), the Guard stage and changeset range rules, JCasC (ci/jenkins/jenkins.yaml), the BuildKit agent pod, ECR build caches, JENKINS_HOME on EFS, and how Jenkins changes reach the cluster (terraform apply, not git push). Use before editing either Jenkinsfile, ci/jenkins/*, terraform/addon-jenkins.tf or charts/jenkins-support, and when debugging a build, a skipped stage, a rollback or a Jenkins login.
---

# Voteball CI/CD (Jenkins in the `ci` namespace)

*Moved verbatim from the root `CLAUDE.md` on 2026-10-02 so it loads only when working here. Where a paragraph says "above" or "below" about something not in this file, it is in one of: `terraform/CLAUDE.md`, `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`, `charts/observability/CLAUDE.md`, `charts/voteball/CLAUDE.md`, or the `voteball-cicd` skill.*

The scripts each pipeline stage calls (`scripts/ci/*`) and their tests are documented in `scripts/CLAUDE.md`. The operational reference is `docs/cicd.md`.

## The two pipelines

**CI/CD is Jenkins, running IN the cluster** (namespace `ci`), installed by Terraform as a
`helm_release` (`terraform/addon-jenkins.tf`) of the official chart, configured by JCasC
(`ci/jenkins/jenkins.yaml`), and split (since 2026-08-04) into **two pipelines**: `application-ci`
(`Jenkinsfile-ci`) tests, builds, scans and pushes; `application-cd` (`Jenkinsfile-cd`) promotes,
deploys, verifies and rolls back. CI never deploys and holds no cluster credentials; CD never
builds and holds a strictly read-only Kubernetes Role. Pushing app code to `master` fires a GitHub
webhook → `application-ci` (guard → validate → lint → test → build → Trivy → push → publish
metadata) → triggers `application-cd` (validate → promote `image.tag` `[skip ci]` → ArgoCD sync →
wait → verify → smoke test, with automatic rollback on failure). Two parameters worth knowing:
`application-ci`'s `FORCE_BUILD` builds even when the changeset touches nothing under `services/**`
(needed for the empty-changelog case G3b guards against — see the Guard-stage note below);
`application-cd`'s `ROLLBACK_DEPTH` bounds rollback recursion — without it, a rollback that itself
fails would trigger another rollback, which could fail the same way, forever, pushing a commit each
cycle. `./scripts/build-push-ecr.sh` does
the build and push by hand -- **it does NOT scan; it contains no Trivy call at all** (verified
2026-08-27, and the images this repo ships to production on a rebuild therefore reach ECR
unscanned: `application-ci` is the only thing that runs the Trivy gate). It is the **only** way to
build while the cluster is destroyed
(there is no CI without a cluster). Agent pods authenticate to AWS via **IRSA** — CI's
`jenkins-agent` ServiceAccount gets ECR push, CD's `jenkins-cd-agent` gets ECR read-only, and the
controller itself carries no AWS role at all. Region, cluster name, GitHub repo and app domain
arrive as **pod environment variables** set by Terraform — the equivalent of the retired EC2 host's
global environment variables, and the reason a hardcoded region or prefix in either `Jenkinsfile-*`
or `ci/jenkins/jenkins.yaml` would be a bug. **See `docs/cicd.md`** for the full flow, the
first-time setup runbook, and failure modes; the split's design rationale — including why ArgoCD
stays the applier instead of a direct `helm upgrade`, and how rollback works — is in
`docs/design/2026-08-04-cicd-split-design.md`.

**Jenkins is a platform add-on, not the application** — the opposite of `charts/voteball`. Changes to
the Jenkins release reach the cluster by `terraform apply`, **not** by committing to `master` (ArgoCD
does not manage it; Terraform does, the same way it owns ArgoCD, ESO and external-dns). Committing a
change to `ci/jenkins/jenkins.yaml` or `terraform/addon-jenkins.tf` and walking away does nothing
until someone runs `terraform apply`.

**`JENKINS_HOME` is a PersistentVolumeClaim backed by EFS, not an `emptyDir`.** The node group is
100% Spot, reclaimed roughly once a day, and the reason an *EBS*-backed PVC was rejected still
holds: an EBS volume is locked to one Availability Zone, so it would need every reschedule to land
back in the same AZ or the pod hangs `Pending` forever. **EFS has a mount target in every AZ**, so
it carries none of that lock-in — a rescheduled controller pod rebinds the same volume regardless of
which AZ it lands in. That is why the fix is EFS (`terraform/modules/storage/main.tf`), not an EBS PVC pinned
to one AZ, and not staying on `emptyDir` — the course brief for the 2026-08-04 CI/CD split lists
persistent Jenkins-home storage as a mandatory component. Build history (last 20 builds) now
survives a routine Spot reclaim. Removing the Jenkins release (`scripts/jenkins/uninstall-jenkins.sh`
or a targeted `terraform destroy`) deletes the PVC — it carries no `resource-policy: keep`
annotation — but the `efs-sc` StorageClass's reclaim policy is `Retain`, so the underlying EFS
access point and its data survive as a `Released` PV; a reinstall provisions a **new, empty** PVC
and does not rebind to the old one automatically, so recovering that history needs a manual PV
rebind. It is gone for good only on a full `terraform destroy` of the EFS resources themselves —
see `docs/cicd.md`'s "Running the instance" for the three-tier breakdown. The durable
record of what was *deployed* was never the build log regardless — it is the
`release: <sha> (image tag <tag>)` commits on the **`release`** branch, which never expire.
(They were `ci: image tag <sha> [skip ci]` on `master` until the 2026-08-23 branch split.)

## The agent pod: BuildKit, traced secrets, build caches

**The `buildkit` container is the one container in this entire project that runs
`allowPrivilegeEscalation: true` plus `SETUID`/`SETGID`.** Rootless BuildKit builds inside a user
namespace, and mapping UIDs into that namespace needs those two things — without them the pod looks
healthy (4/5 containers) and the build just hangs forever with nothing logged. It is still **uid
1000, not privileged, no host devices, no host paths** — nothing like Docker-in-Docker's
`privileged: true`, which is why DinD was rejected for this pipeline in the first place. Every
container in `devops-app` still runs `allowPrivilegeEscalation: false`; **do not "tidy" this one
container to match them** — rootless BuildKit cannot start without the exception, and it is scoped to
one CI pod in a namespace whose NetworkPolicy already denies it any route to RDS or `devops-app`.

**Jenkins traces every `sh` step with `set -x`, which echoes a command AFTER argument
expansion — so any secret fetched at RUNTIME (as opposed to injected via `withCredentials`, which
Jenkins masks in the log) leaks in full the moment it reaches an argument position**, e.g. as a
`printf`/`$(...)` argument. This leaked a live ECR token into committed CI evidence on 2026-08-04
(fixed in `Jenkinsfile-ci`'s image-auth step: write straight to a file, read it back with
`cat`/a pipe, never as an argument). The counter-constraint is that `aws ecr get-login-password`
emits a trailing newline that a plain file redirect preserves, which corrupts the base64 auth
string it feeds into — so the newline still has to go, just without reintroducing the leak: use
`tr -d '\n' < file`, never `$(...)`, which trims the newline but never puts the token back in
argument position. State both constraints together — the trailing fix for one re-broke the other
once already.

**Both build caches live in ECR** (`${cluster_name}-buildcache`, `${cluster_name}-trivy-db`), and
both repos **must stay `MUTABLE` and outside `local.ecr_repos`** in `terraform/modules/storage/main.tf`. That set is
`IMMUTABLE` because a git-SHA tag must never be silently overwritten; a cache tag is *rewritten on
every build* by design, so adding either repo to that set fails every build's cache export with
"cannot overwrite immutable tag" — at the end of a long build, not the start.

## The Guard stage and changeset ranges

**Do not remove the Guard stage from `Jenkinsfile-ci`, or `scripts/ci/should-skip-build.sh`** — and
note that since 2026-08-23 **nothing writes the `[skip ci]` marker any more**, which makes the Guard
look even more like dead weight than it did before. It is not. Jenkins has no native `[skip ci]` (that
is a GitHub Actions feature), and the Guard is the only thing standing between a master-pushing
promotion and an unbounded, billable build loop across both pipelines that also rolls production pods
continuously. It must already be in place *before* anyone reintroduces one. `deploy.sh` step 9 still
commits to `master` today. Proven, not theoretical: build 5 in `docs/cicd.md` is the webhook firing on
Jenkins' own commit and being stopped by exactly this stage.

**The Guard is range-aware and must stay that way.** `should-skip-build.sh --subjects` reads every
commit subject since `GIT_PREVIOUS_SUCCESSFUL_COMMIT` and skips only if *all* of them carry the
marker; the single-message form is the fallback for a first build or a rewritten base. Reading only
the tip is what let the 2026-08-21 queued-build race hide a source commit behind a promotion commit
so that nothing ever built it — reported as `NOT_BUILT`, which reads like a pass.
`test-ci-guards.sh` pins the incident as a regression case.

**Every consumer of that range needed the same fix, and only the Guard got it — so the identical
trap fired again on 2026-09-08 (G3c).** Jenkins' `when { changeset 'services/**' }` diffs against
the **previous build**, not the previous *successful* one, so **a build that FAILS consumes its
changeset**: whatever it was carrying falls behind the next build's range base and no later
`changeset` can see it again. Observed end to end — `seed.sql` took a party off the ballot, that
build failed on an unrelated broken test, the follow-up commit touched only `scripts/tests/**`, and
the next build went **green while skipping Build, Push and Trigger CD**, leaving the party on a live
public ballot. The Jenkinsfile's own Guard comment had already named the mechanism (*"it sits BEHIND
the tip and so falls outside every subsequent changeset"*) fifteen months' worth of context earlier
in the same file. **When you fix a range base in one place, grep for every other consumer of that
range** — the fix and the unfixed copy look equally correct in review, and the unfixed one fails
silently and green. The gates now read `env.SERVICES_CHANGED`/`env.CHARTS_CHANGED`, computed in
*Resolve tag and account* by `scripts/ci/changed-paths.sh` from `GIT_PREVIOUS_SUCCESSFUL_COMMIT`
(absent or rewritten base → `true`, the same fail-safe as G3b and `images-exist.sh`).
`test-changed-paths.sh` pins the answer from **both** bases in both directions, and
`test-ci-guards.sh` fails if a raw `changeset` directive returns or if the base is changed to
anything else. **Asymmetry worth knowing before you go looking for a cleverer fix:** this rescues a
change swallowed by a **failed** build, and nothing can rescue one a **successful** build has
already passed over — no later push brings it back into range, so `FORCE_BUILD` is the only route.
That is why the escape hatch cannot be removed as redundant.

## JCasC

**Jenkins is configured by JCasC, not by clicking — but the mechanism is `terraform apply`, not a
reboot of a hand-managed host.** `ci/jenkins/jenkins.yaml` is delivered as the Terraform-managed
ConfigMap `kubernetes_config_map_v1.jenkins_casc` (label `jenkins-jenkins-config`) and applied by the
chart's config-reload sidecar (plugins, admin
user, authorization, the Kubernetes cloud, both agent pod templates, all credentials, and both jobs —
`application-ci` and `application-cd`), so **UI changes are lost the next time the controller
restarts** — which, on Spot, is roughly
daily whether you touch anything or not. **It is a ConfigMap, not `controller.JCasC.configScripts`,
since 2026-09-15**: in the Helm values it made every plan touching the release print the whole
previous values document (~1,400 lines; the Helm provider echoes it in `metadata` on any update).
**Keep `JCasC.securityRealm` and `JCasC.authorizationStrategy` set to `""` in `addon-jenkins.tf`.**
Chart 5.9.45 renders its own defaults for both unless `configScripts` *contains those strings*, a text
check our file used to pass silently. The move made them render, JCasC hit a
`ConfiguratorConflictException`, and the controller crash-looped. A failed upgrade also leaves those
ConfigMaps orphaned, because Helm prunes against the last *deployed* revision, so they had to be
deleted by hand. Edit the YAML, commit, then run `terraform apply` to push it
to the running release; committing alone changes nothing (see the platform-add-on note above).
Secrets come from Secrets Manager (`voteball/jenkins`, seeded by `./scripts/seed-jenkins-secret.sh`),
synced into a Kubernetes Secret by External Secrets Operator and projected as pod environment
variables — a Kubernetes Secret carries the deploy key's trailing newline natively, so the old
one-file-per-value workaround for that is gone. **The GitHub plugin is configured by the official
chart, not by hand-written XML** — the EC2-era `hookSecretConfigs`/two-file/SHA-256 workaround
existed only because that plugin version couldn't be data-bound by JCasC; it no longer applies.

## Commands

```bash
cd terraform
terraform apply -var-file=voteball.tfvars   # same stack, same state; re-applies the Jenkins release too
kubectl port-forward -n ci svc/jenkins 8080:8080   # then browse http://localhost:8080
```

There is nothing to start or stop — it runs whenever the cluster does, and goes with it on
`terraform destroy`. Webhook URL: `https://jenkins.<app_domain>/github-webhook/`.
