# AWS provider 6, EKS module v21, IAM module v6, Kubernetes provider v3

**Date:** 2026-09-15 · **Status:** applied to the live cluster, in place, in four phases

## Why

`terraform/versions.tf` pinned `aws ~> 5.0` because `terraform-aws-modules/eks` v20 capped the provider
below 6.0, and 20.37.2 was the last v20 release. Every plan and apply carried a `resolve_conflicts`
deprecation warning from inside that module, and the IAM role module (v5) added eight more under
AWS provider 6. The Kubernetes provider's unversioned resource names are deprecated in its v3.

## Constraint that shaped every decision

Upgrade **in place, with nothing important replaced**: not the EKS cluster, the node group, RDS, or
any IRSA role. Each phase was planned, the saved plan was classified change by change, and only that
exact plan file was applied. Any replacement of those resources was a stop condition.

## Phase 1 -- AWS provider 6.64.0 + EKS module 21.25.0

- Renamed inputs only (`cluster_name` -> `name`, `cluster_version` -> `kubernetes_version`,
  `cluster_endpoint_public_access*` -> `endpoint_public_access*`, `cluster_addons` -> `addons`).
  Every output this stack reads kept its name.
- **v21 changed three node-group defaults, and two replace every node**: IMDS hop limit 2 -> 1 and
  `use_latest_ami_release_version` false -> true (both change the launch template or AMI release).
  `enable_monitoring` also flipped true -> false. All three are pinned to their v20 values in
  `modules/compute/main.tf`. Hop limit 1 is the more secure setting (pods cannot read the node's
  IMDS credentials) and is worth adopting as its own planned node rollout.
- The vpc-cni addon keeps `most_recent = false`; v21 defaults it to true.
- Checked in the v21 source rather than trusted from the upgrade guide: the IRSA OIDC provider URL is
  still the cluster's own issuer (only the thumbprint lookup moved to the dual-stack endpoint), and
  `bootstrap_self_managed_addons`, now hardcoded false, sits in the cluster's `ignore_changes`, so it
  cannot force a cluster replacement.
- Result: 2 added, 2 changed, 4 destroyed. Dropped by v21 and unused here: the Auto Mode `custom`
  policy and the `AmazonEKSVPCResourceController` attachment (per-pod security groups).

## Phase 2 -- IAM module v6 for the eight IRSA roles

- `iam-role-for-service-accounts-eks` -> `iam-role-for-service-accounts`, `role_name` -> `name`,
  `role_policy_arns` -> `policies`, output `iam_role_arn` -> `arn`.
- **`use_name_prefix = false` on every role.** v6 defaults it to true, which renames and therefore
  replaces the role, breaking IRSA until every consumer picks up a new ARN.
- v6 consolidates each role's generated policy into one. **Permissions were diffed per role before
  applying**: identical for the ALB controller, cluster autoscaler, EFS CSI and external-dns; EBS CSI
  gains `ec2:DescribeInstanceTypes`; External Secrets loses `kms:Decrypt` on any key and SSM
  parameter reads. Neither is used: all three SecretStores are Secrets Manager and all three secrets
  use the AWS-managed key. That loss is a least-privilege gain.
- `moved` blocks keep the cloudwatch and jenkins-cd attachments (caller-supplied ARNs, now under
  `additional`) from being detached and re-attached. They stay in `addon-cloudwatch.tf` and
  `addon-jenkins.tf`; on a from-scratch apply a `moved` with no source is a no-op.
- Follow-up in the same pass: v6's default policy names (`External_DNS`, `EBS_CSI`, ...) are unique
  per account and unprefixed, so a fork or second cluster would collide. `policy_name` is now
  `${var.cluster_name}-<role>`.
- Result: 12 + 12 policies/attachments replaced, twice, no role touched, zero AccessDenied in any
  IRSA controller afterwards, a forced ExternalSecret refresh synced.

## Phase 3 -- Kubernetes provider 3.2.1

- The provider cannot move state between resource **types**, so `kubernetes_namespace` (3) and
  `kubernetes_storage_class` (2) became `_v1` via `removed { lifecycle { destroy = false } }` plus
  `import` blocks. The plan was 5 imports, 5 forgets, 0 created, 0 destroyed; the three "updates"
  were `wait_for_default_service_account` (Terraform-only) and the `kubernetes.io/metadata.name`
  label Kubernetes already sets on every namespace.
- **The migration file was deleted in the commit that recorded the apply.** Its `import` blocks
  would fail every from-scratch deploy, since the namespaces do not exist yet on a new cluster.
- The destroy-order edges `CLAUDE.md` relies on survive the rename
  (`terraform graph | grep 'kubernetes_namespace.* -> "helm_release.external_secrets"'`), and
  `destroy.sh`'s state-rm filter (`kubernetes_[a-zA-Z0-9_]+`) matches the new names.

## Verification outcome

After all phases: `terraform validate` prints no warnings, a full plan reports **No changes** with no
warnings, all nodes Ready, vpc-cni unchanged (v1.22.4-eksbuild.3), all ExternalSecrets synced, the
site served 200 throughout.

**Verified from scratch on 2026-09-16, after the fix:** vpc-cni and kube-proxy created BEFORE the
node group (7s), the node group itself **1m47s** (against 31m+ deadlocked), coredns 24s after the
nodes, 150 resources added, zero Terraform warnings or errors, site 200. The
clean-failed-helm-installs step correctly no-opped ("no cluster yet") and the watcher printed no
CNI diagnosis, which is the right answer on a healthy run.

**The first from-scratch deploy on these versions (2026-09-15, before that fix) failed exactly where warned.**
eks v21 hardcodes `bootstrap_self_managed_addons = false`, so a new cluster gets no VPC CNI, kube-proxy
or CoreDNS unless they are declared as add-ons -- and v20's config declared only vpc-cni, without
`before_compute`, which v21 creates after the node group. The node group then waited for nodes that
could never become Ready (`cni plugin not initialized`), 26+ minutes in. The in-place upgrade could
not reveal it: the old cluster already had all three add-ons and the flag is in `ignore_changes`.
Fix: all three declared, vpc-cni and kube-proxy `before_compute`. **Lesson: a module upgrade's
create path is a separate contract from its update path; verify both before calling it done.**

**Superseded note, kept as written:** *Not yet exercised: a from-scratch deploy.* Every phase was proven against an existing cluster
only. The first rebuild on these versions is the real test of the create path, and is where a v21
or IAM v6 ordering issue that an in-place upgrade cannot show would surface.
