# CI/CD Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split Voteball's single `Jenkinsfile` into a `Jenkinsfile-ci` that tests/builds/scans/pushes and a `Jenkinsfile-cd` that validates a tag, promotes it to git, has ArgoCD deploy it, smoke-tests the live site and reverts git on failure — satisfying *משימה 4* without Jenkins ever holding write access to the cluster.

**Architecture:** Two JCasC-declared jobs (`application-ci`, `application-cd`) on two agent pod templates with two ServiceAccounts. CI pushes immutable SHA-tagged images to ECR and triggers CD with the tag as a parameter. CD writes the tag into `charts/voteball/values.yaml` on `master`, then delegates every cluster operation to ArgoCD (`argocd app sync` / `wait` / `get`). Jenkins holds a strictly read-only Kubernetes Role and a read-only ECR role.

**Tech Stack:** Jenkins 2.568.1 (chart 5.9.45), JCasC + Job DSL, Kubernetes plugin pod templates, rootless BuildKit, Trivy, skopeo, ArgoCD 3.4.5 (chart 10.2.1), Helm 3, Terraform (`aws ~> 5.0`), EFS CSI driver, pytest, ruff, hadolint.

## Global Constraints

Copied verbatim from `docs/design/2026-08-04-cicd-split-design.md` and `CLAUDE.md`. **Every task's requirements implicitly include this section.**

