FROM python:3.12-slim
# Debian security updates, before anything else -- same reason as services/backend/Dockerfile, and it
# has to be repeated here because these are two independent build contexts with no shared base image.
# CI's Trivy gate blocks on CRITICAL,HIGH with --ignore-unfixed, so a base-package CVE fails every
# build as soon as Debian publishes a fix, with no change to this repo. See docs/security.md,
# "Base-image patching".
RUN apt-get update \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py db.py rollups.py alerts.py snapshots.py heartbeat.py notifications.py ./
USER appuser
CMD ["python", "worker.py"]
