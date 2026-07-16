FROM nginx:alpine
COPY index.html results.html admin.html vote.js results.js admin.js analytics.js style.css i18n.js theme.js logos.js /usr/share/nginx/html/
COPY fonts/ /usr/share/nginx/html/fonts/
COPY nginx.conf /etc/nginx/conf.d/default.conf