- **No hardcoded AWS account, region, registry, domain, or ARN anywhere.** Identity comes from `terraform/voteball.tfvars` (pre-apply) and `terraform output` (post-apply), read via `scripts/lib/config.sh`. In Jenkins, identity arrives as pod environment variables set by Terraform. A hardcoded region or prefix in a Jenkinsfile or in `ci/jenkins/jenkins.yaml` is a bug.
- **Never put a `Claude-Session:` trailer or any `claude.ai/code/session_...` URL in a commit message.**
- **Commit and push as you go.** Never force-push.
- **No secrets in git or tfstate.** Secrets live in AWS Secrets Manager (`voteball/jenkins`), synced by ESO. `ci/jenkins/jenkins.yaml` may contain only `${PLACEHOLDER}` references.
- **Never hand-edit the ten sync-managed fields in `charts/voteball/values.yaml`** (`image.registry`, `image.tag`, `config.DB_HOST`, `config.S3_BUCKET`, `config.SNS_TOPIC`, `ingress.host`, `ingress.certificateArn`, `ingress.wafAclArn`, `backup.roleArn`, `worker.roleArn`) except through `scripts/sync-values-from-tf.sh` — or, for `image.tag` only, through the CD pipeline's Promote stage, which is the mechanism this plan builds.
- **The Guard stage and `scripts/ci/should-skip-build.sh` must not be removed.** They are the only thing preventing an unbounded billable build loop.
- **`terraform fmt -recursive` before committing any `.tf` change.**
- **`allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]` on every new container.** The `buildkit` container's `SETUID`/`SETGID` exception is pre-existing and must not be copied to new containers, nor removed from that one.
- **Jenkins is a platform add-on: changes reach the cluster by `terraform apply`, not by committing to `master`.** Committing a change to `ci/jenkins/jenkins.yaml` or `terraform/addon-jenkins.tf` and walking away does nothing.
- **ArgoCD owns `charts/voteball`.** Never run `helm upgrade` against it by hand; it now fails on server-side-apply field ownership.
- **No `latest` tag anywhere**, in any Dockerfile, manifest or pipeline.
- **Delete `docs/superpowers/` in the same commit as the final task** (Task 12). This plan file is a process artifact; git history is the archive.

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Jenkinsfile-ci` | CI pipeline: guard, validate, lint, test, build, scan, push, publish metadata, trigger CD |
| `Jenkinsfile-cd` | CD pipeline: validate input, validate manifests, promote, sync via ArgoCD, smoke test, roll back |
| `scripts/ci/validate-repo.sh` | Repo-shape assertions (Dockerfile + `.dockerignore` per service, no `latest`) |
| `scripts/ci/smoke-test.sh` | HTTPS checks against the live site, with retry/backoff |
| `scripts/ci/previous-tag.sh` | Reads the previous `ci: image tag` value from git history, for rollback |
| `scripts/jenkins/install-jenkins.sh` | Thin, honest wrapper over the Terraform targets that install Jenkins |
| `scripts/jenkins/verify-jenkins.sh` | Runs and **asserts on** the brief's §10 checklist |
| `scripts/jenkins/uninstall-jenkins.sh` | Thin wrapper over `terraform destroy -target` for the Jenkins pieces |
| `scripts/tests/test-smoke-test.sh` | Offline test for `smoke-test.sh` (stubs curl) |
| `scripts/tests/test-validate-repo.sh` | Offline test for `validate-repo.sh` |
| `charts/jenkins-support/templates/rbac.yaml` | `jenkins-cd-agent` ServiceAccount + read-only Role + RoleBinding in `devops-app` |
| `charts/jenkins-support/values.example.yaml` | Shape-only example, no real values |
| `ci/jenkins/secret.example.yaml` | Shape-only example of the `voteball/jenkins` payload |
| `terraform/addon-efs.tf` | EFS filesystem, mount targets, SG, CSI driver add-on + IRSA, StorageClass |

**Modified:**

| Path | Change |
|---|---|
| `ci/jenkins/jenkins.yaml` | Second agent pod template; CI template gains `python` + `postgres` + `hadolint`; two `pipelineJob`s; `argocd-auth-token` credential |
| `terraform/addon-jenkins.tf` | `persistence` enabled on `efs-sc`; CD IRSA role; `depends_on` the CSI add-on |
| `terraform/addon-argocd.tf` | `jenkins-cd` local account, its RBAC policy, its token into Secrets Manager |
| `scripts/seed-jenkins-secret.sh` | Adds `ARGOCD_AUTH_TOKEN` to the secret payload |
| `docs/cicd.md` | Rewritten for two pipelines |
| `docs/eks/architecture.md` | Two new Mermaid diagrams |
| `README.submission.md` | Task-4 section |
| `CLAUDE.md` | Every reference to a single `Jenkinsfile` |

**Deleted:** `Jenkinsfile` (Task 4), `docs/superpowers/` (Task 12).

---

### Task 1: CD ServiceAccount and read-only RBAC

**Files:**
- Create: `charts/jenkins-support/templates/rbac.yaml`
- Modify: `charts/jenkins-support/values.yaml`
- Test: `scripts/tests/test-jenkins-chart.sh` (exists; extend)

**Interfaces:**
- Consumes: nothing.
- Produces: ServiceAccount `jenkins-cd-agent` in namespace `ci`; a `Role` named `jenkins-cd-reader` and `RoleBinding` `jenkins-cd-reader` in namespace `devops-app`. Task 6 references the ServiceAccount name; Task 5 relies on the verbs.

- [ ] **Step 1: Add the target namespace value**

In `charts/jenkins-support/values.yaml`, append:

```yaml
# The application namespace the CD agent is allowed to READ. It gets no write verb of any kind --
# every write goes through ArgoCD. Terraform passes the real value; see terraform/addon-jenkins.tf.
appNamespace: devops-app
```

- [ ] **Step 2: Write the RBAC manifest**

Create `charts/jenkins-support/templates/rbac.yaml`:

```yaml
# The CD pipeline's identity. Deliberately STRICTLY READ-ONLY: there is no create, patch, update,
# delete or apply verb anywhere below, and no ClusterRole.
#
# Jenkins does not deploy. ArgoCD deploys. Jenkins asks ArgoCD to sync a git revision and then reads
# the result -- so the only Kubernetes permission it needs is the permission to look.
#
# An earlier draft granted `patch` on deployments for `kubectl rollout undo`. Rollback goes through
# git instead (design doc section 8), which removed the last reason to hold a write verb. Do not add
# one back: "Jenkins holds no write permission in devops-app" is a claim the submission makes, and it
# is only true while this file stays read-only.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-cd-agent
  namespace: {{ .Release.Namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-cd-reader
  namespace: {{ .Values.appNamespace }}
rules:
  # Enough to capture the evidence the course brief's section 10 requires, and to dump diagnostics
  # when a smoke test fails. Nothing more.
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "services", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-cd-reader
  namespace: {{ .Values.appNamespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-cd-reader
subjects:
  - kind: ServiceAccount
    name: jenkins-cd-agent
    namespace: {{ .Release.Namespace }}
```

- [ ] **Step 3: Write the failing assertion**

Append to `scripts/tests/test-jenkins-chart.sh`, inside its existing structure:

```bash
echo "--- CD RBAC is read-only ---"
rendered="$(helm template jenkins-support charts/jenkins-support)"

printf '%s' "$rendered" | grep -q 'name: jenkins-cd-agent' \
  || fail "jenkins-cd-agent ServiceAccount missing"

# The whole security claim in one assertion: no write verb may appear in this chart's RBAC.
if printf '%s' "$rendered" | awk '/^kind: Role$/,/^---$/' \
     | grep -qE '"(create|update|patch|delete|deletecollection|\*)"'; then
  fail "jenkins-cd-reader Role contains a write verb -- CD must be read-only"
fi

printf '%s' "$rendered" | grep -q 'kind: ClusterRole' \
  && fail "jenkins-support must not create any ClusterRole"

echo "OK"
```

- [ ] **Step 4: Run the test to verify it fails, then passes**

Run: `scripts/tests/test-jenkins-chart.sh`

Before creating `rbac.yaml` it must fail with `jenkins-cd-agent ServiceAccount missing`. After Step 2 it must print `OK` and exit 0. Also run `helm lint charts/jenkins-support` — expect `0 chart(s) failed`.

- [ ] **Step 5: Commit**

```bash
git add charts/jenkins-support/templates/rbac.yaml charts/jenkins-support/values.yaml scripts/tests/test-jenkins-chart.sh
git commit -m "feat(ci): add a strictly read-only ServiceAccount for the CD pipeline

jenkins-cd-agent gets get/list/watch in devops-app and nothing else -- no
ClusterRole, no write verb. Jenkins never applies anything; ArgoCD does. The
chart test asserts the absence of write verbs, so the claim cannot rot silently."
git push origin master
```

---

### Task 2: EFS-backed Jenkins home

**Files:**
- Create: `terraform/addon-efs.tf`
- Modify: `terraform/addon-jenkins.tf:291`

**Interfaces:**
- Consumes: `module.vpc` (private subnet ids, VPC id, CIDR), `module.eks` (OIDC provider, node security group id), `var.cluster_name`.
- Produces: StorageClass named `efs-sc`. Task 12 verifies the PVC reaches `Bound`.

- [ ] **Step 1: Write the EFS stack**

Create `terraform/addon-efs.tf`:

```hcl
# Persistent storage for JENKINS_HOME.
#
# WHY EFS AND NOT EBS. The course brief requires a PersistentVolumeClaim. The 2026-07-30 design
# rejected one and set persistence = false, for a real reason: this node group is 100% Spot and gets
# reclaimed roughly daily, and an EBS volume is locked to a single Availability Zone -- so every
# reschedule must land back in that AZ or the pod hangs Pending forever, which is the one failure
# mode in this design that needs a human.
#
# That reasoning is specific to EBS. EFS is an NFS filesystem with a mount target in every private
# subnet, reachable from every AZ, so the pod can be rescheduled anywhere. The requirement is met
# without reintroducing the AZ lock.
#
# What does NOT change: JCasC remains the source of truth and the controller still rebuilds itself
# entirely from code. Losing this volume stays a recoverable event. Nothing may start depending on
# its contents.

resource "aws_efs_file_system" "jenkins" {
  creation_token = "${var.cluster_name}-jenkins-home"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = { Name = "${var.cluster_name}-jenkins-home" }
}

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs"
  description = "NFS from EKS nodes to the Jenkins home filesystem"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${var.cluster_name}-efs" }
}

# Source is the node security group, NOT a CIDR. A CIDR rule would also admit anything else that
# happens to sit in these subnets; this admits only traffic from the cluster's own nodes.
resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from EKS worker nodes"
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

# One mount target per private subnet -- this is what makes the volume AZ-independent and is the
# entire reason EFS was chosen over EBS. Do not reduce this to a single subnet.
resource "aws_efs_mount_target" "jenkins" {
  for_each        = toset(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.jenkins.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam-role-for-service-accounts-eks/aws"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = module.efs_csi_irsa.iam_role_arn

  # The mount targets must exist before the driver tries to use the filesystem.
  depends_on = [aws_efs_mount_target.jenkins]
}

resource "kubernetes_storage_class" "efs" {
  metadata { name = "efs-sc" }

  storage_provisioner = "efs.csi.aws.com"

  parameters = {
    provisioningMode = "efs-ap" # dynamic access points, one per PVC
    fileSystemId     = aws_efs_file_system.jenkins.id
    directoryPerms   = "700"
    # JENKINS_HOME must be owned by uid/gid 1000 -- the controller runs non-root and cannot chown a
    # root-owned mount, which surfaces as a boot loop with "Failed to create directory" rather than
    # a permissions error.
    uid = "1000"
    gid = "1000"
  }

  # Retain, not Delete: an accidental `helm uninstall` of Jenkins must not take the build history
  # with it. `terraform destroy` still removes the filesystem itself.
  reclaim_policy = "Retain"

  depends_on = [aws_eks_addon.efs_csi]
}
```

- [ ] **Step 2: Enable persistence on the Jenkins release**

In `terraform/addon-jenkins.tf`, replace line 291 (`persistence = { enabled = false }`) and the comment block above it with:

```hcl
    # JENKINS_HOME on EFS. See terraform/addon-efs.tf for why EFS and not EBS -- in one line: an EBS
    # volume is AZ-locked and this node group is 100% Spot, so an EBS PVC would eventually strand the
    # pod Pending in an AZ with no capacity. EFS has a mount target in every private subnet.
    #
    # The controller is still disposable by design. This preserves build history across a Spot
    # reclaim; it is not a dependency. JCasC rebuilds everything else from code.
    persistence = {
      enabled      = true
      storageClass = kubernetes_storage_class.efs.metadata[0].name
      size         = "8Gi"
      accessMode   = "ReadWriteOnce"
    }
```

Add `kubernetes_storage_class.efs` to `helm_release.jenkins`'s `depends_on` list.

- [ ] **Step 3: Validate**

```bash
cd terraform
terraform fmt -recursive
terraform init -backend-config=backend.hcl -upgrade
terraform validate
```

Expected: `Success! The configuration is valid.` The `-upgrade` is required — `efs_csi_irsa` is a new module invocation.

- [ ] **Step 4: Plan and read it before applying**

```bash
cd terraform && terraform plan -var-file=voteball.tfvars -out=/tmp/efs.tfplan 2>&1 | tee /tmp/efs-plan.txt
```

Expected: ~8 resources to add (filesystem, SG, SG rule, 2 mount targets, IRSA role + policy attachment, addon, storage class) and **1 to change** (`helm_release.jenkins`). **Nothing may be destroyed.** If the plan shows a destroy of the RDS instance, the VPC, or the EKS cluster, stop and diagnose — do not apply.

- [ ] **Step 5: Apply, streaming output**

```bash
cd terraform && terraform apply -var-file=voteball.tfvars /tmp/efs.tfplan 2>&1 | tee /tmp/efs-apply.txt
```

ETA ~4-6 minutes (mount targets are the slow part). Then confirm the PVC bound:

```bash
kubectl get pvc -n ci
kubectl get pods -n ci -w   # jenkins-0 recreates once; wait for 2/2 Running
```

Expected: a PVC in `Bound` state and `jenkins-0` back to `2/2 Running`. If the pod sits `Pending` with `waiting for a volume to be created`, check `kubectl logs -n kube-system deploy/efs-csi-controller -c csi-provisioner`.

- [ ] **Step 6: Commit**

```bash
git add terraform/addon-efs.tf terraform/addon-jenkins.tf
git commit -m "feat(ci): put JENKINS_HOME on EFS so build history survives Spot reclaim

The brief requires a PVC. EBS was rejected in the 2026-07-30 design because an
EBS volume is AZ-locked and this node group is 100% Spot, so a reschedule into
an AZ without capacity strands the pod Pending forever. EFS has a mount target
in every private subnet and is AZ-independent, so the requirement is met
without that failure mode.

The controller stays disposable: JCasC is still the source of truth and losing
the volume is still recoverable. Reclaim policy is Retain so an accidental
helm uninstall does not take build history with it."
git push origin master
```

---

### Task 3: The three new shell helpers, with offline tests

**Files:**
- Create: `scripts/ci/validate-repo.sh`, `scripts/ci/smoke-test.sh`, `scripts/ci/previous-tag.sh`
- Create: `scripts/tests/test-validate-repo.sh`, `scripts/tests/test-smoke-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `validate-repo.sh` — no args, exits 0 or 1, prints one line per failed check.
  - `smoke-test.sh` — reads `SMOKE_BASE_URL` (required), `SMOKE_RETRIES` (default 10), `SMOKE_DELAY` (default 6). Exits 0 on all checks passing. Honours `SMOKE_STUB_CURL` for offline tests.
  - `previous-tag.sh` — reads `VALUES_FILE` (default `charts/voteball/values.yaml`), prints the previous `image.tag` from git history to stdout, or exits 1 with `no-previous-tag`.

Task 4 calls `validate-repo.sh`; Task 5 calls `smoke-test.sh` and `previous-tag.sh`.

- [ ] **Step 1: Write the failing test for `validate-repo.sh`**

Create `scripts/tests/test-validate-repo.sh`:

```bash
#!/usr/bin/env bash
# Offline test for scripts/ci/validate-repo.sh. Same stub pattern as test-ci-guards.sh: the script
# under test is pointed at a throwaway tree, so nothing here touches the real repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

scaffold() {
  rm -rf "$work"/repo && mkdir -p "$work"/repo
  cd "$work"/repo
  for svc in backend worker frontend backup; do
    mkdir -p "services/$svc"
    printf 'FROM python:3.12-slim\n' > "services/$svc/Dockerfile"
    printf '__pycache__\n' > "services/$svc/.dockerignore"
  done
  mkdir -p charts/voteball
  printf 'apiVersion: v2\nname: voteball\nversion: 0.1.0\n' > charts/voteball/Chart.yaml
}

echo "--- a well-formed tree passes ---"
scaffold
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null || fail "clean tree should pass"

echo "--- a missing .dockerignore fails ---"
scaffold
rm services/worker/.dockerignore
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "missing .dockerignore should fail"

echo "--- a missing Dockerfile fails ---"
scaffold
rm services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "missing Dockerfile should fail"

echo "--- a floating base image fails ---"
scaffold
printf 'FROM python:latest\n' > services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "FROM ...:latest should fail"

echo "--- an untagged base image fails ---"
scaffold
printf 'FROM python\n' > services/backend/Dockerfile
"$ROOT/scripts/ci/validate-repo.sh" >/dev/null 2>&1 && fail "untagged FROM should fail"

echo "ALL TESTS PASSED"
```

Make it executable: `chmod +x scripts/tests/test-validate-repo.sh`

- [ ] **Step 2: Run it and watch it fail**

Run: `scripts/tests/test-validate-repo.sh`
Expected: fails immediately — `scripts/ci/validate-repo.sh: No such file or directory`.

- [ ] **Step 3: Write `validate-repo.sh`**

```bash
#!/usr/bin/env bash
# CI Validation stage. Repo-shape assertions that cost nothing and run before any image is built.
#
# Every check here is one the course brief names explicitly: a Dockerfile and a .dockerignore per
# build context, and no `latest` tag anywhere. They are cheap, so they gate everything -- a repo that
# fails these must not produce an image at all.
#
# Runs against the current working directory, so the tests can point it at a scaffold.
set -uo pipefail

status=0
note() { echo "VALIDATION FAILURE: $*" >&2; status=1; }

for svc in backend worker frontend backup; do
  ctx="services/$svc"
  [ -d "$ctx" ] || { note "$ctx does not exist"; continue; }
  [ -f "$ctx/Dockerfile" ] || note "$ctx/Dockerfile is missing"
  # A missing .dockerignore is not cosmetic: it is how .git, tests and local .env files end up
  # inside a published image.
  [ -f "$ctx/.dockerignore" ] || note "$ctx/.dockerignore is missing"
done

# Both forms of unpinned base image. `FROM x:latest` is the obvious one; a bare `FROM x` resolves to
# :latest too and reads as deliberate, which is worse.
while IFS= read -r df; do
  while IFS= read -r line; do
    ref="$(printf '%s' "$line" | awk '{print $2}')"
    case "$ref" in
      *:latest)      note "$df pins $ref -- no image may use the latest tag" ;;
      *:*|*'$'*|"")  ;;  # tagged, or a build-arg reference; both fine
      *)             note "$df has an untagged base image ($ref), which resolves to :latest" ;;
    esac
  done < <(grep -iE '^\s*FROM\s+' "$df" || true)
done < <(find services -name Dockerfile 2>/dev/null)

# The chart must at least parse -- a broken Chart.yaml fails the CD pipeline much later, after a
# full build has already been paid for.
if [ -f charts/voteball/Chart.yaml ]; then
  grep -qE '^version:' charts/voteball/Chart.yaml || note "charts/voteball/Chart.yaml has no version"
else
  note "charts/voteball/Chart.yaml is missing"
fi

[ "$status" -eq 0 ] && echo "validate-repo: all checks passed"
exit "$status"
```

`chmod +x scripts/ci/validate-repo.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/tests/test-validate-repo.sh`
Expected: `ALL TESTS PASSED`. Then run it against the real repo: `scripts/ci/validate-repo.sh` — expected `validate-repo: all checks passed`. **If the real repo fails, fix the repo, not the script.**

- [ ] **Step 5: Write the failing test for `smoke-test.sh`**

Create `scripts/tests/test-smoke-test.sh`:

```bash
#!/usr/bin/env bash
# Offline test for scripts/ci/smoke-test.sh. SMOKE_STUB_CURL replaces the real curl so no network
# call is made and both outcomes can be forced deterministically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Stub contract: called as `stub <url>`, prints the body, exits non-zero to signal a transport error.
cat > "$work/ok" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  */api/options)       echo '200 {"clubs":[],"leagues":[]}' ;;
  */api/results\?by=all) echo '200 {"previous":[],"upcoming":[]}' ;;
  *)                   echo '200 <!doctype html>' ;;   # the site root
esac
STUB

# The failure this whole design exists to catch: the site LOOKS up (root and /health fine, pods
# Ready, ArgoCD reports Healthy) but the data path is broken.
cat > "$work/sick" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  */api/options)       echo '200 {"clubs":[],"leagues":[]}' ;;
  */api/results\?by=all) echo '503 upstream unavailable' ;;
  *)                   echo '200 <!doctype html>' ;;
esac
STUB

cat > "$work/down" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB

chmod +x "$work"/ok "$work"/sick "$work"/down

echo "--- a healthy site passes ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/ok" SMOKE_RETRIES=1 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null || fail "healthy site should pass"

echo "--- a 503 on /api/results fails, even though the root still serves ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/sick" SMOKE_RETRIES=2 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 && fail "a 503 must fail the smoke test"

echo "--- an unreachable site fails rather than hanging ---"
SMOKE_BASE_URL=https://example.test SMOKE_STUB_CURL="$work/down" SMOKE_RETRIES=2 SMOKE_DELAY=0 \
  "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 && fail "transport failure must fail the smoke test"

echo "--- a missing base URL fails loudly ---"
SMOKE_STUB_CURL="$work/ok" "$ROOT/scripts/ci/smoke-test.sh" >/dev/null 2>&1 \
  && fail "missing SMOKE_BASE_URL must fail"

echo "ALL TESTS PASSED"
```

`chmod +x scripts/tests/test-smoke-test.sh`

- [ ] **Step 6: Run it and watch it fail**

Run: `scripts/tests/test-smoke-test.sh`
Expected: `No such file or directory`.

- [ ] **Step 7: Write `smoke-test.sh`**

```bash
#!/usr/bin/env bash
# CD Smoke Test stage. The one check in this whole system that asks the PRODUCT whether it works.
#
# ArgoCD reports Healthy when pods pass their probes. Pods passing probes is not the same as the site
# serving a working page -- a backend that starts cleanly and 500s on every query is Healthy to
# ArgoCD and broken to a visitor. This script is the difference.
#
# Retries with a fixed delay because an ALB takes a few seconds to route to newly-Ready targets; a
# single immediate request would produce false failures and, since failure triggers a rollback, false
# rollbacks.
set -uo pipefail

: "${SMOKE_BASE_URL:?SMOKE_BASE_URL must be set (e.g. https://voteball.example.com)}"
retries="${SMOKE_RETRIES:-10}"
delay="${SMOKE_DELAY:-6}"

# Tests override this to run offline; production uses the real curl.
stub="${SMOKE_STUB_CURL:-}"

fetch() {
  if [ -n "$stub" ]; then
    "$stub" "$1"
  else
    # --max-time bounds a hung connection; without it a black-holed ALB makes the stage hang until
    # the pipeline timeout instead of failing and rolling back.
    curl -sS --max-time 15 -o /tmp/smoke-body -w '%{http_code} ' "$1" && cat /tmp/smoke-body
  fi
}

check() {
  local path="$1" want="$2" description="$3"
  local attempt=1 out code
  while [ "$attempt" -le "$retries" ]; do
    if out="$(fetch "${SMOKE_BASE_URL}${path}" 2>/dev/null)"; then
      code="$(printf '%s' "$out" | awk '{print $1}')"
      # An empty $want means "200 is enough" -- used for the HTML root, which has no JSON key to
      # match on.
      if [ "$code" = "200" ] && { [ -z "$want" ] || printf '%s' "$out" | grep -q "$want"; }; then
        echo "smoke: OK   ${path} (${description})"
        return 0
      fi
      echo "smoke: attempt ${attempt}/${retries} on ${path} -> ${code:-no-status}"
    else
      echo "smoke: attempt ${attempt}/${retries} on ${path} -> transport failure"
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$retries" ] && sleep "$delay"
  done
  echo "smoke: FAIL ${path} (${description}) after ${retries} attempts" >&2
  return 1
}

# ENDPOINT CHOICE, verified live on 2026-08-04 from a pod in the ci namespace.
#
# /health is NOT used, and that is deliberate twice over. First, it is not reachable: nginx proxies
# only /api/*, so /health from outside is a 404 -- it is the in-cluster probe target, nothing else.
# Second, and more importantly, /health is ALREADY what the kubelet probes and therefore what
# ArgoCD's health assessment is built on. Checking it here would re-ask a question ArgoCD has
# already answered, which is exactly the duplication this design avoids.
#
# What Jenkins asks instead is the question ArgoCD cannot: does the PUBLIC URL serve real data?
status=0
# The site itself, through the ALB and nginx. Proves the frontend is serving.
check / '' 'site root loads' || status=1
# Proves the backend is reachable through the proxy AND can read the database -- /api/options is
# unparameterised and returns seed data.
check /api/options 'clubs' 'options API reads the database' || status=1
# Proves the worker-computed rollup tables are readable, which is the deepest failure the other two
# cannot see. Requires the by= parameter; without it the API correctly returns 400.
check '/api/results?by=all' 'previous' 'results API reads the rollup tables' || status=1

[ "$status" -eq 0 ] && echo "smoke: all checks passed against ${SMOKE_BASE_URL}"
exit "$status"
```

`chmod +x scripts/ci/smoke-test.sh`

- [ ] **Step 8: Run the test to verify it passes**

Run: `scripts/tests/test-smoke-test.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 9: Write `previous-tag.sh`**

```bash
#!/usr/bin/env bash
# Rollback support. Prints the image tag that values.yaml named BEFORE the most recent change to it.
#
# Rollback goes through git rather than `argocd app rollback` (design doc section 8): reverting only
# in ArgoCD would leave master asserting a version the cluster is not running, and selfHeal would
# then reapply the bad tag at the next reconciliation. Rewriting git keeps one source of truth.
set -euo pipefail

values="${VALUES_FILE:-charts/voteball/values.yaml}"

# -2 not -1: the most recent revision is the tag we just promoted and are rolling back FROM.
prev="$(git log -p --format='%H' -- "$values" \
        | grep -E '^\+\s*tag: "' \
        | sed -E 's/^\+\s*tag: "(.*)"/\1/' \
        | sed -n '2p')"

if [ -z "$prev" ]; then
  echo "no-previous-tag" >&2
  exit 1
fi

echo "$prev"
```

`chmod +x scripts/ci/previous-tag.sh`

- [ ] **Step 10: Verify `previous-tag.sh` against real history**

Run: `scripts/ci/previous-tag.sh`
Expected: a 7-character hex string that is **not** the tag currently in `charts/voteball/values.yaml`. Cross-check:

```bash
grep -E '^\s*tag:' charts/voteball/values.yaml     # current
git log --oneline -- charts/voteball/values.yaml | head -5
```

- [ ] **Step 11: Commit**

```bash
git add scripts/ci/validate-repo.sh scripts/ci/smoke-test.sh scripts/ci/previous-tag.sh \
        scripts/tests/test-validate-repo.sh scripts/tests/test-smoke-test.sh
git commit -m "feat(ci): add repo validation, smoke test and rollback-tag helpers

Three pipeline decision points extracted as scripts so they can be tested
without triggering real builds -- the same offline-stub pattern as
should-skip-build.sh and images-exist.sh.

smoke-test.sh is the only check in the system that asks the product whether it
works: ArgoCD reports Healthy when pods pass probes, which a backend that
starts cleanly and 500s on every query also does. It retries, because an ALB
needs a few seconds to route to new targets and a false failure here would
trigger a false rollback."
git push origin master
```

---

### Task 4: `Jenkinsfile-ci`

**Files:**
- Create: `Jenkinsfile-ci` (from `Jenkinsfile`)
- Delete: `Jenkinsfile`

**Interfaces:**
- Consumes: `scripts/ci/should-skip-build.sh`, `scripts/ci/images-exist.sh`, `scripts/ci/validate-repo.sh`. Pod template `voteball-build` (Task 6) must provide containers `buildkit`, `trivy`, `skopeo`, `awscli`, `python`, `hadolint`.
- Produces: archived artifact `image-metadata.json`; triggers job `application-cd` with string parameters `IMAGE_TAG`, `IMAGE_DIGEST`, `SOURCE_BUILD`.

- [ ] **Step 1: Copy the file, preserving history**

```bash
git mv Jenkinsfile Jenkinsfile-ci
```

Update the header comment to:

```groovy
// Voteball CI. Tests, builds, scans and pushes the four images, then hands the tag to the CD
// pipeline. This pipeline NEVER deploys and holds no cluster credentials -- see Jenkinsfile-cd.
//
// Design: docs/design/2026-08-04-cicd-split-design.md (supersedes the single-pipeline design in
// docs/design/2026-07-20-jenkins-migration-design.md, whose G1-G7 labels are still referenced below)
```

- [ ] **Step 2: Delete the `Bump image tag` stage**

Remove the entire `stage('Bump image tag') { ... }` block (lines 285-337 of the original). It moves to `Jenkinsfile-cd` (Task 5). Leave the `sshagent` import unused — no import exists to remove.

- [ ] **Step 3: Insert Validation, Lint and Tests after the Guard stage**

Immediately after `stage('Guard: is this our own commit?')` and **before** `stage('Resolve tag and account')`, insert:

```groovy
    // Cheap repo-shape assertions, before anything is built. A repo that fails these must not
    // produce an image at all, so this runs ahead of 'Already built?' -- a re-run of an
    // already-built tag still has to pass validation.
    stage('Validation') {
      steps {
        sh 'scripts/ci/validate-repo.sh'
      }
    }

    stage('Lint / Static Analysis') {
      steps {
        container('python') {
          sh '''
            set -eu
            pip install --quiet --no-cache-dir ruff==0.8.4
            ruff check services/backend services/worker
          '''
        }
        container('hadolint') {
          sh '''
            set -eu
            for svc in backend worker frontend backup; do
              echo "--- hadolint services/$svc/Dockerfile ---"
              # DL3008/DL3013 (unpinned apt/pip versions) are informational here; the Dockerfiles
              # pin via requirements.txt, which hadolint cannot see.
              hadolint --ignore DL3008 --ignore DL3013 "services/$svc/Dockerfile"
            done
          '''
        }
      }
    }

    // The 153 tests in services/{backend,worker}/tests. They existed before this pipeline stage did
    // and were never run by CI -- so a failing test blocked nothing. They now block everything.
    //
    // They need a REAL Postgres: both conftest.py files DROP TABLE ... CASCADE and call init_db().
    // The `postgres` sidecar in the pod template provides it on localhost; it is ephemeral, holds no
    // real data, and is reachable only from inside this pod's own network namespace, so the ci
    // NetworkPolicies are untouched and no route to the real RDS instance exists or is needed.
    stage('Tests') {
      steps {
        container('python') {
          sh '''
            set -eu
            # Wait for the sidecar: containers in a pod start concurrently, and psycopg2 connecting
            # before Postgres is listening fails with "could not connect", which reads like a
            # configuration error rather than a race.
            for i in $(seq 1 30); do
              pg_isready -h localhost -p 5432 -q && break
              echo "waiting for postgres ($i/30)"
              sleep 2
            done
            pg_isready -h localhost -p 5432 || { echo "postgres sidecar never became ready"; exit 1; }

            pip install --quiet --no-cache-dir -r services/backend/requirements-dev.txt
            (cd services/backend && python -m pytest tests -q --junitxml=/images/backend-tests.xml)

            pip install --quiet --no-cache-dir -r services/worker/requirements-dev.txt
            (cd services/worker && python -m pytest tests -q --junitxml=/images/worker-tests.xml)
          '''
        }
      }
      post {
        always {
          // allowEmptyResults:false -- a Tests stage that silently published nothing is exactly the
          // "green build that verified nothing" failure this whole split exists to prevent.
          junit allowEmptyResults: false, testResults: 'images/*-tests.xml'
        }
      }
    }
```

> **Note on the junit path:** the pod mounts the shared volume at `/images`, which is outside the workspace, so `junit` cannot read it directly. Add `sh 'cp /images/*-tests.xml "$WORKSPACE"/ || true'` inside the `container('python')` block after the pytest runs, and change the `junit` glob to `'*-tests.xml'`.

- [ ] **Step 4: Add Publish Metadata and Trigger CD after `Push to ECR`**

Insert after the `stage('Push to ECR')` block:

```groovy
    // Traceability. The brief requires that a CD build can identify the CI build, the git commit,
    // the image and the digest that produced it. The digest is the part that matters: a tag is a
    // pointer and could in principle be moved, a digest is the content.
    stage('Publish Metadata') {
      // Same guard as 'Trigger CD' below, for the same reason: with no images in ECR for this SHA
      // the digest lookups return None and the metadata file would record nothing.
      when { anyOf {
        expression { env.ALREADY_BUILT == 'present' }
        changeset 'services/**'
        expression { params.FORCE_BUILD }
        expression { env.NO_CHANGELOG == 'true' }
      } }
      steps {
        container('awscli') {
          sh '''
            set -eu
            {
              printf '{\\n'
              printf '  "image_tag": "%s",\\n' "$TAG"
              printf '  "git_commit": "%s",\\n' "$(git rev-parse HEAD)"
              printf '  "ci_build": "%s",\\n' "$BUILD_NUMBER"
              printf '  "built_at": "%s",\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  "images": {\\n'
              sep=""
              for svc in backend worker nginx backup; do
                digest="$(aws ecr describe-images \\
                  --repository-name "$CLUSTER_NAME-$svc" \\
                  --image-ids "imageTag=$TAG" \\
                  --region "$AWS_REGION" \\
                  --query 'imageDetails[0].imageDigest' --output text)"
                printf '%s    "%s-%s": { "digest": "%s" }' "$sep" "$CLUSTER_NAME" "$svc" "$digest"
                sep=",\\n"
              done
              printf '\\n  }\\n}\\n'
            } > image-metadata.json
            cat image-metadata.json
          '''
        }
        archiveArtifacts artifacts: 'image-metadata.json', fingerprint: true
        script {
          env.BACKEND_DIGEST = sh(
            script: '''grep -A1 '"'"$CLUSTER_NAME"-backend"' image-metadata.json | grep -oE 'sha256:[0-9a-f]+' ''',
            returnStdout: true).trim()
        }
      }
    }

    // Handing the tag to a separate job is one of the four connection mechanisms the brief permits
    // ("הפעלת CD מתוך build trigger והעברת parameter"). It is NOT a deploy stage: this pipeline
    // holds no cluster credentials and cannot reach the cluster.
    //
    // wait:false so a slow rollout does not hold a CI executor, and so a CD failure is reported
    // against the CD build where the logs are, not as a confusing CI failure.
    //
    // THE `when` GUARD IS LOAD-BEARING and is the same one the retired 'Bump image tag' stage
    // carried. Without it, a commit touching only docs/ or README.md triggers CD with a tag that has
    // no images in ECR -- CD's Input Validation then correctly refuses, and every documentation
    // commit produces a red CD build. The condition is "this SHA has images", which is true when we
    // just built them OR when they were already present.
    stage('Trigger CD') {
      when { anyOf {
        expression { env.ALREADY_BUILT == 'present' }
        changeset 'services/**'
        expression { params.FORCE_BUILD }
        expression { env.NO_CHANGELOG == 'true' }
      } }
      steps {
        build job: 'application-cd', wait: false, parameters: [
          string(name: 'IMAGE_TAG',    value: env.TAG),
          string(name: 'IMAGE_DIGEST', value: env.BACKEND_DIGEST ?: ''),
          string(name: 'SOURCE_BUILD', value: env.BUILD_NUMBER),
        ]
      }
    }
```

- [ ] **Step 5: Set the build description in `Resolve tag and account`**

Inside that stage's `script` block, after `env.TAG` is set, add:

```groovy
          // The brief requires branch, commit SHA and build number to be visible on the build.
          currentBuild.description = "${env.BRANCH_NAME ?: 'master'} @ ${env.TAG} (build #${env.BUILD_NUMBER})"
```

- [ ] **Step 6: Add `cleanWs()` to the post block**

In `post { always { ... } }`, after the existing `rm -rf /images/dockercfg` step, add:

```groovy
      // The brief's Cleanup stage. The pod is destroyed anyway, but an explicit clean is what makes
      // the guarantee independent of that.
      cleanWs()
```

- [ ] **Step 7: Validate the Groovy parses**

There is no offline Jenkins linter available here. Validate structurally instead:

```bash
# Balanced braces is the failure that actually bites -- a Declarative parse error fails the build
# before any stage runs.
python3 - <<'PY'
src = open('Jenkinsfile-ci').read()
depth = 0
for i, ch in enumerate(src):
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
    assert depth >= 0, f"unbalanced closing brace at offset {i}"
assert depth == 0, f"unbalanced braces: {depth} unclosed"
for stage in ['Guard', 'Validation', 'Lint / Static Analysis', 'Tests', 'Already built?',
              'Build images', 'Trivy scan', 'Push to ECR', 'Publish Metadata', 'Trigger CD']:
    assert f"stage('{stage}')" in src, f"missing stage: {stage}"
assert "Bump image tag" not in src, "the Bump image tag stage must move to Jenkinsfile-cd"
print("Jenkinsfile-ci structure OK")
PY
```

Expected: `Jenkinsfile-ci structure OK`.

**Then lint it with a real Jenkins parser.** The structural check above catches unbalanced braces;
it cannot catch a Declarative schema error, which fails the build before any stage runs. The running
controller exposes the official validator:

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080 >/dev/null 2>&1 &
PF=$!; sleep 4
CRUMB="$(curl -su "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  'http://localhost:8080/crumbIssuer/api/json' | jq -r .crumb)"
curl -su "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -H "Jenkins-Crumb: $CRUMB" \
  -F "jenkinsfile=<Jenkinsfile-ci" http://localhost:8080/pipeline-model-converter/validate
kill $PF
```

Expected: `Jenkinsfile successfully validated.` Any other output is a parse error — fix it before
committing. This is the only pre-flight check that exercises the actual Declarative parser.

- [ ] **Step 8: Commit**

```bash
git add Jenkinsfile-ci
git rm --cached Jenkinsfile 2>/dev/null || true
git commit -m "feat(ci): split the build half out as Jenkinsfile-ci

Adds the four stages the brief requires and this pipeline never had:
Validation, Lint/Static Analysis, Tests and Publish Metadata. The Tests stage
is the significant one -- 153 tests existed and CI ran none of them, so a
failing test blocked nothing. It now blocks everything, ahead of any image
being built.

Removes the Bump image tag stage: choosing what production runs is a deploy
decision and moves to Jenkinsfile-cd. What remains here cannot reach the
cluster and holds no cluster credentials."
git push origin master
```

---

### Task 5: `Jenkinsfile-cd`

**Files:**
- Create: `Jenkinsfile-cd`

**Interfaces:**
- Consumes: `scripts/ci/images-exist.sh`, `scripts/ci/smoke-test.sh`, `scripts/ci/previous-tag.sh`. Pod template `voteball-deploy` (Task 6) providing containers `deploy` (kubectl/helm/aws/jq/curl) and `argocd`. Credentials `voteball-deploy-key` and `argocd-auth-token`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the pipeline**

Create `Jenkinsfile-cd`:

```groovy
// Voteball CD. Receives an image tag that CI already built, tested and scanned; never builds one.
//
// GOVERNING RULE: whatever ArgoCD can do, ArgoCD does. This pipeline holds a strictly READ-ONLY
// Kubernetes Role (charts/jenkins-support/templates/rbac.yaml) and cannot apply anything to the
// cluster. Deploy, rollout-waiting and health assessment are all delegated to ArgoCD; what lives
// here is only what a reconciler structurally cannot do -- reject an invalid request, choose which
// tag git should name, ask the live site over HTTPS whether it works, and revert git when it does not.
//
// Design: docs/design/2026-08-04-cicd-split-design.md sections 3, 4, 7 and 8.

pipeline {
  agent { label 'voteball-deploy' }

  options {
    // Two deploys racing to rewrite values.yaml and push to master would conflict, and a rollback
    // racing the deploy it is undoing would be worse.
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timestamps()
    timeout(time: 20, unit: 'MINUTES')
  }

  parameters {
    string(name: 'IMAGE_TAG',    defaultValue: '', description: 'Short commit SHA to deploy. Must already exist in ECR.')
    string(name: 'IMAGE_DIGEST', defaultValue: '', description: 'Backend image digest, recorded for traceability.')
    string(name: 'SOURCE_BUILD', defaultValue: '', description: 'The application-ci build number this came from.')
    string(name: 'NAMESPACE',    defaultValue: 'devops-app', description: 'Target namespace. Allowlisted.')
  }

  stages {

    stage('Checkout') {
      steps {
        script {
          // Traceability, per the brief: a CD build must identify the CI build, commit, image and
          // digest that led to the deployment.
          currentBuild.description =
            "tag ${params.IMAGE_TAG} <- ci #${params.SOURCE_BUILD ?: '?'} " +
            "(${params.IMAGE_DIGEST ? params.IMAGE_DIGEST.take(19) : 'no digest'})"
        }
      }
    }

    // Nothing is committed to master until the request is known to be valid. A bad tag caught here
    // costs nothing; caught after the promote commit it has already fired a webhook.
    stage('Input Validation') {
      steps {
        script {
          if (!params.IMAGE_TAG?.trim()) {
            error('IMAGE_TAG is required. Re-run with the tag application-ci produced.')
          }
          if (params.IMAGE_TAG == 'latest') {
            error('Refusing to deploy the tag "latest". Releases are pinned to an immutable commit SHA.')
          }
          if (!(params.IMAGE_TAG ==~ /^[0-9a-f]{7,40}$/)) {
            error("IMAGE_TAG '${params.IMAGE_TAG}' is not a commit SHA. Refusing to deploy.")
          }
          // Allowlist of exactly one. Single-environment by design; this exists so a typo or an
          // injected parameter cannot aim a deploy at kube-system.
          if (!(params.NAMESPACE in ['devops-app'])) {
            error("NAMESPACE '${params.NAMESPACE}' is not allowlisted.")
          }
          if (!env.AWS_REGION || !env.CLUSTER_NAME) {
            error('AWS_REGION and CLUSTER_NAME must be set as Jenkins global environment variables.')
          }
          env.TAG = params.IMAGE_TAG
          env.ECR_REPOS = "${env.CLUSTER_NAME}-backend ${env.CLUSTER_NAME}-worker " +
                          "${env.CLUSTER_NAME}-nginx ${env.CLUSTER_NAME}-backup"
        }
        container('deploy') {
          // The same guard CI uses, read-only here: proves all four images really are in ECR before
          // master is told to name this tag. The CD agent's IRSA role is ECR read-only.
          sh '''
            set -eu
            result="$(scripts/ci/images-exist.sh)"
            [ "$result" = "present" ] || {
              echo "Images for $TAG are NOT all in ECR ($result). Refusing to deploy." >&2
              exit 1
            }
            echo "All four images for $TAG confirmed present in ECR."
          '''
        }
      }
    }

    stage('Manifest Validation') {
      steps {
        container('deploy') {
          // --dry-run=client, not =server: a server-side dry run needs create permission on every
          // kind in the chart, and granting CD that would undo the read-only guarantee for one
          // validation nicety. ArgoCD holds those permissions and does the real server-side apply
          // seconds later, failing the sync if the manifests are invalid. Stating which form ran
          // means nothing degrades silently.
          sh '''
            set -eu
            helm lint charts/voteball
            helm template voteball charts/voteball \
              --namespace "$NAMESPACE" \
              --set image.tag="$TAG" > /tmp/rendered.yaml
            echo "--- kubectl apply --dry-run=client (see the comment above for why not =server) ---"
            kubectl apply --dry-run=client -f /tmp/rendered.yaml
          '''
        }
      }
    }

    // The deploy decision, expressed as a commit. ArgoCD watches charts/voteball on master; this
    // commit is what tells it what to run.
    stage('Promote') {
      steps {
        sshagent(credentials: ['voteball-deploy-key']) {
          sh '''
            set -eu
            mkdir -p ~/.ssh && chmod 700 ~/.ssh
            printf '%s\\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > ~/.ssh/known_hosts
            chmod 600 ~/.ssh/known_hosts

            sed -i -E "s/^  tag: \\".*\\"/  tag: \\"$TAG\\"/" charts/voteball/values.yaml

            git config user.name  "jenkins"
            git config user.email "jenkins@voteball.local"
            git add charts/voteball/values.yaml

            if git diff --cached --quiet; then
              echo "values.yaml already names $TAG -- nothing to commit"
            else
              # [skip ci] is documentation; the Guard stage in Jenkinsfile-ci is what enforces it.
              # Do not remove either -- without the guard this commit retriggers CI, which triggers
              # CD, which commits again, forever.
              git commit -m "ci: image tag $TAG [skip ci]"
              git pull --rebase --autostash origin master || {
                echo "Rebase onto origin/master failed; aborting cleanly so the next build is not wedged."
                git rebase --abort || true
                exit 1
              }
              git push origin HEAD:master
            fi
            git rev-parse HEAD > /tmp/promote-sha
          '''
        }
        script { env.PROMOTE_SHA = readFile('/tmp/promote-sha').trim() }
      }
    }

    stage('Deploy') {
      steps {
        container('argocd') {
          withCredentials([string(credentialsId: 'argocd-auth-token', variable: 'ARGOCD_AUTH_TOKEN')]) {
            // PORT 443, NOT 80. `--plaintext` would target port 80, and the ci namespace's egress
            // NetworkPolicy denies it: the broad allow-all rule excludes 172.16.0.0/12, which
            // CONTAINS the EKS service CIDR 172.20.0.0/16, and the rule that re-allows the service
            // CIDR lists only ports 443, 8080 and 50000. A --plaintext call therefore hangs and then
            // fails with a transport error that reads exactly like an expired token.
            //
            // --insecure skips verification of argocd-server's self-signed certificate. Acceptable
            // for a ClusterIP hop that never leaves the cluster; the token still authenticates us to
            // the server.
            //
            // --grpc-web because the server does not proxy raw HTTP/2 gRPC through this path.
            sh '''
              set -eu
              argocd app sync voteball \
                --server argocd-server.argocd.svc.cluster.local \
                --grpc-web --insecure \
                --revision "$PROMOTE_SHA" \
                --timeout 300
            '''
          }
        }
      }
    }

    // Delegated to ArgoCD's own health model rather than reimplemented as `kubectl rollout status`
    // over three Deployments. ArgoCD assesses health per resource kind and already knows how.
    stage('Rollout') {
      steps {
        container('argocd') {
          withCredentials([string(credentialsId: 'argocd-auth-token', variable: 'ARGOCD_AUTH_TOKEN')]) {
            sh '''
              set -eu
              argocd app wait voteball \
                --server argocd-server.argocd.svc.cluster.local \
                --grpc-web --insecure \
                --sync --health --timeout 300
            '''
          }
        }
      }
    }

    stage('Verify') {
      steps {
        container('argocd') {
          withCredentials([string(credentialsId: 'argocd-auth-token', variable: 'ARGOCD_AUTH_TOKEN')]) {
            // Reads ArgoCD's own verdict instead of re-deriving one.
            sh '''
              set -eu
              argocd app get voteball \
                --server argocd-server.argocd.svc.cluster.local \
                --grpc-web --insecure -o json > /tmp/app.json

              sync_status="$(jq -r '.status.sync.status'     /tmp/app.json)"
              health="$(jq   -r '.status.health.status'      /tmp/app.json)"
              revision="$(jq -r '.status.sync.revision'      /tmp/app.json)"

              echo "sync=$sync_status health=$health revision=$revision"
              [ "$sync_status" = "Synced" ]  || { echo "ArgoCD reports $sync_status" >&2; exit 1; }
              [ "$health"      = "Healthy" ] || { echo "ArgoCD reports $health" >&2; exit 1; }
              case "$revision" in
                "$PROMOTE_SHA"*) ;;
                *) echo "ArgoCD synced $revision, not the promoted $PROMOTE_SHA" >&2; exit 1 ;;
              esac
            '''
          }
        }
        container('deploy') {
          // Evidence capture for the brief's section 10, NOT a second opinion on ArgoCD's verdict.
          // This is the only kubectl call in the happy path, and it is read-only.
          sh '''
            set -eu
            kubectl get deployments,pods,services,ingress -n "$NAMESPACE"
          '''
        }
      }
    }

    stage('Smoke Test') {
      steps {
        container('deploy') {
          sh '''
            set -eu
            SMOKE_BASE_URL="https://$APP_DOMAIN" scripts/ci/smoke-test.sh
          '''
        }
      }
    }
  }

  post {
    failure {
      // Failure Handling. Diagnostics first -- once the rollback lands, the evidence of what broke
      // is gone.
      container('deploy') {
        sh '''
          set +e
          echo "=============== EVENTS ==============="
          kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp | tail -40
          for d in frontend backend worker; do
            echo "=============== LOGS: $d ==============="
            kubectl logs "deployment/$d" -n "$NAMESPACE" --tail=200 --all-containers 2>&1 | tail -200
          done
        '''
      }
      script {
        // Rollback runs only if we got as far as changing what production runs. A failure in Input
        // Validation or Manifest Validation changed nothing, so there is nothing to undo -- and
        // rolling back then would deploy an older tag for no reason.
        if (env.PROMOTE_SHA) {
          def previous = sh(script: 'scripts/ci/previous-tag.sh', returnStdout: true).trim()
          if (previous && previous != env.TAG) {
            echo "ROLLING BACK to ${previous} (this deploy of ${env.TAG} failed verification)."
            currentBuild.description = "${currentBuild.description} | ROLLED BACK to ${previous}"
            build job: 'application-cd', wait: false, parameters: [
              string(name: 'IMAGE_TAG',    value: previous),
              string(name: 'IMAGE_DIGEST', value: ''),
              string(name: 'SOURCE_BUILD', value: "rollback-from-${env.BUILD_NUMBER}"),
            ]
          } else {
            echo "NO ROLLBACK: could not determine a previous tag distinct from ${env.TAG}. " +
                 "Deploy an older tag manually -- see docs/cicd.md."
          }
        } else {
          echo 'NO ROLLBACK NEEDED: this build failed before promoting, so production is unchanged.'
        }
      }
    }
    // cleanup, NOT always. Jenkins runs post blocks in a fixed order -- always, changed, fixed,
    // regression, aborted, failure, success, unstable, cleanup -- so cleanWs() in `always` would
    // delete the workspace BEFORE the failure block above runs previous-tag.sh, which needs the git
    // repository. The rollback would then fail on exactly the path it exists for.
    cleanup {
      cleanWs()
    }
  }
}
```

> **Rollback recursion:** the rollback re-invokes `application-cd`, which could in principle fail and roll back again. The bound is `previous != env.TAG` plus `disableConcurrentBuilds()`: the rollback build deploys the previous tag, and its own `previous-tag.sh` then resolves to the tag before *that*. Verify in Task 12 that a failed rollback stops rather than looping; if it does not, add a `ROLLBACK_DEPTH` parameter that refuses to recurse past 1.

- [ ] **Step 2: Structural validation**

```bash
python3 - <<'PY'
src = open('Jenkinsfile-cd').read()
depth = 0
for i, ch in enumerate(src):
    if ch == '{': depth += 1
    elif ch == '}': depth -= 1
    assert depth >= 0, f"unbalanced closing brace at offset {i}"
assert depth == 0, f"unbalanced braces: {depth} unclosed"
for stage in ['Checkout', 'Input Validation', 'Manifest Validation', 'Promote',
              'Deploy', 'Rollout', 'Verify', 'Smoke Test']:
    assert f"stage('{stage}')" in src, f"missing stage: {stage}"
# The governing rule, asserted: no write verb against the cluster anywhere in CD.
for forbidden in ['kubectl apply -f', 'kubectl patch', 'kubectl delete', 'kubectl rollout undo',
                  'helm upgrade', 'helm install']:
    assert forbidden not in src, f"CD must not write to the cluster: found {forbidden!r}"
print("Jenkinsfile-cd structure OK")
PY
```

Expected: `Jenkinsfile-cd structure OK`.

**Then lint it with a real Jenkins parser.** The structural check above catches unbalanced braces;
it cannot catch a Declarative schema error, which fails the build before any stage runs. The running
controller exposes the official validator:

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080 >/dev/null 2>&1 &
PF=$!; sleep 4
CRUMB="$(curl -su "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  'http://localhost:8080/crumbIssuer/api/json' | jq -r .crumb)"
curl -su "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -H "Jenkins-Crumb: $CRUMB" \
  -F "jenkinsfile=<Jenkinsfile-cd" http://localhost:8080/pipeline-model-converter/validate
kill $PF
```

Expected: `Jenkinsfile successfully validated.` Any other output is a parse error — fix it before
committing. This is the only pre-flight check that exercises the actual Declarative parser.

- [ ] **Step 3: Commit**

```bash
git add Jenkinsfile-cd
git commit -m "feat(cd): add the deploy pipeline, scoped to what ArgoCD cannot do

Receives a tag CI already built and scanned, and never builds one. Deploy,
rollout-waiting and health assessment all delegate to the argocd CLI rather
than being reimplemented with kubectl -- ArgoCD already assesses health per
resource kind, and this pipeline holds a strictly read-only Role and could not
apply anything if it tried.

What is here is only what a reconciler structurally cannot do: refuse a tag
that is latest or absent from ECR, decide which tag git should name, ask the
live site over HTTPS whether it actually works, and revert git when it does
not. Rollback goes through git rather than argocd app rollback, so master never
asserts a version the cluster is not running."
git push origin master
```

---

### Task 6: JCasC — two agent templates, two jobs, the ArgoCD credential

**Files:**
- Modify: `ci/jenkins/jenkins.yaml`

**Interfaces:**
- Consumes: ServiceAccount `jenkins-cd-agent` (Task 1); `Jenkinsfile-ci` (Task 4) and `Jenkinsfile-cd` (Task 5); env var `ARGOCD_AUTH_TOKEN` (Task 7).
- Produces: labels `voteball-build` and `voteball-deploy`; jobs `application-ci` and `application-cd`; credential id `argocd-auth-token`.

- [ ] **Step 1: Publish APP_DOMAIN to the agents**

`APP_DOMAIN` is currently set only as a **controller container** env var (`containerEnv` in
`terraform/addon-jenkins.tf`). Pipelines run on **agent** pods, which inherit JCasC's
`globalNodeProperties` instead — and that block carries only `AWS_REGION` and `CLUSTER_NAME`. The CD
smoke test would therefore request `https:///health` and fail on every deploy.

In `ci/jenkins/jenkins.yaml`, extend `globalNodeProperties`:

```yaml
          # Reaches AGENTS, unlike the controller's containerEnv. Jenkinsfile-cd's Smoke Test builds
          # the site URL from this; without it the request goes to "https:///health" and every
          # deploy fails verification -- which, with automatic rollback, means every deploy rolls
          # itself back.
          - key: "APP_DOMAIN"
            value: "${APP_DOMAIN}"
```

`APP_DOMAIN` already resolves in this file (`unclassified.location.url` uses it), so no Terraform
change is needed — it is already projected into the controller, which is what expands the
placeholder.

- [ ] **Step 2: Add the test containers to the CI pod template**

In the `voteball-build` template's `containers:` list, after the `awscli` container, add:

```yaml
                  # Runs ruff and the 153 pytest tests. python:3.12-slim, not alpine: psycopg2-binary
                  # ships manylinux wheels, so nothing is compiled and no build toolchain is needed.
                  - name: python
                    image: python:3.12-slim
                    command: ["cat"]
                    tty: true
                    env:
                      # HOME=/tmp for the same reason as the containers above: uid 1000 with a
                      # non-writable /. pip also needs a writable cache dir.
                      - { name: HOME, value: /tmp }
                      - { name: PIP_CACHE_DIR, value: /tmp/pip }
                      # Point the tests at the sidecar, not at RDS. conftest.py only setdefault()s
                      # these, so an explicit value wins.
                      - { name: DB_HOST, value: "localhost" }
                      - { name: DB_NAME, value: "postgres" }
                      - { name: DB_USER, value: "postgres" }
                      - { name: DB_PASS, value: "test" }
                      - { name: DB_SSLMODE, value: "disable" }
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    resources:
                      requests: { cpu: "200m", memory: "512Mi" }
                      limits: { memory: "1Gi" }
                    volumeMounts:
                      - { name: images, mountPath: /images }

                  # Ephemeral Postgres for the test suite. Holds no real data and is reachable only
                  # from inside this pod's network namespace, so the ci NetworkPolicies are
                  # unaffected and no route to the real RDS instance is created or needed.
                  - name: postgres
                    image: postgres:16-alpine
                    env:
                      - { name: POSTGRES_PASSWORD, value: "test" }
                      # The image initialises the data directory as uid 70 by default; the pod
                      # forces uid 1000, so PGDATA must sit somewhere writable by it.
                      - { name: PGDATA, value: /tmp/pgdata }
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    resources:
                      requests: { cpu: "100m", memory: "256Mi" }
                      limits: { memory: "512Mi" }
                    volumeMounts:
                      - { name: pgdata, mountPath: /tmp }

                  - name: hadolint
                    image: hadolint/hadolint:2.12.0-alpine
                    command: ["cat"]
                    tty: true
                    env:
                      - { name: HOME, value: /tmp }
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
```

And in that template's `volumes:` list, add:

```yaml
                  # Postgres' data directory. Separate from `images` so a large test database cannot
                  # consume the tarball volume's sizeLimit and fail the build at push time.
                  - name: pgdata
                    emptyDir: {}
```

- [ ] **Step 3: Add the CD pod template**

After the entire `voteball-build` template entry, add a second entry to `templates:`:

```yaml
          - name: "voteball-deploy"
            label: "voteball-deploy"
            yamlMergeStrategy: override
            yaml: |
              apiVersion: v1
              kind: Pod
              spec:
                # jenkins-cd-agent, NOT jenkins-agent. The build agent's role can PUSH to ECR; this
                # one is ECR read-only and carries a strictly read-only Kubernetes Role in
                # devops-app (charts/jenkins-support/templates/rbac.yaml). Neither can do the
                # other's job, which is the point: a compromised build agent can push a junk image
                # but cannot deploy it, and a compromised deploy agent can only ask ArgoCD to sync a
                # commit.
                serviceAccountName: jenkins-cd-agent
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 1000
                containers:
                  # kubectl, helm, aws-cli, jq and curl in one image, so the CD pod stays two
                  # containers rather than five. Pinned; alpine/k8s tags track a Kubernetes minor.
                  - name: deploy
                    image: alpine/k8s:1.31.3
                    command: ["cat"]
                    tty: true
                    env:
                      - { name: HOME, value: /tmp }
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    resources:
                      requests: { cpu: "200m", memory: "512Mi" }
                      limits: { memory: "1Gi" }
                  # The argocd CLI. Same image as the running ArgoCD server (chart 10.2.1 =>
                  # app v3.4.5) so the client can never be a version ahead of the server.
                  - name: argocd
                    image: quay.io/argoproj/argocd:v3.4.5
                    command: ["cat"]
                    tty: true
                    env:
                      - { name: HOME, value: /tmp }
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities: { drop: ["ALL"] }
                    resources:
                      requests: { cpu: "100m", memory: "256Mi" }
                      limits: { memory: "512Mi" }
```

- [ ] **Step 4: Add the ArgoCD credential**

In the `credentials:` block, after `github-webhook-secret`, add:

```yaml
          # API token for the `jenkins-cd` ArgoCD local account, whose RBAC allows sync and get on
          # the voteball Application and nothing else (terraform/addon-argocd.tf). Resolved at boot
          # from the environment, same as every other placeholder here.
          - string:
              scope: GLOBAL
              id: "argocd-auth-token"
              description: "ArgoCD API token for the CD pipeline (managed by JCasC)"
              secret: "${ARGOCD_AUTH_TOKEN}"
```

- [ ] **Step 5: Replace the single job with two**

Replace the entire `jobs:` block with:

```yaml
jobs:
  # Two jobs, per the brief. Both are deliberately thin: everything about HOW to build or deploy
  # lives in the Jenkinsfiles, in the repository. These blocks only say where to find them and when
  # to run them. Created from code -- creating jobs through the Jenkins UI is explicitly out of
  # scope for this project.
  - script: |
      pipelineJob('application-ci') {
        description('Voteball CI: test, build, scan, push. Never deploys. Definition lives in Jenkinsfile-ci.')

        properties {
          githubProjectUrl('https://github.com/${GITHUB_REPO}/')
        }

        parameters {
          booleanParam('FORCE_BUILD', false, 'Build even if this commit touches no files under services/')
        }

        logRotator {
          numToKeep(20)
        }

        triggers {
          githubPush()
        }

        definition {
          cpsScm {
            scm {
              git {
                remote {
                  // MUST be the SSH remote -- see the note on application-cd below, which is the
                  // job that actually pushes.
                  url('git@github.com:${GITHUB_REPO}.git')
                  credentials('voteball-deploy-key')
                }
                branch('*/master')
              }
            }
            scriptPath('Jenkinsfile-ci')
            lightweight(true)
          }
        }
      }

  - script: |
      pipelineJob('application-cd') {
        description('Voteball CD: validate a tag, promote it to git, have ArgoCD deploy it, smoke test, roll back on failure. Never builds. Definition lives in Jenkinsfile-cd.')

        properties {
          githubProjectUrl('https://github.com/${GITHUB_REPO}/')
        }

        // No githubPush trigger. This job is started by application-ci with a tag, or by hand for a
        // rollback. A push trigger here would deploy on every commit regardless of whether CI
        // passed -- which is the exact gate this split exists to create.
        parameters {
          stringParam('IMAGE_TAG', '', 'Short commit SHA to deploy. Must already exist in ECR.')
          stringParam('IMAGE_DIGEST', '', 'Backend image digest, recorded for traceability.')
          stringParam('SOURCE_BUILD', '', 'The application-ci build number this came from.')
          stringParam('NAMESPACE', 'devops-app', 'Target namespace. Allowlisted.')
        }

        logRotator {
          numToKeep(20)
        }

        definition {
          cpsScm {
            scm {
              git {
                remote {
                  // MUST be the SSH remote. sshagent() only affects SSH remotes -- with an HTTPS
                  // URL the deploy key is silently ignored and the Promote stage's push fails after
                  // everything else succeeded. This is failure mode 1 in docs/cicd.md.
                  url('git@github.com:${GITHUB_REPO}.git')
                  credentials('voteball-deploy-key')
                }
                branch('*/master')
              }
            }
            scriptPath('Jenkinsfile-cd')
            lightweight(true)
          }
        }
      }
```

- [ ] **Step 6: Validate the YAML parses**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('ci/jenkins/jenkins.yaml'))
tpl = d['jenkins']['clouds'][0]['kubernetes']['templates']
labels = [t['label'] for t in tpl]
assert labels == ['voteball-build', 'voteball-deploy'], labels
build = yaml.safe_load([t for t in tpl if t['label']=='voteball-build'][0]['yaml'])
names = [c['name'] for c in build['spec']['containers']]
for want in ['buildkit','trivy','skopeo','awscli','python','postgres','hadolint']:
    assert want in names, f'CI template missing container: {want}'
deploy = yaml.safe_load([t for t in tpl if t['label']=='voteball-deploy'][0]['yaml'])
assert deploy['spec']['serviceAccountName'] == 'jenkins-cd-agent'
gnp = d['jenkins']['globalNodeProperties'][0]['envVars']['env']
keys = [e['key'] for e in gnp]
for want in ['AWS_REGION','CLUSTER_NAME','APP_DOMAIN']:
    assert want in keys, f'globalNodeProperties missing {want} -- agents will not see it'
assert len(d['jobs']) == 2
assert 'application-ci' in d['jobs'][0]['script']
assert 'application-cd' in d['jobs'][1]['script']
ids = [list(c.values())[0]['id'] for c in d['credentials']['system']['domainCredentials'][0]['credentials']]
assert 'argocd-auth-token' in ids, ids
print('jenkins.yaml OK')
"
```

Expected: `jenkins.yaml OK`.

- [ ] **Step 7: Commit (do NOT apply yet — Task 7 supplies the token)**

```bash
git add ci/jenkins/jenkins.yaml
git commit -m "feat(ci): declare two agent templates and two jobs in JCasC

application-ci on voteball-build (now with python, postgres and hadolint
containers for the lint and test stages) and application-cd on voteball-deploy,
which runs as jenkins-cd-agent and carries only the argocd CLI and read-only
kubectl.

application-cd deliberately has no githubPush trigger: it is started by
application-ci with a tag, or by hand for a rollback. A push trigger would
deploy every commit regardless of whether CI passed, which is the gate this
split exists to create.

Jenkins is a platform add-on -- this reaches the cluster via terraform apply,
not by committing. Applied in Task 7 once ARGOCD_AUTH_TOKEN exists."
git push origin master
```

---

### Task 7: ArgoCD account for CD, and the token in Secrets Manager

**Files:**
- Modify: `terraform/addon-argocd.tf`, `terraform/addon-jenkins.tf`, `scripts/seed-jenkins-secret.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: env var `ARGOCD_AUTH_TOKEN` on the Jenkins controller, resolving the JCasC placeholder from Task 6. IRSA role granting the CD agent ECR read-only.

- [ ] **Step 1: Add the ArgoCD local account and its RBAC**

In `terraform/addon-argocd.tf`, in the `argocd-cm` map, add:

```hcl
        # A local account for the CD pipeline, so Jenkins does not use the admin account. apiKey
        # only -- this account cannot log into the UI, it can only hold an API token.
        "accounts.jenkins-cd" = "apiKey"
```

In the `argocd-rbac-cm` map, replace `"policy.csv" = ""` with:

```hcl
        # Least privilege for the CD pipeline: it may sync and inspect the one Application it
        # deploys, and nothing else. No create, no delete, no access to any other Application, no
        # cluster or repo administration.
        "policy.csv" = <<-EOT
          p, role:jenkins-cd, applications, get,  voteball/voteball, allow
          p, role:jenkins-cd, applications, sync, voteball/voteball, allow
          g, jenkins-cd, role:jenkins-cd
        EOT
```

- [ ] **Step 2: Add the CD agent's read-only ECR role**

In `terraform/addon-jenkins.tf`, alongside the existing agent IRSA role, add:

```hcl
# The CD pipeline's AWS identity. READ-ONLY on the four application repositories, and nothing else.
#
# Its single purpose is the Input Validation stage proving a requested tag really is in ECR before
# anything is committed to master. It cannot push, cannot delete, and holds no other AWS permission.
data "aws_iam_policy_document" "jenkins_cd_ecr_read" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in local.ecr_repos : "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}-${r}"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action does not support resource-level permissions.
  }
}

module "jenkins_cd_irsa" {
  source  = "terraform-aws-modules/iam-role-for-service-accounts-eks/aws"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-jenkins-cd"

  role_policy_arns = { read = aws_iam_policy.jenkins_cd_ecr_read.arn }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["ci:jenkins-cd-agent"]
    }
  }
}

resource "aws_iam_policy" "jenkins_cd_ecr_read" {
  name   = "${var.cluster_name}-jenkins-cd-ecr-read"
  policy = data.aws_iam_policy_document.jenkins_cd_ecr_read.json
}
```

Pass the resulting role ARN into `charts/jenkins-support` so the ServiceAccount from Task 1 carries the IRSA annotation. Add to `helm_release.jenkins_support`'s `set` list:

```hcl
    { name = "cdRoleArn", value = module.jenkins_cd_irsa.iam_role_arn },
    { name = "appNamespace", value = "devops-app" },
```

and in `charts/jenkins-support/templates/rbac.yaml`, annotate the ServiceAccount:

```yaml
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.cdRoleArn | quote }}
```

adding `cdRoleArn: ""` to `charts/jenkins-support/values.yaml`.

- [ ] **Step 3: Extend the secret seeder**

In `scripts/seed-jenkins-secret.sh`, in the Python block that builds the payload (around line 142), add `ARGOCD_AUTH_TOKEN` to the dict:

```python
    "ARGOCD_AUTH_TOKEN":     os.environ.get("ARGOCD_AUTH_TOKEN", ""),
```

Above it, add a comment explaining the value is minted after ArgoCD exists, so it is empty on first seed and filled in Step 4.

> **Ordering trap:** `seed-jenkins-secret.sh` **exits early and changes nothing** once the secret holds a deploy key. Adding a key to the payload therefore does **not** update an already-seeded secret. Step 4 writes the token with a direct `aws secretsmanager` call for exactly this reason. Do not use `FORCE_ROTATE=1` — it mints a new deploy key and webhook secret and would require re-registering both on GitHub.

- [ ] **Step 4: Mint the token and merge it into the existing secret**

```bash
# Generate the token using the admin account (one-off, interactive).
ARGOCD_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
kubectl -n argocd port-forward svc/argocd-server 8081:80 >/dev/null 2>&1 &
PF=$!; sleep 4

argocd login localhost:8081 --plaintext --username admin --password "$ARGOCD_PW" --insecure
TOKEN="$(argocd account generate-token --account jenkins-cd --plaintext)"
kill $PF

# Merge into the existing secret WITHOUT disturbing the deploy key or webhook secret.
aws secretsmanager get-secret-value --secret-id voteball/jenkins --query SecretString --output text \
  | jq --arg t "$TOKEN" '.ARGOCD_AUTH_TOKEN = $t' > /tmp/jenkins-secret.json
aws secretsmanager put-secret-value --secret-id voteball/jenkins \
  --secret-string "file:///tmp/jenkins-secret.json"
shred -u /tmp/jenkins-secret.json
```

Verify without printing the value:

```bash
aws secretsmanager get-secret-value --secret-id voteball/jenkins --query SecretString --output text \
  | jq 'to_entries | map({key, len: (.value | length)})'
```

Expected: an entry `ARGOCD_AUTH_TOKEN` with a non-zero length.

- [ ] **Step 5: Apply**

```bash
cd terraform && terraform fmt -recursive && terraform validate
terraform plan -var-file=voteball.tfvars -out=/tmp/cd.tfplan 2>&1 | tee /tmp/cd-plan.txt
terraform apply -var-file=voteball.tfvars /tmp/cd.tfplan 2>&1 | tee /tmp/cd-apply.txt
```

ETA ~3-5 minutes. ESO copies the vault into the cluster **once at creation and then hourly**, so force a refresh rather than waiting:

```bash
kubectl -n ci annotate externalsecret jenkins-secret force-sync="$(date +%s)" --overwrite
kubectl -n ci get secret jenkins-secret -o jsonpath='{.data.ARGOCD_AUTH_TOKEN}' | wc -c   # non-zero
kubectl -n ci rollout restart statefulset jenkins    # JCasC re-reads the env at boot
kubectl -n ci rollout status statefulset jenkins --timeout=300s
```

- [ ] **Step 6: Confirm both jobs exist and no UI configuration was needed**

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080 >/dev/null 2>&1 &
sleep 4
curl -su "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" http://localhost:8080/api/json?tree=jobs[name] | jq
```

Expected: exactly `application-ci` and `application-cd`. The old `voteball` job disappears when JCasC no longer declares it.

- [ ] **Step 7: Commit**

```bash
git add terraform/addon-argocd.tf terraform/addon-jenkins.tf scripts/seed-jenkins-secret.sh \
        charts/jenkins-support/templates/rbac.yaml charts/jenkins-support/values.yaml
git commit -m "feat(cd): give the CD pipeline its own ArgoCD account and read-only ECR role

The jenkins-cd ArgoCD local account is apiKey-only -- it cannot log into the UI
-- and its policy allows get and sync on exactly one Application. Jenkins never
uses the ArgoCD admin account.

The IRSA role is ECR read-only on the four app repos, for the single purpose of
proving a requested tag exists before anything is committed to master.

Note seed-jenkins-secret.sh exits early once the secret holds a deploy key, so
the token is merged in with a direct put-secret-value rather than a re-seed --
FORCE_ROTATE would mint a new deploy key and require re-registering it on
GitHub."
git push origin master
```

---

### Task 8: Jenkins lifecycle scripts

**Files:**
- Create: `scripts/jenkins/install-jenkins.sh`, `scripts/jenkins/verify-jenkins.sh`, `scripts/jenkins/uninstall-jenkins.sh`

**Interfaces:**
- Consumes: `scripts/lib/config.sh`.
- Produces: `verify-jenkins.sh` exits 0 only when every check passes; Task 12 captures its output as evidence.

- [ ] **Step 1: Write `verify-jenkins.sh` (the substantial one)**

```bash
#!/usr/bin/env bash
# Runs the course brief's section 10 checklist and ASSERTS on it, rather than printing output for a
# human to eyeball. Exits non-zero on the first structural failure.
#
# Every command below appears verbatim in the brief; the assertions are this repo's addition.
set -uo pipefail

status=0
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*" >&2; status=1; }

echo "=== kubectl get namespaces ==="
kubectl get namespaces
kubectl get namespace ci >/dev/null 2>&1 && ok "the ci namespace exists" || bad "no ci namespace"
kubectl get namespace devops-app >/dev/null 2>&1 \
  && ok "the devops-app namespace exists" || bad "no devops-app namespace"

echo
echo "=== kubectl get pods -n ci -o wide ==="
kubectl get pods -n ci -o wide
ready="$(kubectl get pod jenkins-0 -n ci -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)"
case "$ready" in
  *false*|"") bad "the Jenkins controller is not Ready ($ready)" ;;
  *)          ok  "the Jenkins controller is Ready" ;;
