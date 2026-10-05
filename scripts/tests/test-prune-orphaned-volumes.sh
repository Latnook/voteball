#!/usr/bin/env bash
# scripts/prune-orphaned-volumes.sh -- deletes EBS volumes a previous cluster's PVCs left behind.
#
# Like prune-db-snapshots.sh this script DELETES storage, so the tests are about what it refuses to
# do. Fully offline: `aws` is a fake on PATH that serves a fixture and records every call.
#
# The fake filters its fixture by the --filters it is actually passed. That is what makes the
# predicate tests non-vacuous: the fixture holds an ATTACHED volume, a volume with the right name
# and no PVC tag, and another cluster's volume, and each of them is deleted the moment the matching
# filter is dropped from the script. A fake that returned a pre-filtered list would pass whatever
# the script asked for -- the mistake test-prune-db-snapshots.sh records making twice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/scripts/lib"

old="$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%S.000000+00:00)"
older="$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%S.000000+00:00)"
young="$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S.000000+00:00)"

# Fixture columns: id, CreateTime, size, state, Name tag, has-pvc-tag, namespace, claim.
# Listed NEWEST FIRST on purpose, so an "oldest first" result can only come from the script's sort.
cat > "$work/rows.txt" <<ROWS
vol-young	$young	20	available	voteball-dynamic-pvc-young	yes	logging	es-data
vol-old	$old	20	available	voteball-dynamic-pvc-old	yes	logging	es-data
vol-older	$older	10	available	voteball-dynamic-pvc-older	yes	observability	prometheus-db
vol-attached	$older	10	in-use	voteball-dynamic-pvc-attached	yes	observability	prometheus-db
vol-notpvc	$older	50	available	voteball-dynamic-pvc-lookalike	no	-	-
vol-othercluster	$older	20	available	otherapp-dynamic-pvc-1	yes	logging	es-data
vol-handmade	$older	100	available	my-scratch-disk	no	-	-
ROWS

make_aws() {  # $1 = cluster state: gone | exists | error   $2 = describe-volumes exit   $3 = delete exit
  cat > "$work/bin/aws" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/calls.log"
case "\$*" in
  *"eks describe-cluster"*)
    case "$1" in
      gone)   echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: voteball." >&2; exit 254 ;;
      exists) echo "ACTIVE"; exit 0 ;;
      *)      echo "An error occurred (ExpiredTokenException) when calling the DescribeCluster operation: token expired" >&2; exit 254 ;;
    esac ;;
  *"ec2 describe-volumes"*)
    [ "$2" = 0 ] || exit $2
    python3 - "\$@" <<'PYEOF'
import sys, fnmatch
rows = [l.rstrip("\n").split("\t") for l in open("$work/rows.txt") if l.strip()]
args = sys.argv[1:]
# Refuse rather than default: no sort key in --query means the script stopped sorting.
q = next((a for a in args if "sort_by" in a), "")
if "&CreateTime" not in q:
    sys.stderr.write("fake aws: --query does not sort by CreateTime; refusing to guess\n")
    sys.exit(9)
filters = {}
for a in args:
    if a.startswith("Name=") and ",Values=" in a:
        name, values = a[len("Name="):].split(",Values=", 1)
        filters[name] = values
if "status" in filters:
    rows = [r for r in rows if r[3] == filters["status"]]
if "tag:Name" in filters:
    rows = [r for r in rows if fnmatch.fnmatchcase(r[4], filters["tag:Name"])]
if filters.get("tag-key") == "kubernetes.io/created-for/pvc/name":
    rows = [r for r in rows if r[5] == "yes"]
for r in sorted(rows, key=lambda r: r[1]):
    print("\t".join([r[0], r[1], r[2], r[6], r[7]]))
PYEOF
    exit 0 ;;
  *"ec2 delete-volume"*) exit $3 ;;
esac
exit 0
EOF
  chmod +x "$work/bin/aws"
}

# Offline by contract, not by accident (the 2026-09-08 test-render-argocd-app.sh lesson).
cat > "$work/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform must not be invoked by this test" >&2
exit 127
EOF
chmod +x "$work/bin/terraform"

cp "$ROOT/scripts/prune-orphaned-volumes.sh" "$work/repo/scripts/"
cat > "$work/repo/scripts/lib/config.sh" <<'EOF'
export AWS_PAGER=""
REGION="test-region-1"
CLUSTER="voteball"
EOF

run() {
  : > "$work/calls.log"
  ( cd "$work/repo" && PATH="$work/bin:$PATH" ./scripts/prune-orphaned-volumes.sh "$@" ) 2>&1
}
deleted() { grep -c 'ec2 delete-volume' "$work/calls.log" || true; }
was_deleted() { grep -q "ec2 delete-volume --volume-id $1 " "$work/calls.log"; }

# ---- 1. dry run is the DEFAULT, and deletes nothing ---------------------------------------------
make_aws gone 0 0
out="$(run)"
grep -q 'would delete  vol-old ' <<<"$out" || fail "dry run printed no plan:\n$out"
grep -q 'Dry run -- nothing was deleted' <<<"$out" || fail "dry run did not say so:\n$out"
[ "$(deleted)" -eq 0 ] || fail "DRY RUN CALLED delete-volume"
ok "dry run is the default and issues no delete call"

