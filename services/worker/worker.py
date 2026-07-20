import os
import time

import boto3

import db
import rollups
import alerts
import snapshots
import heartbeat

SNS_TOPIC = os.environ['SNS_TOPIC']
AWS_REGION = os.environ.get('AWS_REGION', 'il-central-1')

# Optional S3 export. When S3_BUCKET is unset (the current k3s deployment), the worker makes NO S3
# calls at all -- this is what keeps the snapshot feature inert on the live site until EKS sets it.
S3_BUCKET = os.environ.get('S3_BUCKET')
S3_SNAPSHOT_PREFIX = os.environ.get('S3_SNAPSHOT_PREFIX', 'snapshots')


def run_iteration(sns, s3, snapshot_fingerprint):
    """Run one recompute/alert/snapshot cycle.

    Catches and logs any exception so a transient DB blip (failover, connection reset, etc.)
    doesn't crash the process -- Kubernetes would otherwise turn a brief hiccup into a
    crash-restart loop. Always closes the connection it opens, even on failure.

    Args:
        sns: boto3 SNS client for milestone alerts.
        s3: boto3 S3 client for results snapshots, or None to disable S3 export entirely.
        snapshot_fingerprint: the fingerprint returned by the previous iteration (None on the
            first). Threaded through the loop so snapshots.export_if_changed() can tell whether the
            national results actually changed -- kept in memory because the worker's write-only
            IRSA role can't read latest.json back to compare.

    Returns:
        The (possibly updated) snapshot fingerprint, to feed into the next iteration.
    """
    conn = None
    try:
        conn = db.get_db()
        rollups.recompute(conn)
        alerts.check_and_notify(conn, sns, SNS_TOPIC)
        if s3 is not None:
            snapshot_fingerprint = snapshots.export_if_changed(
                conn, s3, S3_BUCKET, S3_SNAPSHOT_PREFIX, snapshot_fingerprint
            )
        print('Rollups recomputed, milestones checked.')
    except Exception as e:
        print(f'Worker iteration failed, will retry next cycle: {e}')
    finally:
        if conn is not None:
            conn.close()
    return snapshot_fingerprint


if __name__ == '__main__':
    sns = boto3.client('sns', region_name=AWS_REGION)
    # Only build an S3 client if a bucket is configured; otherwise stay None and skip S3 work.
    s3 = boto3.client('s3', region_name=AWS_REGION) if S3_BUCKET else None
    print('Voteball worker started...')
    snapshot_fingerprint = None
    while True:
        snapshot_fingerprint = run_iteration(sns, s3, snapshot_fingerprint)
        # Touch the heartbeat every iteration, even after a caught error: liveness means "the loop
        # is spinning", not "the DB is up". A DB outage must not restart the worker; a wedged
        # process (which never reaches here) lets the file go stale and gets restarted.
        heartbeat.touch()
        time.sleep(30)
