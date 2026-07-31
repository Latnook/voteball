# Search-engine visibility (2026-07-31)

Making the site discoverable, and making it discoverable under all three of its names:
**Voteball**, **ווטבול**, **Вотбол**.

## Problem

The site was fully crawlable and completely undiscoverable. Those are different things.

Nothing blocked crawlers — `terraform/waf.tf` has `default_action { allow }`, no Bot Control rule
group, and a 2000 req/5min site-wide ceiling no crawler approaches. What was missing was any reason
for a crawler to visit and any signal about what it had found: no `robots.txt`, no sitemap, no meta
description, a `<title>` of just `Voteball`, and no registration with any search engine. The only
inbound link anywhere was the GitHub repo, which marks outbound links `rel="nofollow"`.

The harder half of the problem is the two non-Latin names. Both already existed in
`services/frontend/i18n.js` (`ווטבול` at the `he` block, `Вотбол` at the `ru` block) — but only as
JavaScript string literals. The page renders in English by default, and the default render is what
gets indexed, so neither string was ever in the indexed DOM. A search for `ווטבול` could not find the
site regardless of how well everything else was configured.

## What was decided

### Scope: brand-findable, not topic-ranked

The site should be findable by name and look right when shared. It does **not** chase Hebrew or
Russian *topic* traffic — that would need real `/he/` and `/ru/` routes with per-language content and
`hreflang`, which is a routing change across nginx, `i18n.js` and every internal link. Brand-name
queries are winnable without it because `ווטבול` and `Вотбол` have essentially zero competition;
topic queries are a separate project. **This is the boundary to re-read before "improving" the SEO
later** — most of what looks missing here was declined on purpose.

### The domain problem, and `sub_filter`

`robots.txt`, sitemaps, `canonical` and Open Graph all require **absolute** URLs. The repo's
forkability rule forbids a hardcoded domain anywhere. Those collide.

Resolution: every absolute URL is written as the literal `__SITE_URL__`, and nginx rewrites it from
the request's own `Host` header at serve time:

```nginx
sub_filter_types text/xml application/xml text/plain;
sub_filter __SITE_URL__ "https://$host";
sub_filter_once off;
```

One directive covers `robots.txt`, `sitemap.xml`, `canonical`, `og:url`, `og:image` and the JSON-LD
`url`. A forker changes nothing. A rebuild onto a different domain fixes itself.

Three things about it that are load-bearing:

- **`application/json` is deliberately absent from `sub_filter_types`.** Adding it would let the
  filter rewrite `/api/` proxy responses. `text/html` is always included by nginx and needs no entry.
- **The scheme is the fixed string `https`, not `$scheme`.** The ALB terminates TLS and forwards
  plain HTTP to the pod, so `$scheme` is always `http` here and every emitted URL would be wrong.
- **Alternatives considered and rejected:** generating the files at container start with `envsubst`
  (the pod runs `readOnlyRootFilesystem: true`, so it would need an `emptyDir` and an entrypoint
  hook) and committing real absolute URLs (breaks forkability, and every rebuild that changes the
  domain silently ships stale ones).

### Getting the non-Latin names into the indexed DOM

`applyStaticText()` in `i18n.js` sets `textContent` on every `[data-i18n]` element. That is the whole
difficulty: anything in the dictionary exists in the index **only in its English form**.

So the trilingual name is placed where JavaScript cannot reach it:

- **A static footer line on `index.html` and `results.html`**, `class="site-names"`, deliberately
  **not** `data-i18n`. It reads identically in all three languages — it is a list of the site's
  names, not a translated string — so staying out of the dictionary costs nothing and guarantees the
  names survive. Content JavaScript does not touch is content JavaScript cannot un-index.
- **`index.html`'s `<title>` carried all three names** and had no `data-i18n`. **Reverted 2026-08-01
  at the owner's request:** the tab should read just the site's name in the current language, so the
  title is now `data-i18n="voteTitle"` (`Voteball` / `ווטבול` / `Вотбол`). The cost is real and was
  stated before the change — the `<title>` is the strongest single on-page signal for a brand query,
  and Googlebot resolves `navigator.language` to `en`, so the indexed homepage title is now just
  `Voteball`. **That makes the three remaining carriers load-bearing rather than belt-and-braces:**
  the JSON-LD `alternateName`, the static `.site-names` footer line, and the meta description. Do
  not weaken any of them.
  `results.html`'s title was always translated — it is `data-i18n="resultsTitle"`, so any static
  edit there is overwritten on load and would be cosmetic.
- **JSON-LD `WebSite` with `alternateName: ["ווטבול", "Вотбол"]`** — the mechanism Google documents
  for "this site is also known as X". Generic structured data was rejected as markup nobody consumes;
  `alternateName` earns its place the moment the brand has non-Latin forms.
- **The meta description and `og:title` carry all three**, and `og:locale:alternate` declares
  `he_IL` / `ru_RU`.

