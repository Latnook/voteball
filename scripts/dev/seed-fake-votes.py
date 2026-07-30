#!/usr/bin/env python3
"""seed-fake-votes.py -- LOCAL DEV TOOL ONLY.

Not referenced by any Dockerfile COPY line and not imported by any application code (see
services/backend/CLAUDE.md and services/worker/CLAUDE.md on why backend/worker never share code --
this script is a third, standalone thing, not a fourth member of that split).

Why this exists: the Traits tab (docs/design/2026-07-30-party-families-club-traits-design.md) hides
any club with fewer than LEAN_MIN_VOTES=10 upcoming-election votes. Production currently has
single-digit votes per club, so the tab renders nothing to look at. This script fabricates ballots
directly in a local database so the tab has real, over-represented data to check the family
assignments against, before any of this reaches master.

What it does:
  1. Connects to a database that must already have schema.sql and seed.sql applied (it does not run
     them -- see docs/deploy.md / services/backend/CLAUDE.md for that).
  2. Inserts fake ballots (votes / vote_clubs / vote_leagues / vote_upcoming_parties), following the
     exact shape of queries.insert_vote() in services/backend/queries.py. A handful of named clubs
     are deliberately skewed toward specific upcoming parties (see SKEW_MAP below) so the Traits tab
     shows real over-representation instead of noise.
  3. Runs the worker's own rollups.recompute() against the same connection, because the app never
     reads votes/vote_clubs/... directly -- only the worker-computed rollup_* tables. Raw inserts
     with no recompute are invisible to the app.

Usage:
  python3 scripts/dev/seed-fake-votes.py                     # 400 votes into the local test container
  python3 scripts/dev/seed-fake-votes.py --votes 800
  python3 scripts/dev/seed-fake-votes.py --db-url postgresql://postgres:test@localhost:5432/revcheck

Safety: refuses to run against anything that isn't localhost/127.0.0.1/::1 unless --allow-remote (or
env VOTEBALL_SEED_FAKE_VOTES_ALLOW_REMOTE=1) is given, and refuses unconditionally -- no override --
against a host that looks like AWS RDS, since this repo runs a single environment with no dev/prod
split (root CLAUDE.md): the only RDS instance that exists IS production.
"""

import argparse
import importlib.util
import os
import random
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse

import psycopg2

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DB_URL = 'postgresql://postgres:test@localhost:5432/postgres'
LOCAL_HOSTNAMES = {'localhost', '127.0.0.1', '::1'}

# Which parties each skewed club leans towards, keyed by the party's name_he (matching seed.sql), and
# the family values that lean is expected to surface (per services/backend/seed.sql's upcoming_parties
# families UPDATE) -- printed so the rendered Traits tab can be checked against intent (brief Step 3).
# Israeli Premier League clubs, chosen only for a real seeded name to skew, not for any real-world
# claim about their fanbases.
SKEW_MAP = {
    'Beitar Jerusalem': {
        'parties_he': ['ש"ס', 'יהדות התורה'],
        'expected_families': ['welfare-state', 'sectoral-budgeting'],
    },
    'Maccabi Tel Aviv': {
        'parties_he': ['ישר', 'ביחד'],
        'expected_families': ['universal-conscription', 'constitutional-reform'],
    },
    'Hapoel Petah Tikva': {
        'parties_he': ['הציונות הדתית', 'עוצמה יהודית'],
        'expected_families': ['judicial-restraint'],
    },
}

# Out of --votes total, how many are reserved to each skewed club so it reliably clears
# LEAN_MIN_VOTES=10 (analytics.js) regardless of what the random background noise happens to land on.
VOTES_PER_SKEWED_CLUB = 40

SKEW_PARTY_HIT_RATE = 0.75   # chance a skewed-club ballot's upcoming picks include a target party
CONSIDERING_RATE = 0.9        # noise ballots: chance of 'considering' (vs 'undecided') -- skewed-club
                               # ballots are always 'considering', or they'd never reach rollup_upcoming
