#!/usr/bin/env python3
"""Emit seed.sql's straight tables from a seeded database.

The data is transcribed by machine, not by hand. 212 clubs across four merged statements
is exactly the kind of retyping that produces a silently wrong row, and the guard that
used to catch a duplicate key ("first in file order wins") no longer exists -- a VALUES
block joins, so a repeated key matches arbitrarily.

Usage: generate-tables.py --dsn <dsn> --table leagues|clubs|previous_parties|upcoming_parties
"""
import argparse
import re
import unicodedata

import psycopg2

SPECS = {
    # 'name' (the legacy column) is fetched here too, ahead of name_en, and carried into
    # the temp table as `legacy_name`. The clubs roster INSERT further down seed.sql still
    # joins ON l.name = c.league_name using the tokens 'UCL'/'EPL' -- if this table's INSERT
    # wrote name_en into `name` instead, that join would match nothing on a fresh database
    # and insert zero clubs. Selecting the live `name` column (rather than deriving it) is
    # what keeps the two literal exceptions -- UCL and EPL -- exactly in sync with what
    # seed.sql has always inserted, with no hand-maintained exception list here.
    'leagues': dict(
        slug_from='name_en',
        columns=['name', 'name_en', 'name_he', 'name_ru', 'logo_url', 'sort_order',
                 'has_divisions'],
        types='seed_key TEXT PRIMARY KEY, legacy_name TEXT, name_en TEXT, name_he TEXT, '
              'name_ru TEXT, logo_url TEXT, sort_order INTEGER, has_divisions BOOLEAN',
        order='sort_order'),
    'clubs': dict(
        slug_from='name_en',
        columns=['name_en', 'name_he', 'name_ru', 'logo_url', 'group_label'],
        types='seed_key TEXT PRIMARY KEY, league TEXT, also_in TEXT, name_en TEXT, '
              'name_he TEXT, name_ru TEXT, logo_url TEXT, group_label TEXT',
        order='id'),
    'previous_parties': dict(
        slug_from='name_en',
        columns=['name_he', 'name_en', 'name_ru', 'logo_url', 'bloc', 'economic',
                 'security', 'religiosity', 'sector', 'tags'],
        types='seed_key TEXT PRIMARY KEY, name_he TEXT, name_en TEXT, name_ru TEXT, '
              'logo_url TEXT, bloc TEXT, economic INTEGER, security INTEGER, '
              'religiosity INTEGER, sector TEXT, tags TEXT[]',
        order='id'),
    'upcoming_parties': dict(
        slug_from='name_en',
        columns=['name_he', 'name_en', 'name_ru', 'logo_url', 'bloc', 'economic',
                 'security', 'religiosity', 'sector', 'tags', 'families', 'family_evidence'],
        types='seed_key TEXT PRIMARY KEY, name_he TEXT, name_en TEXT, name_ru TEXT, '
              'logo_url TEXT, bloc TEXT, economic INTEGER, security INTEGER, '
              'religiosity INTEGER, sector TEXT, tags TEXT[], families TEXT[], '
              'family_evidence TEXT',
        order='id'),
}


def slug(value):
    """ASCII kebab-case identity. Latin-transliterable names only; parties use name_en."""
    text = unicodedata.normalize('NFKD', value or '')
    text = text.encode('ascii', 'ignore').decode('ascii').lower()
    text = re.sub(r'[^a-z0-9]+', '-', text).strip('-')
    return text


def lit(value):
    if value is None:
        return 'NULL'
    if isinstance(value, bool):
        return 'TRUE' if value else 'FALSE'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        if not value:
            return "'{}'"
        inner = ', '.join("'{}'".format(v.replace("'", "''")) for v in value)
        return 'ARRAY[{}]::text[]'.format(inner)
    return "'{}'".format(str(value).replace("'", "''"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dsn', required=True)
    ap.add_argument('--table', required=True, choices=sorted(SPECS))
    args = ap.parse_args()
    spec = SPECS[args.table]

    with psycopg2.connect(args.dsn) as conn, conn.cursor() as cur:
        if args.table == 'clubs':
            cur.execute(
                'SELECT c.name_en, l.name_en, d.name_en, {} FROM clubs c '
                'JOIN leagues l ON l.id = c.league_id '
                'LEFT JOIN leagues d ON d.id = c.domestic_league_id '
                'ORDER BY l.sort_order, c.name_en'.format(
                    ', '.join('c.' + c for c in spec['columns'])))
            rows = [(slug(r[0]), slug(r[1]), slug(r[2]) if r[2] else None) + tuple(r[3:])
                    for r in cur.fetchall()]
        else:
            cols = spec['columns']
            cur.execute('SELECT {} FROM {} ORDER BY {}'.format(
                ', '.join(cols), args.table, spec['order']))
            slug_at = cols.index(spec['slug_from'])
            rows = [(slug(r[slug_at]),) + tuple(r) for r in cur.fetchall()]

    keys = [r[0] for r in rows]
    dupes = sorted({k for k in keys if keys.count(k) > 1})
    # A duplicate key is silent under the new scheme and must fail here. With one statement
    # per row the IS NULL guard made it "first in file order wins"; a VALUES block JOINS, so
    # a repeated key lets Postgres match arbitrarily -- same SQL, non-deterministic row.
    assert not dupes, 'duplicate seed_key: {}'.format(dupes)
    assert all(keys), 'empty seed_key generated -- a source name was NULL or non-Latin'

    print('CREATE TEMP TABLE seed_{} ({}) ON COMMIT DROP;'.format(args.table, spec['types']))
    print('INSERT INTO seed_{} VALUES'.format(args.table))
    for i, row in enumerate(rows):
        end = ';' if i == len(rows) - 1 else ','
        print('    ({}){}'.format(', '.join(lit(v) for v in row), end))


if __name__ == '__main__':
    main()
