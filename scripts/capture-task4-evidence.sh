#!/usr/bin/env bash
# Capture the Task 4 (Jenkins CI/CD on Kubernetes) submission evidence from the LIVE cluster into
# docs/eks/evidence/<date>-task4-*.txt.
#
# Why this is a script and not a list of commands in a doc: the 2026-08-04 task4 set WAS hand-run,
# and by 2026-08-17 it no longer showed the Script-tests stage, the resolved plugin versions, or any
# of the brief's section-2 mandatory components (pinned image, probes, resource limits,
# securityContext) -- exactly the drift `capture-evidence.sh` was written to stop for the section-10
# kubectl outputs. Re-running this is the cheap path.
#
# Captured evidence is DATED and never edited afterwards. A value in an old file that no longer
# resolves is the file working as intended; capture a new set rather than "correcting" an old one.
#
# Usage:
#   ./scripts/capture-task4-evidence.sh                    # all static captures
#   ./scripts/capture-task4-evidence.sh --build-log application-ci 3            # a build console log
#   ./scripts/capture-task4-evidence.sh --build-log application-ci 1 scan-blocks-deploy
#
# Static captures are read-only -- nothing here mutates the cluster, triggers a build, or pushes a
# commit. The CI/CD run and rollback captures are deliberately NOT automated: which build to trigger,
# and whether it is safe to fail one on purpose, are judgement calls that belong to an operator.
set -uo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=docs/eks/evidence
DATE="$(date +%F)"
PREFIX="${OUT_DIR}/${DATE}-task4"

kubectl get namespace ci >/dev/null 2>&1 || {
  echo "ERROR: cannot reach the cluster / namespace ci." >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Jenkins API access. The webhook Ingress deliberately exposes ONLY /github-webhook (asserted by
# scripts/jenkins/verify-jenkins.sh), so the controller API is reachable only by port-forward.
#
# GETs need no CSRF crumb -- Jenkins enforces the crumb+cookie pair on state-changing requests only.
# Credentials are passed to curl via --netrc-file rather than -u: this script's output is committed,
# and `set -x`-style traces or a `ps` listing would expose a -u argument. Nothing here echoes them.
# ---------------------------------------------------------------------------------------------
JPF_PID=""; JPF_PORT=""; JPF_LOG=""; JPF_NETRC=""
jenkins_cleanup() {
  [ -n "$JPF_PID" ] && { kill "$JPF_PID" 2>/dev/null; wait "$JPF_PID" 2>/dev/null; }
  [ -n "$JPF_LOG" ] && rm -f "$JPF_LOG"
  [ -n "$JPF_NETRC" ] && rm -f "$JPF_NETRC"
  JPF_PID=""; JPF_PORT=""
}
trap jenkins_cleanup EXIT

jenkins_up() {
  [ -n "$JPF_PORT" ] && return 0
  if [ -z "${JENKINS_ADMIN_USER:-}" ] || [ -z "${JENKINS_ADMIN_PASSWORD:-}" ]; then
    return 1
  fi
  JPF_LOG="$(mktemp)"
  kubectl port-forward -n ci svc/jenkins 0:8080 >"$JPF_LOG" 2>&1 &
  JPF_PID=$!
  for _ in $(seq 1 20); do
    JPF_PORT="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' "$JPF_LOG" | head -1)"
    [ -n "$JPF_PORT" ] && break
    sleep 0.5
  done
  [ -n "$JPF_PORT" ] || return 1
  JPF_NETRC="$(mktemp)"
  chmod 600 "$JPF_NETRC"
  printf 'machine 127.0.0.1 login %s password %s\n' \
    "$JENKINS_ADMIN_USER" "$JENKINS_ADMIN_PASSWORD" >"$JPF_NETRC"
  return 0
}

# jenkins_get PATH -- echoes the response body, or returns non-zero.
jenkins_get() {
  jenkins_up || return 1
  curl -sS -g --netrc-file "$JPF_NETRC" "http://127.0.0.1:${JPF_PORT}$1"
}

# The running Jenkins version. It is NOT in /api/json (there is no .jenkinsVersion field there) --
# Jenkins reports it in the X-Jenkins response header, which is why the first version of this
# capture recorded "unknown".
jenkins_version() {
  jenkins_up || return 1
  curl -sSI -g --netrc-file "$JPF_NETRC" "http://127.0.0.1:${JPF_PORT}/api/json" \
    | sed -nE 's/^[Xx]-[Jj]enkins: *([^ \r]+).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------------------------
# --build-log JOB NUMBER -- fetch one build's full console log.
# ---------------------------------------------------------------------------------------------
if [ "${1:-}" = "--build-log" ]; then
  job="${2:?usage: --build-log JOB NUMBER [SUFFIX]}"
  num="${3:?usage: --build-log JOB NUMBER [SUFFIX]}"
  # An optional SUFFIX names the file for what the build DEMONSTRATES rather than just which job ran.
  # A pipeline's failure behaviour is as much required evidence as its happy path (the brief's
  # "התנהגות במקרי כשל"), and two runs of the same job can show opposite things -- a scan gate
  # blocking a deploy, and a path filter correctly skipping one.
  suffix="${4:-}"
  case "$job" in
    application-ci) out="${PREFIX}-ci${suffix:+-$suffix}-run.txt" ;;
    application-cd) out="${PREFIX}-cd${suffix:+-$suffix}-run.txt" ;;
    *) echo "ERROR: unknown job '$job'" >&2; exit 1 ;;
  esac
  jenkins_get "/job/${job}/${num}/consoleText" >"$out" || {
    echo "ERROR: could not fetch ${job} #${num} (are JENKINS_ADMIN_USER/PASSWORD set?)" >&2; exit 1; }
  # A console log is the one capture that can contain a secret Jenkins failed to mask -- a runtime-
  # fetched token in argument position gets printed by `set -x` (this leaked a live ECR token into
  # committed evidence on 2026-08-04). Refuse to leave such a file on disk.
  if grep -qE 'eyJwYXlsb2FkIjoi|AWS:[A-Za-z0-9+/]{40,}|ADMIN_PASSWORD_HASH=[^ ]' "$out"; then
    rm -f "$out"
    echo "ERROR: ${job} #${num} console log appears to contain a credential; NOT written." >&2
    exit 1
  fi
  echo "wrote $out ($(wc -l <"$out") lines)"
  exit 0
