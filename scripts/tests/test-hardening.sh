#!/usr/bin/env bash
# Browser/transport/runtime hardening added 2026-09-09, pinned so it cannot quietly rot:
#
#   1. The frontend's security headers (HSTS, CSP, nosniff, X-Frame-Options, Referrer-Policy,
#      Permissions-Policy, COOP) -- and, more importantly, that they reach EVERY response. nginx's
#      add_header is not inherited into a block that has its own add_header, so a new `location`
#      with an add_header of its own silently drops all of them for that path. The check here is
#      structural: every location that declares add_header must include the snippet.
#   2. The CSP is strict (no 'unsafe-inline'), which is only true while the pages contain no inline
#      <style>, style="", on*="" or inline <script>. A browser enforces that silently -- the page
#      just loses its styling or its click handlers, and only the console says why.
#   3. The ALB TLS policy is set, is TLS 1.2+ only, and is IDENTICAL on every Ingress in the shared
#      ALB group: ssl-policy is an Exclusive annotation and a mismatch fails the whole group.
#   4. Every container in charts/voteball carries seccompProfile RuntimeDefault -- counted against
#      allowPrivilegeEscalation: false so a new container without it is caught.
#
# Offline: grep/awk over repo text only. No python3, no helm, no docker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
pass=0; fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "ok: $*"; pass=$((pass+1)); }

SNIP=services/frontend/security-headers.conf
CONF=services/frontend/nginx.conf

# ---- 1. the snippet ------------------------------------------------------------------------------
[ -f "$SNIP" ] || fail "$SNIP is missing"
for h in Strict-Transport-Security Content-Security-Policy X-Content-Type-Options X-Frame-Options Referrer-Policy Permissions-Policy Cross-Origin-Opener-Policy; do
  grep -qE "^add_header $h " "$SNIP" || fail "$SNIP no longer sets $h"
done
ok "all seven headers are declared"
n_hdr=$(grep -cE '^add_header ' "$SNIP"); n_always=$(grep -cE '^add_header .* always;$' "$SNIP")
[ "$n_hdr" -eq "$n_always" ] || fail "every add_header must end with 'always;' (headers on error responses too): $n_always of $n_hdr do"
ok "every header uses 'always'"
grep -qE "^add_header Strict-Transport-Security \"max-age=[0-9]{8,}" "$SNIP" || fail "HSTS max-age must be at least 8 digits (~1 year)"
grep -E '^add_header Content-Security-Policy' "$SNIP" | grep -qE "unsafe-(inline|eval)" && fail "CSP must not carry 'unsafe-inline' or 'unsafe-eval'"
grep -E '^add_header Content-Security-Policy' "$SNIP" | grep -qE "frame-ancestors 'none'" || fail "CSP must set frame-ancestors 'none'"
grep -E '^add_header Content-Security-Policy' "$SNIP" | grep -qE "object-src 'none'" || fail "CSP must set object-src 'none'"
ok "HSTS >= 1y; CSP strict, frames and plugins denied"

# ---- 2. the snippet reaches every response ------------------------------------------------------
grep -qE '^\s*server_tokens off;' "$CONF" || fail "nginx.conf must set server_tokens off"
# Server-level include: must appear inside the FIRST server block, before its first location.
awk '/^server \{/{s++} s==1 && /^\s*location /{exit} s==1 && /include .*security-headers\.conf;/{found=1} END{exit !found}' "$CONF" \
  || fail "nginx.conf must include security-headers.conf at server level (before the first location)"
ok "snippet included at server level"
# Every location block that has its own add_header must ALSO include the snippet, or inheritance
# drops every header for that path. Walk each location by brace depth.
awk '
  /^\s*location /{inloc=1; depth=0; has_hdr=0; has_inc=0; name=$0}
  inloc {
    n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m
    if ($0 ~ /add_header/) has_hdr=1
    if ($0 ~ /include .*security-headers\.conf;/) has_inc=1
    if (depth<=0 && ($0 ~ /\}/)) { if (has_hdr && !has_inc) { print "  location with add_header but no snippet include: " name; bad=1 } inloc=0 }
  }
  END{exit bad}' "$CONF" || fail "a location block declares add_header without re-including security-headers.conf (nginx does not inherit add_header)"
