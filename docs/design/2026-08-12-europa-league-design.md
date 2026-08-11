# UEFA Europa League (2026-08-12)

Adds the UEFA Europa League as a tenth league, alongside the Champions League it structurally
copies: a continental competition whose clubs are votable **both** under it and under their
domestic league. This doc records only what is specific to it — the dual-league mechanics
themselves are already designed in `2026-08-07-nations-league-design.md` (decisions 1–5) and the
UCL blocks in `seed.sql`.

## Scope

Sixteen clubs, not the competition's eventual full field. Qualification for the 2026-27 Europa
League (and the Conference League) is still running as of this date; the sixteen seeded here are
the teams already through. **The roster is expected to grow**, which shapes two decisions below
(seed extensibility, and the admin toggle in decision 6) more than anything else in this pass.

Nine of the sixteen are already seeded under a domestic league — Bayer Leverkusen, Juventus,
AC Milan, Real Sociedad, Crystal Palace, Bournemouth, Sunderland, Celta Vigo, TSG Hoffenheim.
Seven are new: Olympiacos, Union Saint-Gilloise, Sparta Prague, Stade Rennais, Sturm Graz,
Torreense, Olympique de Marseille.

## Decisions

### 1. The league's `name` literal is its final English name, unlike UCL's

`seed.sql` seeds `name = 'UEFA Europa League'` with `name_en` identical, and never rewrites it.

The Champions League is seeded as `name = 'UCL'` and then renamed by an **unguarded**
`UPDATE leagues SET name_en = 'UEFA Champions League' WHERE name = 'UCL'`. That rewrite is the
sole reason the leagues INSERT carries a three-way identity check with a `CASE` mapping `'UCL' →
'UEFA Champions League'`: once the rename has run, neither the `'UCL'` token nor an admin-drifted
`name` column matches the row, and without the canonical fallback the INSERT creates a *duplicate*
league (incident 2026-07-17 — phantom `UCL` row, duplicate clubs, `clubs_name_en_uidx` crash on
every backend pod boot).

Seeding the final string directly means there is no rewrite, so the new league needs no `CASE`
entry and no third identity branch. It follows the Nations League, which did the same thing.
**Do not "make it consistent" with UCL** — UCL's shape is a historical cost, not a pattern.

### 2. Tab position 7, between the Champions League and the World Cup

`sort_order` becomes: Israeli Premier League 0, Liga Leumit 1, Premier League 2, La Liga 3,
Bundesliga 4, Serie A 5, UEFA Champions League 6, **UEFA Europa League 7**, World Cup 2026 8,
Nations League 9. The two European club cups sit together; the two national-team competitions
stay together at the end.

The two shifted values reach production because the `sort_order` statements are unguarded, which
is what lets a reordering be a value change rather than a migration.

### 3. Dual-league links are keyed on `name_en`, not the legacy `name` column

The nine already-seeded clubs get `domestic_league_id = <Europa League>` while keeping their
domestic `league_id` — the "reverse direction" of the UCL links, and the same direction the
Nations League uses.

The UCL blocks key on the legacy `name` column. This one does not, because `rename_club`
overwrites `name` with `name_he` on **any** admin save — including a no-op one — so a `name`-keyed
statement silently stops matching a club an admin has ever touched. `name_en` survives admin
renames and is the stable identity every newer statement in the file uses. That places this
statement **after** the `name_en` backfill (`UPDATE clubs SET name_en = name WHERE name_en IS
NULL`), since a freshly inserted club carries only `name` until the backfill runs.

All nine were verified to hold `domestic_league_id IS NULL` before this change — none appears in
any UCL link list — so nothing is overwritten. `domestic_league_id` is a single column, so a club
can hold exactly one continental link; a club in both cups is not representable, and none of the
sixteen needs to be.

### 4. The seven new clubs stay Europa-League-only

