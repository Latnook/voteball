#!/usr/bin/env bash
# Offline guard: terraform/modules/compute/main.tf must declare the three networking add-ons a NEW
# EKS cluster needs, with vpc-cni and kube-proxy created BEFORE the node group.
#
# Why this exists (2026-09-15): terraform-aws-modules/eks v21 hardcodes
# bootstrap_self_managed_addons = false, so a new cluster gets no VPC CNI, kube-proxy or CoreDNS
# unless they are listed. An add-on without before_compute is created AFTER the node group, which
# waits for Ready nodes that can never exist without a CNI. The first rebuild on v21 deadlocked for
# 31 minutes and left six half-installed Helm releases behind. The in-place upgrade that introduced
# it passed every check, because an existing cluster already had all three -- which is exactly why
# this is a static check on the file and not something a plan against a live cluster would show.
#
# COMPUTE_TF overrides the file, so the test can prove it fails on a broken copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF="${COMPUTE_TF:-$ROOT/terraform/modules/compute/main.tf}"

python3 - "$TF" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Strip comments so a commented-out block cannot satisfy the check.
code = "\n".join(re.sub(r'\s*#.*$', '', l) for l in src.splitlines())

def block(text, header):
    m = re.search(header, text)
    if not m:
        return None
    i = text.index('{', m.end() - 1)
    depth = 0
    for j in range(i, len(text)):
        depth += {'{': 1, '}': -1}.get(text[j], 0)
        if depth == 0:
            return text[i + 1:j]
    return None

errors = []
addons = block(code, r'\baddons\s*=\s*\{')
if addons is None:
    print("FAIL: no `addons = {` block in", sys.argv[1]); sys.exit(1)

want = {'vpc-cni': True, 'kube-proxy': True, 'coredns': False}
for name, before in want.items():
    body = block(addons, r'(^|\s)"?' + re.escape(name) + r'"?\s*=\s*\{')
    if body is None:
        errors.append(f"add-on `{name}` is not declared -- a new cluster would have none")
        continue
    has = re.search(r'\bbefore_compute\s*=\s*true\b', body) is not None
    if before and not has:
        errors.append(f"`{name}` must set before_compute = true, or it is created after the node group it is needed by")
    if not before and has:
        errors.append(f"`{name}` must NOT be before_compute: it is a Deployment and needs Ready nodes to schedule")
if errors:
    for e in errors: print("FAIL:", e)
    sys.exit(1)
print("  ok: vpc-cni and kube-proxy are declared before_compute; coredns follows the nodes")
PY

# Prove the check can fail, against copies with each property broken in turn.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mutate() { # <name> <python replacement expression>
  python3 - "$TF" "$work/$1.tf" "$2" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); exec("s = " + sys.argv[3]); open(sys.argv[2], 'w').write(s)
PY
  if COMPUTE_TF="$work/$1.tf" "$0" --no-mutations >/dev/null 2>&1; then
    echo "FAIL: the check passed against a copy with $1 -- it cannot catch that regression"; exit 1
  fi
  echo "  ok: fails when $1"
}
if [ "${1:-}" != "--no-mutations" ]; then
  mutate "vpc-cni not before_compute" \
    "re.sub(r'(vpc-cni\s*=\s*\{)(.*?)before_compute\s*=\s*true', r'\1\2before_compute = false', s, count=1, flags=re.S)"
  mutate "kube-proxy removed" \
    "re.sub(r'\n\s*kube-proxy\s*=\s*\{.*?\n\s*\}', '', s, count=1, flags=re.S)"
  mutate "coredns made before_compute" \
    "re.sub(r'(coredns\s*=\s*\{)', r'\1\n      before_compute = true', s, count=1)"
fi
echo "PASS: scripts/tests/test-eks-addons.sh"
