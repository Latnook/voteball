import os
import time
import boto3
import db
import rollups
import alerts

SNS_TOPIC = os.environ['SNS_TOPIC']
AWS_REGION = os.environ.get('AWS_REGION', 'il-central-1')

if __name__ == '__main__':
    sns = boto3.client('sns', region_name=AWS_REGION)
    print('Voteball worker started...')
    while True:
        conn = db.get_db()
        rollups.recompute(conn)
        alerts.check_and_notify(conn, sns, SNS_TOPIC)
        conn.close()
        print('Rollups recomputed, milestones checked.')
        time.sleep(30)
