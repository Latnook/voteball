#!/usr/bin/env bash
# The two CI agent pod templates must stay in step with the stages that use them.
#
# Jenkinsfile-ci runs on TWO templates since 2026-09-16: `voteball-test` (light) for
# test/validate/publish, `voteball-build` (heavy) for Build/Trivy/Push. The split exists because
# Kubernetes pulls and STARTS every container in a pod before any stage runs, so the G3c guards
# (env.SERVICES_CHANGED) were skipping the work and none of the setup -- a docs-only push paid for
# buildkit, trivy and skopeo and then declined to use them.
#
# The failure this guards against is silent in review and loud only at runtime: a stage that calls
# container('x') on an agent whose template has no container x fails with "container [x] not found",
# which reads like a Jenkinsfile bug and is actually a template-drift bug. Nothing else checks it --
# helm lint does not parse JCasC, and the Declarative linter does not know what a pod template holds.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - <<'PY' || exit 1
import re, sys

# NO PyYAML. It is absent from python:3.12-slim -- the image run-ci-suite.sh's PYTHON_GROUP
# actually executes in -- and the pipeline only pip-installs ruff and the services' test deps.
# The alternative pattern in test-render-argocd-app.sh guards on `import yaml` and degrades to a
# skip, which is the lying-skip-line failure CLAUDE.md already records against that file. Plain
# text parsing needs nothing, so there is no degraded path to lie. Every extraction below asserts
# it found something, so a structural change to jenkins.yaml fails loudly instead of matching
# nothing and passing.
LIGHT, HEAVY = 'voteball-test', 'voteball-build'
HEAVY_ONLY = {'buildkit', 'trivy', 'skopeo'}

casc = open('ci/jenkins/jenkins.yaml', encoding='utf-8').read()

def template_block(name):
    """The raw text of one `- name: \"<name>\"` template, up to the next template at the same indent."""
    m = re.search(rf'^(\s*)- name: "{re.escape(name)}"$', casc, re.M)
    if not m:
        sys.exit(f"FAIL: pod template {name!r} is missing from ci/jenkins/jenkins.yaml")
    start, indent = m.end(), m.group(1)
    nxt = re.search(rf'^{indent}- name: "', casc[start:], re.M)
    return casc[start:start + nxt.start()] if nxt else casc[start:]

def containers(name):
    """Container names under this template's `containers:` key, stopping at `volumes:`."""
    block = template_block(name)
    m = re.search(r'^(\s*)containers:$', block, re.M)
    if not m:
        sys.exit(f"FAIL: template {name!r} has no `containers:` key -- did the pod YAML change shape?")
    rest = block[m.end():]
    end = re.search(rf'^{m.group(1)}\w', rest, re.M)
    names = set(re.findall(r'^\s*- name: ([a-z][a-z0-9-]*)$', rest[:end.start()] if end else rest, re.M))
    if not names:
        sys.exit(f"FAIL: parsed ZERO containers out of template {name!r} -- the parser matched "
                 "nothing, which would make every check below pass vacuously")
    return names

light, heavy = containers(LIGHT), containers(HEAVY)

# 1. The light template is exactly the heavy one minus the build-only three. Checked BOTH ways: an
#    extra container in light is dead weight (fewer is the whole point), a missing one is a runtime
#    "container [x] not found" that reads like a Jenkinsfile bug and is not.
if light != heavy - HEAVY_ONLY:
    sys.exit(f"FAIL: {LIGHT} should be {HEAVY} minus {sorted(HEAVY_ONLY)}.\n"
             f"  only in {LIGHT}: {sorted(light - (heavy - HEAVY_ONLY))}\n"
             f"  missing from {LIGHT}: {sorted((heavy - HEAVY_ONLY) - light)}")
if not HEAVY_ONLY <= heavy:
    sys.exit(f"FAIL: {HEAVY} no longer carries {sorted(HEAVY_ONLY - heavy)}")

src = open('Jenkinsfile-ci', encoding='utf-8').read()

