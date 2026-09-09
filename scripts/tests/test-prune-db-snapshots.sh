#!/usr/bin/env bash
# scripts/prune-db-snapshots.sh -- retention sweep for manual RDS snapshots.
#
# This is the only script in the repo that DELETES a backup, so the tests are about what it refuses
# to do, not about the happy path. Fully offline: `aws` is replaced by a fake on PATH that serves a
# fixture listing and records every command it is asked to run.
#
# The fake is also the point of the ordering tests. The fixture deliberately contains snapshots whose
# NAME order disagrees with their SnapshotCreateTime order, because that disagreement is real: the
# identifier embeds time_static.deploy, so a snapshot created today can be named after the day the
# stack was deployed. Live data on 2026-09-09 had voteball-eks-db-final-20260727061817 created on
# 2026-07-30 and ...-20260730222636 created on 2026-08-02 -- name order and time order genuinely
# differ. A pruner that sorted by name would delete the newest snapshot and keep an ancient one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Fixture: five snapshots. Column order matches the script's --query projection
# ([DBSnapshotIdentifier, SnapshotCreateTime]), oldest first by TIME. Note snap-name-late sorts LAST
# alphabetically but is the SECOND OLDEST by time -- a name-sorted pruner would protect it.
cat > "$work/rows.txt" <<'ROWS'
voteball-eks-db-final-20260701000000	2026-07-01T00:00:00.000000+00:00	available
voteball-zzz-name-sorts-last	2026-07-02T00:00:00.000000+00:00	available
voteball-eks-db-final-20260703000000	2026-07-03T00:00:00.000000+00:00	available
voteball-aaa-name-sorts-first	2026-07-04T00:00:00.000000+00:00	available
voteball-eks-db-final-20260705000000	2026-07-05T00:00:00.000000+00:00	available
voteball-eks-db-final-20260706000000	2026-07-06T00:00:00.000000+00:00	creating
ROWS

# The fake MUST honour the --query's sort key, or the ordering assertions below are vacuous. First
# version of this test just `cat`-ed a time-sorted fixture and ignored --query entirely; mutation
# testing then showed that swapping the script's sort_by to &DBSnapshotIdentifier was NOT CAUGHT --
# the fixture came back in the same order no matter what was asked for. That is this repo's
# "a pattern that can never match" shape: the assertion read correctly and could not fail.
make_aws() {  # $1 = describe exit code
  cat > "$work/bin/aws" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/calls.log"
case "\$*" in
  *describe-db-snapshots*)
    python3 - "\$@" <<'PYEOF'
import sys, re
rows = [l.rstrip("\n").split("\t") for l in open("$work/rows.txt") if l.strip()]
q = next((a for a in sys.argv if "sort_by" in a), "")
# The sort key is the LAST &Word before a closing paren. Do NOT anchor on sort_by(...,&Key):
# the query embeds a filter that contains its own commas and parens, so a [^,]+ pattern stops at
# the first inner comma and never reaches the key. (No backticks in this comment on purpose -- it
# sits inside an UNQUOTED heredoc, so a backtick here is command substitution, not punctuation.)
m = re.search(r"&(\w+)\s*\)", q)
# Refuse rather than default. A silent fallback to SnapshotCreateTime is exactly what made the
# first two versions of this fake vacuous: the script could stop sorting entirely, or sort by
# the wrong field, and the fixture still came back in time order.
if not m:
    sys.stderr.write("fake aws: no sort key in --query; refusing to guess\n")
    sys.exit(9)
key = m.group(1)
# column 0 is DBSnapshotIdentifier, column 1 is SnapshotCreateTime
idx = 0 if key == "DBSnapshotIdentifier" else 1
# Honour the Status predicate as well. Without this the status filter is untested: a mutation
# deleting it was NOT CAUGHT until this fixture grew a non-available row (2026-09-09).
want = re.search(r"Status == .(\w+).", q)
if want:
    rows = [r for r in rows if len(r) < 3 or r[2] == want.group(1)]
for r in sorted(rows, key=lambda r: r[idx]):
    print("\t".join(r[:2]))
PYEOF
    exit $1 ;;
  *delete-db-snapshot*)    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$work/bin/aws"
}
make_aws 0

