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
# Debian security updates, before anything else. The base image lags the security feed by design, and
# CI's Trivy gate is blocking on CRITICAL,HIGH with --ignore-unfixed -- which means a base-package CVE
# starts failing every build the moment Debian publishes a FIX for it, with no change to this repo.
# CVE-2026-53615 (util-linux) did exactly that on 2026-08-17, six days after a green build. Fixing it
# here is the fix at source; a .trivyignore would suppress a vulnerability that has an available fix.
# See docs/security.md, "Base-image patching".
#
# This does NOT change the Python version: the official image compiles Python into /usr/local rather
# than installing it from apt, so `apt-get upgrade` cannot move it.
RUN apt-get update \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py db.py metrics.py queries.py gunicorn.conf.py migrate.py schema.sql seed.sql ./
USER appuser
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]
