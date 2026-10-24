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
FROM nginxinc/nginx-unprivileged:alpine@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e

# CVE-2026-111497 (HIGH): out-of-bounds write in the Brotli decoder. brotli-libs 1.2.0-r1 -> fixed in
# 1.2.1-r0. Added 2026-10-24, when it turned the Trivy gate red with no change to this image.
#
# WHY A PATCH HERE AND NOT A DIGEST BUMP: ./scripts/refresh-base-digests.sh is the prescribed remedy
# and does not fix this one. Measured 2026-10-24, the tag still resolves to the digest pinned above
# and still ships 1.2.0-r1, while Alpine v3.24/main already carries 1.2.1-r0 (`apk policy
# brotli-libs`). nginxinc has not rebuilt on the Alpine fix, so there is no newer base to move to.
#
# REMOVE THIS BLOCK once nginxinc/nginx-unprivileged:alpine ships brotli-libs >= 1.2.1-r0:
#   docker run --rm --user 0 --entrypoint sh nginxinc/nginx-unprivileged:alpine -c 'apk info -v | grep -E "^brotli-"'
# Leaving it in place after that costs a layer and silently pins nothing; it is not load-bearing then.
USER 0
RUN apk upgrade --no-cache brotli-libs
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
