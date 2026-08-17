FROM python:3.12-slim
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
COPY app.py db.py queries.py gunicorn.conf.py migrate.py schema.sql seed.sql ./
USER appuser
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]
