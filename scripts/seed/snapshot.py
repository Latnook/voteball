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
# The legacy `name` column is deliberately excluded from every entry below. Per
# services/backend/CLAUDE.md it is internal identity only, never returned by the API, and
# every admin rename route (rename_league/rename_club/rename_*_party in queries.py)
# unconditionally overwrites it with name_he -- even on a no-op rename. A production
# database that has ever been touched by an admin therefore has `name` != seed.sql's
# literal insert value on those rows, while a pristine fresh install still has the
# literal. That divergence is real, pre-existing, and has nothing to do with whether a
# seed.sql restructure is data-neutral -- comparing it turned every A-vs-B diff on this
# dump into 107 false-positive hunks, all on this one non-served column, confirmed by
# grepping the diff for which field actually changed.
TABLES = {
    'leagues': ('name_en',
                ['name_en', 'name_he', 'name_ru', 'logo_url',
                 'sort_order', 'has_divisions']),
    'clubs': ('name_en',
              ['name_en', 'name_he', 'name_ru', 'logo_url', 'group_label']),
    'previous_parties': ('name_he',
                         ['name_en', 'name_he', 'name_ru', 'logo_url', 'bloc',
                          'economic', 'security', 'religiosity', 'sector', 'tags']),
    'upcoming_parties': ('name_he',
                         ['name_en', 'name_he', 'name_ru', 'logo_url', 'bloc',
                          'economic', 'security', 'religiosity', 'sector', 'tags',
                          'families', 'family_evidence']),
}


def snapshot(dsn, include=()):
    """Return {table: {natural_key: {column: value}}}.

    `include` names extra columns to compare where they exist -- used to inspect
    seed_key/admin_edited, which are excluded by default because they do not exist
    in the old schema and would make every baseline diff non-empty.
    """
    out = {}
    with psycopg2.connect(dsn) as conn:
        for table, (key, columns) in TABLES.items():
            cols = list(columns)
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
    args = ap.parse_args()
    extra = [c for c in args.include.split(',') if c]
    json.dump(snapshot(args.dsn, extra), sys.stdout,
              ensure_ascii=False, indent=1, sort_keys=True, default=str)
    print()


if __name__ == '__main__':
    main()
