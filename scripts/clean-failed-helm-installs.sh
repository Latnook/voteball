#!/usr/bin/env bash
# Before deploy.sh's full apply: uninstall Helm releases whose FIRST install failed and that
# Terraform does not track, so the apply can install them cleanly instead of dying on
# "cannot re-use a name that is still in use".
#
# The failure this exists for (2026-09-15): a deploy whose node group never became Ready timed out
# every helm_release waiting on it. Helm kept each one as a `failed` revision 1; Terraform recorded
# none of them. The next deploy then failed six times over on the name collision, and recovery was
# six hand-typed `helm uninstall`s.
#
# A release is removed only when ALL of these hold -- each one exists to protect something:
#   * status failed or pending-install  (a working release is never touched)
#   * revision 1                        (it has NEVER deployed successfully, so there is no working
#                                        state to lose; a failed UPGRADE of a good release is left
#                                        alone for a human)
#   * its name is declared as a literal `name = "..."` in a terraform/*.tf helm_release block
#                                       (ArgoCD-, CI- or hand-installed releases are out of scope)
#   * it is NOT in Terraform state      (Terraform will not try to install it -- or it would already
#                                        own it and handle it itself)
#
# Non-fatal by design: anything it cannot determine is reported and skipped, and deploy.sh ignores
# its exit status. The apply that follows is the real check.
#
# Offline-testable: CLEANHELM_STUB_{AWS,HELM,TERRAFORM}_CMD replace the binaries.
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh
. scripts/lib/config.sh

AWS_CMD="${CLEANHELM_STUB_AWS_CMD:-aws}"
HELM_CMD="${CLEANHELM_STUB_HELM_CMD:-helm}"
TF_CMD="${CLEANHELM_STUB_TERRAFORM_CMD:-terraform}"

if ! "$AWS_CMD" eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.status --output text >/dev/null 2>&1; then
  echo "    no cluster '$CLUSTER' yet -- nothing to clean."
  exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export KUBECONFIG="$work/kubeconfig"
"$AWS_CMD" eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 \
  || { echo "    could not reach cluster '$CLUSTER' -- skipping the failed-release check."; exit 0; }

"$HELM_CMD" list -A --failed --pending -o json > "$work/failed.json" 2>/dev/null \
  || { echo "    helm list failed -- skipping the failed-release check."; exit 0; }
"$TF_CMD" -chdir="$TF_DIR" show -json > "$work/state.json" 2>/dev/null || echo '{}' > "$work/state.json"

python3 - "$work/failed.json" "$work/state.json" "$TF_DIR" > "$work/targets" <<'PY'
import json, re, sys, glob, os
text = open(sys.argv[1]).read().strip()
failed = json.loads(text) if text else []
try:
    state = json.load(open(sys.argv[2]))
except Exception:
    state = {}

def modules(m):
    yield m
    for c in m.get('child_modules', []) or []:
        yield from modules(c)
in_state = set()
root = ((state.get('values') or {}).get('root_module')) or {}
for m in modules(root):
    for r in m.get('resources', []) or []:
        if r.get('type') == 'helm_release':
            v = r.get('values') or {}
            in_state.add((v.get('name'), v.get('namespace')))

declared = set()
for f in glob.glob(os.path.join(sys.argv[3], '*.tf')):
    code = "\n".join(re.sub(r'\s*#.*$', '', l) for l in open(f).read().splitlines())
    for m in re.finditer(r'resource\s+"helm_release"\s+"[^"]+"\s*\{', code):
        i, depth = m.end() - 1, 0
        for j in range(i, len(code)):
            depth += {'{': 1, '}': -1}.get(code[j], 0)
            if depth == 0:
                break
        body = code[i + 1:j]
        # top-level `name = "literal"` only: depth-0 lines of the block
        d, top = 0, []
        for line in body.splitlines():
            if d == 0:
                top.append(line)
            d += line.count('{') + line.count('[') - line.count('}') - line.count(']')
        for line in top:
            nm = re.match(r'\s*name\s*=\s*"([^"$]+)"\s*$', line)
            if nm:
                declared.add(nm.group(1))

for r in failed:
    name, ns, status, rev = r.get('name'), r.get('namespace'), r.get('status'), str(r.get('revision'))
    if status not in ('failed', 'pending-install'):
        continue
    why = None
    if rev != '1':
        why = f"revision {rev}: it deployed successfully before, leaving it for a human"
    elif name not in declared:
        why = "not a Terraform-declared release"
    elif (name, ns) in in_state or any(n == name for n, _ in in_state):
        why = "Terraform already tracks it"
    print(("SKIP" if why else "REMOVE") + f"\t{name}\t{ns}\t{status}\t{why or ''}")
PY

removed=0
while IFS=$'\t' read -r action name ns status why; do
  [ -z "$action" ] && continue
  if [ "$action" = SKIP ]; then
    echo "    leaving $ns/$name ($status): $why"
    continue
  fi
  echo "    removing $ns/$name: first install $status and Terraform does not track it"
  if "$HELM_CMD" uninstall "$name" -n "$ns" >/dev/null 2>&1; then
    removed=$((removed + 1))
  else
    echo "    WARNING: could not uninstall $ns/$name -- the apply will fail on it; remove it by hand." >&2
  fi
done < "$work/targets"
[ "$removed" -gt 0 ] && echo "    removed $removed failed first-install release(s); the apply will reinstall them."
[ -s "$work/targets" ] || echo "    no failed first-install Helm releases."
exit 0