# config.sh is sourced by the script under test; stub the two values it needs so nothing reads
# terraform state or AWS. A terraform shim that exits 127 makes the offline-ness a CONTRACT rather
# than an accident -- the 2026-09-08 test-render-argocd-app.sh lesson, where a test passed only
# because the developer machine happened to have credentials the CI agent did not.
cat > "$work/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform must not be invoked by this test" >&2
exit 127
EOF
chmod +x "$work/bin/terraform"

run() {  # run the script with the fakes in front of PATH, from a stub repo
  : > "$work/calls.log"
  ( cd "$work/repo" && PATH="$work/bin:$PATH" ./scripts/prune-db-snapshots.sh "$@" ) 2>&1
}

# A stub repo: the real script plus a minimal config.sh, so nothing reaches the live tfvars.
mkdir -p "$work/repo/scripts/lib"
cp "$ROOT/scripts/prune-db-snapshots.sh" "$work/repo/scripts/"
cat > "$work/repo/scripts/lib/config.sh" <<'EOF'
export AWS_PAGER=""
REGION="test-region-1"
CLUSTER="voteball"
EOF

# ---- 1. dry run is the DEFAULT, and deletes nothing --------------------------------------------
out="$(run --retain 2)"
grep -q 'would delete' <<<"$out" || fail "dry run printed no plan:\n$out"
grep -q 'Dry run -- nothing was deleted' <<<"$out" || fail "dry run did not say so:\n$out"
grep -q 'delete-db-snapshot' "$work/calls.log" && fail "DRY RUN CALLED delete-db-snapshot"
ok "dry run is the default and issues no delete call"

# ---- 2. --apply deletes exactly the oldest (TOTAL - retain) -------------------------------------
out="$(run --retain 2 --apply)"
n=$(grep -c 'delete-db-snapshot' "$work/calls.log" || true)
[ "$n" -eq 3 ] || fail "expected 3 deletes with retain=2 over 5 snapshots, got $n"
ok "--apply deletes exactly TOTAL - retain"

# ---- 3. it deletes by TIME, not by NAME. The whole point. ---------------------------------------
# retain=2 must keep the two NEWEST BY TIME (...20260704 'aaa' and ...20260705) and delete the three
# oldest -- including 'voteball-zzz-name-sorts-last', which any name-based sort would have kept.
grep -q 'voteball-zzz-name-sorts-last' "$work/calls.log" \
  || fail "did not delete the second-oldest snapshot whose NAME sorts last -- pruning by name?"
grep -q 'delete-db-snapshot .*voteball-aaa-name-sorts-first' "$work/calls.log" \
  && fail "DELETED voteball-aaa-name-sorts-first, which is the 2nd NEWEST by time -- pruning by name"
ok "retention is decided by SnapshotCreateTime, not by identifier"

# ---- 4. the newest is never deleted, even at --retain 0 -----------------------------------------
out="$(run --retain 0 --apply)"
grep -q 'delete-db-snapshot .*voteball-eks-db-final-20260705000000' "$work/calls.log" \
  && fail "--retain 0 deleted the NEWEST snapshot -- the next deploy would restore nothing"
n=$(grep -c 'delete-db-snapshot' "$work/calls.log" || true)
[ "$n" -eq 4 ] || fail "--retain 0 should still keep 1 (deleting 4 of 5), deleted $n"
ok "--retain 0 still protects the newest snapshot (hard floor)"

# ---- 5. a FAILED listing must delete nothing ----------------------------------------------------
# The accidental-data-loss shape: an expired token makes the listing empty, and an empty listing must
# never be read as "there is nothing worth keeping".
make_aws 1
out="$(run --retain 2 --apply || true)"
grep -q 'delete-db-snapshot' "$work/calls.log" && fail "deleted snapshots after a FAILED listing"
grep -q 'Refusing to delete anything on a failed listing' <<<"$out" \
  || fail "a failed listing must say so explicitly:\n$out"
ok "a failed describe call deletes nothing and exits loudly"
make_aws 0

