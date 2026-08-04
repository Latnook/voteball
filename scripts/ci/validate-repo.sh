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
