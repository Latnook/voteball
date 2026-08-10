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
while IFS= read -r hit; do
  note "${hit%%:*} has an empty list literal (${hit#*:}) -- omit the field instead; see the comment in $0"
done < <(grep -rnE '^[[:space:]]*(-[[:space:]]+)?[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*\[[[:space:]]*\][[:space:]]*$' \
           charts/voteball/templates 2>/dev/null || true)

[ "$status" -eq 0 ] && echo "validate-repo: all checks passed"
exit "$status"
