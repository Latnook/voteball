#!/usr/bin/env python3
"""Diff the live RDS instance's admin-editable data (leagues/clubs/previous_parties/
upcoming_parties) against what the current working tree's schema.sql + seed.sql would produce,
and (with --apply) backfill the safe subset of that diff into seed.sql.

Invoked via scripts/sync-seed-from-rds.sh, which resolves connection details and opens the SSH
tunnel to RDS (it's in a private subnet) before calling this script -- see that script for the
operator-facing entry point. This file assumes an already-open, already-authenticated path to
RDS on the given host/port.

Three-way classification of every field-level difference, per the "reverse seeding" design in
docs/plan.md-adjacent session notes (see CLAUDE.md pointer):

  - NULL-BACKFILL: the reference (fresh install) has NULL, RDS has a value -- this is exactly the
    "admin curated more than seed.sql captures yet" case (e.g. a logo_url added via the admin UI).
    Safe to auto-generate a guarded `UPDATE ... WHERE ... IS NULL` statement for, matching the
    pattern seed.sql already uses everywhere. Only this category is ever written to seed.sql, and
    only when --apply is passed.

  - VALUE-CONFLICT: both sides have a non-NULL value, but they differ (e.g. a rename). A guarded
    `WHERE col IS NULL` statement can never fix this -- the field is already populated. Report
    only; a human has to decide whether RDS or seed.sql (or neither) is "right" and fix the wrong
    side directly (see the "Yachad" -> "Together" fix earlier this session, which needed a direct
    UPDATE against RDS, not a seed.sql change).

  - ROW-EXISTENCE: a name exists on only one side. Could mean "admin added this on purpose" (only
    in RDS), "deleted on purpose" (only in seed.sql, e.g. the Joint List), or "not yet deployed"
    (either direction). Always needs a human call. Report only.

Never writes to RDS. Only ever writes to the local seed.sql file, and only for the NULL-BACKFILL
category, and only with --apply.
"""
import argparse
import os
import sys

import psycopg2

BACKEND_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                            'ansible-project', 'roles', 'backend', 'files', 'backend')
SEED_SQL_PATH = os.path.join(BACKEND_DIR, 'seed.sql')

sys.path.insert(0, BACKEND_DIR)

TABLES = {
    'leagues': ['name_en', 'name_he', 'logo_url'],
    'previous_parties': ['name_en', 'name_he', 'logo_url'],
    'upcoming_parties': ['name_en', 'name_he', 'logo_url'],
}
# clubs is handled separately since its "identity" columns (league/domestic_league) are FKs that
# differ by id across environments -- resolved to the *league's* legacy name instead, so the join
# key is stable across RDS and the local reference the same way leagues/parties already are.
CLUB_COLUMNS = ['name_en', 'name_he', 'logo_url']


def sql_escape(value):
    return value.replace("'", "''")


def dump_simple_table(conn, table, columns, key_column):
    """Returns {identity_key: {col: value}}, keyed by key_column (name_en/name_he -- see
    TABLE_KEY_COLUMN -- not the legacy `name` column, which admin renames flip to the other
    language and so can't be trusted as a stable identity once a row has been edited)."""
    cur = conn.cursor()
    select_cols = [c for c in columns if c != key_column]
    cur.execute(f"SELECT {key_column}, {', '.join(select_cols)} FROM {table}")
    rows = cur.fetchall()
    cur.close()
    return {r[0]: dict(zip(select_cols, r[1:])) for r in rows}


def dump_clubs(conn, key_column):
    cur = conn.cursor()
    cur.execute(f'''
        SELECT c.{key_column}, c.name_en, c.name_he, c.logo_url,
               l1.name_en AS league_name, l2.name_en AS domestic_league_name
        FROM clubs c
        JOIN leagues l1 ON l1.id = c.league_id
        LEFT JOIN leagues l2 ON l2.id = c.domestic_league_id
    ''')
    rows = cur.fetchall()
    cur.close()
    return {
        r[0]: {
            'name_en': r[1], 'name_he': r[2], 'logo_url': r[3],
            'league': r[4], 'domestic_league': r[5],
        }
        for r in rows
    }


