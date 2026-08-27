#!/usr/bin/env bash
# Prove the EFK pipeline actually carries a log line end to end.
#
# WHY THIS IS NOT A POD CHECK. Three of this repo's most expensive defects share one shape: a check
# that passes against a component which is healthy and doing nothing. Fluent Bit's forward output
# buffers and retries on a refused connection while the DaemonSet stays Running; a missing
# NetworkPolicy rule, a typo'd Service name, or a dropped [OUTPUT] block all look identical to "no
# logs have been written yet". So this writes a KNOWN line and counts it back.
#
# It also exercises the query against input it KNOWS should match, once, before trusting a zero --
# an empty result from a pattern that can never match is indistinguishable from a correct negative,
# which is the one failure mode no amount of re-reading the code reveals.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/config.sh

NS=logging
ES_SVC=voteball-logs-es-http
ALIAS=voteball-logs
TIMEOUT_SECS="${EFK_VERIFY_TIMEOUT:-180}"
ALIAS_WAIT_SECS="${EFK_VERIFY_ALIAS_WAIT:-60}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> Verifying the EFK pipeline end to end"

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace $NS does not exist -- has terraform apply run?"

echo "--> waiting for Elasticsearch and Kibana to be Ready"
kubectl wait --for=condition=Ready pod -l common.k8s.elastic.co/type=elasticsearch \
  -n "$NS" --timeout=300s || fail "Elasticsearch pod never became Ready"
kubectl wait --for=condition=Ready pod -l common.k8s.elastic.co/type=kibana \
  -n "$NS" --timeout=300s || fail "Kibana pod never became Ready"
kubectl wait --for=condition=Available deployment/fluentd -n "$NS" --timeout=300s \
  || fail "Fluentd never became Available"

# The elastic password and CA come from Secrets ECK generated; neither is in git or Secrets Manager.
PASS="$(kubectl get secret voteball-logs-es-elastic-user -n "$NS" -o go-template='{{.data.elastic | base64decode}}')"
[ -n "$PASS" ] || fail "could not read the elastic user password"

# --- Credential handling ---------------------------------------------------------------------------
# NEVER pass the password as `curl -u elastic:$PASS`. That puts it in curl's own argv for the entire
# duration of every call, readable via `ps`/`/proc/*/cmdline` inside the pod for as long as the
# process runs -- the same defect shape as the live ECR token this repo leaked into CI evidence on
# 2026-08-04, and the same one already fixed in Task 4's ILM Job (charts/logging/templates/ilm.yaml)
# before this script existed. Use the identical remedy: write a curl config file INSIDE the pod with
# the shell BUILTIN `printf` (a builtin forks no process, so nothing puts the secret in a process
# table entry of its own), then pass every request through `-K` instead of `-u`. The Elasticsearch
# container's filesystem is writable at /tmp (readOnlyRootFilesystem does not cover it), so this has
# somewhere to land.
#
# The password reaches the pod over STDIN, never as an argument. `kubectl exec` sends its command
# line to the Kubernetes API server, where it can be recorded in the audit log -- a durable copy, not
# just a `ps` race on this machine. The local `printf` is a bash builtin (no forked process, so
# nothing lands in local argv either), and inside the pod `cat` reads the value from stdin rather than
# receiving it as a parameter.
#
# `-i` is REQUIRED. Without it, stdin is not forwarded, `cat` reads nothing, and the file is written
# with an EMPTY password -- silently (exit 0) -- which then fails authentication looking like a wrong
# credential rather than a plumbing bug. Confirmed both directions against a throwaway container
# before trusting this: piped correctly, the file holds the exact password; without `-i`, it holds
# `user = "elastic:"` and nothing else.
echo "--> writing a curl credential file inside the Elasticsearch pod (via stdin, never on curl's argv)"
printf '%s' "$PASS" | kubectl exec -i -n "$NS" --request-timeout=30s statefulset/voteball-logs-es-default \
  -c elasticsearch -- sh -c \
  'umask 077; { printf "user = \"elastic:"; cat; printf "\"\n"; } > /tmp/efk-curlrc' \
  || fail "could not write the curl credential file in the Elasticsearch pod"

# A marker unique to this run. Passed in rather than generated with $RANDOM so a re-run after a
# failure can search for the previous one.
MARKER="${EFK_VERIFY_MARKER:-efk-verify-$(date -u +%Y%m%d%H%M%S)}"