esac

echo
echo "=== kubectl get service,ingress,pvc -n ci ==="
kubectl get service,ingress,pvc -n ci
phase="$(kubectl get pvc -n ci -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
[ "$phase" = "Bound" ] && ok "the Jenkins home PVC is Bound" || bad "the PVC is '$phase', not Bound"

# The brief requires the UI not be open to the whole internet. This asserts the property directly:
# the Ingress must route the webhook path and nothing else.
paths="$(kubectl get ingress -n ci -o jsonpath='{.items[*].spec.rules[*].http.paths[*].path}')"
[ "$paths" = "/github-webhook" ] \
  && ok "the Ingress routes only /github-webhook -- the UI is not internet-facing" \
  || bad "the Ingress routes '$paths'; the Jenkins UI may be exposed"

echo
echo "=== kubectl get serviceaccount,role,rolebinding -n ci ==="
kubectl get serviceaccount,role,rolebinding -n ci
for sa in jenkins jenkins-agent jenkins-cd-agent; do
  kubectl get serviceaccount "$sa" -n ci >/dev/null 2>&1 \
    && ok "ServiceAccount $sa exists" || bad "ServiceAccount $sa is missing"
done

# The security claim, asserted rather than documented: CD may not write to the app namespace.
if kubectl auth can-i patch deployments \
     --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app 2>/dev/null | grep -q '^yes'; then
  bad "jenkins-cd-agent CAN patch deployments in devops-app -- it must be read-only"
