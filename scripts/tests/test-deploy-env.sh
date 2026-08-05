#!/usr/bin/env bash
# Offline test for deploy.sh's deploy.env loader. Same stub pattern as the other tests here: nothing
# runs deploy.sh itself (it would reach a billed `terraform apply`), so the loader block is extracted
# from the real script and sourced in a throwaway directory.
#
# Extracting the block rather than restating it is the point. A hand-written copy of the four lines
# would pass forever while the real script did something else -- which is precisely the failure this
# file exists to catch: deploy.env was gitignored and documented as "read by scripts/deploy.sh" for
# days while no code read it at all, so every deploy prompted and nothing reported a problem.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Pull the loader out of the live deploy.sh: the `if [ -f deploy.env ]` block through its closing
# `fi`. If deploy.sh stops containing that block, the extraction comes back empty and this fails --
# which is the correct outcome, not a false alarm.
awk '/^if \[ -f deploy.env \]; then$/,/^fi$/' "$ROOT/scripts/deploy.sh" > "$work/block.sh"
[ -s "$work/block.sh" ] || fail "could not find the deploy.env loader block in scripts/deploy.sh"
grep -q 'set -a' "$work/block.sh" || fail "loader no longer uses 'set -a' -- values would not be exported"

cd "$work"

# Print the four credentials as seen by a CHILD process (`env`, not the shell's own variables). The
# seed scripts in steps 3/3b are children, so an unexported value is useless to them even though it
# would satisfy deploy.sh's own preflight -- testing the shell's variables would hide that.
probe() {
  cat > "$work/probe.sh" <<'EOF'
set -euo pipefail
. ./block.sh
env | grep -E '^(ADMIN_USERNAME|ADMIN_PASSWORD|JENKINS_ADMIN_USER|JENKINS_ADMIN_PASSWORD)=' | sort || true
EOF
  bash "$work/probe.sh" 2>/dev/null
}

write_env_file() {
  cat > "$work/deploy.env" <<'EOF'
ADMIN_USERNAME=filename
ADMIN_PASSWORD=filepass
JENKINS_ADMIN_USER=filejuser
JENKINS_ADMIN_PASSWORD=filejpass
EOF
}

echo "--- deploy.env is loaded and exported to child processes ---"
write_env_file
out="$(probe)"
for expect in ADMIN_USERNAME=filename ADMIN_PASSWORD=filepass \
              JENKINS_ADMIN_USER=filejuser JENKINS_ADMIN_PASSWORD=filejpass; do
  grep -qx "$expect" <<<"$out" || fail "expected $expect in a child's environment; got: $out"
done

echo "--- an explicit environment value beats the file ---"
# The override case: rotating a password for one run without editing deploy.env. A bare
# `set -a; . deploy.env` assigns unconditionally and would silently discard this.
out="$(ADMIN_PASSWORD=envpass probe)"
grep -qx 'ADMIN_PASSWORD=envpass' <<<"$out" || fail "environment did not win over deploy.env; got: $out"
grep -qx 'JENKINS_ADMIN_PASSWORD=filejpass' <<<"$out" \
  || fail "unset vars should still come from the file; got: $out"

echo "--- no deploy.env is a clean no-op, not an error ---"
rm -f "$work/deploy.env"
out="$(probe)"
[ -z "$out" ] || fail "expected no credentials without deploy.env; got: $out"
cat > "$work/exitcheck.sh" <<'EOF'
set -euo pipefail
. ./block.sh
echo OK
EOF
[ "$(bash "$work/exitcheck.sh")" = "OK" ] || fail "loader errored under 'set -euo pipefail' with no deploy.env"

echo "PASS: scripts/tests/test-deploy-env.sh"