`dir="rtl"` on the Hebrew span and `unicode-bidi: isolate` on both are functional: without them the
bidi algorithm reorders the `·` separators around the Hebrew run. No `:lang()` font rule is needed —
the `unicode-range` split across the `Heebo` `@font-face` declarations already selects the Hebrew and
Cyrillic faces per character.

### `/admin`: noindex, and explicitly *not* `Disallow`

`robots.txt` does **not** disallow `/admin`, and that is the correct configuration, not an oversight.
`Disallow` blocks crawling; `noindex` blocks indexing; a crawler must fetch a page to read its
`noindex`. Disallowing the path would leave the tag unread and permit the URL to be indexed anyway if
it were ever linked from elsewhere. The two are mutually exclusive and de-indexing is what is wanted,
so `admin.html` carries `<meta name="robots" content="noindex,nofollow">` and stays crawlable.

### `/api/`: crawlable, but never indexed

The first version of this design disallowed `/api/` wholesale, on the reasoning that it held "nothing
`/results` does not already render". **That reasoning is inverted, and it broke indexing of
`/results`.** Google indexes the *rendered* page — it executes the JavaScript — and every piece of
content on `/results` arrives through those GETs. Blocking them made Googlebot render an empty
shell. URL Inspection refused the page and reported `Googlebot blocked by robots.txt` against the
XHR to `/api/options`.

The two concerns are separable, and conflating them was the mistake:

- **Crawlability** — Googlebot must be able to fetch the read-only GETs, or the page has no content.
  `robots.txt` therefore carries explicit `Allow: /api/options` and `Allow: /api/results`. They are
  listed explicitly rather than relying on the blanket `Allow: /`, because robots.txt precedence is
  longest-match-wins: a future blanket `Disallow: /api/` cannot silently re-break rendering while
  those longer rules exist.
- **Indexability** — the raw JSON should never appear as a search result in its own right. That is
  what `X-Robots-Tag: noindex, nofollow` on the `/api/` location in `nginx.conf` does. `always` is
  set so the header survives error responses too.

`/api/vote` (POST-only) and `/api/admin/` stay disallowed: there is genuinely nothing to crawl.

The guard test derives the must-be-crawlable set from the `/api/` paths referenced in the JS the
**public** pages load (`admin.js` excluded, since `admin.html` is `noindex`), so adding a `fetch()`
to `results.js` fails the test until `robots.txt` permits it.

### The social card

`services/frontend/og-card.png`, 1200×630, rendered once from the site's own `@font-face` files and
palette (Anton for `Voteball`, Secular One for `ווטבול`, Oswald for `Вотбол` — Anton has no Hebrew or
Cyrillic) and committed as a static asset. A cropped screenshot was rejected: at link-preview size a
dashboard is unreadable, and the card's job is to carry the three names.

## Files

| File | Change |
|---|---|
| `services/frontend/nginx.conf` | `sub_filter` block rewriting `__SITE_URL__` |
| `services/frontend/robots.txt` | new |
| `services/frontend/sitemap.xml` | new — two URLs, hand-maintained |
| `services/frontend/og-card.png` | new — 1200×630 link-preview card |
| `services/frontend/index.html` | trilingual `<title>`, meta/OG/JSON-LD block, footer names |
| `services/frontend/results.html` | meta/OG block, footer names |
| `services/frontend/admin.html` | `noindex,nofollow` |
| `services/frontend/style.css` | `.site-names` |
| `services/frontend/Dockerfile` | `COPY` line for the three new assets |
| `scripts/tests/test-frontend-seo.sh` | new — offline guard |

## The guard test

`scripts/tests/test-frontend-seo.sh` (offline, same pattern as `test-i18n-parity.sh`). It exists
because every failure mode here is invisible on review and produces no build error:

- **A new asset missing from the `Dockerfile` `COPY` line** 404s at runtime with no build error.
- **A Latin homoglyph in either name** renders identically and breaks the exact search the name
  exists to serve — the same trap as the seeded-party `РААМ`/`PAAM` case that
  `test_migration.py::test_seeded_russian_names_are_cyrillic` catches. The test reads the names **out
  of the markup** rather than comparing against its own literals; an earlier version compared against
  constants defined in the test and would have passed on any string whatsoever.
- **A `data-i18n` added to `.site-names` or to `index.html`'s `<title>`** silently deletes the Hebrew
  and Russian names from the indexed DOM.
- **A hardcoded domain** in any frontend `.html`/`.txt`/`.xml`.

## Verification outcome

Verified against the real image (`docker build` of `services/frontend`, run with
`--add-host backend:127.0.0.1` since `proxy_pass http://backend:5000` cannot resolve outside the
cluster):

- `robots.txt` and `sitemap.xml` serve with `__SITE_URL__` rewritten to the request Host; correct
  content types (`text/plain`, `text/xml`); `og-card.png` serves as `image/png`, 114702 bytes.
