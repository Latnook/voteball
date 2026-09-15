#!/usr/bin/env bash
# Offline test for scripts/clean-failed-helm-installs.sh. aws, helm and terraform are fakes; the
# fake helm records every uninstall so the test can assert exactly which releases were removed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/clean-failed-helm-installs.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tf"
# A Terraform dir declaring three releases: two literal names, one expression (never eligible).
cat > "$work/tf/addons.tf" <<'TF'
resource "helm_release" "argocd" {
  name      = "argocd"
  namespace = "argocd"
  set = [
    { name = "server.name", value = "x" },
  ]
}
resource "helm_release" "external_dns" {
  name      = "external-dns"   # trailing comment
  namespace = "kube-system"
}
resource "helm_release" "computed" {
  name      = "${var.cluster_name}-thing"
  namespace = "kube-system"
}
TF
cat > "$work/tf/voteball.tfvars" <<'TF'
cluster_name = "voteball"
aws_region   = "il-central-1"
app_domain   = "example.test"
route53_zone_name = "example.test"
TF

cat > "$work/aws" <<'STUB'
#!/usr/bin/env bash
[ "${NO_CLUSTER:-0}" = 1 ] && [[ "$*" == *describe-cluster* ]] && exit 254
exit 0
STUB
cat > "$work/helm" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) cat "$HELM_LIST" ;;
  uninstall) echo "$2 $4" >> "$UNINSTALLS" ;;
esac
STUB
cat > "$work/terraform" <<'STUB'
#!/usr/bin/env bash
cat "$TF_STATE"
STUB
chmod +x "$work/aws" "$work/helm" "$work/terraform"

export CLEANHELM_STUB_AWS_CMD="$work/aws" CLEANHELM_STUB_HELM_CMD="$work/helm" CLEANHELM_STUB_TERRAFORM_CMD="$work/terraform"
export TF_DIR="$work/tf" TFVARS="$work/tf/voteball.tfvars"
export HELM_LIST="$work/list.json" TF_STATE="$work/state.json" UNINSTALLS="$work/uninstalls"

run() { : > "$UNINSTALLS"; "$SCRIPT" 2>&1; }

# ---- the incident: failed revision-1 releases, declared, not in state -> removed ----------------
cat > "$HELM_LIST" <<'J'
[{"name":"argocd","namespace":"argocd","status":"failed","revision":"1"},
 {"name":"external-dns","namespace":"kube-system","status":"pending-install","revision":1}]
J
echo '{"values":{"root_module":{"resources":[]}}}' > "$TF_STATE"
out="$(run)"
grep -qx "argocd argocd" "$UNINSTALLS" || fail "a failed first install Terraform declares must be removed: $out"
grep -qx "external-dns kube-system" "$UNINSTALLS" || fail "pending-install counts as a failed first install too: $out"
ok "removes failed and pending first installs that Terraform declares but does not track"

# ---- a failed UPGRADE (revision > 1) of a release that once worked is left alone ---------------
echo '[{"name":"argocd","namespace":"argocd","status":"failed","revision":"4"}]' > "$HELM_LIST"
out="$(run)"
[ -s "$UNINSTALLS" ] && fail "a failed upgrade must never be uninstalled: $(cat "$UNINSTALLS")"
grep -q "revision 4" <<<"$out" || fail "the skip must say why: $out"
ok "leaves a failed upgrade (revision > 1) for a human"

# ---- a release Terraform already tracks is left to Terraform -----------------------------------
echo '[{"name":"argocd","namespace":"argocd","status":"failed","revision":"1"}]' > "$HELM_LIST"
echo '{"values":{"root_module":{"child_modules":[{"resources":[{"type":"helm_release","values":{"name":"argocd","namespace":"argocd"}}]}]}}}' > "$TF_STATE"
out="$(run)"
[ -s "$UNINSTALLS" ] && fail "a release in Terraform state must not be uninstalled: $out"
ok "leaves a release that is in Terraform state (including in a child module)"

# ---- a release Terraform does not declare (ArgoCD-, CI- or hand-installed) is out of scope -------
echo '[{"name":"voteball","namespace":"devops-app","status":"failed","revision":"1"},
 {"name":"voteball-thing","namespace":"kube-system","status":"failed","revision":"1"},
 {"name":"server.name","namespace":"argocd","status":"failed","revision":"1"}]' > "$HELM_LIST"
echo '{}' > "$TF_STATE"
out="$(run)"
[ -s "$UNINSTALLS" ] && fail "only literal Terraform-declared names may be removed, got: $(cat "$UNINSTALLS")"
ok "leaves releases not declared by a literal helm_release name (incl. nested set names and expressions)"

# ---- deployed releases are never even considered ------------------------------------------------
echo '[]' > "$HELM_LIST"
out="$(run)"
[ -s "$UNINSTALLS" ] && fail "nothing failed means nothing removed"
grep -q "no failed first-install" <<<"$out" || fail "the clean case must say so: $out"
ok "does nothing, and says so, when no release failed"

# ---- no cluster yet (a fresh deploy) -> no helm call at all, exit 0 -----------------------------
: > "$UNINSTALLS"
out="$(NO_CLUSTER=1 "$SCRIPT" 2>&1)" || fail "a missing cluster must exit 0: $out"
grep -q "no cluster" <<<"$out" || fail "must report there is no cluster yet: $out"
[ -s "$UNINSTALLS" ] && fail "no cluster means no uninstall"
ok "a fresh deploy with no cluster yet is a clean no-op"

# ---- deploy.sh calls it before the full apply, and does not let it fail the deploy --------------
line_clean="$(grep -n 'clean-failed-helm-installs.sh' "$ROOT/scripts/deploy.sh" | head -1 | cut -d: -f1)"
line_apply="$(grep -n 'terraform -chdir=terraform apply -compact-warnings -var-file="\$TFVARS" "\${APPROVE\[@\]}"' "$ROOT/scripts/deploy.sh" | cut -d: -f1)"
[ -n "$line_clean" ] || fail "deploy.sh does not call clean-failed-helm-installs.sh"
[ -n "$line_apply" ] || fail "could not find deploy.sh's full apply line"
[ "$line_clean" -lt "$line_apply" ] || fail "the cleanup must run BEFORE the full apply (line $line_clean vs $line_apply)"
grep -n 'clean-failed-helm-installs.sh' "$ROOT/scripts/deploy.sh" | head -1 | grep -q '|| true' \
  || fail "deploy.sh must not let the cleanup's exit status stop a billed deploy"
ok "deploy.sh runs it before the full apply, non-fatally"

echo "PASS: scripts/tests/test-clean-failed-helm-installs.sh"
