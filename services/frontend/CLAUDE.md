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
- **Never add `data-i18n` to `.site-names`.** `applyStaticText()` sets `textContent` on every
  `[data-i18n]` element, so anything in the dictionary exists in the indexed DOM only in English.
  That footer line, the meta description and the JSON-LD `alternateName` are the only places
  `ווטבול` and `Вотбол` reach search engines; a `data-i18n` on the footer line deletes them with no
  visible symptom. (`index.html`'s `<title>` **is** `data-i18n="voteTitle"` — it follows the
  language toggle by request, and gave up that job on 2026-08-01.)
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

## Security headers and the strict CSP (2026-09-09)

`security-headers.conf` is the frontend's browser-hardening header set and **it is in the Dockerfile
`COPY` line under `/etc/nginx/snippets/`** -- the same COPY-by-name rule as every other file here,
and the same failure if it is missed: image builds, nginx starts, headers absent, nothing says so.
`nginx.conf` includes it twice (server level and inside `location /api/`) because `add_header` is not
inherited into a block that has its own; **any new `location` that sets an `add_header` must
`include` the snippet too**, or that path serves none of the headers. `scripts/tests/test-hardening.sh`
walks every location block and fails the build otherwise.

The Content-Security-Policy is `style-src 'self'; script-src 'self'` with **no `'unsafe-inline'`**,
which means: **no `<style>` blocks, no `style=""` attributes, no `on*=""` handlers, no `<script>`
without `src`, and no `setAttribute('style', …)` / `.cssText` in JS.** Setting `element.style.x`
from JS is fine (CSSOM is not inline style). `type="application/ld+json"` blocks are data, not code.
The browser enforces this silently -- the page simply loses its styling -- so the test greps for
each pattern. The admin page's tab styles live at the bottom of `style.css` for exactly this reason,
and `#admin-content` is toggled with the `hidden` attribute, not `style.display`.

`img-src` is the one directive wider than `'self'` (`'self' data: https:`), because `logo_url`
values are hotlinked; the no-hotlinking rule above is about which hosts, not about CSP.

## Languages (English, Hebrew, Russian)

*Moved verbatim from the root `CLAUDE.md` on 2026-10-02 so it loads only when working here. Where a paragraph says "above" or "below" about something not in this file, it is in one of: `terraform/CLAUDE.md`, `scripts/CLAUDE.md`, `charts/logging/CLAUDE.md`, `charts/observability/CLAUDE.md`, `charts/voteball/CLAUDE.md`, or the `voteball-cicd` skill.*

Two independent layers, and adding a language means doing **both**:

- **Interface strings** — the `DICTIONARY` in `services/frontend/i18n.js`, keyed language → string
  id. All three language objects must carry **identical key sets and identical `{placeholder}`
  tokens**; `t()` returns the key itself on a miss, so a gap renders `voteHeroTitle` on the page
  rather than throwing. Language handling reads `SUPPORTED_LANGS`/`RTL_LANGS`/`NAME_FIELD_BY_LANG`
  at the top of that file — add a language there, not by extending `en`/`he` conditionals.
- **Entity names** — `name_en`/`name_he`/`name_ru` **columns** on `leagues`, `clubs`,
  `previous_parties`, `upcoming_parties`, selected by `localizedName()`, which falls back to
  `name_en`. `name_ru` is **nullable and optional in the admin API** — requiring it would 400 every
  existing admin client and block saving any entity with no Russian name yet. The cost is that
  coverage can rot silently as clubs are added.

**Any admin PATCH that forwards a subset of fields must forward every name column.** Those endpoints
replace all fields, so an omitted name is written as `NULL`. `patchClubLeagues` in `admin.js` (behind
the per-competition "Add to UEFA Champions League" / "Add to UEFA Europa League" buttons, which are
generated from `CONTINENTAL_COMPETITIONS`) is the one call site that does this, and it resends
`name_en`/`name_he`/`name_ru`/`logo_url` for exactly this reason.

**Russian names must be Cyrillic, and a homoglyph will pass review.** `РААМ` typed on a Latin
keyboard layout is `PAAM` — visually identical, a different string, and it breaks Russian text
search and collation. `test_migration.py::test_seeded_russian_names_are_cyrillic` asserts the
property; don't rely on reading the file.

Fonts: Heebo and Anton have no Cyrillic. Roboto's Cyrillic subset is declared under the **same
`Heebo` family** (Heebo's Latin derives from Roboto, so it matches rather than approximates) and the
browser picks it by `unicode-range`, so body text needs no `:lang(ru)` rule. Display headings use
Oswald via `--font-display-ru`, mirroring the `:lang(he)` rules in `style.css`.
