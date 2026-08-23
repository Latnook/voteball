#!/usr/bin/env bash
# Publish a pipeline notification to the project's SNS topic.
#
# WHY (2026-08-23, Task 4 review finding P3: "a rollback action is not a reliable notification
# mechanism by itself"). The pipeline's worst outcome is the NEEDS A HUMAN branch -- a deploy failed,
# the automatic rollback was REFUSED because this build is itself already a rollback
# (ROLLBACK_DEPTH >= 1), and production is left running a version nobody chose. Until now that state
# announced itself only as a red build in a UI reachable through `kubectl port-forward`, on a
# controller the Spot node group reclaims roughly daily. Nobody was going to see it.
#
# Reuses the EXISTING voteball notifications topic rather than creating a second one: its email
# subscription is already confirmed and has delivered, so this path is proven the moment the IAM
# policy applies -- as opposed to being one more alerting channel that has never carried a message.
#
# NEVER FAILS THE BUILD. It is called from post{} blocks that are already handling a failure, and a
# notification that turns a clean rollback into a broken pipeline is worse than no notification. Every
# exit is 0; problems go to stderr where the console log keeps them.
#
# Usage:  notify.sh <subject> <message>
# Reads SNS_TOPIC (set as a pod env var by terraform/addon-jenkins.tf) and AWS_REGION.
set -uo pipefail

# AWS CLI v2 pages when stdout is a terminal. Carried here rather than sourced, like images-exist.sh
# and resolve-digests.sh: this runs in a CI container with no repo layout to source lib/config.sh
# from. See scripts/lib/config.sh for the full reasoning.
export AWS_PAGER=""

subject="${1:-Voteball pipeline}"
message="${2:-(no message)}"

if [ -z "${SNS_TOPIC:-}" ]; then
  echo "notify: SNS_TOPIC is not set -- skipping notification (not failing the build)." >&2
  echo "notify: would have sent: $subject" >&2
  exit 0
fi

# SNS caps Subject at 100 characters and rejects newlines in it; a longer one is a 400 from the API,
# which would otherwise look like a permissions problem in the log.
subject="$(printf '%s' "$subject" | tr '\n' ' ' | cut -c1-99)"

# --message file://- rather than an argument, deliberately. Jenkins traces every `sh` step with
# `set -x`, which echoes commands AFTER expansion -- so anything in argument position lands in the
# console log in full. The message here is not secret, but the habit is what stops the NEXT one being
# a token (a live ECR token reached committed CI evidence exactly this way on 2026-08-04). Subject is
# short and fixed-shape, so it stays an argument.
tmp="$(mktemp)"
printf '%s\n' "$message" > "$tmp"

if aws sns publish \
     --topic-arn "$SNS_TOPIC" \
     --subject "$subject" \
     --message "file://$tmp" \
     --region "${AWS_REGION:-}" >/dev/null 2>"$tmp.err"; then
  echo "notify: sent \"$subject\""
else
  echo "notify: FAILED to publish to SNS (continuing anyway):" >&2
  sed 's/^/notify:   /' "$tmp.err" >&2 || true
fi

rm -f "$tmp" "$tmp.err"
exit 0