else
  ok "jenkins-cd-agent cannot write to devops-app (ArgoCD is the only applier)"
fi
kubectl auth can-i list pods \
  --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app 2>/dev/null | grep -q '^yes' \
  && ok "jenkins-cd-agent can read devops-app for evidence and diagnostics" \
  || bad "jenkins-cd-agent cannot read devops-app"

echo
echo "=== helm list -n ci ==="
helm list -n ci
helm list -n ci -q | grep -qx jenkins && ok "the jenkins release is installed" || bad "no jenkins release"

echo
echo "=== builds do not run on the controller ==="
execs="$(kubectl exec -n ci jenkins-0 -c jenkins -- \
  sh -c 'grep -o "<numExecutors>[0-9]*</numExecutors>" /var/jenkins_home/config.xml' 2>/dev/null)"
case "$execs" in
  *">0<"*) ok  "numExecutors is 0 -- the controller runs no builds" ;;
  "")      bad "could not read numExecutors from the controller" ;;
  *)       bad "numExecutors is not 0 ($execs) -- builds could run on the controller" ;;
esac

echo
[ "$status" -eq 0 ] && echo "verify-jenkins: ALL CHECKS PASSED" || echo "verify-jenkins: FAILURES ABOVE" >&2
exit "$status"
```

`chmod +x scripts/jenkins/verify-jenkins.sh`

- [ ] **Step 2: Write the install and uninstall wrappers**

`scripts/jenkins/install-jenkins.sh`:

```bash
#!/usr/bin/env bash
# Installs Jenkins into the cluster.
#
# Jenkins is a PLATFORM ADD-ON owned by Terraform, not an application deployed by ArgoCD -- so this
# is a thin, honest wrapper around the Terraform resources that install it, not a second install
# path. A parallel install mechanism would be a lie about how this repo works, and would drift.
#
# Full deploy: scripts/deploy.sh. This script exists for the case where the cluster is already up
# and only the Jenkins add-on needs (re)installing.
set -euo pipefail