Their domestic leagues (Greek Super League, Belgian Pro League, Czech First League, Ligue 1,
Austrian Bundesliga, Primeira Liga) are not seeded by this app, so there is no second league to
link them to. This is the same treatment Club Brugge, Feyenoord, Galatasaray, Lens, Lille, PSV,
Shakhtar, Slavia Prague and Sporting CP already get in the UCL block. Note Sparta Prague and
Slavia Prague are distinct clubs and both are seeded; `clubs_name_en_uidx` is global, so a name
collision would have failed loudly rather than silently merging them.

### 5. The logo ships as two hand-made files, not one file plus a filter

`services/frontend/logos/uefa-europa-league.svg` (black trophy, `#FE7000` brackets) and
`uefa-europa-league-dark.svg` (white trophy, same brackets). `seed.sql` points `logo_url` at the
light one; `logos.js` knows the dark one by a `DARK_VARIANT_LOGOS` map keyed on `name_en`, and
renders the pair as `<img class="logo-orig">` + `<img class="logo-recolored">`. The four CSS rules
that already switch that class pair handle both the manual `data-theme` toggle and the
`prefers-color-scheme` fallback, so this adds **no** new theme logic.

Three alternatives were rejected:

- **`OUTLINE_CLUBS`** (the thin white halo used for Juventus and the UCL crest) traces a shape
  without lifting it. The trophy is a large solid black mass, not a thin wordmark; an outline
  leaves it black.
- **The party canvas recolour** would in fact produce roughly the right result — it lifts dark ink
  and keeps saturated colour, which is exactly "white trophy, orange brackets". It was rejected
  for being derived at runtime: the result cannot be reviewed by looking at a file, and it drags
  in `crossOrigin`, pixel reads and the tainted-canvas fallback for a two-colour flat asset.
- **`prefers-color-scheme` inside the SVG** cannot see the site's theme toggle. An `<img>`-embedded
  SVG is an isolated document; it would follow the OS while the page followed the button.

**The upstream file is a raster, which is why these are re-traced rather than cropped.** The
Wikimedia "SVG" (`UEFA_Europa_League_logo_(2024_version).svg`) is a 1 MB base64 PNG inside `<image>`
tags with two `feColorMatrix` masks — it has no vector geometry, so no `viewBox` edit can crop it
cleanly and no fill swap can recolour it. Both files here are `potrace` traces of a 3200 px render,
split into a black mask and an orange mask and reassembled as two path groups, then cropped to the
mark (the "UEFA EUROPA LEAGUE" wordmark below it is dropped). 10 KB each. **Regenerating them means
re-tracing, not editing paths by hand.**

The gaps between the trophy's segments are transparent in both files, and that is correct here in a
way it is not for Shas or בית ציוני (see `FILL_INTERIOR_PARTIES` / `SKIP_RECOLOR_PARTIES` in
`logos.js`): those gaps are separation lines that read against any ground, not a knockout that only
resolves against white.

### 6. The admin club row gets a per-competition continental toggle

`renderUclToggleButton` in `admin.js` is hardcoded to the Champions League. It becomes
`renderContinentalToggleButtons`, rendering one button per continental competition (UCL, UEL) from
a single parameterised function, and the two i18n strings take a `{league}` placeholder in all
three languages.

This is scope beyond "add the league", and it is here specifically because the roster is
incomplete (see Scope): it lets a newly-qualified club be attached to the competition through the
live admin UI instead of a `seed.sql` edit and a full deploy.

The existing rule that a club can hold only **one** continental link is preserved and is now
load-bearing across two buttons rather than one: a club already linked to the UCL shows a disabled
"Add to Europa League", because `domestic_league_id` is occupied. `patchClubLeagues` continues to
resend `name_en`/`name_he`/`name_ru`/`logo_url` on every call — that PATCH replaces every field, so
an omitted name is written as `NULL`.

## Verification outcome

_To be filled in after the change is deployed and verified._
