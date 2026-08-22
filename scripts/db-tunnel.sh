#!/usr/bin/env bash
# Open a local TCP tunnel to the RDS instance so a desktop client (pgAdmin, DBeaver, psql) can reach
# it. RDS lives in the isolated DB subnets with publicly_accessible = false and a security group that
# only admits 5432 from the EKS node security group -- there is no route to it from a laptop, and
# there is no bastion host. The only thing already inside that boundary is the cluster, so this
# borrows it: a throwaway socat pod relays 5432 to RDS, and `kubectl port-forward` relays your
# machine to that pod (over the Kubernetes API server, so no inbound port is opened anywhere).
#
#   ./scripts/db-tunnel.sh            # listens on localhost:5433
#   LOCAL_PORT=5555 ./scripts/db-tunnel.sh
#
# Ctrl-C ends the tunnel and deletes the pod.
#
# Two details that are not obvious:
#
#   * The pod is labelled `app: migrate`, not a name of its own. charts/voteball/templates/
#     networkpolicy.yaml default-denies egress in devops-app and re-allows it only for the labels
#     backend/worker/backup/frontend/migrate/canary -- a pod outside that list resolves DNS and then
#     has every TCP connection silently dropped (this is how the backup CronJob shipped broken for 12
#     days). `migrate` is the right one to borrow: it carries the RDS egress the backend has, and no
#     Service selects it, so nothing routes live traffic here.
#   * socat relays raw bytes, so TLS is still negotiated end-to-end between your client and RDS.
#     Use sslmode=require (NOT verify-full: the certificate names the RDS endpoint, and your client
#     is dialling localhost).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh
. scripts/lib/config.sh

NS="${NS:-devops-app}"
POD="${POD:-db-tunnel}"
LOCAL_PORT="${LOCAL_PORT:-5433}"
SOCAT_IMAGE="${SOCAT_IMAGE:-alpine/socat:1.8.0.0}"

# Read the endpoint from the live ConfigMap rather than values.yaml or `terraform output`: it is what
# the running pods actually connect to, and it needs no terraform init/backend.hcl.
DB_HOST="$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.DB_HOST}')"
DB_NAME="$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.DB_NAME}')"
DB_USER="$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.DB_USER}')"
[ -n "$DB_HOST" ] || { echo "ERROR: DB_HOST is empty -- is the cluster up and the chart deployed?" >&2; exit 1; }

cleanup() {
  echo
  echo "Removing tunnel pod ${POD}..."
  kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=true >/dev/null

kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels:
    app: migrate          # borrows the RDS egress allowance -- see the header comment
spec:
  restartPolicy: Never
  containers:
    - name: socat
      image: ${SOCAT_IMAGE}
      args: ["TCP-LISTEN:5432,fork,reuseaddr", "TCP:${DB_HOST}:5432"]
      ports: [{ containerPort: 5432 }]
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 64Mi }
EOF

echo "Waiting for ${POD} to become ready..."
kubectl wait --for=condition=Ready "pod/${POD}" -n "$NS" --timeout=120s

cat <<EOF

Connect your client to:

  Host      localhost
  Port      ${LOCAL_PORT}
  Database  ${DB_NAME}
  Username  ${DB_USER}
  Password  the db_password value in ${TFVARS}
  SSL mode  require

Leave this running. Ctrl-C closes the tunnel.

EOF

kubectl port-forward -n "$NS" "pod/${POD}" "${LOCAL_PORT}:5432"