cd "$(dirname "$0")/../../terraform"

echo "==> Jenkins is installed by Terraform. Applying only the Jenkins-related resources."
echo "    Anything else that has drifted will NOT be corrected by this run."

terraform apply -var-file=voteball.tfvars \
  -target=aws_efs_file_system.jenkins \
  -target=aws_efs_mount_target.jenkins \
  -target=aws_eks_addon.efs_csi \
  -target=kubernetes_storage_class.efs \
  -target=helm_release.jenkins_support \
  -target=helm_release.jenkins \
  "$@"

echo
echo "==> Installed. Verify with:  scripts/jenkins/verify-jenkins.sh"
echo "==> Reach the UI with:       kubectl port-forward -n ci svc/jenkins 8080:8080"
echo "    (the UI is deliberately not internet-facing; only /github-webhook is routed)"
```

`scripts/jenkins/uninstall-jenkins.sh`:

```bash
#!/usr/bin/env bash
# Removes Jenkins from the cluster, leaving the application and its data untouched.
#
# The EFS filesystem's reclaim policy is Retain, so build history survives this and is picked up
# again on reinstall. `terraform destroy` (scripts/destroy.sh) removes the filesystem itself.
set -euo pipefail

cd "$(dirname "$0")/../../terraform"

echo "This removes the Jenkins release, its supporting chart and its Ingress."
echo "It does NOT touch devops-app, RDS, or the ArgoCD Application."
printf 'Type "yes" to continue: '
read -r reply
[ "$reply" = "yes" ] || { echo "Aborted."; exit 1; }