ok "every location with its own add_header re-includes the snippet"
grep -qE '^COPY .*security-headers\.conf .*/etc/nginx/snippets/' services/frontend/Dockerfile \
  || fail "frontend Dockerfile must COPY security-headers.conf into /etc/nginx/snippets/ (a file on disk but not in COPY is absent from the image with no build error)"
grep -qE '^COPY .*security-headers\.conf .*/etc/nginx/conf\.d/' services/frontend/Dockerfile \
  && fail "security-headers.conf must NOT land in conf.d/ -- the main nginx.conf globs conf.d/*.conf into the http context"
ok "Dockerfile ships the snippet under snippets/, not conf.d/"

# ---- 3. the pages honour the strict CSP ------------------------------------------------------------
html=$(ls services/frontend/*.html); js=$(ls services/frontend/*.js)
grep -nE '<style[ >]' $html && fail "inline <style> found -- blocked by style-src 'self' (move it to style.css)"
grep -nE ' style="' $html && fail "inline style=\"\" attribute found -- blocked by style-src 'self' (use a class or the hidden attribute)"
grep -nE ' on[a-z]+="' $html && fail "inline on*=\"\" handler found -- blocked by script-src 'self'"
grep -nE '<script>' $html && fail "inline <script> found -- blocked by script-src 'self' (only src= and type=application/ld+json are allowed)"
grep -nE "setAttribute\(['\"]style['\"]|\.cssText\s*=|document\.write\(|\beval\(|new Function\(" $js && fail "CSP-blocked JS pattern found (setAttribute('style'), cssText, document.write, eval)"
ok "no inline style/script/handler in HTML, no CSP-blocked JS patterns"

# ---- 4. ALB TLS policy: set, modern, and identical across the shared group ---------------------------
mapfile -t ING < <(grep -lE 'listen-ports:.*HTTPS' charts/*/templates/*.yaml | sort)
[ "${#ING[@]}" -ge 3 ] || fail "expected at least 3 HTTPS Ingress templates, found ${#ING[@]}"
vals=()
for f in "${ING[@]}"; do
  v=$(grep -E '^\s*alb\.ingress\.kubernetes\.io/ssl-policy:' "$f" | sed -E 's/.*ssl-policy:\s*//; s/\s+$//')
  [ -n "$v" ] || fail "$f has an HTTPS listener but no ssl-policy (controller default is ELBSecurityPolicy-2016-08 = TLS 1.0/1.1 accepted)"
  [ "$(printf '%s\n' "$v" | wc -l)" -eq 1 ] || fail "$f sets ssl-policy more than once"
  vals+=("$v")
done
[ "$(printf '%s\n' "${vals[@]}" | sort -u | wc -l)" -eq 1 ] \
  || fail "ssl-policy differs across the ALB group (Exclusive annotation -> whole group errors): $(printf '%s ' "${vals[@]}")"
case "${vals[0]}" in
  ELBSecurityPolicy-TLS13-*) : ;;
  *) fail "ssl-policy '${vals[0]}' is not a TLS13-* policy" ;;
esac
ok "ssl-policy ${vals[0]} on all ${#ING[@]} HTTPS Ingresses, identical"

# ---- 5. seccomp on every container in charts/voteball ---------------------------------------------
n_ape=$(grep -rhE '^\s*allowPrivilegeEscalation: false' charts/voteball/templates | wc -l)
n_sec=$(grep -rhE '^\s*seccompProfile: \{ type: RuntimeDefault \}' charts/voteball/templates | wc -l)
[ "$n_ape" -ge 7 ] || fail "expected >= 7 container securityContexts in charts/voteball, found $n_ape"
[ "$n_sec" -eq "$n_ape" ] || fail "seccompProfile RuntimeDefault on $n_sec containers but allowPrivilegeEscalation: false on $n_ape -- a container is missing seccomp"
ok "seccompProfile RuntimeDefault on all $n_sec containers"

# ---- 6. both services pin the same pytest ------------------------------------------------------------
pb=$(grep -oE '^pytest==[0-9.]+' services/backend/requirements-dev.txt); pw=$(grep -oE '^pytest==[0-9.]+' services/worker/requirements-dev.txt)
[ -n "$pb" ] && [ "$pb" = "$pw" ] || fail "backend ($pb) and worker ($pw) pin different pytest versions"
ok "backend and worker pin the same pytest ($pb)"

echo "PASS: $pass assertions"
