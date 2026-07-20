#!/usr/bin/env bash
# G2 -- Jenkins has NO native [skip ci] support; that is a GitHub Actions feature.
#
# Without this guard, the tag-bump commit the pipeline itself pushes fires the webhook, Jenkins
# builds that new SHA, pushes images, bumps the tag, commits again -- an unbounded build loop that
# consumes ECR storage and continuously rolls production pods.
#
# Prints "skip" or "build". Deliberately fails safe: any occurrence of the marker anywhere in the
# message skips, because a spurious skip costs one manual rebuild while a spurious build costs a loop.
set -euo pipefail

msg="${1-}"

case "$msg" in
  *"[skip ci]"*) echo "skip" ;;
  *)             echo "build" ;;
esac
