# nginx-unprivileged: runs as uid 101 on :8080, designed for readOnlyRootFilesystem. Replaces the
# stock nginx:alpine (root, :80/:443) now that the ALB terminates TLS outside the pod (EKS migration).
FROM nginxinc/nginx-unprivileged:alpine
COPY index.html results.html admin.html vote.js results.js admin.js analytics.js style.css i18n.js theme.js logos.js /usr/share/nginx/html/
COPY fonts/ /usr/share/nginx/html/fonts/
# Self-hosted crests for clubs with no Wikimedia artwork. Directory copy, unlike the file list
# above: these are data, not code, and adding one should not require editing the Dockerfile.
COPY logos/ /usr/share/nginx/html/logos/
COPY nginx.conf /etc/nginx/conf.d/default.conf