# ---- 2. --apply deletes exactly the old orphans, oldest first -----------------------------------
out="$(run --apply)"
[ "$(deleted)" -eq 2 ] || fail "expected 2 deletes (vol-older, vol-old), got $(deleted):\n$out"
was_deleted vol-old   || fail "did not delete vol-old"
was_deleted vol-older || fail "did not delete vol-older"
first="$(grep 'ec2 delete-volume' "$work/calls.log" | head -1)"
grep -q 'vol-older' <<<"$first" || fail "did not delete oldest first: $first"
grep -q 'Deleted 30 GiB' <<<"$out" || fail "did not total the deleted size (20 + 10):\n$out"
ok "--apply deletes the two old orphans, oldest first, and totals them"

# ---- 3. the grace period: a young volume is kept ------------------------------------------------
was_deleted vol-young && fail "DELETED vol-young, which is 2 days old with a 7-day grace period"
grep -q 'kept     vol-young' <<<"$out" || fail "did not report keeping the young volume:\n$out"
out="$(run --apply --min-age-days 1)"
was_deleted vol-young || fail "--min-age-days 1 should delete a 2-day-old volume"
ok "a volume younger than the grace period is kept, and --min-age-days moves the line"

# ---- 4. the predicate: attached, untagged, other-cluster and hand-made volumes are never touched -
run --apply --min-age-days 0 >/dev/null
for v in vol-attached vol-notpvc vol-othercluster vol-handmade; do
  was_deleted "$v" && fail "DELETED $v, which is not an orphaned PVC volume of this cluster"
done
[ "$(deleted)" -eq 3 ] || fail "at --min-age-days 0 expected exactly the 3 orphans, got $(deleted)"
ok "only unattached volumes carrying BOTH this cluster's name prefix and the PVC tag are eligible"

# ---- 5. a live cluster stops everything ---------------------------------------------------------
make_aws exists 0 0
out="$(run --apply --min-age-days 0)" || fail "a live cluster is not an error, but the script exited non-zero"
[ "$(deleted)" -eq 0 ] || fail "DELETED VOLUMES WHILE THE CLUSTER EXISTS"
grep -q 'refusing to prune' <<<"$out" || fail "did not say why it stopped:\n$out"
grep -q 'ec2 describe-volumes' "$work/calls.log" && fail "listed volumes at all while the cluster exists"
ok "refuses to prune while the EKS cluster exists"

# ---- 6. 'cannot tell' counts as 'exists' --------------------------------------------------------
make_aws error 0 0
if out="$(run --apply --min-age-days 0)"; then fail "an unanswerable cluster check must exit non-zero:\n$out"; fi
[ "$(deleted)" -eq 0 ] || fail "DELETED VOLUMES without knowing whether the cluster is gone"
ok "a failed cluster check deletes nothing and exits non-zero"

# ---- 7. a FAILED listing must delete nothing ----------------------------------------------------
make_aws gone 255 0
if out="$(run --apply)"; then fail "a failed describe-volumes must exit non-zero:\n$out"; fi
[ "$(deleted)" -eq 0 ] || fail "deleted after a failed listing"
ok "a failed listing deletes nothing and exits non-zero"

# ---- 8. a delete that fails is reported, the rest still run, and the exit is non-zero ------------
make_aws gone 0 1
if out="$(run --apply)"; then fail "a failed delete must exit non-zero:\n$out"; fi
[ "$(deleted)" -eq 2 ] || fail "stopped at the first failed delete instead of trying both"
grep -q 'FAILED   vol-old' <<<"$out" || fail "did not report the failed delete:\n$out"
ok "a failed delete is reported, does not stop the others, and exits non-zero"

# ---- 9. arguments -------------------------------------------------------------------------------
make_aws gone 0 0
if run --min-age-days abc >/dev/null; then fail "accepted a non-numeric --min-age-days"; fi
if run --delete-everything >/dev/null; then fail "accepted an unknown argument"; fi
[ "$(deleted)" -eq 0 ] || fail "deleted something on a rejected argument"
ok "rejects a non-numeric age and unknown arguments before touching AWS"

# ---- 10. destroy.sh runs it, with --apply, only after the infrastructure is gone ----------------
d="$ROOT/scripts/destroy.sh"
call="$(grep -n 'prune-orphaned-volumes.sh" --apply' "$d" | head -1 | cut -d: -f1)"
[ -n "$call" ] || fail "destroy.sh does not call prune-orphaned-volumes.sh --apply"
tf="$(grep -n 'step "7/7  Destroying AWS infrastructure' "$d" | head -1 | cut -d: -f1)"
[ -n "$tf" ] || fail "could not find destroy.sh's terraform destroy step -- has it been renamed?"
[ "$call" -gt "$tf" ] || fail "destroy.sh prunes volumes BEFORE terraform destroy (line $call <= $tf); the cluster still exists then and the script will refuse"
ok "destroy.sh calls it with --apply after the terraform destroy step"

echo "PASS: test-prune-orphaned-volumes.sh -- $pass checks"
