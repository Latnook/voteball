# postgres-client (pg_dump) + AWS CLI, non-root. pg_dump major version must be >= the server's (17).
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
FROM postgres:17-alpine@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73
# Unpinned deliberately -- see the hadolint --ignore DL3018 comment in Jenkinsfile-ci for why a
# pinned Alpine package version is a time bomb, not a reproducibility win, in this project.
# The apk upgrade is CVE-2026-14456 (HIGH, openssl DoS via unbounded memory growth in the QUIC
# server): this base ships libcrypto3/libssl3 3.5.7-r0 and Alpine v3.24/main has the fixed 3.5.8-r0.
# ./scripts/refresh-base-digests.sh does NOT fix it -- measured 2026-08-27 on the frontend's Alpine
# base, whose tag had moved while still shipping 3.5.7-r0. services/frontend/Dockerfile carries the
# same upgrade and the same removal condition; when upstream ships >= 3.5.8-r0, drop BOTH.
# Combined into ONE RUN with the gosu removal below, not because layer count matters here but
# because hadolint's DL3059 (consecutive RUN instructions) is info-level and hadolint's DEFAULT
# FAILURE THRESHOLD IS info -- so a second RUN fails the Lint stage outright. Learned on CI build #1,
# 2026-08-23: the local script suite was green because it does not run hadolint, and Lint runs before
# Tests, so the whole build died before a single test executed.
# The libexpat upgrade (CVE-2026-66046 + CVE-2026-76641, both HIGH, 2.8.3-r0 -> 2.8.4-r0) must come
# AFTER the aws-cli install, not alongside the openssl pair above: libexpat is NOT in this base at
# all -- aws-cli is what pulls it in -- so upgrading it first is a no-op on a package that does not
# exist yet, and the image still scans dirty. Found 2026-09-02 by scanning this image locally after
# the same two CVEs turned the frontend red; CI had never reached it, because Trivy scans the four
# images in one `set -e` shell and stops at the first failure, so a second image with the same CVE
# stays invisible until the first is fixed. Still ONE RUN, for the DL3059 reason above.
RUN apk upgrade --no-cache libssl3 libcrypto3 \
 && apk add --no-cache aws-cli \
 && apk upgrade --no-cache libexpat \
 && rm -f /usr/local/bin/gosu

# THE gosu REMOVAL ABOVE. It is the ONLY source of HIGH/CRITICAL findings in this image -- all 22 of them
# (measured 2026-08-23 with trivy --severity CRITICAL,HIGH --ignore-unfixed), every one a Go stdlib
# CVE statically linked into that single binary. Nothing else in the image scans dirty.
#
# It is also completely unused here. gosu exists so postgres:17-alpine's own docker-entrypoint.sh can
# start as root and drop to the postgres user; this image overrides ENTRYPOINT with backup.sh and
# runs as USER 1000 from the start, so that path is never taken. The container was carrying a
# privilege-dropping tool it has no privileges to drop.
#
# THIS IS WHY THE BACKUP IMAGE'S TRIVY SCAN IS NOW BLOCKING (Task 3 review T3-5 / Task 4 review P2).
# It was report-only on the grounds that the findings were inherited from a third-party base and
# outside this project's control. That was true of their ORIGIN and not of their PRESENCE: the
# offending binary was removable in one line. The review offered "build a controlled backup image,
# make scanning blocking, or maintain time-bound risk acceptances" -- this is the first, which makes
# the second free and the third unnecessary.
#
# If a future base drags in another unused Go binary, delete that too rather than reverting the
# scan to report-only.
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh
USER 1000
ENTRYPOINT ["/usr/local/bin/backup.sh"]