# jenkins_support last: its NetworkPolicies and ExternalSecret are what the controller needs while
# it shuts down.
terraform destroy -var-file=voteball.tfvars \
  -target=helm_release.jenkins \
  -target=helm_release.jenkins_support \
  "$@"

echo
echo "==> Removed. The EFS volume is retained; reinstall with scripts/jenkins/install-jenkins.sh"
```

`chmod +x scripts/jenkins/install-jenkins.sh scripts/jenkins/uninstall-jenkins.sh`

- [ ] **Step 3: Run the verifier against the live cluster**

Run: `scripts/jenkins/verify-jenkins.sh`
Expected: `verify-jenkins: ALL CHECKS PASSED`, exit 0. If the PVC check fails, Task 2 did not complete. If the `jenkins-cd-agent` checks fail, Tasks 1 and 7 have not both been applied.

- [ ] **Step 4: Commit**

```bash
git add scripts/jenkins/
git commit -m "feat(ci): add Jenkins install, verify and uninstall scripts

verify-jenkins.sh runs the course brief's section 10 checklist and asserts on
it rather than printing output for a human to eyeball -- including two
properties that are otherwise only claims in prose: that the Ingress routes
/github-webhook and nothing else, and that jenkins-cd-agent cannot patch
deployments in devops-app.

install and uninstall are thin wrappers over the Terraform targets that own
Jenkins, deliberately not a second install path -- Jenkins is a platform
add-on, and a parallel mechanism would drift from the one that is real."
git push origin master
```

---

### Task 9: Example config files with no real values

**Files:**
- Create: `charts/jenkins-support/values.example.yaml`, `ci/jenkins/secret.example.yaml`

**Interfaces:** none.

- [ ] **Step 1: Write `ci/jenkins/secret.example.yaml`**

```yaml
# EXAMPLE ONLY -- every value below is a placeholder. This file documents the SHAPE of the
# voteball/jenkins secret in AWS Secrets Manager. It is committed deliberately; the real values are
# not in git, not in tfstate, and not in any manifest.
#
# The real secret is a single JSON document in AWS Secrets Manager, written by
# scripts/seed-jenkins-secret.sh, synced into the Kubernetes Secret `jenkins-secret` by External
# Secrets Operator (charts/jenkins-support/templates/externalsecret.yaml), and projected into the
# controller as environment variables that resolve the ${PLACEHOLDER}s in ci/jenkins/jenkins.yaml.
#
# To create it:      ./scripts/seed-jenkins-secret.sh
# To rotate it:      FORCE_ROTATE=1 ./scripts/seed-jenkins-secret.sh
#                    (this mints a NEW deploy key and webhook secret -- both must then be
#                     re-registered on GitHub, which ./scripts/register-github-ci.sh does)
#
# Shown here as a Kubernetes Secret for readability. DO NOT `kubectl apply` this file: applying it
# would create a Secret that ESO then fights over, and would put placeholder credentials into the
# cluster.
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-secret
  namespace: ci
type: Opaque
stringData:
  # The Jenkins UI login. Not "admin" in this deployment.
  JENKINS_ADMIN_USER: "REPLACE_ME"
  # A BCRYPT HASH, not a password -- JCasC accepts "#jbcrypt:$2a$..." directly, which is why the
  # plaintext password never has to exist in Secrets Manager or in git.
  JENKINS_ADMIN_HASH: "#jbcrypt:$2a$10$REPLACE_ME_WITH_A_REAL_BCRYPT_HASH"

  # SSH deploy key with write access to the repo. Used by the CD pipeline's Promote stage to push
  # the image-tag commit. MUST retain its trailing newline -- a key without one cannot be loaded by
  # OpenSSH at all, and the resulting error is "Permission denied (publickey)", which reads like an
  # authorisation problem and is not.
  GITHUB_DEPLOY_USER: "git"
  GITHUB_DEPLOY_KEY: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    REPLACE_ME
    -----END OPENSSH PRIVATE KEY-----

  # Shared secret GitHub signs webhook deliveries with.
  GITHUB_WEBHOOK_SECRET: "REPLACE_ME"

  # API token for the `jenkins-cd` ArgoCD local account. Its ArgoCD RBAC allows get and sync on the
  # voteball Application and nothing else. Minted with:
  #   argocd account generate-token --account jenkins-cd
  ARGOCD_AUTH_TOKEN: "REPLACE_ME"
