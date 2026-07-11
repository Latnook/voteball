import queries


def test_get_options_returns_seeded_leagues(conn):
    options = queries.get_options(conn)
    league_names = {l['name'] for l in options['leagues']}
    assert 'EPL' in league_names
    assert 'Israeli Premier League' in league_names

    club_names = {c['name'] for c in options['clubs']}
    assert 'Liverpool' in club_names

    epl = next(l for l in options['leagues'] if l['name'] == 'EPL')
    epl_clubs = [c for c in options['clubs'] if c['league_id'] == epl['id']]
    assert len(epl_clubs) == 20

    assert options['previous_parties'] == []
    assert options['upcoming_parties'] == []
