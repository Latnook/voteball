#!/usr/bin/env bash
# Offline test for scripts/ci/notify.sh. The AWS CLI is replaced by a fake on PATH; nothing here
# touches the network or AWS.
#
# The property that matters is NOT "it sends a message" -- it is "it never breaks the build". This
# script is called from Jenkinsfile-cd's post{failure} block, which is already handling a failed
# deploy and is about to decide whether to roll back. A notifier that throws there would convert a
# clean automatic rollback into a wedged pipeline, i.e. it would cause the outage it exists to
# report. Every case below therefore asserts exit 0.
set -uo pipefail

cd "$(dirname "$0")/../.."
SUT="$PWD/scripts/ci/notify.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; pass=$((pass+1)); }

# A fake aws that records its argv and the message body it was handed.
make_aws() {   # make_aws <exit-code>
  cat > "$work/bin/aws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/argv"
for a in "\$@"; do
  case "\$a" in
    file://*) cp "\${a#file://}" "$work/body" 2>/dev/null || true ;;
  esac
done
exit $1
EOF
  chmod +x "$work/bin/aws"
}

run() { PATH="$work/bin:$PATH" SNS_TOPIC="arn:aws:sns:eu-west-1:1:voteball" AWS_REGION=eu-west-1 bash "$SUT" "$@"; }

# ---- 1. the happy path publishes and exits 0 ----------------------------------------------------
make_aws 0
out="$(run "Subject here" "Body line one")" || fail "a successful publish must exit 0"
grep -q "sns" "$work/argv" || fail "aws was not called with sns"
grep -q -- "--topic-arn" "$work/argv" || fail "no --topic-arn passed"
ok "publishes to the topic and exits 0"

# ---- 2. the MESSAGE goes via a file, never in argument position ---------------------------------
# Jenkins traces every sh step with `set -x`, which echoes commands AFTER expansion -- so anything in
# argument position lands in the console log in full. A live ECR token reached committed CI evidence
# exactly that way on 2026-08-04. The message here is not secret; the habit is what stops the next
# one being a token.
grep -q "^file:///" "$work/argv" || grep -q "^file://" "$work/argv" \
  || fail "the message must be passed as file://, not as an argument. argv was: $(tr '\n' ' ' < "$work/argv")"
grep -qx "Body line one" "$work/body" || fail "the message body did not reach the file: $(cat "$work/body" 2>/dev/null)"
grep -qx "Body line one" "$work/argv" && fail "the message body appeared in ARGUMENT position -- set -x would print it in the console log"
ok "the message body is passed by file, never as a command argument"

# ---- 3. an AWS failure must NOT fail the build --------------------------------------------------
make_aws 1
out="$(run "Subject" "Body" 2>&1)" || fail "a FAILED publish must still exit 0 -- this runs inside post{failure} and must never wedge the rollback decision"
grep -q "FAILED to publish" <<<"$out" || fail "a failed publish should say so on stderr, got: $out"
ok "an SNS failure is reported but still exits 0"

# ---- 4. a missing aws binary must NOT fail the build --------------------------------------------
# Simulated with a shim exiting 127 rather than by emptying PATH. Emptying PATH also removes mktemp,
# printf and sed, so the script fails for a reason that has nothing to do with the case under test --
# which is exactly what the first version of this test did, and it looked like a real defect.
# 127 is what the shell reports for command-not-found, so this is the same signal notify.sh sees.
make_aws 127
out="$(run "S" "B" 2>&1)" || fail "a missing aws binary (exit 127) must still exit 0"
grep -q "FAILED to publish" <<<"$out" || fail "it should report the failure, got: $out"
ok "a missing aws binary is survivable"

# ---- 5. an unset SNS_TOPIC is a skip, not an error ----------------------------------------------
# A fork that has not wired a topic, or a local run, must not see failed builds because of it.
make_aws 0
out="$(PATH="$work/bin:$PATH" SNS_TOPIC="" bash "$SUT" "S" "B" 2>&1)" || fail "an unset SNS_TOPIC must exit 0"
grep -q "skipping notification" <<<"$out" || fail "it should say it skipped, got: $out"
[ -f "$work/argv" ] && rm -f "$work/argv"
out="$(PATH="$work/bin:$PATH" SNS_TOPIC="" bash "$SUT" "S" "B" 2>&1)"
[ -f "$work/argv" ] && fail "aws must not be called at all when SNS_TOPIC is unset"
ok "an unset SNS_TOPIC skips silently and calls nothing"

