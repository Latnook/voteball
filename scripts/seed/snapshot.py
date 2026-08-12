#!/usr/bin/env python3
"""Dump the five seeded tables to normalized JSON for data-neutrality diffing.

Two normalizations exist because both previously produced a confident "31 unexplained
changes" against a refactor that was in fact exact (services/backend/CLAUDE.md):

  * timestamps are excluded -- the databases being compared are seeded seconds apart,
    so every `updated_at` differs;
  * rows are keyed by their natural key, never sorted by whole-row text -- if a value
    changes, row text changes, sort order changes with it, and diff reports dozens of
    unrelated rows as modified.

Surrogate `id` columns are excluded for the same reason: they are assignment order, not data.
"""
import argparse
import json
import sys

import psycopg2

# table -> (natural key, columns compared)
#
# `name` IS compared by default -- do not exclude it here. It is a legacy column (per
# services/backend/CLAUDE.md, internal identity only, never returned by the API) that
# every admin rename route unconditionally overwrites with name_he, so it is exactly the
# kind of admin-owned value a seed.sql regression could silently clobber on an
# already-adopted row -- that is a real data-neutrality bug, and A vs C (both built from
# the same production dump) is precisely the comparison that must catch it. Only the
# A-vs-B comparison in verify-neutrality.sh (production-dump-derived vs pristine fresh
# install) legitimately expects `name` to differ -- a fresh install has never been
# admin-touched, so it still carries seed.sql's literal first-seed token (e.g. 'EPL')
# instead of the admin-set name_he. That comparison strips `name` for itself, explicitly
# and visibly, via --exclude; it does not change what this table defines as compared.
TABLES = {
    'leagues': ('name_en',
                ['name', 'name_en', 'name_he', 'name_ru', 'logo_url',
                 'sort_order', 'has_divisions']),
    'clubs': ('name_en',
              ['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'group_label']),
    'previous_parties': ('name_he',
                         ['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'bloc',
                          'economic', 'security', 'religiosity', 'sector', 'tags']),
    'upcoming_parties': ('name_he',
                         ['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'bloc',
                          'economic', 'security', 'religiosity', 'sector', 'tags',
                          'families', 'family_evidence']),
}


def snapshot(dsn, include=(), exclude=()):
    """Return {table: {natural_key: {column: value}}}.

    `include` names extra columns to compare where they exist -- used to inspect
    seed_key/admin_edited, which are excluded by default because they do not exist
    in the old schema and would make every baseline diff non-empty.

    `exclude` names columns to drop from the default set for this call only -- used by
    verify-neutrality.sh's A-vs-B comparison to strip `name` (see the TABLES comment
    above for why that one comparison, and only that one, doesn't want it). The natural
    key can't be excluded: rows would lose their identity and every comparison keyed on
    it would break.
    """
    out = {}
    with psycopg2.connect(dsn) as conn:
        for table, (key, columns) in TABLES.items():
            cols = [c for c in columns if c not in exclude or c == key]
            for extra in include:
                if extra not in cols and _has_column(conn, table, extra):
                    cols.append(extra)
            with conn.cursor() as cur:
                cur.execute(
                    'SELECT {} FROM {}'.format(', '.join(cols), table))
                rows = cur.fetchall()
            out[table] = {
                row[cols.index(key)]: {
                    c: (list(v) if isinstance(v, list) else v)
                    for c, v in zip(cols, row)
                }
                for row in rows
            }
        # party_lineage carries no natural key of its own; resolve it to party names
        # so it survives id reassignment between databases.
        with conn.cursor() as cur:
            cur.execute(
                'SELECT p.name_he, u.name_he FROM party_lineage l '
                'JOIN previous_parties p ON p.id = l.previous_party_id '
                'JOIN upcoming_parties u ON u.id = l.upcoming_party_id')
            out['party_lineage'] = {
                f'{a} -> {b}': {'linked': True} for a, b in cur.fetchall()
            }
    return out


def _has_column(conn, table, column):
    with conn.cursor() as cur:
        cur.execute(
            'SELECT 1 FROM information_schema.columns '
            'WHERE table_name = %s AND column_name = %s', (table, column))
        return cur.fetchone() is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dsn', required=True)
    ap.add_argument('--include', default='',
                    help='comma-separated extra columns to compare, e.g. seed_key')
    ap.add_argument('--exclude', default='',
                    help='comma-separated columns to drop from the default set, e.g. name')
    args = ap.parse_args()
    extra = [c for c in args.include.split(',') if c]
    drop = [c for c in args.exclude.split(',') if c]
    json.dump(snapshot(args.dsn, extra, drop), sys.stdout,
              ensure_ascii=False, indent=1, sort_keys=True, default=str)
    print()


if __name__ == '__main__':
    main()
