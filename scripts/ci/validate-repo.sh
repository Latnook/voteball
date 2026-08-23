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
      *'$'*|"")      ;;  # a build-arg reference; nothing to check here
      *@sha256:*)    ;;  # digest-pinned, which is what we want
      *:*)
        # Tagged but not digest-pinned. Allowed by the brief's no-latest rule, and still a
        # reproducibility hole: `python:3.12-slim` is a different image every few weeks, so a git-SHA
        # image tag describes the SOURCE exactly and the BASE not at all. Task 3 review finding T3-2.
        # Fix by running ./scripts/refresh-base-digests.sh, not by deleting this check.
        note "$df pins $ref by tag only -- pin it by digest (tag@sha256:...) so rebuilding this commit produces the same image. Run ./scripts/refresh-base-digests.sh." ;;
      *)             note "$df has an untagged base image ($ref), which resolves to :latest" ;;
    esac
  done < <(grep -iE '^\s*FROM\s+' "$df" || true)
  # ci/jenkins/Dockerfile INCLUDED, not just services/. It was outside this loop until 2026-08-23,
  # which is how the controller base sat on a floating `lts-jdk21` tag through several reviews -- the
  # one image in the repo whose drift the Task 4 review actually caught in the evidence.
done < <(find services -name Dockerfile 2>/dev/null; ls ci/jenkins/Dockerfile 2>/dev/null)

# The chart must at least parse -- a broken Chart.yaml fails the CD pipeline much later, after a
# full build has already been paid for.
if [ -f charts/voteball/Chart.yaml ]; then
  grep -qE '^version:' charts/voteball/Chart.yaml || note "charts/voteball/Chart.yaml has no version"
else
  note "charts/voteball/Chart.yaml is missing"
fi

# An empty LIST literal (`to: []`, `imagePullSecrets: []`) in a chart template is a deploy-breaking
# bug here, not a style nit, and it fails ~90 minutes into a rebuild rather than at authoring time.
#
# The API server DROPS an empty list on write -- for every field in this chart, `[]` and "field
# absent" are the same thing, which is exactly why it is safe to drop. But ArgoCD and `helm upgrade`
# (step 10 of scripts/deploy.sh) both apply this chart SERVER-SIDE, and server-side apply compares
# what you sent against what is stored to decide field ownership. Two managers may CO-OWN a field
# only while they apply the identical value; a value the server normalises away can never match, so
# the second applier conflicts against the first on that field on every single upgrade, forever:
#
#   UPGRADE FAILED: conflict occurred while applying object devops-app/allow-dns-egress
#   ... Apply failed with 1 conflict: conflict with "argocd-controller": .spec.egress
#
# That is a real 2026-08-10 deploy failure caused by one `- to: []`. It stayed invisible for months
# because Helm 3 patched client-side and never consulted field ownership; Helm 4 applies server-side
# by default, which is what turned it into a hard failure. `--force-conflicts` is NOT the fix -- it
# would let an uncommitted local chart silently overwrite what GitOps declares. Omitting the field is.
#
# An empty MAP (`podSelector: {}`) is deliberately NOT matched: it is meaningful and is preserved.
#
# EVERY chart's templates directory, not just charts/voteball's -- ArgoCD applies charts/observability
# server-side identically (see charts/observability/templates/networkpolicy.yaml), so it has the exact
# same `- to: []` failure mode. This still scans TEMPLATE FILES only (charts/*/templates/**), never
# rendered output or the dashboards' JSON under charts/observability/dashboards/ -- that JSON's
# `"overrides": []` is an opaque ConfigMap string value the Kubernetes API server never parses as a
# list, so matching it would be a false positive, not a real instance of this bug.
while IFS= read -r hit; do
  note "${hit%%:*} has an empty list literal (${hit#*:}) -- omit the field instead; see the comment in $0"
done < <(grep -rnE '^[[:space:]]*(-[[:space:]]+)?[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*\[[[:space:]]*\][[:space:]]*$' \
           charts/*/templates 2>/dev/null || true)

# EGRESS COVERAGE. Every workload in charts/voteball must be named by at least one egress
# NetworkPolicy, and this check exists because of how that fails when it is not.
#
# The namespace is default-deny, and allow-dns-egress selects ALL pods. So a workload whose label
# appears in no other egress policy still resolves DNS perfectly and has every TCP connection
# silently dropped. There is no event, no log line, no policy error -- it presents as an application
# bug. The backup CronJob shipped in exactly that state for 12 days (2026-07-19 to 2026-07-31)
# because its label did not match the one big policy's selector.
#
# On 2026-08-23 that one policy was split into four (Task 3 review T3-1), which is strictly better
# for least privilege and strictly worse for this failure: four selectors are four chances to forget.
# Hence a build gate rather than a comment.
#
# Deliberately grep/awk only, no helm and no python3 -- this script runs in the CI Validation stage
# before any tooling image is available, and the whole point of these checks is that they cost
# nothing. Comments are stripped first: this file's own prose quotes `app: backend` and `app:
# migrate` while explaining the rules, and counting those would make the check pass on a repo where
# the real selector had been deleted.
NP="charts/voteball/templates/networkpolicy.yaml"
if [ -f "$NP" ]; then
  strip_comments() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }

  # Labels that a real pod template carries: only files that declare a pod-bearing kind.
  workload_files="$(grep -lE '^kind: (Deployment|Job|CronJob)' charts/voteball/templates/*.yaml 2>/dev/null || true)"
  workload_labels=""
  for wf in $workload_files; do
    workload_labels="$workload_labels
$(strip_comments "$wf" | grep -oE '\bapp: [a-z0-9][a-z0-9-]*' | awk '{print $2}')"
  done
  workload_labels="$(printf '%s\n' "$workload_labels" | grep -v '^$' | sort -u)"

  # Labels named by an egress policy. allow-dns-egress is EXCLUDED on purpose -- it selects every pod
  # ({}), so counting it would make this check vacuous, and DNS-only is precisely the broken state.
  egress_labels="$(strip_comments "$NP" | awk '
    BEGIN { RS = "\n---\n" }
    /policyTypes: \[Egress\]/ && $0 !~ /name: allow-dns-egress/ {
      s = $0
      while (match(s, /app: [a-z0-9][a-z0-9-]*/)) {           # matchLabels: { app: frontend }
        print substr(s, RSTART + 5, RLENGTH - 5)
        s = substr(s, RSTART + RLENGTH)
      }
      s = $0
      while (match(s, /values: \[[a-z0-9, -]*\]/)) {          # matchExpressions values list
        v = substr(s, RSTART + 9, RLENGTH - 10)
        gsub(/[[:space:]]/, "", v)
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
        s = substr(s, RSTART + RLENGTH)
      }
    }' | sort -u)"

  for lbl in $workload_labels; do
    printf '%s\n' "$egress_labels" | grep -qx "$lbl" || \
      note "pod label 'app: $lbl' is selected by NO egress NetworkPolicy in $NP -- that pod will resolve DNS and then have every TCP connection silently dropped (see the comment in $0). Add it to a policy there."
  done
fi

[ "$status" -eq 0 ] && echo "validate-repo: all checks passed"
exit "$status"
