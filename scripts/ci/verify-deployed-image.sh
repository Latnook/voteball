#!/usr/bin/env bash
# CD Verify -- assert that what is RUNNING is what this build asked for.
#
# WHY THIS IS A SCRIPT AND NOT A HEREDOC IN Jenkinsfile-cd. It used to be inline, and it asserted
# `case "$image" in *":$TAG")` -- that the running image reference ends in the requested tag. When
# charts/voteball started rendering `repo@sha256:...` (2026-08-23, Task 4 review P2, deploy by
# digest), that reference stopped containing a tag at all, so the check could never pass again.
# Live CD #1 that day: the deploy was correct, ArgoCD reported Synced/Healthy, the public site served
# 200 -- and Verify failed anyway and rolled back a perfectly good release. The rollback build then
# failed identically, because it carried the same defect, and the depth guard stopped it there.
#
# Nothing caught that before it ran in production: check-jenkinsfile-shell.sh proves the block PARSES,
# not that it decides correctly. That is the whole argument for extracting pipeline decisions --
# "pipeline logic that can only be tested by running the pipeline is exactly what this project
# refuses to accept" (root CLAUDE.md).
#
# DIGEST IS STRICTLY STRONGER than the tag check it replaces: a tag is a label that ECR happens to
# make immutable, while the digest IS the content. The tag branch survives for the fallback case --
# an empty digest map, i.e. a fresh fork or a rebuild where the ECR lookup failed -- where the chart
# still renders `repo:tag`.
#
# Usage:  TAG=<tag> IMAGE_DIGESTS="name=sha256:... ..." NAMESPACE=<ns> verify-deployed-image.sh
# Env:    DEPLOYMENTS   space-separated (default: frontend backend worker)
#         KUBECTL_CMD   overridden by the tests to run offline
set -uo pipefail

: "${TAG:?TAG must be set}"
: "${NAMESPACE:?NAMESPACE must be set}"
IMAGE_DIGESTS="${IMAGE_DIGESTS:-}"
DEPLOYMENTS="${DEPLOYMENTS:-frontend backend worker}"
KUBECTL="${KUBECTL_CMD:-kubectl}"

status=0

for d in $DEPLOYMENTS; do
  # The mapping is NOT identity: the `frontend` Deployment runs the `nginx` image (voteball-nginx),
  # which is also why _helpers.tpl takes an image name rather than a workload name.
  case "$d" in frontend) iname=nginx ;; *) iname="$d" ;; esac

  image="$($KUBECTL get deployment "$d" -n "$NAMESPACE" \
           -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" || image=""
  if [ -z "$image" ]; then
    echo "Could not read the image of deployment $d in $NAMESPACE -- failing verification." >&2
    status=1
    continue
  fi
  echo "$d -> $image"

  case "$image" in
    *@sha256:*)
      running="${image##*@}"
      want=""
      for pair in $IMAGE_DIGESTS; do
        case "$pair" in "${iname}="*) want="${pair#*=}" ;; esac
      done
      if [ -z "$want" ]; then
        echo "  $d is deployed by digest, but no digest for image '$iname' was resolved for tag" >&2
        echo "  $TAG. Cannot verify what is running -- failing." >&2
        status=1
      elif [ "$running" != "$want" ]; then
        echo "  $d is running $running, but tag $TAG resolves to $want." >&2
        echo "  What is running is not what this build asked for." >&2
        status=1
      else
        echo "   digest matches the one $TAG resolves to"
      fi
      ;;
    *":$TAG")
      echo "   tag matches (chart rendered by tag -- no digest pinned for $iname)"
      ;;
    *)
      echo "  $d is running $image, which neither carries tag $TAG nor the digest it resolves to." >&2
      status=1
      ;;
  esac
done

[ "$status" -eq 0 ] && echo "All deployments ($DEPLOYMENTS) match $TAG."
exit "$status"