def classify(rds_data, ref_data, columns):
    """Returns (null_backfill, value_conflict, only_in_rds, only_in_ref).
    null_backfill / value_conflict: {name: {col: (ref_value, rds_value)}}
    only_in_rds / only_in_ref: set of names
    """
    only_in_rds = set(rds_data) - set(ref_data)
    only_in_ref = set(ref_data) - set(rds_data)

    null_backfill, value_conflict = {}, {}
    for name in sorted(set(rds_data) & set(ref_data)):
        rds_row, ref_row = rds_data[name], ref_data[name]
        for col in columns:
            rds_val, ref_val = rds_row.get(col), ref_row.get(col)
            if rds_val == ref_val:
                continue
            if ref_val is None and rds_val is not None:
                null_backfill.setdefault(name, {})[col] = (ref_val, rds_val)
            else:
                # Either ref has a value RDS lacks (ref_val set, rds_val None -- e.g. seed.sql
                # added something not yet deployed) or both are set but differ (a real rename).
                # Both are human-decision territory, not a safe auto-backfill.
                value_conflict.setdefault(name, {})[col] = (ref_val, rds_val)

    return null_backfill, value_conflict, only_in_rds, only_in_ref


def print_report(table, null_backfill, value_conflict, only_in_rds, only_in_ref):
    if not (null_backfill or value_conflict or only_in_rds or only_in_ref):
        print(f"  {table}: in sync, no differences.")
        return
    print(f"  {table}:")
    if null_backfill:
        print(f"    NULL-backfill (safe, auto-generated below) -- {len(null_backfill)} row(s):")
        for name, cols in null_backfill.items():
            for col, (_, rds_val) in cols.items():
                print(f"      {name!r}.{col} = {rds_val!r}")
    if value_conflict:
        print(f"    VALUE-CONFLICT (needs a human decision) -- {len(value_conflict)} row(s):")
        for name, cols in value_conflict.items():
            for col, (ref_val, rds_val) in cols.items():
                print(f"      {name!r}.{col}: seed.sql={ref_val!r}  RDS={rds_val!r}")
    if only_in_rds:
        print(f"    Only in RDS (admin-added?) -- {sorted(only_in_rds)}")
    if only_in_ref:
        print(f"    Only in seed.sql (deleted on RDS, or not yet deployed?) -- {sorted(only_in_ref)}")


def build_backfill_sql(table, key_column, null_backfill):
    lines = []
    for name, cols in null_backfill.items():
        for col, (_, rds_val) in cols.items():
            lines.append(
                f"UPDATE {table} SET {col} = '{sql_escape(rds_val)}' "
                f"WHERE {key_column} = '{sql_escape(name)}' AND {col} IS NULL;"
            )
    return lines


def insert_into_seed_sql(table, marker_line, new_lines, header_comment):
    with open(SEED_SQL_PATH) as f:
        content = f.read()
    if content.count(marker_line) != 1:
        print(f"ERROR: could not find a unique anchor line in seed.sql for {table}; "
              f"leaving seed.sql untouched for this table. Anchor was:\n  {marker_line!r}",
              file=sys.stderr)
        return False
    block = "\n" + header_comment + "\n" + "\n".join(new_lines) + "\n"
    content = content.replace(marker_line, marker_line + block)
    with open(SEED_SQL_PATH, 'w') as f:
        f.write(content)
    return True


# Which column to key generated WHERE clauses on, per table. seed.sql's own backfill pattern is
# "UPDATE <table> SET name_en = name" for leagues/clubs (their legacy `name` column is English) and
# "UPDATE <table> SET name_he = name" for previous_parties/upcoming_parties (legacy `name` is
# Hebrew) -- so that's the column value stable/present regardless of which side (RDS vs a fresh
# seed.sql install) is being read, and matches the key dump_simple_table()/dump_clubs() already use.
TABLE_KEY_COLUMN = {
    'leagues': 'name_en',
    'clubs': 'name_en',
    'previous_parties': 'name_he',
    'upcoming_parties': 'name_he',
}