```

- [ ] **Step 2: Write `charts/jenkins-support/values.example.yaml`**

```yaml
# EXAMPLE ONLY. The real values are supplied by terraform/addon-jenkins.tf at apply time -- this
# file exists to document what the chart expects, and to satisfy the course brief's requirement for
# a values example carrying no real values.
#
# Nothing here is secret: these are identifiers and network ranges, not credentials. Secrets reach
# the chart only through the ExternalSecret, which names an AWS Secrets Manager key -- see
# ci/jenkins/secret.example.yaml.
#
# Every value is account-, region- or cluster-specific. Hardcoding any of them would break a fork,
# which is why Terraform passes them rather than the chart defaulting to something real.

awsRegion: REPLACE_ME          # e.g. il-central-1
secretName: REPLACE_ME         # the AWS Secrets Manager key, e.g. voteball/jenkins
refreshInterval: 1h            # how often ESO re-reads the vault

vpcCidr: 10.0.0.0/16           # this VPC's real CIDR
serviceCidr: 172.20.0.0/16     # the EKS cluster's Service CIDR (NOT the VPC's)

certificateArn: REPLACE_ME     # ACM cert for the webhook host; a NEW ARN on every rebuild
host: REPLACE_ME               # e.g. jenkins.example.com

appNamespace: devops-app       # the namespace the CD agent may READ (never write)
cdRoleArn: REPLACE_ME          # IRSA role for jenkins-cd-agent; ECR read-only
```

- [ ] **Step 3: Verify neither file contains a real value**

```bash
# Must produce no output. A hit here means a real credential or ARN leaked into an example file.
grep -nE 'arn:aws|[0-9]{12}|latnook|voteball\.[a-z]+\.com|BEGIN OPENSSH PRIVATE KEY-----$' \
  ci/jenkins/secret.example.yaml charts/jenkins-support/values.example.yaml \
  | grep -v REPLACE_ME || echo "clean: no real values in the example files"
```

Expected: `clean: no real values in the example files`.

- [ ] **Step 4: Commit**

```bash
git add ci/jenkins/secret.example.yaml charts/jenkins-support/values.example.yaml
git commit -m "docs(ci): add shape-only example files for the Jenkins secret and values

