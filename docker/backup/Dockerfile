# postgres-client (pg_dump) + AWS CLI, non-root. pg_dump major version must be >= the server's (17).
FROM postgres:17-alpine
RUN apk add --no-cache aws-cli
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh
USER 1000
ENTRYPOINT ["/usr/local/bin/backup.sh"]
