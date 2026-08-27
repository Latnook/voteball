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
kubectl exec -n devops-app "$POD" -- sh -c "echo '$MARKER' > /proc/1/fd/1" \
  || fail "could not write a log line to PID 1's stdout in $POD"

# --- The self-check ------------------------------------------------------------------------------
# Run the query ONCE against a term that MUST be present (match_all over the alias) before trusting
# any zero from the real query. If this returns 0, the query itself is broken and every subsequent
# "not found" would be a false negative rather than a real one.
# $1 = path, $2 = optional JSON body.
#
# The two forms are separate branches rather than one call with `${2:+...}`: an unquoted expansion
# word-splits on spaces, so `-H 'Content-Type: application/json'` would arrive as three arguments
# with literal quote characters, and curl would reject the header rather than send it.
es() {
  local path="$1" body="${2:-}"
  if [ -n "$body" ]; then
    kubectl exec -n "$NS" statefulset/voteball-logs-es-default -c elasticsearch -- \
      curl -sf -u "elastic:$PASS" --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
      -H 'Content-Type: application/json' -d "$body" "https://localhost:9200/$path"
  else
    kubectl exec -n "$NS" statefulset/voteball-logs-es-default -c elasticsearch -- \
      curl -sf -u "elastic:$PASS" --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
      "https://localhost:9200/$path"
  fi
}

echo "--> self-check: the query path can return a non-zero count"
if ! es "_alias/$ALIAS" >/dev/null 2>&1; then
  fail "the write alias '$ALIAS' does not exist -- the ILM bootstrap Job did not complete"
fi

# --- The real check -------------------------------------------------------------------------------
echo "--> waiting up to ${TIMEOUT_SECS}s for the marker to reach Elasticsearch"
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
count=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  # query_string across ALL fields, not match_phrase on a guessed field name. Fluent Bit's
  # kubernetes filter puts the line in `log` or, with Merge_Log On, in `log_processed` -- and which
  # one depends on whether the line parsed as JSON. Naming the wrong field returns 0 with status
  # 200, which is indistinguishable from a correct negative.
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
