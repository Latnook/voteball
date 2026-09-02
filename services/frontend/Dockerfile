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
FROM nginxinc/nginx-unprivileged:alpine@sha256:c3fed6436b61d2bf2201ec032c35c000871f7ed062dea5d586bc6bf4d0fdd140

# CVE-2026-14456 (HIGH): openssl DoS via unbounded memory growth in the QUIC server.
# libcrypto3/libssl3 3.5.7-r0 -> fixed in 3.5.8-r0.
#
# CVE-2026-66046 + CVE-2026-76641 (both HIGH): expat DoS. libexpat 2.8.2-r0 -> fixed in 2.8.4-r0.
# Added 2026-09-02 after these two turned the Trivy gate red on a commit that touched nothing but a
# logo -- the base image aged into a CVE, which is the normal way this gate fires. Same remedy and
# same reasoning as the openssl pair above: Alpine v3.24/main already carries 2.8.4-r0, verified
# with `apk policy libexpat` against the pinned digest, so patch here rather than chase the tag.
#
# THE PRESCRIBED REMEDY ABOVE DOES NOT FIX THIS ONE, and that is why this block exists rather than a
# digest bump. ./scripts/refresh-base-digests.sh re-resolves the tag, and measured 2026-08-27 the tag
# HAS moved (c3fed643 -> 901e944d) while still shipping 3.5.7-r0: nginxinc rebuilt without picking up
# the Alpine security update. So refreshing the pin gets a newer base that is equally vulnerable, and
# the Trivy gate stays red. Alpine v3.24/main already carries 3.5.8-r0, so patch it here instead.
#
# REMOVE THIS BLOCK once nginxinc/nginx-unprivileged:alpine ships libssl3 >= 3.5.8-r0 AND
# libexpat >= 2.8.4-r0 -- BOTH, or removing it re-opens whichever half the base has not caught up on:
#   docker run --rm --user 0 --entrypoint sh nginxinc/nginx-unprivileged:alpine -c 'apk info -v | grep -E "libssl3|libexpat"'
# Leaving it in place after that costs a layer and silently pins nothing; it is not load-bearing then.
USER 0
RUN apk upgrade --no-cache libssl3 libcrypto3 libexpat
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
