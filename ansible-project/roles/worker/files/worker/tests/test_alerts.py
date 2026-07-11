import alerts


def test_milestones_crossed_single():
    assert alerts.milestones_crossed(90, 105) == [100]


def test_milestones_crossed_multiple_in_one_jump():
    assert alerts.milestones_crossed(50, 600) == [100, 500]


def test_milestones_crossed_none():
    assert alerts.milestones_crossed(100, 150) == []


def test_milestones_crossed_exact_boundary():
    assert alerts.milestones_crossed(99, 100) == [100]


class FakeSNSClient:
    def __init__(self):
        self.published = []

    def publish(self, TopicArn, Subject, Message):
        self.published.append((TopicArn, Subject, Message))


def test_check_and_notify_publishes_and_updates_state(conn):
    import alerts
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('EPL') RETURNING id")
    league_id = cur.fetchone()[0]
    for i in range(100):
        cur.execute(
            '''INSERT INTO votes (league_id, previous_vote_status, upcoming_vote_status, cookie_token)
               VALUES (%s, 'did_not_vote', 'undecided', %s)''',
            (league_id, f'token-{i}')
        )
    conn.commit()
    cur.close()

    fake_sns = FakeSNSClient()
    alerts.check_and_notify(conn, fake_sns, 'arn:aws:sns:il-central-1:000000000000:test')

    assert len(fake_sns.published) == 1
    assert '100 votes' in fake_sns.published[0][2]

    cur = conn.cursor()
    cur.execute('SELECT last_seen_total FROM alert_state WHERE id = 1')
    assert cur.fetchone()[0] == 100
    cur.close()

    # Running again with no new votes must not re-notify
    alerts.check_and_notify(conn, fake_sns, 'arn:aws:sns:il-central-1:000000000000:test')
    assert len(fake_sns.published) == 1