VOTED_PREVIOUS_RATE = 0.7


def _looks_like_production(hostname):
    hostname = (hostname or '').lower()
    return 'rds.amazonaws.com' in hostname or hostname.endswith('.amazonaws.com')


def _check_target_is_safe(db_url, allow_remote):
    parsed = urlparse(db_url)
    hostname = parsed.hostname or ''

    if _looks_like_production(hostname):
        sys.exit(
            f'Refusing to run: "{hostname}" looks like an AWS RDS endpoint. This repo runs a single '
            'environment with no dev/prod split (see root CLAUDE.md) -- the only RDS instance that '
            'exists is production. This check has no override; point --db-url at a local database.'
        )

    if hostname.lower() not in LOCAL_HOSTNAMES and not allow_remote:
        sys.exit(
            f'Refusing to run: "{hostname}" is not localhost. This is a dev-only fake-data generator; '
            'if you really mean to target a non-local database, pass --allow-remote or set '
            'VOTEBALL_SEED_FAKE_VOTES_ALLOW_REMOTE=1.'
        )


def _load_rollups_module():
    """Loads services/worker/rollups.py by file path (not via sys.path) so this stays a standalone
    dev tool with no import dependency on either service package -- see the module docstring."""
    rollups_path = REPO_ROOT / 'services' / 'worker' / 'rollups.py'
    if not rollups_path.exists():
        sys.exit(f'Could not find {rollups_path} -- is the repo layout as expected?')
    spec = importlib.util.spec_from_file_location('voteball_dev_rollups', rollups_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fetch_clubs(cur):
    cur.execute('SELECT id, league_id, domestic_league_id, name_en, name_he FROM clubs')
    return [
        {'id': r[0], 'league_id': r[1], 'domestic_league_id': r[2], 'name_en': r[3], 'name_he': r[4]}
        for r in cur.fetchall()
    ]


def fetch_leagues(cur):
    cur.execute('SELECT id, name_en FROM leagues')
    return {r[0]: r[1] for r in cur.fetchall()}


def fetch_upcoming_parties(cur):
    cur.execute('SELECT id, name_he, name_en FROM upcoming_parties')
    return [{'id': r[0], 'name_he': r[1], 'name_en': r[2]} for r in cur.fetchall()]


def fetch_previous_party_ids(cur):
    cur.execute('SELECT id FROM previous_parties')
    return [r[0] for r in cur.fetchall()]


def build_skew_map(clubs, upcoming_parties):
    """Resolves SKEW_MAP's club/party names against what's actually in the seeded database. Missing
    clubs or parties are dropped with a warning rather than aborting -- a partial demo is still a demo,
    and a hard failure here would block Step 1 from being testable against a seed.sql that has since
    added or renamed a party."""
    clubs_by_name = {c['name_en']: c for c in clubs}
    clubs_by_name.update({c['name_he']: c for c in clubs if c['name_he']})
    parties_by_name_he = {p['name_he']: p for p in upcoming_parties}

    resolved = {}
    for club_name, spec in SKEW_MAP.items():
        club = clubs_by_name.get(club_name)
        if club is None:
            print(f'WARNING: skew club "{club_name}" not found in clubs table -- skipping it.')
            continue
        party_ids = []
        party_names = []
        for party_name_he in spec['parties_he']:
            party = parties_by_name_he.get(party_name_he)
            if party is None:
                print(f'WARNING: skew party "{party_name_he}" not found in upcoming_parties -- skipping it.')
                continue
            party_ids.append(party['id'])
            party_names.append(party_name_he)
        if not party_ids:
            print(f'WARNING: no resolvable skew parties for club "{club_name}" -- dropping it from the skew map.')
            continue
        resolved[club['id']] = {
            'club_name': club_name,
            'club': club,
            'party_ids': party_ids,
            'party_names_he': party_names,
            'expected_families': spec['expected_families'],
        }
    return resolved


def print_skew_map(resolved_skew):
    print('\nSkew map in use:')
    if not resolved_skew:
        print('  (none -- no configured skew club/party matched the seeded database)')
        return
    for entry in resolved_skew.values():
        parties = ' + '.join(entry['party_names_he'])
        families = ', '.join(entry['expected_families'])
        print(f"  {entry['club_name']:<20} -> {parties}   (expected families: {families})")
    print()


def make_team_picks(club, all_clubs, rng):
    """Builds 1-3 team_picks entries for a single ballot, anchored on `club` (a specific pick under
    its own league_id), following queries.insert_vote's {'league_id', 'club_id'} shape. Occasionally
    adds a second, unrelated pick under a different league for realism -- never two picks in the same
    league, matching how app.py's _validate_team_picks treats mixed/duplicate picks in one league."""
    picks = [{'league_id': club['league_id'], 'club_id': club['id']}]
    used_leagues = {club['league_id']}

    if rng.random() < 0.25:
        candidates = [c for c in all_clubs if c['league_id'] not in used_leagues]
        if candidates:
            extra = rng.choice(candidates)
            if rng.random() < 0.5:
                picks.append({'league_id': extra['league_id'], 'club_id': extra['id']})
            else:
                picks.append({'league_id': extra['league_id'], 'club_id': None})
            used_leagues.add(extra['league_id'])

    return picks


def make_random_team_picks(all_clubs, rng):
    """Same shape as make_team_picks, but for background-noise ballots with no anchor club."""
    club = rng.choice(all_clubs)
    return make_team_picks(club, all_clubs, rng)


def make_upcoming_party_ids(rng, upcoming_parties, skew_party_ids=None):
    if skew_party_ids and rng.random() < SKEW_PARTY_HIT_RATE:
        picks = [rng.choice(skew_party_ids)]
        if rng.random() < 0.3:
            other = rng.choice(upcoming_parties)['id']
            if other != picks[0]:
                picks.append(other)
        return picks

    n = rng.choice([1, 1, 2, 3])
    return list({p['id'] for p in rng.sample(upcoming_parties, k=min(n, len(upcoming_parties)))})


def insert_vote(cur, team_picks, previous_vote_status, previous_party_id,
                 upcoming_vote_status, upcoming_party_ids, cookie_token):
    """Mirrors queries.insert_vote in services/backend/queries.py (same tables, same shapes), minus
    the NOTIFY/rollback wrapping -- this script commits once at the end of the whole batch, and the
    worker isn't running to LISTEN anyway; the explicit recompute() call at the end of main() is what
    actually populates the rollup tables the app reads."""
    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES (%s, %s, %s, %s) RETURNING id''',
        (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
    )
    vote_id = cur.fetchone()[0]

    for pick in team_picks:
        if pick['club_id'] is None:
            cur.execute(
                'INSERT INTO vote_leagues (vote_id, league_id) VALUES (%s, %s)',
                (vote_id, pick['league_id'])
            )
        else:
            cur.execute(
                'INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)',
                (vote_id, pick['club_id'], pick['league_id'])
            )

    for party_id in upcoming_party_ids:
        cur.execute(
            'INSERT INTO vote_upcoming_parties (vote_id, upcoming_party_id) VALUES (%s, %s)',
            (vote_id, party_id)
        )

    return vote_id


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--votes', type=int, default=400, help='total fake ballots to insert (default 400)')
    parser.add_argument('--db-url', default=DEFAULT_DB_URL,
                         help=f'target database (default: {DEFAULT_DB_URL}, the local test container)')
    parser.add_argument('--allow-remote', action='store_true',
                         help='permit a non-localhost --db-url (also settable via '
                              'VOTEBALL_SEED_FAKE_VOTES_ALLOW_REMOTE=1)')
    parser.add_argument('--seed', type=int, default=None, help='random seed, for reproducible runs')
    args = parser.parse_args()

    allow_remote = args.allow_remote or os.environ.get('VOTEBALL_SEED_FAKE_VOTES_ALLOW_REMOTE') == '1'
    _check_target_is_safe(args.db_url, allow_remote)

    rng = random.Random(args.seed)

    conn = psycopg2.connect(args.db_url)
    try:
        cur = conn.cursor()

        clubs = fetch_clubs(cur)
        leagues = fetch_leagues(cur)
        upcoming_parties = fetch_upcoming_parties(cur)
        previous_party_ids = fetch_previous_party_ids(cur)

        if not clubs or not leagues or not upcoming_parties:
            sys.exit(
                'Target database has no clubs/leagues/upcoming_parties. Load schema.sql then seed.sql '
                'first (see services/backend/CLAUDE.md) -- this script only inserts votes, it does not '
                'seed reference data.'
            )

        resolved_skew = build_skew_map(clubs, upcoming_parties)
        print_skew_map(resolved_skew)

        inserted = 0

        # Reserved batch: guarantee each skewed club clears LEAN_MIN_VOTES=10 regardless of noise.
        for entry in resolved_skew.values():
            for _ in range(VOTES_PER_SKEWED_CLUB):
                team_picks = make_team_picks(entry['club'], clubs, rng)
                upcoming_party_ids = make_upcoming_party_ids(rng, upcoming_parties, entry['party_ids'])
                previous_vote_status = 'voted' if rng.random() < VOTED_PREVIOUS_RATE else 'did_not_vote'
                previous_party_id = rng.choice(previous_party_ids) if previous_vote_status == 'voted' and previous_party_ids else None
                insert_vote(
                    cur, team_picks, previous_vote_status, previous_party_id,
                    'considering', upcoming_party_ids, uuid.uuid4().hex,
                )
                inserted += 1

        # Background noise, filling the rest of --votes.
        remaining = max(args.votes - inserted, 0)
        for _ in range(remaining):
            team_picks = make_random_team_picks(clubs, rng)
            considering = rng.random() < CONSIDERING_RATE
            upcoming_vote_status = 'considering' if considering else 'undecided'
            upcoming_party_ids = make_upcoming_party_ids(rng, upcoming_parties) if considering else []
            previous_vote_status = 'voted' if rng.random() < VOTED_PREVIOUS_RATE else 'did_not_vote'
            previous_party_id = rng.choice(previous_party_ids) if previous_vote_status == 'voted' and previous_party_ids else None
            insert_vote(
                cur, team_picks, previous_vote_status, previous_party_id,
                upcoming_vote_status, upcoming_party_ids, uuid.uuid4().hex,
            )
            inserted += 1

        conn.commit()
        print(f'Inserted {inserted} fake ballots ({VOTES_PER_SKEWED_CLUB} reserved per skewed club, '
              f'{len(resolved_skew)} skewed clubs).')

        print('Recomputing rollup tables via the worker\'s rollups.recompute()...')
        rollups = _load_rollups_module()
        rollups.recompute(conn)
        print('Recompute done.')

        cur.execute(
            'SELECT club_id, SUM(vote_count) FROM rollup_upcoming WHERE club_id IS NOT NULL '
            'GROUP BY club_id'
        )
        totals_by_club = dict(cur.fetchall())
        print('\nrollup_upcoming totals for skewed clubs (>=10 required to clear LEAN_MIN_VOTES):')
        for entry in resolved_skew.values():
            total = totals_by_club.get(entry['club']['id'], 0)
            status = 'OK' if total >= 10 else 'BELOW THRESHOLD'
            print(f"  {entry['club_name']:<20} {total:>4} votes  [{status}]")

        cur.close()
    finally:
        conn.close()


if __name__ == '__main__':
    main()
