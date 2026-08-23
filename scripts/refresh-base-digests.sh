#!/usr/bin/env bash
# Re-resolve every digest-pinned base image in this repo to the current digest of its tag, and
# rewrite the Dockerfiles in place.
#
# WHY PINNING NEEDS A REFRESH SCRIPT (2026-08-23, Task 3 review T3-2 and Task 4 review P2). Pinning
# base images by digest buys reproducibility and costs currency: a frozen base stops receiving
# upstream CVE fixes, and this project's Trivy gate BLOCKS on HIGH/CRITICAL for the three runtime
# images. So the pins will eventually fail a build. That is the intended behaviour -- it turns
# "quietly running a base nobody has looked at in months" into a build that stops and asks -- but it
# is only a reasonable trade if updating is one command rather than an afternoon of docker inspect.
#
# The alternative the review offered was "document a scheduled rebuild policy" instead of pinning.
# Pinning plus this script is strictly more: you get the reproducibility AND the update path, and the
# update is a reviewable diff of digests rather than an invisible change in what a tag means.
#
# THIS IS NOT AUTOMATED ON PURPOSE. It is not run by CI and not on a timer. Ariel works alone and
# commits straight to master, so there is no PR for a bot to open and nothing to review an automatic
# digest bump; an unattended rewrite of every base image is exactly the change that should be a
# deliberate act. Run it, read the diff, let CI's Trivy gate judge the result.
#
# Usage:
#   ./scripts/refresh-base-digests.sh           rewrite the Dockerfiles
#   ./scripts/refresh-base-digests.sh --check   report drift, write nothing, exit 1 if any
#
# Covers services/*/Dockerfile and ci/jenkins/Dockerfile. Needs docker and network.
set -euo pipefail

cd "$(dirname "$0")/.."

check_only=0
[ "${1-}" = "--check" ] && check_only=1

command -v docker >/dev/null || { echo "docker is required." >&2; exit 1; }

mapfile -t DOCKERFILES < <(find services -name Dockerfile 2>/dev/null; ls ci/jenkins/Dockerfile 2>/dev/null)

drift=0
unresolved=0
for df in "${DOCKERFILES[@]}"; do
  # Only lines that are ALREADY digest-pinned. An unpinned base is a separate decision -- silently
  # pinning one here would make this script change policy rather than refresh it, and
  # scripts/ci/validate-repo.sh is where "must be pinned" belongs.
  while IFS= read -r line; do
    ref="$(printf '%s' "$line" | awk '{print $2}')"
    case "$ref" in *@sha256:*) ;; *) continue ;; esac

    tagged="${ref%@*}"
    old_digest="${ref#*@}"

    # </dev/null is load-bearing. This loop reads its list from a process substitution on stdin, and
    # docker inherits and CONSUMES it -- so without the redirect the first inspect eats the rest of
    # the list and every subsequent resolution fails. It failed that way on first run, silently.
    # The awk has NO `exit`, deliberately, and that is not a style choice. `exit` after the first
    # match closes the pipe while docker is still writing the per-architecture manifest list; docker
    # takes SIGPIPE, exits non-zero, `set -o pipefail` propagates that, and the `|| new_digest=""`
    # below then WIPES a digest that had already been read correctly. Every lookup failed that way on
    # first run while the value was sitting right there in the trace. So: match once, keep reading.
    new_digest="$(docker buildx imagetools inspect "$tagged" </dev/null 2>/dev/null \
                  | awk '/^Digest:/ && !seen { print $2; seen = 1 }')" || new_digest=""
    if [ -z "$new_digest" ]; then
      echo "WARNING: could not resolve $tagged -- leaving it pinned at $old_digest" >&2
      unresolved=$((unresolved + 1))
      continue
    fi

    if [ "$new_digest" = "$old_digest" ]; then
      printf '  %-52s up to date\n' "$tagged"
      continue
    fi

    drift=1
    printf '  %-52s %s -> %s\n' "$tagged" "${old_digest:0:19}..." "${new_digest:0:19}..."
    [ "$check_only" = 1 ] && continue

    # python3, not sed: the replacement contains '/' and ':' and comes off the network. Building a
    # sed expression around it is how a malformed response rewrites more of the file than intended.
    DF="$df" OLD="$ref" NEW="${tagged}@${new_digest}" python3 - <<'PY'
import os
df, old, new = os.environ["DF"], os.environ["OLD"], os.environ["NEW"]
s = open(df).read()
assert old in s, f"{old} vanished from {df}"
open(df, "w").write(s.replace(old, new))
PY
  done < <(grep -iE '^\s*FROM\s+' "$df" || true)
done

# A run that could not reach the registry must NOT report success. The first version of this script
# did exactly that -- every lookup failed (docker was eating the loop's stdin, see above) and it
# still printed "All pinned base images are current", which is the worst possible answer: it is the
# same output as a genuinely up-to-date repo, so nothing would ever have noticed.
if [ "$unresolved" -gt 0 ]; then
  echo >&2
  echo "ERROR: $unresolved base image(s) could not be resolved -- this run proves NOTHING about" >&2
  echo "       whether the pins are current. Check network/registry access and re-run." >&2
  exit 2
fi

if [ "$check_only" = 1 ]; then
  [ "$drift" = 0 ] && { echo "All pinned base images are current."; exit 0; }
  echo
  echo "Base image digests are behind. Run ./scripts/refresh-base-digests.sh and commit the result." >&2
  exit 1
fi

if [ "$drift" = 0 ]; then
  echo "Nothing to do -- every pinned base image is already current."
else
  echo
  echo "Dockerfiles rewritten. Review the diff, then let CI's Trivy gate judge the new bases:"
  echo "  git diff -- services/*/Dockerfile ci/jenkins/Dockerfile"
  echo "If the controller base moved, ALSO regenerate the plugin lock in the same commit:"
  echo "  ./scripts/jenkins/lock-plugins.sh"
fi
