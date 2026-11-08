#!/usr/bin/env bash
# Fails if any operational script (scripts/**, excluding scripts/tests/) or Jenkinsfile pipes a
# producer into `grep -q`.
#
# WHY: under `set -o pipefail`, `producer | grep -q pat` turns a MATCH into a MISS whenever the
# producer writes more than once. grep exits at the first match; the producer's next write hits a
# closed pipe and dies of SIGPIPE (141); pipefail reports the pipeline as failed. It is a race, so it
# passes locally and flakes in CI. bash's own `printf '%s\n' "$multi_line_var"` is such a producer --
# it issues one write(2) PER LINE (measured with strace on 2026-11-08: six lines, six writes).
#
# Proven twice. 2026-09-17: changed-paths.sh answered "nothing changed" for large commits and
# test-aws-pager-guard.sh flaked only in CI. 2026-11-08: validate-repo.sh's egress-coverage check
# failed application-ci with "pod label 'app: backup' is selected by NO egress NetworkPolicy" on a
# chart that had passed the identical check 17 minutes earlier -- `backup` is the second line of the
# label list, so grep matched early and the third write took the SIGPIPE. Six more scripts carried
# the same shape, including smoke-test.sh (a false miss there fails CD and triggers a ROLLBACK) and
# render-argocd-app.sh (a false miss there waves an unrendered placeholder through).
#
# The rule was already written down in scripts/CLAUDE.md and was broken seven times anyway, which is
# why it is now a test. Use instead:
#   grep -q pat <<<"$var"              # a here-string: no producer process to kill
#   producer | grep pat >/dev/null     # without -q, grep reads all of its input
#
# scripts/tests/ itself is NOT scanned: it still holds ~49 such sites. In a test, a false miss is a
# flake or a check that passes when it should fail -- real, but not a wrong answer about a deploy.
# Extending the scan to it means fixing those first.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $*" >&2; exit 1; }

# A pipe (not `||`) followed by grep with a -q somewhere in its leading flags. Comment lines skipped.
PATTERN='(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*q'

scan() {
  grep -rHnE "$PATTERN" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}

# Prove the scan can fail before trusting it to pass (scripts/CLAUDE.md).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/bad.sh" <<'EOF'
printf '%s\n' "$labels" | grep -qx "$lbl" || note missing
kubectl get x | grep -Eq '^yes'
EOF
cat > "$tmp/good.sh" <<'EOF'
grep -qx -- "$lbl" <<<"$labels" || note missing
[ -z "$want" ] || grep -q "$want" <<<"$out"
helm list -q | grep -x jenkins >/dev/null
# a comment quoting the bad form: printf x | grep -q y
EOF
[ "$(scan "$tmp/bad.sh" | wc -l)" -eq 2 ] || fail "the scan must flag both bad forms in its own fixture"
[ -z "$(scan "$tmp/good.sh")" ] || fail "the scan flags a safe form: $(scan "$tmp/good.sh")"
echo "  ok: the scan flags pipe-to-grep-q and passes here-strings, || and comments"

files=()
while IFS= read -r f; do files+=("$f"); done < <(find scripts -name '*.sh' -not -path 'scripts/tests/*' | sort)
files+=(Jenkinsfile-ci Jenkinsfile-cd)
hits="$(scan "${files[@]}")"
[ -z "$hits" ] || fail "producer | grep -q under pipefail can report a match as a miss (see this file's header):
$hits"
echo "  ok: no operational script or Jenkinsfile pipes into grep -q (${#files[@]} files scanned)"

echo "PASS: test-no-pipe-to-grep-q.sh"
