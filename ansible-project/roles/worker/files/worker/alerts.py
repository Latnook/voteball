MILESTONES = [100, 500, 1000, 2500, 5000, 10000]


def milestones_crossed(previous_total, current_total):
    return [m for m in MILESTONES if previous_total < m <= current_total]


def check_and_notify(conn, sns_client, topic_arn):
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM votes')
    current_total = cur.fetchone()[0]

    cur.execute('SELECT last_seen_total FROM alert_state WHERE id = 1')
    previous_total = cur.fetchone()[0]

    for milestone in milestones_crossed(previous_total, current_total):
        sns_client.publish(
            TopicArn=topic_arn,
            Subject='Voteball milestone reached',
            Message=f'Voteball has reached {milestone} votes! Current total: {current_total}.'
        )

    if current_total != previous_total:
        cur.execute('UPDATE alert_state SET last_seen_total = %s WHERE id = 1', (current_total,))
        conn.commit()
    cur.close()
