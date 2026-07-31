# services/frontend — CLAUDE.md

Guidance for `services/frontend/`. The root `CLAUDE.md` carries the project-wide rules.


Plain HTML/CSS/vanilla JS, no build step, no automated test suite (matches the S3App precedent) —
verify by driving the real page in a browser, or during an end-to-end deploy verification against the
live site.

**Adding a new frontend file (JS/CSS/HTML) requires updating `services/frontend/Dockerfile`'s `COPY`
line too** — the `Dockerfile` lists every file it bakes into the image by name, not by directory. A file
that exists on disk but is missing from that `COPY` line 404s at runtime with no build error and
no obvious symptom beyond "the page is broken" (any script that calls a function the missing file
was supposed to define throws and silently kills the rest of that script's execution) — this
exact gap shipped once (i18n.js, fixed in commit `d02e255`) before being caught.

**SEO markup (added 2026-07-31 — see `docs/design/2026-07-31-seo-design.md`).** Three rules that are
easy to break by accident:

- **`__SITE_URL__` is a placeholder, not a bug.** `nginx.conf`'s `sub_filter` rewrites it to
  `https://$host` at serve time, which is how `robots.txt`, `sitemap.xml`, `canonical`, `og:url` and
  `og:image` carry absolute URLs without hardcoding a domain. **Never add `application/json` to
  `sub_filter_types`** — that would let the filter rewrite `/api/` proxy responses. Keep the literal
  out of explanatory comments too, or the comments get rewritten and serve as nonsense.
- **Never add `data-i18n` to `.site-names` or to `index.html`'s `<title>`.** `applyStaticText()` sets
  `textContent` on every `[data-i18n]` element, so anything in the dictionary exists in the indexed
  DOM only in English. Those two spots are where `ווטבול` and `Вотбол` live for search engines; a
  `data-i18n` deletes them with no visible symptom.
- **`robots.txt` must not `Disallow: /admin`.** `admin.html` carries `noindex,nofollow`, and a
  crawler has to fetch the page to read it. Blocking the crawl and de-indexing the page are mutually
  exclusive; de-indexing is what's wanted.
- **Never blanket-`Disallow: /api/`.** Google indexes the *rendered* page, and everything on
  `/results` arrives via `fetch()`. A blanket disallow makes Googlebot render an empty shell — it
  shipped on 2026-07-31 and URL Inspection refused `/results` outright. The read-only GETs stay
  crawlable; `nginx.conf` sends `X-Robots-Tag: noindex` on `/api/` so the JSON is never indexed as a
  document. Crawlability and indexability are separate levers — use the header, not the disallow.

`scripts/tests/test-frontend-seo.sh` asserts all of the above plus Dockerfile `COPY` coverage and
that both names are genuine Hebrew/Cyrillic (no Latin homoglyphs). Run it after touching any of it.

**`services/frontend/logos/` is the exception: it is copied as a whole directory**, so adding a club
crest is a data change, not a Dockerfile edit. Put crests there for clubs with no Wikimedia artwork and
point `seed.sql`'s `logo_url` at `/logos/<file>.png`. **Do not hotlink social-media CDNs** — those URLs
are signed and expire, the CDN may refuse hotlinks, and (the one that actually bit, on F.C. Kiryat Yam)
tracker blockers drop `*.fbcdn.net` in the browser, so the crest is invisible to many visitors while
`curl` fetches it happily. That class of bug is undetectable server-side.