# ---- 6. retain >= total is a no-op --------------------------------------------------------------
out="$(run --retain 99 --apply)"
grep -q 'delete-db-snapshot' "$work/calls.log" && fail "deleted something with retain > total"
grep -q 'nothing to prune' <<<"$out" || fail "expected a 'nothing to prune' message:\n$out"
ok "retain >= total prunes nothing"

# ---- 7. a non-numeric retain is refused rather than defaulted ------------------------------------
if out="$(run --retain seven --apply 2>&1)"; then
  fail "a non-numeric --retain was accepted:\n$out"
fi
grep -q 'delete-db-snapshot' "$work/calls.log" && fail "deleted something on a bad --retain"
# Pin the MESSAGE, not just the non-zero exit. Without the explicit check the script still fails --
# on `[: seven: integer expression expected` -- so the exit status alone passed even with the
# validation deleted (mutation-confirmed 2026-09-09). Failing by accident is not the same as
# refusing on purpose, and only one of them survives a refactor.
grep -q 'retain must be a non-negative integer' <<<"$out" \
  || fail "a bad --retain must be refused explicitly, not fall through to an arithmetic error:\n$out"
ok "a non-numeric --retain is refused explicitly, not silently defaulted"

# ---- 7b. a snapshot that is still CREATING is ignored entirely -----------------------------------
# The fixture's newest row by time is 'creating'. If the status filter is dropped, that row becomes
# "the newest, never deleted" -- which silently un-protects the newest AVAILABLE snapshot and lets it
# be pruned. A still-forming snapshot also cannot be deleted by the API anyway, so counting it is
# wrong in both directions.
out="$(run --retain 2 --apply)"
grep -q 'voteball-eks-db-final-20260706000000' "$work/calls.log" \
  && fail "tried to delete a snapshot that is still 'creating'"
grep -q 'Newest (never deleted): voteball-eks-db-final-20260705000000' <<<"$out" \
  || fail "the protected newest must be the newest AVAILABLE snapshot, not a 'creating' one:\n$out"
ok "a 'creating' snapshot is neither deleted nor counted as the newest"

# ---- 8. the predicate matches find-latest-snapshot.sh -------------------------------------------
# If these two ever diverge, the pruner can delete the snapshot the next apply restores from. Pinned
# textually because the failure is silent and only visible on a rebuild.
for needle in 'snapshot-type manual' 'starts_with(DBInstanceIdentifier' 'sort_by' 'SnapshotCreateTime'; do
  grep -q -- "$needle" "$ROOT/scripts/prune-db-snapshots.sh" \
    || fail "prune-db-snapshots.sh no longer uses '$needle' -- it must match find-latest-snapshot.sh"
  grep -q -- "$needle" "$ROOT/scripts/find-latest-snapshot.sh" \
    || fail "find-latest-snapshot.sh no longer uses '$needle' -- the two selectors have diverged"
done
ok "both scripts still select snapshots the same way"

# ---- 9. destroy.sh calls it, with --apply, AFTER terraform destroy ------------------------------
grep -q 'prune-db-snapshots.sh' "$ROOT/scripts/destroy.sh" \
  || fail "destroy.sh no longer calls the pruner -- snapshots accumulate again"
# Regex, not a literal: the call is quoted ("$(dirname "$0")/prune-db-snapshots.sh" --apply), so a
# literal 'prune-db-snapshots.sh --apply' can never match. Allow the closing quote.
grep -qE 'prune-db-snapshots\.sh"? --apply' "$ROOT/scripts/destroy.sh" \
  || fail "destroy.sh must call the pruner with --apply, or it only prints a plan"
prune_ln="$(grep -n 'prune-db-snapshots\.sh' "$ROOT/scripts/destroy.sh" | head -1 | cut -d: -f1)"
destroy_ln="$(grep -n 'step "7/7' "$ROOT/scripts/destroy.sh" | head -1 | cut -d: -f1)"
[ -n "$prune_ln" ] && [ -n "$destroy_ln" ] || fail "could not locate the prune/destroy steps"
[ "$destroy_ln" -lt "$prune_ln" ] \
  || fail "the prune must run AFTER terraform destroy (which takes the final snapshot), got prune=$prune_ln destroy=$destroy_ln"
ok "destroy.sh prunes with --apply, after the final snapshot is taken"

echo "PASS: $pass assertions"
