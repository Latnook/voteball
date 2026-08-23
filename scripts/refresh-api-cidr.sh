#!/usr/bin/env bash
# Write your CURRENT public address into terraform/voteball.tfvars as the EKS API allow-list.
#
# WHY THIS EXISTS: cluster_endpoint_public_access_cidrs has no default (2026-08-23 Task 3 review,
# finding T3-2), so it has to be set -- and because it names a home ISP address, it goes stale on its
# own schedule with no warning. When it does, EVERYTHING outside the VPC loses the cluster at the same
# moment: kubectl, terraform plan/apply, deploy.sh, destroy.sh, the evidence scripts. The symptom is a
# TIMEOUT against the *.eks.amazonaws.com endpoint, not a 403 -- AWS drops the packet rather than
# refusing the call -- so it presents as "the cluster is down", which is the wrong thing to go
# debugging. Run this, then `terraform apply`, before suspecting anything else.
#
# Usage:
#   ./scripts/refresh-api-cidr.sh            # detect this machine's public IP, write it as a /32
#   ./scripts/refresh-api-cidr.sh --check    # print what would change; exit 1 if it would change
#   ./scripts/refresh-api-cidr.sh 1.2.3.0/24 [10.0.0.0/8 ...]   # set explicit CIDRs instead
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib/config.sh
. scripts/lib/config.sh

KEY="cluster_endpoint_public_access_cidrs"
TFVARS_PATH="${TFVARS:-terraform/voteball.tfvars}"

check_only=0
args=()
for a in "$@"; do
  case "$a" in
    --check) check_only=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$a") ;;
  esac
done

# Detect the public address. checkip.amazonaws.com is preferred because it is the one endpoint here
# that is already in the trust boundary this repo depends on -- asking a random third-party echo
# service for the address you are about to put in a firewall rule is a needless dependency, and a
# wrong answer from it silently locks you out. VOTEBALL_PUBLIC_IP_CMD overrides it for the tests,
# which must not touch the network.
detect_ip() {
  local ip
  if [ -n "${VOTEBALL_PUBLIC_IP_CMD:-}" ]; then
    ip="$($VOTEBALL_PUBLIC_IP_CMD)" || return 1
  else
    ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com)" || return 1
  fi
  # Strip whitespace/newline; checkip returns a bare address with a trailing newline.
  ip="${ip//[$' \t\r\n']/}"
  printf '%s' "$ip"
}

if [ "${#args[@]}" -gt 0 ]; then
  cidrs=("${args[@]}")
else
  ip="$(detect_ip)" || {
    echo "Could not determine this machine's public address." >&2
    echo "Pass CIDRs explicitly:  $0 203.0.113.4/32" >&2
    exit 1
  }
  # Validate before writing. A garbled response (an HTML error page, a captive-portal redirect) would
  # otherwise be written into the tfvars as a CIDR and rejected by terraform minutes later, or worse,
  # accepted as something that locks this machine out.
  case "$ip" in
    *[!0-9.]*|""|*..*) echo "Detected public address '$ip' is not an IPv4 address -- refusing to write it." >&2; exit 1 ;;
  esac
  [ "$(printf '%s' "$ip" | tr -cd . | wc -c)" = "3" ] || {
    echo "Detected public address '$ip' does not have four octets -- refusing to write it." >&2; exit 1; }
  cidrs=("$ip/32")
fi

# Render as a Terraform list literal.
want="$KEY = ["
for i in "${!cidrs[@]}"; do
  [ "$i" -gt 0 ] && want+=", "
  want+="\"${cidrs[$i]}\""
done
want+="]"

have="$(grep -E "^[[:space:]]*${KEY}[[:space:]]*=" "$TFVARS_PATH" 2>/dev/null || true)"

if [ "$have" = "$want" ]; then
  echo "$TFVARS_PATH already sets:"
  echo "  $want"
  exit 0
fi

if [ "$check_only" = 1 ]; then
  echo "$TFVARS_PATH would change:"
  echo "  from: ${have:-(unset)}"
  echo "  to:   $want"
  exit 1
fi

[ -f "$TFVARS_PATH" ] || { echo "$TFVARS_PATH does not exist -- copy terraform/voteball.tfvars.example first." >&2; exit 1; }

if [ -n "$have" ]; then
  # Rewrite in place. A python one-liner rather than sed -i: the replacement contains '/' and '"',
  # and building a sed expression around a value that came off the network is how you get an
  # injection into your own firewall config.
  KEY="$KEY" WANT="$want" PATH_="$TFVARS_PATH" python3 - <<'PY'
import os, re
key, want, path = os.environ["KEY"], os.environ["WANT"], os.environ["PATH_"]
lines = open(path).read().splitlines(keepends=True)
pat = re.compile(rf'^\s*{re.escape(key)}\s*=')
out = [want + "\n" if pat.match(l) else l for l in lines]
open(path, "w").write("".join(out))
PY
else
  printf '\n# EKS API allow-list -- written by ./scripts/refresh-api-cidr.sh. Re-run it when your ISP\n# reassigns you; a stale entry times out kubectl and terraform against the cluster.\n%s\n' "$want" >> "$TFVARS_PATH"
fi

echo "$TFVARS_PATH now sets:"
echo "  $want"
echo
echo "Apply it:  cd terraform && terraform apply -var-file=voteball.tfvars"
