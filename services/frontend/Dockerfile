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
COPY index.html results.html admin.html vote.js results.js admin.js analytics.js style.css i18n.js theme.js logos.js /usr/share/nginx/html/
# SEO assets. robots.txt and sitemap.xml carry a literal __SITE_URL__ that nginx rewrites from the
# request Host (see nginx.conf); og-card.png is the 1200x630 link-preview image.
COPY robots.txt sitemap.xml og-card.png /usr/share/nginx/html/
COPY fonts/ /usr/share/nginx/html/fonts/
# Self-hosted crests for clubs with no Wikimedia artwork. Directory copy, unlike the file list
# above: these are data, not code, and adding one should not require editing the Dockerfile.
COPY logos/ /usr/share/nginx/html/logos/
COPY nginx.conf /etc/nginx/conf.d/default.conf
