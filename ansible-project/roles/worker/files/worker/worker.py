import os
import time
import boto3
import db
import rollups
import alerts

SNS_TOPIC = os.environ['SNS_TOPIC']
AWS_REGION = os.environ.get('AWS_REGION', 'il-central-1')


def run_iteration(sns):
    """Run one recompute/alert cycle.

    Catches and logs any exception so a transient DB blip (failover,
    connection reset, etc.) doesn't crash the process -- Kubernetes would
    otherwise turn a brief hiccup into a crash-restart loop. Always closes
    the connection it opens, even on failure.
    """
    conn = None
    try:
        conn = db.get_db()
        rollups.recompute(conn)
        alerts.check_and_notify(conn, sns, SNS_TOPIC)
        print('Rollups recomputed, milestones checked.')
    except Exception as e:
        print(f'Worker iteration failed, will retry next cycle: {e}')
    finally:
        if conn is not None:
            conn.close()


if __name__ == '__main__':
    sns = boto3.client('sns', region_name=AWS_REGION)
    print('Voteball worker started...')
    while True:
        run_iteration(sns)
        time.sleep(30)