echo "--> writing marker '$MARKER' to a devops-app pod's stdout"
POD="$(kubectl get pods -n devops-app -l app=backend -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || fail "no backend pod found in devops-app to write a log line from"

# WRITE TO /proc/1/fd/1, NOT to the exec session's own stdout.
#
# `kubectl exec ... -- echo MARKER` prints to the EXEC stream and never touches the container's log.
# The kubelet only writes PID 1's stdout/stderr to /var/log/containers/*.log, which is the only thing
# Fluent Bit tails -- so the obvious form of this check writes a marker that provably cannot be
# found, then reports the pipeline broken. That is a false negative built into the test itself.
#
# /proc/1/fd/1 is PID 1's stdout. The backend container runs as uid 1000 and so does PID 1, so the
# write is permitted; readOnlyRootFilesystem does not apply to /proc.
kubectl exec -n devops-app --request-timeout=30s "$POD" -- sh -c "echo '$MARKER' > /proc/1/fd/1" \
  || fail "could not write a log line to PID 1's stdout in $POD"

# $1 = path, $2 = optional JSON body.
#
# The two forms are separate branches rather than one call with `${2:+...}`: an unquoted expansion
# word-splits on spaces, so `-H 'Content-Type: application/json'` would arrive as three arguments
# with literal quote characters, and curl would reject the header rather than send it.
#
# --max-time 30 on every curl AND --request-timeout=30s on every kubectl exec: the deadline loops
# below only re-check their budget BETWEEN iterations, so one unresponsive Elasticsearch or one hung
# `kubectl exec` would otherwise block indefinitely and defeat the bounded design this script
# advertises. Both timeouts are load-bearing -- do not remove either as noise.
es() {
  local path="$1" body="${2:-}"
  if [ -n "$body" ]; then
    kubectl exec -n "$NS" --request-timeout=30s statefulset/voteball-logs-es-default -c elasticsearch -- \
      curl -sf --max-time 30 -K /tmp/efk-curlrc --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
      -H 'Content-Type: application/json' -d "$body" "https://localhost:9200/$path"
  else
    kubectl exec -n "$NS" --request-timeout=30s statefulset/voteball-logs-es-default -c elasticsearch -- \
      curl -sf --max-time 30 -K /tmp/efk-curlrc --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
      "https://localhost:9200/$path"
  fi
}

# --- Wait for the write alias to exist -------------------------------------------------------------
# A real first deploy can reach here before the ILM bootstrap Job has finished creating the alias --
# Elasticsearch/Kibana going Ready says nothing about that Job's own completion. So this WAITS for the
# alias inside the same bounded-deadline pattern the marker check below uses, rather than asserting it
# once and failing a deploy that only needed a few more seconds.
echo "--> waiting up to ${ALIAS_WAIT_SECS}s for the write alias '$ALIAS' to exist"
alias_deadline=$(( $(date +%s) + ALIAS_WAIT_SECS ))
alias_found=0
while [ "$(date +%s)" -lt "$alias_deadline" ]; do
  if es "_alias/$ALIAS" >/dev/null 2>&1; then
    alias_found=1
    break
  fi
  sleep 5
done
[ "$alias_found" -eq 1 ] \
  || fail "the write alias '$ALIAS' does not exist after ${ALIAS_WAIT_SECS}s -- the ILM bootstrap Job did not complete"

