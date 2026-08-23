# DIGEST-PINNED (2026-08-23, Task 3 review finding T3-2 "harden base-image reproducibility"). The tag
# stays for readability; the digest is what actually pins. A moving tag meant this Dockerfile built a
# different image every week, so the git-SHA tag on the result described the SOURCE precisely and the
# BASE not at all.
#
# The trade this makes, deliberately: a frozen base stops receiving upstream CVE fixes, so the Trivy
# gate will eventually start failing builds on it. That is the intended behaviour -- it converts
# "quietly running a base nobody has looked at in four months" into a build that stops and asks. Do
# not respond by unpinning. Run ./scripts/refresh-base-digests.sh, which re-resolves every base in
# this repo, and commit the result; the policy and cadence are in docs/security.md.
FROM python:3.12-slim@sha256:2c941e860699f878900b0edc2403613c234d4b32eda3cc9fa7036991a2a63c4a
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
COPY worker.py db.py metrics.py rollups.py alerts.py snapshots.py heartbeat.py notifications.py ./
USER appuser
CMD ["python", "worker.py"]
