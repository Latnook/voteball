#!/usr/bin/env bash
# Proves a seed.sql restructure is data-neutral, per services/backend/CLAUDE.md.
#
# Three databases, because a fresh one proves nothing on its own -- a guarded block would
# set the value there anyway. Only the production-shaped database can show that an
# ALREADY-SEEDED database ends up where it is today, which is the only kind that exists
# in production.
#
#   C = OLD schema -> production dump -> OLD seed   (the baseline: current behaviour)
#   A = OLD schema -> production dump -> NEW schema -> NEW seed   (the migration)
#   B = NEW schema -> NEW seed                        (a fresh install; no dump)
#
# A == C is the diff that matters. A == B confirms fresh and migrated converge.
#
# The production dump is DATA-ONLY (bare INSERT statements plus setval calls, taken via
# psycopg2 -- the backend image has no pg_dump), so it can only be loaded into a database
# that already has the tables it inserts into. That is why the OLD schema has to be
# applied before the dump in every branch that uses the dump (C and A), and why B -- which
# never touches the dump -- goes straight from the NEW schema to the NEW seed.
#
# Usage: verify-neutrality.sh <production-dump.sql> <old-git-ref>
set -euo pipefail

DUMP="${1:?usage: verify-neutrality.sh <production-dump.sql> <old-git-ref>}"
OLD_REF="${2:?usage: verify-neutrality.sh <production-dump.sql> <old-git-ref>}"
CONTAINER="${SEED_TEST_CONTAINER:-voteball-test-db}"
DSN_BASE="postgres://postgres:test@localhost:5432"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Old files come from git, not from a hand-kept copy: a restated copy of the previous
# behaviour would pass throughout any period the real file diverged from it.
git -C "$ROOT" show "$OLD_REF:services/backend/schema.sql" > "$WORK/old-schema.sql"
git -C "$ROOT" show "$OLD_REF:services/backend/seed.sql"   > "$WORK/old-seed.sql"

psql_db() { docker exec -i "$CONTAINER" psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }

build() {   # build <dbname> <dump-or-empty> <before-schema-or-empty> <before-seed-or-empty> <after-schema-or-empty> <after-seed-or-empty>
    local db="$1" dump="$2" bschema="$3" bseed="$4" aschema="$5" aseed="$6"
    docker exec "$CONTAINER" psql -U postgres -q \
        -c "DROP DATABASE IF EXISTS $db;" -c "CREATE DATABASE $db;" >/dev/null
    [ -n "$bschema" ] && psql_db -d "$db" < "$bschema"
    [ -n "$bseed" ]   && psql_db -d "$db" < "$bseed"
    [ -n "$dump" ]    && psql_db -d "$db" < "$dump"
    [ -n "$aschema" ] && psql_db -d "$db" < "$aschema"
    [ -n "$aseed" ]   && psql_db -d "$db" < "$aseed"
}

echo "==> C: OLD schema + production dump + OLD seed"
build seed_c "$DUMP" "$WORK/old-schema.sql" "" "" "$WORK/old-seed.sql"
echo "==> A: OLD schema + production dump + NEW schema + NEW seed"
build seed_a "$DUMP" "$WORK/old-schema.sql" "" "$ROOT/services/backend/schema.sql" "$ROOT/services/backend/seed.sql"
echo "==> B: NEW schema + NEW seed (no dump)"
build seed_b "" "$ROOT/services/backend/schema.sql" "" "" "$ROOT/services/backend/seed.sql"

for db in a b c; do
    python3 "$ROOT/scripts/seed/snapshot.py" --dsn "$DSN_BASE/seed_$db" > "$WORK/$db.json"
done

status=0
echo
echo "==> DIFF A vs C  (already-seeded database is unchanged -- THE diff that matters)"
if diff -u "$WORK/c.json" "$WORK/a.json"; then echo "    OK: empty"; else status=1; fi
echo
echo "==> DIFF A vs B  (fresh install and migrated database converge)"
if diff -u "$WORK/b.json" "$WORK/a.json"; then echo "    OK: empty"; else status=1; fi
echo
echo "==> IDEMPOTENCE: re-apply new seed.sql to A"
psql_db -d seed_a < "$ROOT/services/backend/seed.sql"
python3 "$ROOT/scripts/seed/snapshot.py" --dsn "$DSN_BASE/seed_a" > "$WORK/a2.json"
if diff -u "$WORK/a.json" "$WORK/a2.json"; then echo "    OK: empty"; else status=1; fi

[ $status -eq 0 ] && echo && echo "PASS: restructure is data-neutral" || echo >&2 "FAIL: see diffs above"
exit $status