# --- The self-check ------------------------------------------------------------------------------
# Exercise the EXACT SAME query path the real check uses ($ALIAS/_count with a query_string body),
# against a document known to exist, before trusting any zero from it. A self-check that calls a
# different endpoint (e.g. a plain alias-metadata lookup) proves nothing about the query mechanism
# itself -- a bad JSON escape, a wrong field name, or a malformed body would sail straight past it and
# only surface as "the pipeline is broken" after a full timeout, which is exactly the
# false-negative-indistinguishable-from-a-real-negative failure this script's header warns about.
#
# The canary is indexed DIRECTLY into the alias, bypassing Fluent Bit/Fluentd entirely -- this proves
# the query works, not that ingestion works (that is what the real check below is for).
#
# THE CANARY MUST NOT SATISFY THE MARKER QUERY. This was a real defect, and it inverted the whole
# point of the script. The canary used to be "efk-selfcheck-${MARKER}", and Elasticsearch's standard
# analyzer SPLITS ON HYPHENS: with MARKER=efk-verify-20260827120000 that canary tokenizes to
# [efk, selfcheck, efk, verify, 20260827120000], which CONTAINS the marker's own token sequence
# [efk, verify, 20260827120000] as a phrase. Indexing the canary therefore made the real check below
# return >=1 the instant the self-check ran -- so the script PASSED with Fluentd dead, with the
# allow-fluentbit-ingest NetworkPolicy missing, or with the [OUTPUT] forward block dropped from
# terraform/addon-cloudwatch.tf. A check that cannot fail is worse than no check.
#
# The remedy is in the CANARY, not in the query: strip every punctuation character so the analyzer
# sees ONE opaque term that shares no token with the marker. Measured against a throwaway
# elasticsearch:9.1.4 container, `_analyze` with the standard analyzer:
#
#   efk-verify-20260827120000                -> [efk, verify, 20260827120000]
#   efk-selfcheck-efk-verify-20260827120000  -> [efk, selfcheck, efk, verify, 20260827120000]   (OLD)
#   selfcheckefkverify20260827120000         -> [selfcheckefkverify20260827120000]              (NEW)
#
# and the counts that matter, with ONLY the canary indexed and the real marker query run against it:
# OLD canary -> 1 (the defect), NEW canary -> 0. With a marker-bearing document added, the same query
# returns 1. UAX#29 word segmentation does not break between letters and digits, so the concatenated
# form stays a single term.
CANARY="selfcheck$(printf '%s' "$MARKER" | tr -d '[:punct:]')"

# Structural guard on the property above, not on the query. If a future edit reintroduces a separator
# the canary's tokens can overlap the marker's again, and the failure is SILENT -- a self-check that
# poisons the real check reads as a pass. `[:punct:]` covers hyphen and underscore and everything else
# the standard tokenizer breaks on.
case "$CANARY" in
  *[![:alnum:]]*) fail "the self-check canary must be a single alphanumeric token (it is '$CANARY') -- a separator lets it satisfy the marker query and the real check can then never fail" ;;
esac
case "$CANARY" in
  *"$MARKER"*) fail "the self-check canary contains the marker verbatim -- it would satisfy the real check on its own" ;;
esac

echo "--> self-check: indexing a canary directly into $ALIAS and querying it back"
es "$ALIAS/_doc?refresh=true" "{\"log\":\"$CANARY\"}" >/dev/null \
  || fail "could not index a canary document -- Elasticsearch is not accepting writes to the alias '$ALIAS'"
self_count="$(es "$ALIAS/_count" "{\"query\":{\"query_string\":{\"query\":\"\\\"$CANARY\\\"\"}}}" \
              | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
[ "${self_count:-0}" -gt 0 ] \
  || fail "SELF-CHECK FAILED: a document indexed directly cannot be found by the same query the real check uses.
  The query path itself is broken -- do NOT read a later zero as 'the pipeline is not delivering'."

# --- The real check -------------------------------------------------------------------------------
echo "--> waiting up to ${TIMEOUT_SECS}s for the marker to reach Elasticsearch"
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
count=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  # query_string across ALL fields, not match_phrase on a guessed field name. Fluent Bit's
  # kubernetes filter puts the line in `log` or, with Merge_Log On, in `log_processed` -- and which
  # one depends on whether the line parsed as JSON. Naming the wrong field returns 0 with status
  # 200, which is indistinguishable from a correct negative -- ruled out above by the self-check.
  count="$(es "$ALIAS/_count" "{\"query\":{\"query_string\":{\"query\":\"\\\"$MARKER\\\"\"}}}" \
            | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
  count="${count:-0}"
  [ "$count" -gt 0 ] && break
  sleep 5
done

[ "$count" -gt 0 ] || fail "marker '$MARKER' never reached Elasticsearch after ${TIMEOUT_SECS}s.
  Check, in order:
    1. kubectl logs -n $NS deploy/fluentd            (is it accepting forward connections?)
    2. kubectl logs -n amazon-cloudwatch -l k8s-app=fluent-bit --tail=50
       (Fluent Bit BUFFERS AND RETRIES SILENTLY on a refused connection -- it will look healthy)
    3. kubectl get networkpolicy -n $NS              (is allow-fluentbit-ingest present?)
    4. the [OUTPUT] forward block in terraform/addon-cloudwatch.tf reached the cluster
       (it needs a terraform apply -- a git push does NOT deploy it)"

echo "PASS: marker found in Elasticsearch ($count document(s))"
echo
echo "  Kibana: https://kibana.${APP_DOMAIN}"
echo "  Index pattern: ${ALIAS}-*"
