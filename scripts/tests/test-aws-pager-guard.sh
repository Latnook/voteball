#!/usr/bin/env bash
# Guards the AWS CLI v2 pager, which is the single most confusing way this repo can hang.
#
# v2 pipes command output through `less` whenever stdout is a terminal. v1 had no pager at all, so
# nothing here noticed until the repo owner upgraded on 2026-08-21. Every script in scripts/ runs at
# a terminal, so any `aws` call whose output is not captured or redirected simply STOPS, waiting for
# someone to press `q`. What you see is a deploy frozen on a normal-looking step -- indistinguishable
# from a slow AWS API call, a hung network path, or a throttled account.
#
# WHICH commands page is not about output size -- it is about which class implements them, and the
# split is counter-intuitive. Ordinary service commands (sts get-caller-identity, secretsmanager
# put-secret-value, every ec2 describe-*) render through OutputStreamFactory and ARE paged: even one
# short line from `--query ... --output text` hangs. The eks customizations `update-kubeconfig` and
# `get-token` are BasicCommand subclasses writing straight to stdout via uni_print, so they are NEVER
# paged. That exemption is what keeps kubectl working: it shells out to `aws eks get-token` on every
# request. Never infer this from a command's output -- check the class, or test it on a pty.
#
# The real hang sites are the --output text/table calls, and the two expensive ones are mid-deploy:
#   deploy.sh step 3b   put-secret-value --output text   (seed-jenkins-secret.sh)
#   deploy.sh step 7b   put-secret-value --output text   (seed-argocd-token.sh) -- AFTER the billed
#                                                         ~13-minute apply, so a hang costs a rebuild
#   capture-evidence.sh sns get-topic-attributes --output table, cloudwatch get-metric-statistics
#
# CI never saw it: Jenkins captures stdout, so it is not a terminal there, and the agents have run
# amazon/aws-cli:2.x all along. That asymmetry is exactly why this needs a test -- a green pipeline
# proves nothing about the laptop path, and the laptop path is where deploys are actually run.
#
# The exhaustiveness check below is the durable half. Fixing today's scripts is easy; what costs a
# debugging cycle is the NEXT script, added months from now, that calls `aws` without the guard.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

CONFIG=scripts/lib/config.sh

# Scripts that mention the aws CLI but never execute it. Same spirit as run-ci-suite.sh's SKIP map:
# an explicit list with a reason, checked in BOTH directions, rather than a silent pattern exclusion.
declare -A EXEMPT=(
  [scripts/tests/test-build-push-ecr.sh]="the aws call is text inside an extracted block assertion, never executed"
)

# ---- 1. the central guard exists and is unconditional -------------------------------------------
grep -qE '^export AWS_PAGER=""' "$CONFIG" \
  || fail "$CONFIG must 'export AWS_PAGER=\"\"' -- without it every terminal aws call can hang"
ok "$CONFIG exports an empty AWS_PAGER"

# Deliberately NOT ${AWS_PAGER-}: honouring a user's global `AWS_PAGER=less` would faithfully
# reproduce the hang this exists to prevent.
grep -qE '^export AWS_PAGER="\$\{AWS_PAGER' "$CONFIG" \
  && fail "AWS_PAGER must be forced empty, not defaulted -- a user's AWS_PAGER=less would hang deploys"
ok "the guard is forced, not merely defaulted (a global AWS_PAGER=less cannot re-break it)"

# ---- 2. it actually reaches child processes -----------------------------------------------------
# Exported, because every aws call in these scripts is a child process. A plain shell variable would
# set the parent and change nothing about the CLI's behaviour -- the same half-working failure the
# deploy.env loader documents about `set -a`.
out="$(AWS_PAGER="less" bash -c '. scripts/lib/config.sh >/dev/null 2>&1; printf "[%s]" "$AWS_PAGER"; env | grep -c "^AWS_PAGER=$"' 2>/dev/null)"
[ "$out" = "[]1" ] || fail "sourcing $CONFIG must EXPORT an empty AWS_PAGER even when one is preset, got: $out"
ok "sourcing config.sh exports an empty AWS_PAGER, overriding a preset one"

# ---- 3. exhaustiveness: no aws-calling script is left unguarded ----------------------------------
unguarded=()
declare -A seen=()
while IFS= read -r f; do
  # Comments stripped: several scripts discuss `aws ...` in prose without running it.
  sed 's/#.*//' "$f" | grep -qE '(^|[^[:alnum:]_./-])aws[[:space:]]+[a-z0-9-]+[[:space:]]+[a-z0-9-]+' || continue
  seen["$f"]=1
  [ -n "${EXEMPT[$f]:-}" ] && continue
  grep -q 'lib/config.sh' "$f" && continue
  grep -q 'AWS_PAGER' "$f" && continue
  unguarded+=("$f")
done < <(find scripts services -name '*.sh' | sort)

if [ ${#unguarded[@]} -gt 0 ]; then
  echo "FAIL: these scripts call the aws CLI with no pager guard:" >&2
  printf '       %s\n' "${unguarded[@]}" >&2
  echo "       Source scripts/lib/config.sh, or 'export AWS_PAGER=\"\"' near the top." >&2
  echo "       Under AWS CLI v2 an unredirected aws call at a terminal hangs forever." >&2
  exit 1
fi
ok "every script that calls the aws CLI is covered (${#seen[@]} scripts scanned)"

# ---- 4. the exemption list cannot rot ------------------------------------------------------------
for f in "${!EXEMPT[@]}"; do
  [ -f "$f" ] || fail "EXEMPT lists '$f' but it does not exist -- drop the entry"
  [ -n "${seen[$f]:-}" ] || fail "EXEMPT lists '$f' but it no longer mentions the aws CLI -- drop the entry"
done
ok "every exemption still exists and is still needed"

# ---- 5. the call sites that actually hang are guarded --------------------------------------------
# Named individually because seed-argocd-token.sh runs at deploy step 7b, AFTER the billed
# ~13-minute apply: hanging there costs a rebuild, not just a retry.
for f in scripts/seed-argocd-token.sh scripts/seed-jenkins-secret.sh scripts/capture-evidence.sh; do
  grep -q 'lib/config.sh' "$f" || fail "$f no longer sources config.sh -- its unredirected aws calls would hang"
done
ok "the known hang sites still inherit the guard"

echo "PASS: scripts/tests/test-aws-pager-guard.sh"