fi

[ $# -eq 0 ] || { echo "ERROR: unexpected argument '$1'" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# 1. Jenkins on Kubernetes -- the brief's section-2 mandatory components and section-6 container
#    security, read off the RUNNING objects rather than off the Terraform/JCasC source. The source
#    says what was intended; only the live spec says what is actually running.
# ---------------------------------------------------------------------------------------------
K8S_OUT="${PREFIX}-jenkins-on-k8s.txt"
{
  echo "# Task 4 evidence -- Jenkins on Kubernetes (captured ${DATE})"
  echo "# Read off the live cluster by scripts/capture-task4-evidence.sh. Never edited afterwards."
  echo
  echo "=== namespace separation: Jenkins in ci, the app in devops-app, neither in default ==="
  kubectl get namespaces
  echo
  echo "=== kubectl get pods -n ci -o wide ==="
  kubectl get pods -n ci -o wide
  echo
  echo "=== kubectl get service,ingress,pvc -n ci ==="
  kubectl get service,ingress,pvc -n ci
  echo
  echo "=== the JENKINS_HOME PersistentVolume and its StorageClass (Retain, EFS-backed) ==="
  kubectl get sc efs-sc
  kubectl get pv "$(kubectl get pvc jenkins -n ci -o jsonpath='{.spec.volumeName}')" 2>/dev/null
  echo
  echo "=== controller images are PINNED -- no :latest anywhere ==="
  kubectl -n ci get statefulset jenkins \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
  echo "-- grep for a :latest tag (expect no output):"
  kubectl -n ci get statefulset jenkins -o jsonpath='{..image}' | tr ' ' '\n' | grep ':latest' || true
  echo
  echo "=== controller probes, resource requests/limits and securityContext ==="
  kubectl -n ci get statefulset jenkins -o json | jq '
    .spec.template.spec as $p
    | {
        podSecurityContext: $p.securityContext,
        containers: [ $p.containers[] | {
          name, image,
          resources,
          securityContext,
          livenessProbe:  (.livenessProbe  // null | if . == null then null else {httpGet, periodSeconds, failureThreshold, timeoutSeconds} end),
          readinessProbe: (.readinessProbe // null | if . == null then null else {httpGet, periodSeconds, failureThreshold, timeoutSeconds} end)
        } ]
      }'
  echo
  echo "=== the controller runs NO builds, and holds NO AWS role ==="
  echo "-- numExecutors (expect 0 -- every build runs on an ephemeral agent pod):"
  jenkins_get '/api/json' | jq -r '.numExecutors // "unavailable (no credentials)"' \
    || echo "unavailable (no credentials)"
  echo "-- controller ServiceAccount IRSA annotation (expect none):"
  kubectl -n ci get sa jenkins -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' \
    || true
  echo "(empty above == the controller carries no AWS role)"
  echo "-- agent ServiceAccount IRSA roles (these DO carry one, least-privilege):"
  for sa in jenkins-agent jenkins-cd-agent; do
    printf '%s\t%s\n' "$sa" \
      "$(kubectl -n ci get sa "$sa" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)"
  done
  echo
  echo "=== the two agent pod templates declared in JCasC (CI and CD are separate) ==="
  # Parsed as YAML, not grepped. Each template's pod spec is an embedded `yaml: |` STRING, so a
  # flat `grep '- name:'` cannot tell a container from a volume -- the first version of this capture
  # listed `images`, `buildkit-state` and `pgdata` (all volumes) as containers.
  python3 - <<'PY'
import yaml

doc = yaml.safe_load(open('ci/jenkins/jenkins.yaml'))

def find_templates(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == 'templates' and isinstance(v, list):
                yield from (t for t in v if isinstance(t, dict) and 'yaml' in t)
            else:
                yield from find_templates(v)
    elif isinstance(node, list):
        for item in node:
            yield from find_templates(item)

for tpl in find_templates(doc):
    pod = yaml.safe_load(tpl['yaml'])
    spec = pod.get('spec', {})
    containers = spec.get('containers', [])
    volumes = [v.get('name') for v in spec.get('volumes', [])]
    print(f"template: {tpl.get('name')}  (label: {tpl.get('label')})")
    print(f"  serviceAccountName: {spec.get('serviceAccountName')}")
    print(f"  pod securityContext: {spec.get('securityContext')}")
    print(f"  containers ({len(containers)}):")
    for c in containers:
        sc = c.get('securityContext') or {}
        ape = sc.get('allowPrivilegeEscalation')
        caps = sc.get('capabilities') or {}
        res = c.get('resources') or {}
        print(f"    - {c['name']:<10} image={c.get('image')}")
        print(f"      allowPrivilegeEscalation={ape}  runAsUser={sc.get('runAsUser')}"
              f"  capabilities={{drop:{caps.get('drop')}, add:{caps.get('add')}}}")
        print(f"      resources: requests={res.get('requests')} limits={res.get('limits')}")
    print(f"  volumes ({len(volumes)}): {volumes}")
    print()
PY
  echo "-- the ONE deliberate exception, and it is scoped to a single CI container:"
  python3 - <<'PY'
import yaml
doc = yaml.safe_load(open('ci/jenkins/jenkins.yaml'))
def find_templates(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == 'templates' and isinstance(v, list):
                yield from (t for t in v if isinstance(t, dict) and 'yaml' in t)
            else:
                yield from find_templates(v)
    elif isinstance(node, list):
        for item in node:
            yield from find_templates(item)
offenders = []
for tpl in find_templates(doc):
    for c in yaml.safe_load(tpl['yaml']).get('spec', {}).get('containers', []):
        sc = c.get('securityContext') or {}
        if sc.get('allowPrivilegeEscalation') is not False:
            offenders.append((tpl.get('name'), c['name'], sc.get('allowPrivilegeEscalation')))
for t, c, v in offenders:
    print(f"    {t}/{c}: allowPrivilegeEscalation={v}  <- rootless BuildKit needs SETUID/SETGID")
print(f"    total containers allowing privilege escalation: {len(offenders)}"
      f" (expected 1: voteball-build/buildkit)")
print("    NOTE: no container mounts /var/run/docker.sock -- this is rootless BuildKit,")
print("          not Docker-in-Docker. Verify with the grep below.")
PY
  echo "-- docker.sock is mounted nowhere in JCasC (expect no output):"
  grep -n 'docker.sock' ci/jenkins/jenkins.yaml || true
  echo
  echo "=== NetworkPolicy is present in ci (the brief's section-6 network requirement) ==="
  kubectl -n ci get networkpolicy
  echo
  echo "=== the CD identity is read-only in devops-app (ArgoCD is the only applier) ==="
  echo "-- can-i patch deployments (expect no):"
  kubectl auth can-i patch deployments \
    --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app
  echo "-- can-i list pods (expect yes):"
  kubectl auth can-i list pods \
    --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app
  echo "-- can-i create secrets anywhere (expect no):"
  kubectl auth can-i create secrets \
    --as=system:serviceaccount:ci:jenkins-cd-agent -n devops-app
  echo
  echo "=== no cluster-admin anywhere in ci ==="
  kubectl get clusterrolebinding -o json \
    | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
             | .subjects[]? | select(.namespace=="ci") | "FOUND: \(.kind)/\(.name)"' \
    || true
  echo "(no FOUND lines above == nothing in ci is cluster-admin)"
  echo
  echo "=== helm list -n ci ==="
  helm list -n ci
} >"$K8S_OUT" 2>&1
echo "wrote $K8S_OUT"

# ---------------------------------------------------------------------------------------------
# 2. Resolved plugin versions. ci/jenkins/plugins.txt deliberately names NO versions -- the
#    controller image tag is the pin, and ci/jenkins/Dockerfile's `jenkins-plugin-cli --verbose
#    --list` records the resolved set in the IMAGE BUILD LOG. That is a sound arrangement, but the
#    build log is ephemeral and lives outside the repository, so nothing a reviewer can open says
#    which versions a given tag contains. This capture is the durable half: the versions actually
#    loaded, next to the image tag that pins them.
# ---------------------------------------------------------------------------------------------
PLUGINS_OUT="${PREFIX}-plugins-resolved.txt"
if plugins_json="$(jenkins_get '/pluginManager/api/json?depth=1')" && [ -n "$plugins_json" ]; then
  {
    echo "# Task 4 evidence -- resolved Jenkins plugin versions (captured ${DATE})"
    echo "#"
    echo "# ci/jenkins/plugins.txt names top-level plugins with NO versions on purpose: the plugins"
    echo "# are baked into an immutable ECR image, so the image TAG is the pin, and the Dockerfile's"
    echo "# 'jenkins-plugin-cli --verbose --list' records the resolved set in the image build log."
    echo "# That log is ephemeral and outside the repo, so this file is the durable half -- the"
    echo "# versions actually loaded by the tag named below."
    echo "#"
    echo "# controller image: $(kubectl -n ci get statefulset jenkins \
      -o jsonpath='{range .spec.template.spec.containers[?(@.name=="jenkins")]}{.image}{end}')"
    echo "# jenkins version: $(jenkins_version)"
    echo "# top-level plugins declared in plugins.txt: $(grep -cvE '^\s*(#|$)' ci/jenkins/plugins.txt)"
    echo "# plugins resolved and loaded: $(echo "$plugins_json" | jq '[.plugins[]] | length')"
    echo
    printf '%-44s %s\n' "SHORTNAME" "VERSION"
    echo "$plugins_json" | jq -r '.plugins | sort_by(.shortName)[]
      | "\(.shortName)\t\(.version)"' | awk -F'\t' '{printf "%-44s %s\n", $1, $2}'
  } >"$PLUGINS_OUT"
  echo "wrote $PLUGINS_OUT"
else
  echo "SKIP $PLUGINS_OUT -- no Jenkins credentials (set JENKINS_ADMIN_USER/JENKINS_ADMIN_PASSWORD)" >&2
fi

# ---------------------------------------------------------------------------------------------
# 3. ArgoCD is configured from the repo, not the GUI. This is the one drift GitOps cannot
#    self-correct -- selfHeal reconciles the chart, but nothing reconciles the Application.
# ---------------------------------------------------------------------------------------------
ARGO_OUT="${PREFIX}-argocd-check.txt"
./scripts/render-argocd-app.sh --check >"$ARGO_OUT" 2>&1
argo_rc=$?
echo "wrote $ARGO_OUT (exit ${argo_rc})"

# ---------------------------------------------------------------------------------------------
# 4. The section-10 checklist, asserted. VERIFY_STRICT=1 is mandatory for evidence: without it a
#    credential-less run still prints ALL CHECKS PASSED, which reads identically to a complete run.
# ---------------------------------------------------------------------------------------------
VERIFY_OUT="${PREFIX}-verify-jenkins.txt"
VERIFY_STRICT=1 ./scripts/jenkins/verify-jenkins.sh >"$VERIFY_OUT" 2>&1
verify_rc=$?
echo "wrote $VERIFY_OUT (exit ${verify_rc})"

echo
if [ "$argo_rc" -ne 0 ] || [ "$verify_rc" -ne 0 ]; then
  echo "capture-task4-evidence: captured, but a check FAILED (argocd=${argo_rc} verify=${verify_rc})" >&2
  exit 1
fi
echo "capture-task4-evidence: all static captures written, all checks passed."
