# nginx-unprivileged: runs as uid 101 on :8080, designed for readOnlyRootFilesystem. Replaces the
# stock nginx:alpine (root, :80/:443) now that the ALB terminates TLS outside the pod (EKS migration).
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
FROM nginxinc/nginx-unprivileged:alpine@sha256:b9241c6e7b8e9a862f129d8d4199ab64b10390949a78bdd5603379b32c844083

# CVE-2026-4775 (HIGH): libtiff code execution or DoS via a signed integer overflow.
# tiff 4.7.1-r0 -> fixed in 4.7.2-r0. Added 2026-10-11, when it turned the Trivy gate red on the
# first build after a rebuild (application-ci #1) with no change to this image.
#
# WHY A PATCH HERE AND NOT A DIGEST BUMP: ./scripts/refresh-base-digests.sh is the prescribed remedy
# and does not fix this one. Measured 2026-10-11, the tag still resolves to the digest pinned above
# and still ships 4.7.1-r0, while Alpine v3.24/community already carries 4.7.2-r0 (`apk policy
# tiff`). nginxinc has not rebuilt on the Alpine fix, so there is no newer base to move to.
#
# This line upgraded libssl3, libcrypto3, libexpat and libuuid until 2026-10-11 (openssl
# CVE-2026-14456, expat CVE-2026-66046/-76641, seven util-linux CVEs). The pinned base now ships all
# of them at or past the fixed versions (3.5.9-r0, 2.8.5-r0, 2.42.3-r1, measured the same day), so
# they were dropped as the old note here instructed; git history has the per-CVE reasoning.
#
# REMOVE THIS BLOCK once nginxinc/nginx-unprivileged:alpine ships tiff >= 4.7.2-r0:
#   docker run --rm --user 0 --entrypoint sh nginxinc/nginx-unprivileged:alpine -c 'apk info -v | grep -E "^tiff-"'
# Leaving it in place after that costs a layer and silently pins nothing; it is not load-bearing then.
USER 0
RUN apk upgrade --no-cache tiff
USER 101
COPY index.html results.html admin.html vote.js results.js admin.js analytics.js style.css i18n.js theme.js logos.js /usr/share/nginx/html/
# SEO assets. robots.txt and sitemap.xml carry a literal __SITE_URL__ that nginx rewrites from the
# request Host (see nginx.conf); og-card.png is the 1200x630 link-preview image.
COPY robots.txt sitemap.xml og-card.png /usr/share/nginx/html/
COPY fonts/ /usr/share/nginx/html/fonts/
# Self-hosted crests for clubs with no Wikimedia artwork. Directory copy, unlike the file list
# above: these are data, not code, and adding one should not require editing the Dockerfile.
COPY logos/ /usr/share/nginx/html/logos/
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Under snippets/, NOT conf.d/: the image's main nginx.conf globs conf.d/*.conf into the http
# context, which would define these headers a second time one level up.
COPY security-headers.conf /etc/nginx/snippets/security-headers.conf