# The last name_en backfill line for each table, used as the anchor to insert new logo_url
# (or other) backfill blocks directly after. Keep these in sync if seed.sql's backfill order
# changes -- insert_into_seed_sql() fails loudly (not silently) if the anchor is no longer unique.
SEED_ANCHORS = {
    'leagues': "UPDATE leagues SET name_en = 'Premier League' WHERE name = 'EPL';\n"
               "UPDATE leagues SET name_en = 'UEFA Champions League' WHERE name = 'UCL';\n",
    'previous_parties': "UPDATE previous_parties SET name_en = 'Other' WHERE name_he = 'אחר' AND name_en IS NULL;\n",
    'upcoming_parties': "UPDATE upcoming_parties SET name_en = 'The Reservists' WHERE name_he = 'המילואימניקים' AND name_en IS NULL;\n",
    'clubs': "UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/d/d6/IroniModiinFC.png' "
             "WHERE name_en = 'Ironi Modi''in' AND logo_url IS NULL;\n",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='localhost', help='Tunneled RDS host (default: localhost)')
    parser.add_argument('--port', type=int, required=True, help='Tunneled local port to RDS')
    parser.add_argument('--password', required=True, help='RDS db_pass')
    parser.add_argument('--dbname', default='postgres')
    parser.add_argument('--user', default='postgres')
    parser.add_argument('--ref-host', default='localhost', help='Local reference Postgres host')
    parser.add_argument('--ref-port', type=int, default=5432)
    parser.add_argument('--ref-password', default='test',
                         help='Password for the local voteball-test-db container (default matches '
                              'CLAUDE.md\'s documented test setup)')
    parser.add_argument('--apply', action='store_true',
                         help='Write the NULL-backfill category into seed.sql (default: report only)')
    parser.add_argument('--dump-rds-clubs', action='store_true',
                         help='Print every live-RDS club (id, league, name_en, name_he, logo_url), '
                              'grouped by league and sorted by name_en, then exit -- for reconstructing '
                              'a seed.sql roster block by hand after a large admin-side roster edit.')
    parser.add_argument('--dump-rds-leagues', action='store_true',
                         help='Print every live-RDS league row (id, name, name_en, name_he, '
                              'sort_order), then exit -- for debugging league ordering/name drift.')
    args = parser.parse_args()

    if args.dump_rds_leagues:
        rds = psycopg2.connect(host=args.host, port=args.port, dbname=args.dbname,
                                user=args.user, password=args.password, sslmode='require')
        cur = rds.cursor()
        cur.execute('SELECT id, name, name_en, name_he, sort_order FROM leagues ORDER BY sort_order NULLS LAST, name_en')
        for row in cur.fetchall():
            print(row)
        cur.close()
        rds.close()
        return

    if args.dump_rds_clubs:
        rds = psycopg2.connect(host=args.host, port=args.port, dbname=args.dbname,
                                user=args.user, password=args.password, sslmode='require')
        cur = rds.cursor()
        cur.execute('''
            SELECT l1.name_en, c.name_en, c.name_he, c.logo_url, l2.name_en
            FROM clubs c
            JOIN leagues l1 ON l1.id = c.league_id
            LEFT JOIN leagues l2 ON l2.id = c.domestic_league_id
            ORDER BY l1.name_en, c.name_en
        ''')
        rows = cur.fetchall()
        cur.close()
        rds.close()
        current_league = None
        for league, name_en, name_he, logo_url, domestic_league in rows:
            if league != current_league:
                print(f"\n-- {league} --")
                current_league = league
            extra = f" (domestic: {domestic_league})" if domestic_league else ""
            print(f"  {name_en!r}\tname_he={name_he!r}\tlogo_url={logo_url!r}{extra}")
        return

    try:
        rds = psycopg2.connect(host=args.host, port=args.port, dbname=args.dbname,
                                user=args.user, password=args.password, sslmode='require')
    except psycopg2.OperationalError as err:
        print(f"ERROR: could not connect to RDS via the tunnel ({args.host}:{args.port}): {err}",
              file=sys.stderr)
        sys.exit(1)

    try:
        ref = psycopg2.connect(host=args.ref_host, port=args.ref_port, dbname='postgres',
                                user='postgres', password=args.ref_password, sslmode='disable')
    except psycopg2.OperationalError as err:
        print(f"ERROR: could not connect to the local reference database at "
              f"{args.ref_host}:{args.ref_port}. This script expects the voteball-test-db "
              f"container to be running -- see CLAUDE.md's backend test setup:\n"
              f"  docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17\n"
              f"Underlying error: {err}", file=sys.stderr)
        sys.exit(1)

    # Reset + reseed the reference DB from the CURRENT working tree's schema.sql/seed.sql, via the
    # backend's own db.init_db() -- guarantees the reference reflects exactly what's on disk right
    # now, matching the DROP TABLE list backend/tests/conftest.py uses. db.py reads its connection
    # config from env vars at import time (even though we only use init_db(), not get_db(), and
    # pass our own already-open connection) -- set them first, matching tests/conftest.py's pattern.
    os.environ.setdefault('DB_HOST', args.ref_host)
    os.environ.setdefault('DB_NAME', 'postgres')
    os.environ.setdefault('DB_USER', 'postgres')
    os.environ.setdefault('DB_PASS', args.ref_password)
    os.environ.setdefault('DB_SSLMODE', 'disable')
    import db as backend_db
    ref_cur = ref.cursor()
    ref_cur.execute('''
        DROP TABLE IF EXISTS vote_upcoming_parties, vote_clubs, vote_leagues, votes,
            rollup_previous, rollup_upcoming, rollup_previous_upcoming,
            rollup_national_previous, rollup_national_upcoming, rollup_national_previous_upcoming,
            clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE
    ''')
    ref.commit()
    ref_cur.close()
    backend_db.init_db(ref)

    print("Diffing live RDS against a fresh reference seeded from the current seed.sql...\n")

    any_backfill = False
    any_conflict_or_existence = False
    pending_writes = []  # (table, key_column, null_backfill) for --apply

    for table, columns in TABLES.items():
        key_column = TABLE_KEY_COLUMN[table]
        diff_columns = [c for c in columns if c != key_column]
        rds_data = dump_simple_table(rds, table, columns, key_column)
        ref_data = dump_simple_table(ref, table, columns, key_column)
        null_backfill, value_conflict, only_in_rds, only_in_ref = classify(rds_data, ref_data, diff_columns)
        print_report(table, null_backfill, value_conflict, only_in_rds, only_in_ref)
        if null_backfill:
            any_backfill = True
            pending_writes.append((table, key_column, null_backfill))
        if value_conflict or only_in_rds or only_in_ref:
            any_conflict_or_existence = True

    clubs_key_column = TABLE_KEY_COLUMN['clubs']
    clubs_diff_columns = [c for c in CLUB_COLUMNS if c != clubs_key_column]
    rds_clubs = dump_clubs(rds, clubs_key_column)
    ref_clubs = dump_clubs(ref, clubs_key_column)
    null_backfill, value_conflict, only_in_rds, only_in_ref = classify(rds_clubs, ref_clubs, clubs_diff_columns)
    print_report('clubs', null_backfill, value_conflict, only_in_rds, only_in_ref)
    if only_in_rds or only_in_ref:
        print("    -- grouped by league, to help spot renames vs. real roster swaps:")
        for name in sorted(only_in_rds):
            row = rds_clubs[name]
            print(f"      RDS-only   [{row['league']}] {name!r}")
        for name in sorted(only_in_ref):
            row = ref_clubs[name]
            print(f"      seed-only  [{row['league']}] {name!r}")
    if null_backfill:
        any_backfill = True
        pending_writes.append(('clubs', TABLE_KEY_COLUMN['clubs'], null_backfill))
    if value_conflict or only_in_rds or only_in_ref:
        any_conflict_or_existence = True

    rds.close()

    if not any_backfill and not any_conflict_or_existence:
        print("\nEverything is in sync -- seed.sql already matches the live RDS instance.")
        ref.close()
        return

    if args.apply and any_backfill:
        print("\nApplying NULL-backfill statements to seed.sql...")
        for table, key_column, null_backfill in pending_writes:
            if table not in SEED_ANCHORS:
                print(f"  WARNING: no seed.sql anchor configured for '{table}' -- skipping "
                      f"(clubs backfills aren't auto-applied yet; add them by hand).",
                      file=sys.stderr)
                continue
            sql_lines = build_backfill_sql(table, key_column, null_backfill)
            ok = insert_into_seed_sql(
                table, SEED_ANCHORS[table], sql_lines,
                f"-- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh."
            )
            if ok:
                print(f"  {table}: wrote {len(sql_lines)} statement(s).")

        # Re-verify: reseed the reference DB again and confirm the NULL-backfill category is gone.
        ref_cur = ref.cursor()
        ref_cur.execute('''
            DROP TABLE IF EXISTS vote_upcoming_parties, vote_clubs, vote_leagues, votes,
                rollup_previous, rollup_upcoming, rollup_previous_upcoming,
                rollup_national_previous, rollup_national_upcoming, rollup_national_previous_upcoming,
                clubs, leagues, previous_parties, upcoming_parties, alert_state CASCADE
        ''')
        ref.commit()
        ref_cur.close()
        backend_db.init_db(ref)

        rds2 = psycopg2.connect(host=args.host, port=args.port, dbname=args.dbname,
                                 user=args.user, password=args.password, sslmode='require')
        remaining = False
        for table, columns in TABLES.items():
            key_column = TABLE_KEY_COLUMN[table]
            diff_columns = [c for c in columns if c != key_column]
            rds_data = dump_simple_table(rds2, table, columns, key_column)
            ref_data = dump_simple_table(ref, table, columns, key_column)
            nb, _, _, _ = classify(rds_data, ref_data, diff_columns)
            if nb:
                remaining = True
        rds2.close()
        print("Verified: NULL-backfill category is now empty." if not remaining
              else "WARNING: some NULL-backfill diffs remain after applying -- check seed.sql manually.")
    elif any_backfill:
        print("\nRun again with --apply to write the NULL-backfill statements above into seed.sql.")

    if any_conflict_or_existence:
        print("\nVALUE-CONFLICT and only-in-one-side findings above are never auto-applied -- "
              "review them and fix the appropriate side by hand (a direct RDS UPDATE, an admin UI "
              "action, or a seed.sql edit).")

    ref.close()


if __name__ == '__main__':
    main()