- **Zero `__SITE_URL__` leaks** across `/`, `/results`, `/admin`, `/robots.txt`, `/sitemap.xml`.
- JSON-LD parses as valid JSON *after* rewriting.
- Under headless Chromium with JavaScript executed, the footer line and the trilingual `<title>`
  both survive `applyStaticText()` — the premise of keeping them out of the dictionary holds.
- The guard test passes on the clean tree and, mutation-tested with a Latin `B` (U+0042) swapped for
  Cyrillic `В` (U+0412), fails 5 assertions naming the offending codepoint.

Two things found and fixed during implementation:

1. **`Disallow: /admin` plus `noindex` was written first**, then caught as the self-defeating
   anti-pattern described above.
2. **The explanatory comments inside `robots.txt`/`sitemap.xml`/the HTML heads originally contained
   the literal `__SITE_URL__`**, so `sub_filter` rewrote the comments too and they served as
   `# Voteball. https://voteball.latnook.com is rewritten to the live origin by nginx`. The comments
   now describe the placeholder without containing it.

## Search-engine registration

**Nothing above causes indexing on its own.** Search engines find sites by following links, and the
only inbound link is `nofollow`. They have to be told the site exists.

### The Google verification TXT is a manual, out-of-stack record — on purpose

Added 2026-07-31, zone `latnook.com` (`Z00371679I0OE09A8HIG`):

```
voteball.latnook.com.  300  TXT  "google-site-verification=YA42wzDkd8hX3aJXuZ9Z2f3U4MxuUsT74DQZeoawq9o"
```

**It is deliberately NOT a Terraform resource, and must not become one.** Terraform only *reads* the
hosted zone (`data "aws_route53_zone" "primary"` in `providers.tf`); it does not own it. Anything it
did own there — the ACM validation records in `acm.tf` — is deleted by `terraform destroy`, which is
right for a cert that gets reissued anyway. This record is the opposite case: if the stack owned it,
every `./scripts/destroy.sh` would delete it, Google would fail re-verification, and the property and
all its accumulated search history would be lost. Surviving teardown is the entire reason DNS
verification was chosen over the HTML-file method. `lifecycle { prevent_destroy = true }` is not a
fix either — it makes `terraform destroy` fail outright and wedges the documented teardown path.

It sits in the same category as the hosted zone itself and the tfstate bucket: **domain-level
identity that outlives any cluster.**

Two things confirmed before it was created, both worth re-checking if this is ever revisited:

- **The apex `latnook.com` carries live email records** (`v=spf1 include:_spf.protonmail.ch ~all`
  plus a ProtonMail verification string). A TXT record set is a single RRSet holding multiple values,
  so an `UPSERT` at the apex with only a new value **destroys the SPF record** and starts sending
  the domain's mail to spam. The verification record belongs at `voteball.latnook.com`, where no TXT
  previously existed — not at the apex.
- **Nothing reaps it.** external-dns runs `policy=sync` but is bounded by its ownership registry, and
  it keeps that registry under *prefixed* names (`cname-voteball`, `aaaa-voteball`), so a bare TXT at
  `voteball.latnook.com` collides with nothing it manages. `scripts/cleanup-stale-dns.sh` only
  deletes TXT records containing both `heritage=external-dns` and `external-dns/owner=voteball`;
  this record has neither.

### Registration status

| Step | Status |
|---|---|
| Route53 verification TXT created | done 2026-07-31 |
| Google Search Console domain verified | done 2026-07-31 |
| `sitemap.xml` submitted and accepted (2 URLs) | done 2026-07-31, after the XML fix below |
| Bing Webmaster Tools | outstanding — add the same domain, import from Search Console in one click; also covers DuckDuckGo |

Indexing typically follows within a few days of the sitemap being accepted.

### The sitemap shipped malformed, and the guard test did not catch it

Search Console rejected the first submission: **"Parsing error, line 5"**. A **double hyphen is
illegal inside an XML comment**, and the explanatory comment at the top of `sitemap.xml` used this
repo's usual dash style. It is harmless in shell, tolerated by HTML parsers, and a hard parse error
in XML. The replacement comment then reintroduced the fault by quoting the offending characters
while explaining them; the test caught that second occurrence.

**The defect was in the test, not the typo.** It asserted a dozen properties of the sitemap — that
`robots.txt` referenced it, that it hardcoded no domain, that it was in the `Dockerfile` `COPY` line
— every one of which is true of a file no XML parser will accept. Structural checks on a document
that is never parsed are checks on a string.

`test-frontend-seo.sh` now parses `sitemap.xml` **twice**: as committed, and as served with
`__SITE_URL__` substituted, since the substituted form is what Google actually fetches. It also
asserts the root element is a `sitemaps.org` `urlset`, that at least one `<url>` exists, and that
every `<loc>` is an absolute `https` URL.

Generalisable: **the `--` dash style used throughout this repo's comments is unsafe in any XML file**
(`sitemap.xml` today; any future `.xml`). The warning lives in `sitemap.xml`'s own header, where
someone editing it will see it.
