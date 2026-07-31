#!/usr/bin/env bash
# Guards the SEO markup added on 2026-07-31. Offline -- reads the source files, builds nothing.
#
# Every assertion here covers a failure that is invisible on review and produces no build error:
#   1. A file missing from the Dockerfile COPY line 404s at runtime (see services/frontend/CLAUDE.md).
#   2. A Latin homoglyph in the Hebrew or Russian site name renders identically and breaks the exact
#      brand-name search the name exists to serve (same class as the seeded-party РААМ/PAAM trap
#      that test_migration.py::test_seeded_russian_names_are_cyrillic catches).
#   3. A data-i18n on the site-names line or on index.html's <title> lets applyStaticText() replace
#      it, erasing the Hebrew and Russian names from the DOM that search engines index.
set -euo pipefail
FE="${1:-$(dirname "$0")/../../services/frontend}"

python3 - "$FE" <<'PY'
import pathlib, re, sys, unicodedata

fe = pathlib.Path(sys.argv[1])
fail = []
def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        fail.append(msg)

# --- 1. every SEO asset is baked into the image ------------------------------------------------
dockerfile = (fe / "Dockerfile").read_text(encoding="utf-8")
print("Dockerfile COPY coverage")
for asset in ("robots.txt", "sitemap.xml", "og-card.png"):
    check((fe / asset).exists(), f"{asset} exists on disk")
    check(re.search(rf"^COPY\b.*\b{re.escape(asset)}\b", dockerfile, re.M) is not None,
          f"{asset} is named in a Dockerfile COPY line")

# --- 2. the site names are genuinely Hebrew / Cyrillic ------------------------------------------
# Read the names OUT of the markup rather than comparing against literals defined here -- a test
# that asserts its own constants are Cyrillic passes no matter what the page actually ships.
def site_names(html):
    m = re.search(r'<p class="site-names"[^>]*>(.*?)</p>', html, re.S)
    if not m:
        return None, {}
    return m.group(0), dict(re.findall(r'<span lang="(he|ru)"[^>]*>([^<]+)</span>', m.group(1)))

idx = (fe / "index.html").read_text(encoding="utf-8")
_, idx_names = site_names(idx)
HE, RU = idx_names.get("he", ""), idx_names.get("ru", "")

print("site-name scripts (read from index.html markup)")
for lang, script in (("he", "HEBREW"), ("ru", "CYRILLIC")):
    name = idx_names.get(lang, "")
    check(bool(name), f'a lang="{lang}" span exists in .site-names')
    bad = [f"{c!r} U+{ord(c):04X} {unicodedata.name(c, '?')}" for c in name
           if not unicodedata.name(c, "").startswith(script)]
    check(bool(name) and not bad, f"{name!r} is all {script} (offenders: {bad or 'none'})")

# --- 3. the names survive applyStaticText() -----------------------------------------------------
print("indexability of the site-name line")
for page in ("index.html", "results.html"):
    html = (fe / page).read_text(encoding="utf-8")
    block, names = site_names(html)
    check(block is not None, f"{page} carries the .site-names line")
    if block:
        check("data-i18n" not in block,
              f"{page} .site-names has no data-i18n (i18n.js would overwrite it)")
        check(names.get("he") == HE and names.get("ru") == RU,
              f"{page} .site-names matches index.html's names exactly")
        check('lang="he"' in block and 'dir="rtl"' in block,
              f"{page} Hebrew span carries lang + dir (bidi reorders the separators without dir)")

# The same two strings must also reach the places search engines actually read.
print("names reach title / description / structured data")
ld = re.search(r'<script type="application/ld\+json">(.*?)</script>', idx, re.S)
desc = re.search(r'<meta name="description" content="([^"]*)"', idx)
for label, hay in (("JSON-LD alternateName", ld.group(1) if ld else ""),
                   ("meta description", desc.group(1) if desc else "")):
    check(bool(HE) and HE in hay, f"{label} contains the Hebrew name")
    check(bool(RU) and RU in hay, f"{label} contains the Russian name")

title = re.search(r"<title[^>]*>(.*?)</title>", idx, re.S)
check(title is not None and "data-i18n" not in title.group(0),
      "index.html <title> has no data-i18n (a translated title drops the other two names)")
check(title is not None and HE in title.group(1) and RU in title.group(1),
      "index.html <title> carries all three site names")

# --- 4. placeholder / robots hygiene ------------------------------------------------------------
print("placeholder + robots hygiene")
nginx = (fe / "nginx.conf").read_text(encoding="utf-8")
check("sub_filter __SITE_URL__" in nginx, "nginx.conf rewrites __SITE_URL__")
check("application/json" not in nginx.split("sub_filter_types", 1)[1].split(";", 1)[0],
      "sub_filter_types excludes application/json (must never rewrite /api/ responses)")

robots = (fe / "robots.txt").read_text(encoding="utf-8")
check("__SITE_URL__/sitemap.xml" in robots, "robots.txt points at the sitemap")
check(not re.search(r"^\s*Disallow:\s*/admin\s*$", robots, re.M),
      "robots.txt does NOT Disallow /admin (that would block the crawler from reading its noindex)")
check('content="noindex,nofollow"' in (fe / "admin.html").read_text(encoding="utf-8"),
      "admin.html carries the noindex tag")

# No source file may hardcode the live domain -- that is the repo's forkability rule.
print("no hardcoded domain")
for f in sorted(list(fe.glob("*.html")) + list(fe.glob("*.txt")) + list(fe.glob("*.xml"))):
    check("latnook.com" not in f.read_text(encoding="utf-8"), f"{f.name} hardcodes no domain")

print()
if fail:
    print(f"FAILED: {len(fail)} assertion(s)")
    sys.exit(1)
print("All frontend SEO assertions passed.")
PY