# ---- 6. the subject is truncated and newline-free -----------------------------------------------
# SNS caps Subject at 100 chars and rejects newlines; either is a 400 from the API, which in a log
# reads like a permissions problem rather than a formatting one.
make_aws 0
long="$(printf 'x%.0s' $(seq 200))"
run "$long" "body" >/dev/null || fail "a long subject must not fail"
subj="$(grep -A1 -- '--subject' "$work/argv" | tail -1)"
[ "${#subj}" -le 100 ] || fail "subject was not truncated to <=100 chars, got ${#subj}"
ok "an over-long subject is truncated rather than 400ing"

run "$(printf 'line one\nline two')" "body" >/dev/null || fail "a multiline subject must not fail"
subj="$(grep -A1 -- '--subject' "$work/argv" | tail -1)"
case "$subj" in *$'\n'*) fail "the subject still contains a newline" ;; esac
grep -q "line one line two" <<<"$subj" || fail "newlines should become spaces, got: $subj"
ok "newlines in the subject are flattened to spaces"

# ---- 7. Jenkinsfile-cd actually calls it, from inside a container that has aws -------------------
grep -q 'scripts/ci/notify.sh' Jenkinsfile-cd \
  || fail "Jenkinsfile-cd does not call notify.sh -- the NEEDS A HUMAN branches are silent again"
pass=$((pass+1))

# Every NEEDS A HUMAN branch must notify. Counting them keeps a newly added branch from being silent.
humans="$(grep -c 'NEEDS A HUMAN"' Jenkinsfile-cd || true)"
notifies="$(grep -c 'notify("Voteball' Jenkinsfile-cd || true)"
[ "$notifies" -ge 3 ] \
  || fail "expected at least 3 notify() calls in Jenkinsfile-cd (rollback-stopped, no-target, no-previous-tag); found $notifies"
pass=$((pass+1))

# The closure must be wrapped in container('deploy'). Its script{} block is not inside a container
# directive, so a bare sh runs in jnlp -- git but no aws -- and every notification would die on
# "aws: not found" at exactly the moment it mattered.
awk '/def notify = \{/,/^          \}/' Jenkinsfile-cd | grep -q "container('deploy')" \
  || fail "the notify closure in Jenkinsfile-cd must run inside container('deploy'); jnlp has no aws CLI"
pass=$((pass+1))

# ---- 8. SNS_TOPIC must reach the AGENT pods, not just the controller ----------------------------
# notify.sh runs in the CD agent pod. Setting SNS_TOPIC only in the controller's containerEnv (which
# is what the 2026-08-23 change first did) leaves the agent without it -- and because this notifier
# is deliberately written never to fail a build, the symptom is NOT an error. The rollback drill's
# log simply read "SNS_TOPIC is not set -- skipping notification": the NEEDS A HUMAN alerting was
# silently absent while every stage reported healthy. That is precisely the failure the notifier
# exists to prevent, one layer up.
#
# BOTH places are required and both are checked: containerEnv so JCasC can resolve ${SNS_TOPIC} at
# boot, globalNodeProperties so the resolved value is inherited by agents.
JY="ci/jenkins/jenkins.yaml"
TF="terraform/addon-jenkins.tf"
if [ -f "$JY" ] && [ -f "$TF" ]; then
  grep -q 'name = "SNS_TOPIC"' "$TF" \
    || fail "$TF no longer sets SNS_TOPIC in the controller's containerEnv -- JCasC cannot resolve \${SNS_TOPIC} without it"
  pass=$((pass+1))

  # Must be inside globalNodeProperties, which is what agents inherit. Comments stripped: this file's
  # own prose names SNS_TOPIC while explaining the trap.
  jy_code="$(sed -e 's|^[[:space:]]*#.*$||' "$JY")"
  gnp="$(printf '%s\n' "$jy_code" | awk '/^  globalNodeProperties:/{f=1} f&&/^  clouds:/{f=0} f')"
  printf '%s\n' "$gnp" | grep -q 'key: "SNS_TOPIC"' \
    || fail "ci/jenkins/jenkins.yaml does not export SNS_TOPIC via globalNodeProperties. The controller's containerEnv does NOT reach agent pods, and notify.sh runs on an agent -- so the NEEDS A HUMAN notifications would silently never send."
  pass=$((pass+1))

  # APP_DOMAIN is the precedent that already learned this; if it ever leaves, the comment explaining
  # the trap goes with it.
  printf '%s\n' "$gnp" | grep -q 'key: "APP_DOMAIN"' \
    || fail "APP_DOMAIN left globalNodeProperties -- agents need it too (the Smoke Test builds the site URL from it)"
  pass=$((pass+1))
fi

echo "PASS: $(basename "$0") -- $pass checks"
