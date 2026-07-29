# services/frontend — CLAUDE.md

Guidance for `services/frontend/`. The root `CLAUDE.md` carries the project-wide rules.


Plain HTML/CSS/vanilla JS, no build step, no automated test suite (matches the S3App precedent) —
verify by driving the real page in a browser (or during Task 21-style end-to-end deploy verification).

**Adding a new frontend file (JS/CSS/HTML) requires updating `services/frontend/Dockerfile`'s `COPY`
line too** — the `Dockerfile` lists every file it bakes into the image by name, not by directory. A file
that exists on disk but is missing from that `COPY` line 404s at runtime with no build error and
no obvious symptom beyond "the page is broken" (any script that calls a function the missing file
was supposed to define throws and silently kills the rest of that script's execution) — this
exact gap shipped once (i18n.js, fixed in commit `d02e255`) before being caught.

**`services/frontend/logos/` is the exception: it is copied as a whole directory**, so adding a club
crest is a data change, not a Dockerfile edit. Put crests there for clubs with no Wikimedia artwork and
point `seed.sql`'s `logo_url` at `/logos/<file>.png`. **Do not hotlink social-media CDNs** — those URLs
are signed and expire, the CDN may refuse hotlinks, and (the one that actually bit, on F.C. Kiryat Yam)
tracker blockers drop `*.fbcdn.net` in the browser, so the crest is invisible to many visitors while
`curl` fetches it happily. That class of bug is undetectable server-side.

