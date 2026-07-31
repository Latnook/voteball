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

# index.html's <title> follows the language toggle (owner's request, 2026-08-01), so unlike
# .site-names it MUST be data-i18n. It therefore no longer carries the Hebrew and Russian names for
# search engines -- the JSON-LD alternateName and the footer line checked above are what do that now,
# which is why those assertions are not optional.
print("index.html title follows the language toggle")
title = re.search(r"<title[^>]*>(.*?)</title>", idx, re.S)
check(title is not None and 'data-i18n="voteTitle"' in title.group(0),
      "index.html <title> is data-i18n=voteTitle (so it follows the language toggle)")

# The three voteTitle values must be the site's name in each language, and must agree with the
# names in the .site-names footer -- otherwise the tab and the page disagree about what the site
# is called, and a homoglyph could creep into the dictionary unnoticed.
i18n = (fe / "i18n.js").read_text(encoding="utf-8")
expected_titles = {"en": "Voteball", "he": HE, "ru": RU}
scripts_by_lang = {"en": "LATIN", "he": "HEBREW", "ru": "CYRILLIC"}
for lang, want in expected_titles.items():
    block = re.search(rf"^  {lang}: \{{(.*?)^  \}}", i18n, re.S | re.M)
    got = re.search(r"^\s*voteTitle:\s*'([^']*)'", block.group(1), re.M) if block else None
    check(got is not None, f"i18n.js {lang} block defines voteTitle")
    if got:
        check(got.group(1) == want,
              f"i18n.js {lang}.voteTitle is {want!r} (got {got.group(1)!r})")
        bad = [f"{c!r} U+{ord(c):04X}" for c in got.group(1)
               if c.isalpha() and not unicodedata.name(c, "").startswith(scripts_by_lang[lang])]
        check(not bad, f"i18n.js {lang}.voteTitle is all {scripts_by_lang[lang]} (offenders: {bad or 'none'})")

# --- 4. placeholder / robots hygiene ------------------------------------------------------------
print("placeholder + robots hygiene")
nginx = (fe / "nginx.conf").read_text(encoding="utf-8")
check("sub_filter __SITE_URL__" in nginx, "nginx.conf rewrites __SITE_URL__")
check("application/json" not in nginx.split("sub_filter_types", 1)[1].split(";", 1)[0],
      "sub_filter_types excludes application/json (must never rewrite /api/ responses)")

# sitemap.xml must be well-formed XML -- both as committed and as served after sub_filter has
# substituted the placeholder. Google rejected the first version of this file ("Parsing error,
# line 5") because an explanatory comment used this repo's usual "--" dash style, which the XML
# spec forbids inside a comment. Nothing else here would have caught that.
print("sitemap.xml is well-formed XML")
# stdlib ElementTree rather than defusedxml: the only input is a first-party file committed to this
# repo, never untrusted XML, and the frontend has no dependency manifest to add defusedxml to.
# If this ever parses a fetched or user-supplied sitemap, switch it.
import xml.etree.ElementTree as ET
raw = (fe / "sitemap.xml").read_text(encoding="utf-8")
SM = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
for label, doc in (("as committed", raw),
                   ("as served", raw.replace("__SITE_URL__", "https://example.test"))):
    try:
        root = ET.fromstring(doc)
        ok, why = True, ""
    except ET.ParseError as e:
        root, ok, why = None, False, f" ({e})"
    check(ok, f"sitemap.xml parses {label}{why}")
    if root is not None and label == "as served":
        check(root.tag == f"{SM}urlset", f"root element is a sitemaps.org urlset (got {root.tag})")
        urls = root.findall(f"{SM}url")
        check(bool(urls), f"sitemap declares at least one <url> (found {len(urls)})")
        check(all(u.findtext(f"{SM}loc", "").startswith("https://") for u in urls),
              "every <url> has an absolute https <loc>")

robots = (fe / "robots.txt").read_text(encoding="utf-8")
check("__SITE_URL__/sitemap.xml" in robots, "robots.txt points at the sitemap")
check(not re.search(r"^\s*Disallow:\s*/admin\s*$", robots, re.M),
      "robots.txt does NOT Disallow /admin (that would block the crawler from reading its noindex)")

# --- 5. render-critical API paths must stay crawlable -------------------------------------------
# Google indexes the RENDERED page, so every GET the public pages fetch has to be crawlable or the
# page renders as an empty shell. A blanket "Disallow: /api/" shipped on 2026-07-31 and did exactly
# that: URL Inspection refused /results with "Googlebot blocked by robots.txt" on /api/options.
# The allowed set is derived from the JS the public pages actually load, so a new fetch() fails this
# test until robots.txt permits it. admin.js is excluded on purpose (admin.html is noindex).
def robots_allows(txt, path):
    """Google's rule: longest matching prefix wins; a tie favours Allow."""
    best_allow = best_disallow = -1
    for line in txt.splitlines():
        line = line.split("#", 1)[0].strip()
        m = re.match(r"(Allow|Disallow)\s*:\s*(\S*)$", line, re.I)
        if not m:
            continue
        rule, pat = m.group(1).lower(), m.group(2)
        if pat and path.startswith(pat):
            if rule == "allow":
                best_allow = max(best_allow, len(pat))
            else:
                best_disallow = max(best_disallow, len(pat))
    return best_allow >= best_disallow

public_js = [p for p in fe.glob("*.js") if p.name != "admin.js"]
needed = sorted({m for p in public_js
                 for m in re.findall(r"/api/[A-Za-z0-9/_-]*", p.read_text(encoding="utf-8"))
                 if not m.startswith("/api/admin")} - {"/api/vote"})
print("render-critical API paths are crawlable")
check(bool(needed), f"found API paths in the public JS to check ({len(needed)})")
for path in needed:
    check(robots_allows(robots, path), f"robots.txt allows {path} (fetched by the public pages)")

print("non-render API paths stay blocked")
for path in ("/api/vote", "/api/admin/login", "/api/admin/votes"):
    check(not robots_allows(robots, path), f"robots.txt disallows {path}")
check(robots_allows(robots, "/admin"), "robots.txt allows /admin (needed to read its noindex tag)")
check(robots_allows(robots, "/results"), "robots.txt allows /results")

check(re.search(r'add_header\s+X-Robots-Tag\s+"noindex', nginx) is not None,
      "nginx sends X-Robots-Tag: noindex on /api/ (crawlable, but never indexed as a document)")
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
