#!/usr/bin/env bash
# Restart Grafana so the grafana-datasources Secret actually reaches it, and repair nothing when
# there is nothing to repair.
#
# THE FAILURE THIS EXISTS FOR (docs/design/2026-08-24-grafana-datasources-design.md, "Verification
# outcome", finding 3): `envFromSecret`/`envFromSecrets` project a Secret's keys as environment
# variables AT POD START ONLY. On a fresh deploy the Grafana pod is already running (kube-
# prometheus-stack lands during step 6's apply) long before ArgoCD syncs charts/observability and
# ESO fills grafana-datasources -- so GF_DATASOURCE_DB_PASSWORD is simply never set. Grafana expands
# an unset variable in a provisioning file to an EMPTY STRING rather than erroring, so it
# authenticates as grafana_ro with an empty password and the PostgreSQL panel fails SASL auth, with
# nothing in Grafana's own health checks ever noticing.
#
# WHY THIS IS CONDITIONAL, not an unconditional restart after every deploy: the node group is 100%
# Spot and Grafana has no persistent state, so restarting it is nearly free, but it is not literally
# free -- a restart on a run where the Secret does not exist yet (charts/observability's
# externalSecret.enabled gate still false) or was already projected on a PRIOR restart (a routine
# re-run of deploy.sh) is pointless churn. Same shape as scripts/verify-public-dns.sh: act only when
# a specific, measurable condition holds.
#
# NOT FATAL from the caller's point of view -- deploy.sh treats a non-zero exit here as a warning,
# the same way it treats 3d/11, 7b/11, 11b/11 and 11c/11. A Grafana restart failing must never fail a
# deploy whose application is otherwise healthy.
#
# Offline-testable: every kubectl call is a variable, so scripts/tests/test-restart-grafana-
# datasources.sh can drive the whole decision tree with fakes and no cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh disable=SC1091
. scripts/lib/config.sh

NS="${GRAFANA_NAMESPACE:-observability}"
DEPLOYMENT="${GRAFANA_DEPLOYMENT:-kube-prometheus-stack-grafana}"
SECRET="${GRAFANA_SECRET_NAME:-grafana-datasources}"
TIMEOUT="${GRAFANA_ROLLOUT_TIMEOUT:-300s}"

# Every stub runs inside a SUBSHELL ( ... ), not a bare eval -- a stub that itself calls `exit`
# (the natural way to fake a failing command) would otherwise terminate this whole script instead of
# just reporting failure to the caller. scripts/verify-public-dns.sh established this pattern.
secret_exists() {
  if [ -n "${GRAFANA_GET_SECRET_CMD:-}" ]; then ( eval "$GRAFANA_GET_SECRET_CMD" ); return; fi
  kubectl get secret "$SECRET" -n "$NS" >/dev/null 2>&1
}

# WAIT for the Secret rather than checking once, because on a FRESH deploy a single check is always
# too early. scripts/deploy.sh calls this at step 11d, moments after step 11 bootstraps ArgoCD --
# at which point ArgoCD has not finished its first sync, the ExternalSecret does not exist, and
# External Secrets Operator has not reconciled it. Observed on the 2026-08-25 rebuild: 11d reported
# "nothing to project. Not restarting." and exited 0 while the credential arrived ~90s later, so the
# deploy finished with Grafana holding no password and both data sources failing on first use.
#
# Bounded and non-fatal: if it never appears we fall through to the same "nothing to project"
# message as before. Waiting cannot make anything worse -- the alternative is a guaranteed miss.
# GRAFANA_WAIT_SECONDS=0 disables the wait entirely, which is what the offline tests use.
wait_for_secret() {
  local budget="${GRAFANA_WAIT_SECONDS:-180}" waited=0 step=5
  secret_exists && return 0
  [ "$budget" -eq 0 ] && return 1
  echo "    ${SECRET} not there yet -- waiting up to ${budget}s for ArgoCD to sync it and ESO to fill it."
  while [ "$waited" -lt "$budget" ]; do
    sleep "$step"; waited=$((waited + step))
    if secret_exists; then
      echo "    ${SECRET} appeared after ${waited}s."
      return 0
    fi
  done
  return 1
}

deployment_exists() {
  if [ -n "${GRAFANA_GET_DEPLOYMENT_CMD:-}" ]; then ( eval "$GRAFANA_GET_DEPLOYMENT_CMD" ); return; fi
  kubectl get deployment "$DEPLOYMENT" -n "$NS" >/dev/null 2>&1
}

# Prints "set" (and only "set") when the running pod already has the credential projected.
env_is_projected() {
  if [ -n "${GRAFANA_CHECK_ENV_CMD:-}" ]; then ( eval "$GRAFANA_CHECK_ENV_CMD" ); return; fi
  kubectl exec -n "$NS" "deploy/$DEPLOYMENT" -c grafana -- \
    sh -c 'echo "${GF_DATASOURCE_DB_PASSWORD:+set}"' 2>/dev/null
}

restart_grafana() {
  if [ -n "${GRAFANA_RESTART_CMD:-}" ]; then ( eval "$GRAFANA_RESTART_CMD" ); return; fi
  kubectl rollout restart "deployment/$DEPLOYMENT" -n "$NS"
}

wait_for_rollout() {
  if [ -n "${GRAFANA_ROLLOUT_STATUS_CMD:-}" ]; then ( eval "$GRAFANA_ROLLOUT_STATUS_CMD" ); return; fi
  kubectl rollout status "deployment/$DEPLOYMENT" -n "$NS" --timeout="$TIMEOUT"
}

echo "==> Checking whether Grafana needs restarting to pick up ${SECRET}"

if ! wait_for_secret; then
  echo "    ${SECRET} does not exist in ${NS} yet (externalSecret.enabled is probably still false, or"
  echo "    the grafana_ro credential has not been seeded) -- nothing to project. Not restarting."
  exit 0
fi

if ! deployment_exists; then
  echo "    deployment/${DEPLOYMENT} does not exist in ${NS} -- Grafana is not deployed yet. Not restarting."
  exit 0
fi

if [ "$(env_is_projected || true)" = "set" ]; then
  echo "    the running Grafana pod already has GF_DATASOURCE_DB_PASSWORD set -- already projected."
  echo "    Not restarting (this is the common case on a routine re-run of deploy.sh)."
  exit 0
fi

echo "    ${SECRET} exists but the running pod predates it -- restarting Grafana to project it."
restart_grafana
wait_for_rollout

if [ "$(env_is_projected || true)" = "set" ]; then
  echo "    verified: GF_DATASOURCE_DB_PASSWORD is now set in the running container."
  exit 0
fi

echo "restart-grafana-datasources: restarted Grafana, but GF_DATASOURCE_DB_PASSWORD is still not set" >&2
echo "  in the running container. The PostgreSQL data source will keep failing SASL auth. Check:" >&2
echo "    kubectl exec -n ${NS} deploy/${DEPLOYMENT} -c grafana -- sh -c 'echo \"\${GF_DATASOURCE_DB_PASSWORD:+set}\"'" >&2
exit 1