# 2. One agent for everything silently undoes the split while every stage still passes.
if not re.search(r'^\s*agent none\s*$', src, re.M):
    sys.exit("FAIL: Jenkinsfile-ci must declare `agent none` at pipeline level; a top-level agent "
             "allocates a pod for the whole build and defeats the two-template split")
for label in (LIGHT, HEAVY):
    if f"agent {{ label '{label}' }}" not in src:
        sys.exit(f"FAIL: Jenkinsfile-ci never allocates {label!r}")

# 3. Every container() call must exist on the agent its stage actually runs on.
current, bad, seen = None, [], 0
for line in src.splitlines():
    m = re.search(r"agent \{ label '([a-z-]+)' \}", line)
    if m:
        current = m.group(1)
        continue
    for c in re.findall(r"container\('([a-z]+)'\)", line):
        seen += 1
        avail = light if current == LIGHT else heavy if current == HEAVY else None
        if avail is not None and c not in avail:
            bad.append((c, current))
if not seen:
    sys.exit("FAIL: found no container() calls in Jenkinsfile-ci -- the pattern matched nothing, "
             "so check 3 proved nothing")
if bad:
    sys.exit("FAIL: stage calls container() for a container its agent does not have:\n" +
             "\n".join(f"  container('{c}') under {lbl}" for c, lbl in sorted(set(bad))))

# 4. The heavy group must carry a `when`, or the pod is allocated and every child then skips -- the
#    exact cost the split removes, with no visible symptom. Scoped to the parent stage's OWN header
#    (agent line -> its nested `stages {`): a wider window passes on a CHILD stage's `when`, which
#    is always there. The first version used +-600 chars and did NOT fail when the guard was
#    deleted; proven by deleting it and watching this line go red.
heavy_at = src.index(f"agent {{ label '{HEAVY}' }}")
header = src[heavy_at:src.index('stages {', heavy_at)]
if 'when {' not in header:
    sys.exit(f"FAIL: the stage that allocates {HEAVY} has no `when` guard, so a docs-only push "
             "still starts buildkit/trivy/skopeo")

# 5. Every agent-allocating stage with a `when` must use `beforeAgent true`. Declarative allocates
#    the agent BEFORE evaluating `when` unless it is set, so the pod is provisioned, every container
#    starts and the repo is cloned -- and only then does the stage skip. The log reads
#    "skipped due to when conditional" either way, so the cost is invisible without timestamps.
#    Shipped without it on 2026-09-16 and build #4 came out SLOWER than the single-pod version:
#    2m27s to allocate the heavy pod and skip, plus 37s for a group whose children all skipped.
#    COMMENTS ARE STRIPPED FIRST, and that is not tidiness. The first version of this check tested
#    the raw header text, which INCLUDES the Jenkinsfile comment explaining why `beforeAgent true`
#    matters -- so the literal string was always present and the check passed on its own prose.
#    Deleting the real flag did not fail it. Found by mutation, not by reading.
gates = 0
strip_comments = lambda t: '\n'.join(l for l in t.split('\n') if not l.lstrip().startswith('//'))
for m in re.finditer(r"agent \{ label '([a-z-]+)' \}(.*?)stages \{", src, re.S):
    label, header = m.group(1), strip_comments(m.group(2))
    if 'when {' not in header:
        continue
    gates += 1
    if 'beforeAgent true' not in header:
        sys.exit(f"FAIL: the stage allocating {label!r} has a `when` without `beforeAgent true`, so "
                 "Declarative provisions the pod and clones the repo before deciding to skip it -- "
                 "a green build that is slower than having no split at all")
if gates < 2:
    sys.exit(f"FAIL: expected both grouping stages to carry a gated agent, found {gates} -- the "
             "pattern matched too little, so check 5 proved nothing")

print(f"  {LIGHT}: {len(light)} containers; {HEAVY}: {len(heavy)}; heavy-only {sorted(HEAVY_ONLY)}; "
      f"{seen} container() calls reachable; {gates} agent groups gated with beforeAgent")
PY

echo "    PASS"