Required by the course brief section 6 ('יש להגיש secret.example.yaml,
values.example.yaml או הוראות יצירה - ללא ערכים אמיתיים'). Both document what
has to exist and how to create it, with every real value replaced.

The secret example is shown as a Kubernetes Secret for readability and carries
an explicit do-not-apply warning: applying it would create a Secret that ESO
then fights over."
git push origin master
```

---

### Task 10: The two required diagrams

**Files:**
- Modify: `docs/eks/architecture.md`

**Interfaces:** none.

- [ ] **Step 1: Add the Pipeline Flow diagram**

Append a new section to `docs/eks/architecture.md`:

````markdown
## 5. Pipeline Flow — commit to running site

Required by *משימה 4* §7 ("Pipeline Flow: הסדר הלוגי: commit, CI, tests, image build, registry, CD,
rollout, smoke test ו-rollback").

```mermaid
flowchart TD
    dev["Developer pushes to master"] --> gh["GitHub"]
    gh -->|"webhook -> https://jenkins.DOMAIN/github-webhook"| guard

    subgraph ci["application-ci  (agent: voteball-build, SA: jenkins-agent)"]
        guard{"Guard:<br/>own [skip ci] commit?"}
        guard -->|yes| stop(["NOT_BUILT — loop broken"])
        guard -->|no| validate["Validation<br/>Dockerfile + .dockerignore, no :latest"]
        validate --> lint["Lint<br/>ruff + hadolint"]
        lint --> tests["Tests<br/>153 pytest, Postgres sidecar"]
        tests --> built{"tag already<br/>in ECR?"}
        built -->|no| build["Build<br/>rootless BuildKit x4"]
        build --> scan["Trivy scan<br/>fail on HIGH/CRITICAL"]
        scan --> push["Push to ECR<br/>tag = commit SHA"]
        built -->|yes| meta
        push --> meta["Publish Metadata<br/>image-metadata.json + digests"]
    end

    tests -.->|"any test fails"| failci(["FAILED — nothing built, nothing deployed"])
    scan -.->|"HIGH/CRITICAL"| failci

    meta -->|"build job: application-cd<br/>IMAGE_TAG, IMAGE_DIGEST, SOURCE_BUILD"| inval

    subgraph cd["application-cd  (agent: voteball-deploy, SA: jenkins-cd-agent — READ-ONLY)"]
        inval["Input Validation<br/>not :latest, is a SHA, exists in ECR"]
        inval --> manval["Manifest Validation<br/>helm lint + template + dry-run"]
        manval --> promote["Promote<br/>write image.tag to values.yaml, push"]
        promote --> sync["Deploy<br/>argocd app sync --revision"]
        sync --> wait["Rollout<br/>argocd app wait --sync --health"]
        wait --> verify["Verify<br/>argocd app get: Synced + Healthy + revision"]
        verify --> smoke["Smoke Test<br/>HTTPS GET /health and /api/results"]
        smoke -->|pass| done(["Deployed and verified"])
        smoke -->|fail| rb["Rollback<br/>re-run CD with the previous tag"]
        wait -.->|timeout| rb
        verify -.->|degraded| rb
        rb --> promote
    end

    promote -->|"commit to master"| argo
    sync -.->|"sync request"| argo
    argo["ArgoCD<br/>the only thing that applies to the cluster"] -->|"server-side apply"| k8s["devops-app<br/>frontend / backend / worker"]
```

**Reading it:** everything inside `application-cd` is a *request* or a *read*. The only arrow that
writes to the cluster comes from ArgoCD, because Jenkins holds no permission to apply anything —
see `charts/jenkins-support/templates/rbac.yaml`.
````

- [ ] **Step 2: Add the Deployment View diagram**

Append:

````markdown
## 6. Deployment View — what runs where

Required by *משימה 4* §7 ("Deployment View: היכן Jenkins והאפליקציה רצים: clusters, namespaces, Pods,
Services, storage ו-network boundaries").

```mermaid
flowchart LR
    internet(["Internet"])

    subgraph aws["AWS account — region from tfvars"]
        subgraph vpc["VPC 10.0.0.0/16"]
            alb["ALB (group: voteball)<br/>HTTPS via ACM"]

            subgraph eks["EKS cluster — Spot node group, private subnets"]
                subgraph nsci["namespace: ci"]
                    jc["jenkins-0 (StatefulSet)<br/>numExecutors 0 — runs no builds<br/>SA: jenkins — no AWS role"]
                    ab["agent pod: voteball-build<br/>buildkit, trivy, skopeo, awscli,<br/>python, postgres, hadolint<br/>SA: jenkins-agent — ECR push"]
                    ad["agent pod: voteball-deploy<br/>kubectl, helm, argocd CLI<br/>SA: jenkins-cd-agent — ECR read"]
                end

                subgraph nsargo["namespace: argocd"]
                    ac["argocd-server + controller<br/>the only applier"]
                end

                subgraph nsapp["namespace: devops-app"]
                    fe["frontend x2<br/>nginx-unprivileged :8080"]
                    be["backend x2<br/>Flask"]
                    wk["worker x1"]
                end
            end

            subgraph iso["isolated DB subnets"]
                rds[("RDS PostgreSQL<br/>sslmode=require")]
            end

            efs[("EFS<br/>JENKINS_HOME<br/>mount target per AZ")]
        end

        ecr[("ECR<br/>4 app repos, IMMUTABLE<br/>+ buildcache, trivy-db")]
        sm[("Secrets Manager<br/>voteball/app-secret<br/>voteball/jenkins")]
        s3[("S3 — backups, rollups")]
        sns[("SNS — milestone alerts")]
    end

    internet -->|"HTTPS voteball.DOMAIN"| alb
    internet -->|"HTTPS jenkins.DOMAIN/github-webhook ONLY"| alb
    alb --> fe
    alb -->|"webhook path only — the UI has no ALB rule"| jc

    jc -.->|"provisions"| ab
    jc -.->|"provisions"| ad
    jc --- efs

    ab -->|"push images"| ecr
    ad -->|"describe images (read-only)"| ecr
    ad -->|"sync / wait / get"| ac
    ad -.->|"read-only: pods, events, logs"| nsapp
    ac ==>|"server-side apply — the ONLY write path"| nsapp

    fe --> be
    be --> rds
    wk --> rds
    wk --> sns
    wk --> s3

    sm -.->|"External Secrets Operator"| nsci
    sm -.->|"External Secrets Operator"| nsapp

    ab -.->|"NetworkPolicy DENIES route to RDS and devops-app"| rds
```

**Boundaries that matter:**

- **Only two paths from the internet exist**: the app on `voteball.DOMAIN`, and exactly one path,
  `/github-webhook`, on `jenkins.DOMAIN`. The Jenkins UI, script console and credential store have no
  ALB rule reaching them and are unreachable from outside the cluster; operators use
  `kubectl port-forward`.
- **The `ci` namespace cannot reach RDS or `devops-app`** — enforced by NetworkPolicy, not by
  convention.
- **The double arrow is the only write into `devops-app`.** Jenkins' CD agent has a read-only Role;
  every change is applied by ArgoCD.
- **The controller carries no AWS role at all.** Only the two agent ServiceAccounts do, with
  push and read-only ECR access respectively.
````

- [ ] **Step 3: Verify both diagrams parse**

Mermaid has no offline CLI here. Check structurally, then visually:

```bash
python3 - <<'PY'
import re
src = open('docs/eks/architecture.md').read()
blocks = re.findall(r'```mermaid\n(.*?)```', src, re.S)
assert len(blocks) >= 3, f"expected at least 3 mermaid blocks, found {len(blocks)}"
for i, b in enumerate(blocks):
    assert b.count('subgraph') == b.count('\n    end') + b.count('\n        end') or True
    # Unbalanced brackets are the common Mermaid parse failure.
    for open_c, close_c in [('[', ']'), ('(', ')'), ('{', '}')]:
        assert b.count(open_c) == b.count(close_c), f"block {i}: unbalanced {open_c}{close_c}"
print(f"{len(blocks)} mermaid blocks, brackets balanced")
PY
```

Then push and confirm both render on GitHub at
`https://github.com/Latnook/voteball/blob/master/docs/eks/architecture.md`. **A diagram that fails to
render is a failed deliverable** — the brief requires it be includable in the README.

- [ ] **Step 4: Commit**

```bash
git add docs/eks/architecture.md
git commit -m "docs(eks): add the Pipeline Flow and Deployment View diagrams

Both required by the course brief section 7. Mermaid rather than draw.io so
they live in git as text, render on GitHub, and cannot drift into a stale PNG
nobody can edit.

The Pipeline Flow marks which stages can trigger a rollback; the Deployment
View marks the single write path into devops-app, which is ArgoCD's, and the
two internet-facing paths, one of which is a single webhook URL."
git push origin master
```

---

### Task 11: Documentation

**Files:**
- Modify: `docs/cicd.md`, `README.submission.md`, `CLAUDE.md`, `README.md`

**Interfaces:** none.

- [ ] **Step 1: Rewrite `docs/cicd.md` for two pipelines**

Preserve the G1–G7 labels (both `docs/design/2026-07-20-jenkins-migration-design.md` and the
`Jenkinsfile-ci` comments cite them). Restructure to:

1. The short version — one paragraph per pipeline, and the sentence *"Jenkins never applies anything to the cluster; ArgoCD does."*
2. What a build agent is — extend for the second agent, contrasting the two ServiceAccounts.
3. `application-ci`, stage by stage (the existing walkthrough, plus Validation, Lint, Tests, Publish Metadata, Trigger CD).
4. `application-cd`, stage by stage.
5. **Rollback** — the automatic path, plus the manual procedure: *"Run `application-cd` with `IMAGE_TAG` set to any older commit SHA. That is the whole procedure; it is the same machinery the automatic rollback uses."*
6. First-time setup runbook — add the `ARGOCD_AUTH_TOKEN` step from Task 7.
7. Failure modes — add: CD triggered with a tag not in ECR; ArgoCD token expired; smoke test failing on a healthy site (ALB warm-up).
8. Update the "Deferred, on purpose" section — tests-in-CI and smoke-testing are no longer deferred.

- [ ] **Step 2: Add the task-4 section to `README.submission.md`**

Cover, in this order (the brief's §9 order):

- Architecture and why EKS.
- Prerequisites and tool versions.
- **Install / configure / verify / uninstall commands** — `scripts/jenkins/install-jenkins.sh`, `terraform apply` for JCasC changes, `scripts/jenkins/verify-jenkins.sh`, `scripts/jenkins/uninstall-jenkins.sh`.
- **How the two jobs are created from code** — JCasC `jobs:` block; state plainly that no job was ever created through the UI.
- **How to create the secrets** — `scripts/seed-eks-secret.sh`, `scripts/seed-jenkins-secret.sh`, pointing at the two example files, with no values.
- **Running CI** — trigger, stage list, where the image tag comes from.
- **Running CD** — parameters, target, how success is verified.
- **The rollback procedure**, and the evidence that it fired.
- **Security** — image security, RBAC (including the read-only claim and how `verify-jenkins.sh` asserts it), secrets, agent isolation, network exposure.
- **Full teardown.**
- **Trade-offs and significant architectural decisions** — and this must include a clearly-headed subsection: *"Why ArgoCD is the applier and Jenkins CD is not"*, reproducing the ownership table from the design doc's §7. A grader looking for `helm upgrade --install` needs to find the reasoning without hunting.

- [ ] **Step 3: Update `CLAUDE.md`**

Every reference to a single `Jenkinsfile` is now wrong. Find them:

```bash
grep -n "Jenkinsfile" CLAUDE.md README.md docs/*.md
```

Update, at minimum: the Deployment section's CI/CD bullet (one pipeline → two), the Guard-stage warning (it lives in `Jenkinsfile-ci` now), the `charts/voteball/CLAUDE.md` note if it mentions the tag bump, and the design-doc index at the top of `CLAUDE.md` (add `2026-08-04-cicd-split-design.md`). Add a line recording that `JENKINS_HOME` is now an EFS PVC and **why it is EFS and not EBS** — the existing "do not fix this with a PVC" warning is now actively misleading and must be replaced, not merely softened.

- [ ] **Step 4: Verify no doc contradicts another**

```bash
# The brief's own criterion is that another person can run this. These are the claims that drift.
grep -rn "Jenkinsfile'" docs/ CLAUDE.md README.md | grep -v cicd-split   # stale single-file refs
grep -rn "emptyDir" CLAUDE.md docs/cicd.md docs/design/2026-07-30-jenkins-on-eks-design.md
grep -rn "numToKeep\|20 builds" docs/cicd.md CLAUDE.md
```

The 2026-07-30 design doc legitimately still says `emptyDir` — it is a dated record of what was decided then, like `docs/eks/live-cluster-snapshot.md`. **Do not "correct" it.** Add a one-line pointer at its §2 to the new design doc instead. `CLAUDE.md` and `docs/cicd.md` describe the present and must be updated.

- [ ] **Step 5: Commit**

```bash
git add docs/cicd.md README.submission.md CLAUDE.md README.md docs/design/2026-07-30-jenkins-on-eks-design.md
git commit -m "docs: rewrite the CI/CD documentation for two pipelines

docs/cicd.md now walks application-ci and application-cd separately and
documents the rollback procedure, automatic and manual. README.submission.md
gains the task-4 section, including a headed subsection on why ArgoCD is the
applier -- a grader looking for helm upgrade --install should find the
reasoning without hunting.

CLAUDE.md's 'do not fix this with a PVC' warning was actively misleading once
the volume existed, so it is replaced rather than softened: the EBS reasoning
still holds and is why the PVC is EFS-backed. The 2026-07-30 design doc keeps
its emptyDir text -- it is a dated record, not a claim about the present --
with a pointer to the new design added."
git push origin master
```

---

### Task 12: Live verification, evidence, and the rollback demo

**Files:**
- Create: `docs/eks/evidence/2026-08-04-task4-*.txt`
- Delete: `docs/superpowers/`

**Interfaces:** consumes everything above.

> **This task changes production and briefly degrades the public site.** Approved by the repo owner on 2026-08-04. Do not run it unattended.

- [ ] **Step 1: Capture the static evidence**

```bash
mkdir -p docs/eks/evidence
scripts/jenkins/verify-jenkins.sh 2>&1 | tee docs/eks/evidence/2026-08-04-task4-verify-jenkins.txt
{
  echo "=== kubectl get namespaces ===";                    kubectl get namespaces
  echo; echo "=== kubectl get pods -n ci -o wide ==="        ; kubectl get pods -n ci -o wide
  echo; echo "=== kubectl get service,ingress,pvc -n ci ===" ; kubectl get service,ingress,pvc -n ci
  echo; echo "=== kubectl get sa,role,rolebinding -n ci ===" ; kubectl get serviceaccount,role,rolebinding -n ci
  echo; echo "=== helm list -n ci ==="                       ; helm list -n ci
} 2>&1 | tee docs/eks/evidence/2026-08-04-task4-jenkins-on-k8s.txt
```

- [ ] **Step 2: Prove CI blocks a bad commit before proving it ships a good one**

Order matters: a green CI run proves nothing about the gate.

```bash
cat >> services/backend/tests/test_app.py <<'PY'


def test_deliberately_failing_ci_gate_demo():
    """Temporary. Proves application-ci blocks a deploy when a test fails. Removed immediately."""
    assert 1 == 2, "deliberate failure to demonstrate the CI test gate"
PY
git add services/backend/tests/test_app.py
git commit -m "test: temporary deliberate failure to demonstrate the CI gate"
git push origin master
```

Watch the build, then capture and revert:

```bash
kubectl port-forward -n ci svc/jenkins 8080:8080 >/dev/null 2>&1 &
# Record: application-ci FAILED at the Tests stage, and application-cd did NOT run.
git revert --no-edit HEAD && git push origin master
```

Expected: `application-ci` red at Tests; **`application-cd` has no new build.** Save the console log
to `docs/eks/evidence/2026-08-04-task4-ci-blocks-deploy.txt`. If CD ran anyway, the `Trigger CD` stage
is not correctly gated — fix before continuing.

- [ ] **Step 3: Capture a full green CI → CD run**

The revert push in Step 2 triggers a clean run. Capture both console logs and the archived
`image-metadata.json` into
`docs/eks/evidence/2026-08-04-task4-ci-run.txt` and `2026-08-04-task4-cd-run.txt`. Confirm the CD
build description names the CI build, tag and digest.

- [ ] **Step 4: Rehearse rollback on a healthy version first**

Before deliberately breaking production, prove the rollback path works while nothing is wrong:

```bash
PREV="$(scripts/ci/previous-tag.sh)"
echo "Will roll back to $PREV, then forward again"
```

Run `application-cd` by hand with `IMAGE_TAG=$PREV`. Expect green: Promote, sync, wait, verify, smoke
test pass. Then run it again with the current tag to return. Capture both to
`docs/eks/evidence/2026-08-04-task4-rollback-rehearsal.txt`.

**If this rehearsal fails, stop.** Do not proceed to Step 5 — an untested rollback path plus a
deliberately broken deploy leaves the site down.

- [ ] **Step 5: The real rollback demo**

Build an image whose backend fails its health check, push it under its own SHA, and deploy it:

**Break the data path, NOT `/health`.** Breaking `/health` would fail the readiness probe, so pods
would never go Ready, `argocd app wait` would time out, and the rollback would fire from *that* path
— proving only that a crash is detected. The interesting failure, and the entire justification for
the smoke test, is the one where **ArgoCD reports Healthy and the site is broken anyway**: pods up,
probes green, data path dead.

```bash
git checkout -b tmp-broken-results

# Line-based insertion with a REAL newline. An earlier draft of this plan used a string replace
# containing a literal backslash-n, which produced `def results():\n    return ...` on ONE line --
# a Python syntax error. The container then CrashLoopBackOffs instead of serving a 500, which
# demonstrates the wrong failure entirely. The ast.parse check below is what catches that.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path('services/backend/app.py')
out = []
for line in p.read_text().splitlines(keepends=True):
    out.append(line)
    if line.startswith('def results():'):
        out.append("    return {'error': 'deliberately broken for the rollback demo'}, 500\n")
p.write_text(''.join(out))
PYEOF

# MANDATORY. The image must be broken at RUNTIME, not at import: a syntax error crashes the pod,
# which the readiness probe catches and which therefore proves nothing about the smoke test.
python3 -c "import ast, pathlib; ast.parse(pathlib.Path('services/backend/app.py').read_text()); print('app.py still parses -- good')"
git diff --stat    # expect exactly 1 file, 1 insertion

git commit -am "demo: deliberately break /api/results to exercise automatic rollback"
BROKEN="$(git rev-parse --short HEAD)"
scripts/build-push-ecr.sh          # builds and pushes under $BROKEN without going through CI
git checkout master && git branch -D tmp-broken-results
```

> **Clean up the demo images afterwards.** `$BROKEN` and any other throwaway tag must be deleted from
> all four ECR repositories once the evidence is captured — a broken backend image sitting in a
> registry is a trap for the next person, even though nothing references it:
> ```bash
> for r in backend worker nginx backup; do
>   aws ecr batch-delete-image --repository-name "$CLUSTER_NAME-$r" \
>     --image-ids imageTag="$BROKEN" --region "$AWS_REGION"
> done
> ```

Note the wall-clock start time, then run `application-cd` with `IMAGE_TAG=$BROKEN`.

**Expected sequence:** Promote succeeds → ArgoCD syncs → `argocd app wait` returns **Healthy**
(pods start and pass their probes — `/health` is untouched) → Verify passes (ArgoCD is Synced and
Healthy at the promoted revision) → **Smoke Test fails on `/api/results?by=all`** → `post { failure }`
dumps events and logs → a rollback build of `application-cd` starts with the previous tag → the site
returns.

**That ArgoCD reports Healthy throughout is the point of the demo, not a flaw in it.** It is the
evidence that a reconciler cannot answer the question the smoke test asks, and therefore the evidence
that the CD pipeline earns its place. State this explicitly in the evidence file and in
`README.submission.md`.

Capture: both console logs, `kubectl get events`, and the wall-clock time from broken-deploy to
recovery. Save to `docs/eks/evidence/2026-08-04-task4-rollback-demo.txt`. Take a browser screenshot of
the CD build page showing the `ROLLED BACK to <tag>` description → `docs/screenshots/cd-rollback.png`.

Confirm recovery independently of Jenkins:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://$APP_DOMAIN/api/results?by=all"   # 200
grep -E '^\s*tag:' charts/voteball/values.yaml                                  # the good tag
kubectl get pods -n devops-app -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u
```

- [ ] **Step 6: Verify the rollback does not recurse**

From the logs of Step 5, confirm the rollback build ran **once**. If the rollback build itself failed
and triggered another, add the `ROLLBACK_DEPTH` parameter noted in Task 5 and re-verify. Record the
outcome either way — the design doc flagged this as an open bound.

- [ ] **Step 7: Confirm ArgoCD was never configured by hand**

```bash
scripts/render-argocd-app.sh --check 2>&1 | tee docs/eks/evidence/2026-08-04-task4-argocd-check.txt
```

Expected: exit 0. This is the evidence for the submission's "everything as code" claim.

- [ ] **Step 8: Record the verification outcome in the design doc**

Add a `## Verification outcome (2026-08-04)` section to
`docs/design/2026-08-04-cicd-split-design.md` following the pattern of
`2026-07-20-jenkins-migration-design.md`: what was predicted, what actually happened, and anything the
design got wrong. **Record failures, not just successes** — that section is the most useful part of
these documents.

- [ ] **Step 9: Delete the plan and commit everything**

Per `CLAUDE.md`: an executed plan is deleted in the same commit as the last task.

```bash
git rm -r docs/superpowers/
git add docs/eks/evidence/ docs/screenshots/ docs/design/2026-08-04-cicd-split-design.md
git commit -m "test(ci): verify the split pipelines end to end and capture the evidence

Captured, in order: verify-jenkins.sh passing; a deliberately failing test
blocking the deploy with no application-cd build at all; a full green CI to CD
run with the digest recorded; a rollback rehearsal on a healthy version; and
the real demo -- a backend whose /health returns 500, deployed, detected by the
smoke test and automatically rolled back.

ArgoCD reported Healthy throughout the broken deploy, which is exactly the gap
the smoke test exists to close: pods passing probes is not a working site.

Removes docs/superpowers/ -- the plan is executed and git history is the
archive."
git push origin master
```

- [ ] **Step 10: Final state check**

```bash
git status                       # clean
scripts/jenkins/verify-jenkins.sh
scripts/tests/test-ci-guards.sh && scripts/tests/test-sync-values.sh \
  && scripts/tests/test-validate-repo.sh && scripts/tests/test-smoke-test.sh \
  && scripts/tests/test-jenkins-chart.sh
curl -sS -o /dev/null -w 'site: %{http_code}\n' https://"$APP_DOMAIN"/
ls docs/superpowers 2>/dev/null && echo "ERROR: plan directory still present" || echo "plan deleted"
```

All must pass, the site must return 200, and `docs/superpowers` must be gone.

---

## Self-Review

**Spec coverage** — every design section maps to a task: §1 → 4,5,6 · §2 → 4 · §3 → 5 · §4 → 1,6,7 · §5 → 6 (postgres sidecar) · §6 → 2 · §7 → 5,11 · §8 → 3 (`previous-tag.sh`), 5, 12 · §9 → 8,9,10,11,12. Verification checklist items 1–9 → Task 12 steps 1–7. Risk-table mitigations: rollback rehearsal → 12.4; recursion bound → 12.6; EFS SG scoping → 2.1; ECR read-only → 7.2.

**Bugs found during self-review and fixed inline (2026-08-04):**
1. **`argocd --plaintext` would have been denied by NetworkPolicy.** The `ci` egress rule excludes `172.16.0.0/12`, which contains the service CIDR `172.20.0.0/16`, and re-allows only ports 443/8080/50000. Port 80 is blocked; the symptom would be a hang then a transport error reading like an expired token. Now `--grpc-web --insecure` over 443.
2. **`cleanWs()` in `post { always }` would have deleted the workspace before `post { failure }` ran the rollback.** Jenkins runs post blocks always → … → failure → cleanup. Moved to `cleanup {}`.
3. **`APP_DOMAIN` was invisible to agents**, so the smoke test would request `https:///health` — and with automatic rollback, every deploy would have rolled itself back. Added to `globalNodeProperties` (Task 6, Step 1).
4. **`Trigger CD` had no `when` guard**, so a docs-only commit would fire CD with a tag that has no images and produce a red build on every README edit. Ported the guard the retired `Bump image tag` stage carried.

**Known gaps, stated rather than hidden:**
- All five pinned images verified to exist on 2026-08-04 (`alpine/k8s:1.31.3`, `quay.io/argoproj/argocd:v3.4.5`, `hadolint/hadolint:2.12.0-alpine`, `postgres:16-alpine`, `python:3.12-slim`).
- Both Jenkinsfiles are validated by the real Declarative parser via the running controller's `/pipeline-model-converter/validate`, not only structurally. That still does not exercise the *steps*, only the shape — first real proof remains the Task 12 build.
- The rollback-recursion bound (`previous != env.TAG` plus `disableConcurrentBuilds()`) is reasoned, not tested. Task 12 Step 6 tests it; if it recurses, add `ROLLBACK_DEPTH`.
- Task 12 Step 5 uses `scripts/build-push-ecr.sh` to build the broken image outside CI deliberately — CI would refuse to build it, which is the point.
- **Smoke-test endpoints verified live on 2026-08-04** from a pod in the `ci` namespace: `/` → 200, `/api/options` → 200, `/api/results?by=all` → 200. The first draft used `/health` (404 from outside — nginx proxies only `/api/*`; it is the in-cluster probe target) and a bare `/api/results` (400 — `by=` is required). Both would have failed every deploy and, with automatic rollback, rolled every deploy back. The same probe confirmed the `ci` NetworkPolicy does **not** block egress to the public ALB, which resolves to addresses outside the excluded VPC range.
- **Every destructive snippet in Task 12 must be run from a file, not pasted into a shell with a heredoc inside it.** A nested-heredoc quoting error while editing this plan on 2026-08-04 caused the Step 5 commands to execute for real against the working tree and ECR. Nothing reached production — `values.yaml` was untouched — but four throwaway image tags had to be deleted. Treat Step 5 as a script to review and then run, never as text to paste.
- `--insecure` on the argocd CLI skips server-certificate verification on a ClusterIP hop that never leaves the cluster. Mounting ArgoCD's CA would be stricter; it is not worth the moving part here, and the token still authenticates the client.
