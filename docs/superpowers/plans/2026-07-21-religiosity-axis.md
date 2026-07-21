# Religion-and-State Axis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third numeric ideology axis, `religiosity` (−3 separationist … +3 theocratic), to both party tables, expose it through `/api/options`, populate it for all seeded parties, and render it as a fourth row in the Political Lean detail card.

**Architecture:** Mirrors the existing `security` axis exactly. A nullable `INTEGER` column with a `CHECK` constraint on both `previous_parties` and `upcoming_parties`; `get_options` selects it; `analytics.js` renders it via the already-generic `weightedAxisAverage(breakdown, axis)` helper. No new functions, no schema tables, no rollup changes.

**Tech Stack:** PostgreSQL 17, Flask 3.1 + psycopg2, vanilla JS (no build step), pytest against a real Postgres.

**Spec:** `docs/design/2026-07-21-religiosity-axis-design.md` — read it before starting. Decision numbers cited below refer to that document.

## Global Constraints

- Axis range is **−3 to +3 inclusive**, enforced by a `CHECK` constraint. Nullable.
- The axis measures **religion-and-state policy** (how religiously Jewish the state should be), **not** the observance of a party's base. That is what `sector` is for.
- **Arab parties are NULL** (Decision 3): `רע"ם`, `חד"ש-תע"ל`, `בל"ד`. So is `ישר` (undefined ideology) and `אחר` ("Other").
- **Conscription is not scored on this axis** (Decision 6). `אל הדגל` and `המילואימניקים` are `0`.
- Seed edits go in a **new unguarded revision block** appended to `seed.sql`. Do **not** add `AND religiosity IS NULL` — the guard is what stops a revision reaching an already-seeded database.
- This block writes **both** party tables (Decision 7), unlike the three revision blocks above it.
- Nothing in the app writes these columns; they are seed-owned. Do not add admin editing.
- Run `docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17` before the backend tests, and wait for readiness with `docker exec voteball-test-db psql -U postgres -c 'SELECT 1'` in a loop — `pg_isready` returns true before the server accepts connections and will produce confusing "relation does not exist" failures.
- Commit and push after each task (repo standing instruction in `CLAUDE.md`). Never force-push.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `services/backend/schema.sql` | Column definition + CHECK | Modify (~line 88) |
| `services/backend/queries.py` | Expose column via `get_options` | Modify (lines 35, 41, 47, 53) |
| `services/backend/tests/test_queries.py` | Round-trip + seed-coverage assertions | Modify |
| `services/backend/seed.sql` | Values for all 27 rows + tag correction | Modify (append block) |
| `services/frontend/analytics.js` | Fourth detail row | Modify (after line 266) |
| `services/frontend/i18n.js` | Label + pole words, en + he | Modify (after lines 84, 96, 236, 248) |

No files are created. No `Dockerfile` changes — `analytics.js` and `i18n.js` are already in the frontend `COPY` line.

---

### Task 1: Schema column and API exposure

**Files:**
- Modify: `services/backend/schema.sql:88`
- Modify: `services/backend/queries.py:35,41,47,53`
- Test: `services/backend/tests/test_queries.py:51`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `previous_parties.religiosity` and `upcoming_parties.religiosity`, both `INTEGER NULL`, both surfaced in every dict returned by `queries.get_options(conn)` under the key `'religiosity'` with value `int | None`. Tasks 2 and 3 rely on this key name.

- [ ] **Step 1: Write the failing test**

In `services/backend/tests/test_queries.py`, extend the existing `test_get_options_exposes_ideology_and_lineage`. Change the `UPDATE` statement and add one assertion:

```python
    cur.execute('''
        UPDATE previous_parties SET bloc = 'bibi', economic = 1, security = 2,
            sector = 'traditional', religiosity = 1, tags = ARRAY['a', 'b']
        WHERE name_he = 'הליכוד'
    ''')
```

and after the existing `assert likud['sector'] == 'traditional'` line:

```python
    assert likud['religiosity'] == 1
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/backend && .venv/bin/python -m pytest tests/test_queries.py::test_get_options_exposes_ideology_and_lineage -v
```

Expected: FAIL with `psycopg2.errors.UndefinedColumn: column "religiosity" of relation "previous_parties" does not exist`.

- [ ] **Step 3: Add the schema columns**

In `services/backend/schema.sql`, immediately after the line `ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS tags TEXT[];` (line 88), insert:

```sql

-- Religion-and-state policy axis (docs/design/2026-07-21-religiosity-axis-design.md).
-- -3 separationist .. +3 theocratic. Measures what a party wants the STATE to do about religion,
-- NOT how observant its base is -- that is `sector`, which is categorical and cannot be averaged.
-- Nullable on the same terms as economic/security: the Arab parties are scoped out entirely
-- (Decision 3), since "how religiously Jewish should Israel be" is not a question they answer.
ALTER TABLE previous_parties ADD COLUMN IF NOT EXISTS religiosity INTEGER
    CHECK (religiosity BETWEEN -3 AND 3);
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS religiosity INTEGER
    CHECK (religiosity BETWEEN -3 AND 3);
```

- [ ] **Step 4: Expose it in `queries.py`**

Four edits in `services/backend/get_options`. Replace both `SELECT` strings (lines 35 and 47) — they are identical except for the table name:

```python
        'SELECT id, name_en, name_he, logo_url, bloc, economic, security, sector, religiosity, tags '
        'FROM previous_parties ORDER BY name_en'
```

```python
        'SELECT id, name_en, name_he, logo_url, bloc, economic, security, sector, religiosity, tags '
        'FROM upcoming_parties ORDER BY name_en'
```

Then both dict builders (lines 41 and 53) — note `tags` moves from `r[8]` to `r[9]`:

```python
            'bloc': r[4], 'economic': r[5], 'security': r[6], 'sector': r[7],
            'religiosity': r[8], 'tags': r[9] or [],
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd services/backend && .venv/bin/python -m pytest tests/test_queries.py::test_get_options_exposes_ideology_and_lineage -v
```

Expected: PASS.

- [ ] **Step 6: Run the full suite — this catches the index shift**

```bash
cd services/backend && .venv/bin/python -m pytest tests/ -q
```

Expected: `126 passed`. If any test fails on `tags`, the `r[8]` → `r[9]` shift was missed in one of the two dict builders.

- [ ] **Step 7: Assert the field reaches the HTTP layer**

`queries.get_options` returning the key does not prove `/api/options` serialises it — add to `services/backend/tests/test_app.py`:

```python
def test_options_includes_religiosity(client):
    resp = client.get('/api/options')
    assert resp.status_code == 200
    for key in ('previous_parties', 'upcoming_parties'):
        assert all('religiosity' in p for p in resp.get_json()[key])
```

Run it:

```bash
cd services/backend && .venv/bin/python -m pytest tests/test_app.py::test_options_includes_religiosity -v
```

Expected: PASS.

- [ ] **Step 8: Verify the CHECK constraint rejects out-of-range values at both ends**

```bash
docker exec voteball-test-db psql -U postgres -c "UPDATE previous_parties SET religiosity = 4 WHERE id = 1;"
docker exec voteball-test-db psql -U postgres -c "UPDATE previous_parties SET religiosity = -4 WHERE id = 1;"
```

Expected, both times: `ERROR:  new row for relation "previous_parties" violates check constraint "previous_parties_religiosity_check"`.

- [ ] **Step 9: Commit and push**

```bash
git add services/backend/schema.sql services/backend/queries.py \
        services/backend/tests/test_queries.py services/backend/tests/test_app.py
git commit -m "Add religiosity axis column and expose it via /api/options

Third numeric ideology axis (-3 separationist .. +3 theocratic) on both party
tables, nullable on the same terms as economic/security. Measures religion-and-
state POLICY, not the observance of a party's base -- see
docs/design/2026-07-21-religiosity-axis-design.md.

Column only; values land in the next commit."
git push origin master
```

---

### Task 2: Seed values for all parties, plus the Economic Party tag correction

**Files:**
- Modify: `services/backend/seed.sql` (append after the revision-3 block, before the commented-out Joint List line)
- Test: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: `religiosity` column and the `'religiosity'` dict key from Task 1.
- Produces: non-null `religiosity` for every seeded party except the five-party NULL set. Task 3 renders these.

- [ ] **Step 1: Write the failing coverage test**

Append to `services/backend/tests/test_queries.py`. This is a new *kind* of assertion — the spec notes no test currently enforces axis coverage for `bloc`/`sector` either, so this covers all of it at once:

```python
# Parties deliberately left NULL on the religiosity axis: the Arab parties are scoped out
# (design Decision 3 -- "how religiously Jewish should the state be" is not a question they
# answer), Yashar has no declared ideology, and "Other" is a catch-all, not a party.
RELIGIOSITY_NULL_BY_DESIGN = {'רע"ם', 'חד"ש-תע"ל', 'בל"ד', 'ישר', 'אחר'}


def test_every_seeded_party_is_classified(conn):
    options = queries.get_options(conn)

    for key in ('previous_parties', 'upcoming_parties'):
        for party in options[key]:
            name = party['name_he']
            assert party['bloc'] is not None, f'{key}/{name} has no bloc'
            assert party['sector'] is not None, f'{key}/{name} has no sector'
            if name in RELIGIOSITY_NULL_BY_DESIGN:
                assert party['religiosity'] is None, \
                    f'{key}/{name} is NULL by design but has a religiosity value'
            else:
                assert party['religiosity'] is not None, \
                    f'{key}/{name} is missing a religiosity value'
                assert -3 <= party['religiosity'] <= 3
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd services/backend && .venv/bin/python -m pytest tests/test_queries.py::test_every_seeded_party_is_classified -v
```

Expected: FAIL with `previous_parties/הליכוד is missing a religiosity value` (or another party — every non-NULL-by-design party is unset at this point).

Note: `אחר` ("Other") exists only in `previous_parties` and has no `bloc`/`sector` either. If the test fails on `אחר has no bloc`, add `אחר` to a skip at the top of the loop rather than inventing a classification for a catch-all row:

```python
            if name == 'אחר':
                continue
```

- [ ] **Step 3: Append the seed revision block**

In `services/backend/seed.sql`, insert immediately before the line `-- The Joint List is temporarily removed from upcoming_parties (admin decision, 2026-07-16) --`:

```sql

-- =============================================================================================
-- Religion-and-state axis, 2026-07-21 (docs/design/2026-07-21-religiosity-axis-design.md).
--
-- Unguarded, like the revision blocks above: nothing in the app writes these columns, so
-- re-running seed.sql just rewrites identical values, and a guard would stop the axis ever
-- reaching an already-seeded database.
--
-- UNLIKE those blocks, this one writes previous_parties TOO. That is not a contradiction of their
-- "previous_parties stays frozen" rule: those blocks refused to back-date 2026 platforms onto
-- previous-election rows, whereas a NEW AXIS is scored for each row as that party stood AT THE
-- TIME. It is also mandatory -- the Political Lean tab computes from previous-election votes, so
-- without these values the feature renders nothing at all.
--
-- Scale: -3 disestablishment / -2 strong separationist / -1 pluralist / 0 status quo /
--        +1 preserve Jewish character / +2 expand religious authority / +3 halakhic state.
--
-- Left NULL deliberately (Decision 3), so they are simply absent below: רע"ם, חד"ש-תע"ל, בל"ד
-- (the axis is scoped to JEWISH religion-and-state), ישר (undefined ideology) and אחר (catch-all).

-- Yisrael Beiteinu: the -3 anchor. Abolish the religious councils, mandatory civil-marriage
-- option, end yeshiva stipends, one chief rabbi per municipality, rabbinical courts moved to the
-- Justice Ministry.
UPDATE previous_parties SET religiosity = -3 WHERE name_he = 'ישראל ביתנו';
UPDATE upcoming_parties SET religiosity = -3 WHERE name_he = 'ישראל ביתנו';

-- The Democrats: also -3, from the opposite motive -- religious pluralism rather than punitive
-- secularism (Decision 5, which is why the tags carry `religious-pluralism` and Beiteinu carries
-- `anti-clerical`). Kariv (#3) is a Reform rabbi campaigning for civil marriage and divorce, for
-- turning the religious councils into municipal departments, for full recognition of the
-- non-Orthodox movements, and against the Rabbinate's conversion monopoly; Fink (#5) is an
-- observant Shabbat-keeper who explicitly supports separation of religion and state; Dabush (#13)
-- runs the cross-denominational Rabbis for Human Rights. The religious figures on this list push
-- the score DOWN, not up.
UPDATE upcoming_parties SET religiosity = -3 WHERE name_he = 'הדמוקרטים';

-- -2: strong separationists.
UPDATE previous_parties SET religiosity = -2 WHERE name_he IN ('יש עתיד', 'העבודה', 'מרצ');
-- Together: "not state-funded -- not on our dime", 60% core curriculum as a funding condition,
-- full state supervision of haredi education, automatic recognition of international kashrut.
UPDATE upcoming_parties SET religiosity = -2 WHERE name_he = 'ביחד';
-- The Economic Party: "kashrut is too important for us to allow a monopoly in it... take the
-- government, with its political interests, out of granting kashrut" -- that is disestablishment,
-- not price policy. Their haredi section is about ending the subsidy-for-study model, i.e. the
-- same fight from the fiscal side. See the tag correction below.
UPDATE upcoming_parties SET religiosity = -2 WHERE name_he = 'המפלגה הכלכלית';

-- -1: pluralist without disestablishing. "Judaism in the spirit of Beit Hillel", local authorities
-- shape Shabbat in their own area -- but the public space should still express the state's Jewish
-- identity.
UPDATE previous_parties SET religiosity = -1 WHERE name_he = 'המחנה הממלכתי';
UPDATE upcoming_parties SET religiosity = -1 WHERE name_he = 'כחול לבן';

-- 0: no religion-and-state agenda. BOTH of these are built on the haredi conscription exemption,
-- and that is deliberately NOT scored here (Decision 6) -- a party can demand universal service
-- while wanting the Rabbinate left exactly as it is. Neither says anything about marriage,
-- Shabbat, kashrut or the Rabbinate's powers. El HaDegel's mandatory core curriculum pulls
-- negative but is offset by a Values Pillar grounded in Jewish heritage plus community autonomy
-- above the core. Their conscription stance lives in the `anti-conscription-exemption` and
-- `universal-conscription` tags.
UPDATE upcoming_parties SET religiosity = 0 WHERE name_he IN ('אל הדגל', 'המילואימניקים');

-- Likud: +1 is the REVEALED position (Decision 4). They do not want a halakhic state, but they
-- reliably fund and defend religious authority to hold a coalition. Rather than adding a
-- claimed/actual column pair -- explicitly rejected for the economic axis by Decision 3 of the
-- parent design doc -- the gap is carried by the new `instrumentally-clerical` tag.
UPDATE previous_parties SET religiosity = 1 WHERE name_he = 'הליכוד';
UPDATE upcoming_parties SET religiosity = 1 WHERE name_he = 'הליכוד';
UPDATE previous_parties SET tags = tags || ARRAY['instrumentally-clerical']
    WHERE name_he = 'הליכוד' AND NOT ('instrumentally-clerical' = ANY(tags));
UPDATE upcoming_parties SET tags = tags || ARRAY['instrumentally-clerical']
    WHERE name_he = 'הליכוד' AND NOT ('instrumentally-clerical' = ANY(tags));

-- +2: the haredi parties. Communal autonomy and state funding, plus defence of the marriage,
-- kashrut and Shabbat monopolies -- but NOT a programme to derive state law from halakha, which is
-- what separates them from +3.
UPDATE previous_parties SET religiosity = 2 WHERE name_he IN ('ש"ס', 'יהדות התורה');
UPDATE upcoming_parties SET religiosity = 2 WHERE name_he IN ('ש"ס', 'יהדות התורה');

-- +3: explicit halakhic-state vision.
UPDATE previous_parties SET religiosity = 3 WHERE name_he = 'הציונות הדתית';
UPDATE upcoming_parties SET religiosity = 3 WHERE name_he IN ('הציונות הדתית', 'עוצמה יהודית');

-- CORRECTION to revision 2 above. That block replaced the Economic Party's `anti-clerical` tag
-- with `kashrut-liberalization`, reading their kashrut position as competition policy. That was
-- wrong -- their own text asks to remove the government from the granting of kashrut, and their
-- haredi section is about ending payment for non-participation. Restore it; both tags are true.
UPDATE upcoming_parties SET tags = tags || ARRAY['anti-clerical']
    WHERE name_he = 'המפלגה הכלכלית' AND NOT ('anti-clerical' = ANY(tags));
-- =============================================================================================
```

- [ ] **Step 4: Run the coverage test**

```bash
cd services/backend && .venv/bin/python -m pytest tests/test_queries.py::test_every_seeded_party_is_classified -v
```

Expected: PASS.

- [ ] **Step 5: Verify the values landed and are idempotent**

```bash
docker exec voteball-test-db psql -U postgres -q -c \
  "SELECT name_he, religiosity FROM upcoming_parties ORDER BY religiosity NULLS LAST, name_he;"
```

Expected: `ישראל ביתנו` and `הדמוקרטים` at −3; `ביחד` and `המפלגה הכלכלית` at −2; `כחול לבן` at −1; `אל הדגל` and `המילואימניקים` at 0; `הליכוד` at 1; `ש"ס` and `יהדות התורה` at 2; `הציונות הדתית` and `עוצמה יהודית` at 3; `ישר`, `רע"ם`, `חד"ש-תע"ל`, `בל"ד` blank.

Then confirm the tag appends do not duplicate on a second run — this is what the `NOT (... = ANY(tags))` guards are for:

```bash
docker exec voteball-test-db psql -U postgres -q -f /tmp/seed.sql > /dev/null
docker exec voteball-test-db psql -U postgres -q -c \
  "SELECT name_he, tags FROM upcoming_parties WHERE name_he IN ('הליכוד','המפלגה הכלכלית');"
```

Expected: `instrumentally-clerical` and `anti-clerical` each appear exactly once. (Copy the file in first with `docker cp services/backend/seed.sql voteball-test-db:/tmp/seed.sql`.)

- [ ] **Step 6: Verify it reaches an already-seeded database**

This is the check that the three earlier revision blocks exist to satisfy. Seed a fresh container with the *previous* version of the file, then apply the new one:

```bash
git show HEAD:services/backend/seed.sql > /tmp/seed_old.sql
docker rm -f vb-upgrade >/dev/null 2>&1
docker run -d --name vb-upgrade -e POSTGRES_PASSWORD=test postgres:17 >/dev/null
for i in $(seq 1 60); do docker exec vb-upgrade psql -U postgres -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
docker cp services/backend/schema.sql vb-upgrade:/tmp/
docker cp /tmp/seed_old.sql vb-upgrade:/tmp/
docker cp services/backend/seed.sql vb-upgrade:/tmp/seed_new.sql
docker exec vb-upgrade psql -U postgres -q -f /tmp/schema.sql
docker exec vb-upgrade psql -U postgres -q -f /tmp/seed_old.sql
docker exec vb-upgrade psql -U postgres -q -f /tmp/seed_new.sql
docker exec vb-upgrade psql -U postgres -q -c \
  "SELECT count(*) FILTER (WHERE religiosity IS NOT NULL) AS classified FROM upcoming_parties;"
docker rm -f vb-upgrade
```

Expected: `classified | 12`.

- [ ] **Step 7: Run the full suite**

```bash
cd services/backend && .venv/bin/python -m pytest tests/ -q
```

Expected: `128 passed` (126 before this work, +1 in Task 1 Step 7, +1 here).

- [ ] **Step 8: Commit and push**

```bash
git add services/backend/seed.sql services/backend/tests/test_queries.py
git commit -m "Populate the religiosity axis for all seeded parties

Values for 12 upcoming and 10 previous parties; the Arab parties, Yashar and
'Other' stay NULL by design (Decision 3 -- the axis is scoped to Jewish
religion-and-state).

Two placements worth noting. Yisrael Beiteinu and the Democrats tie at -3 from
opposite motives, punitive secularism versus religious pluralism: Kariv (#3)
campaigns for civil marriage and against the Rabbinate's conversion monopoly,
and Fink (#5) is an observant Shabbat-keeper who backs separation outright, so
the religious figures on that list push the score down rather than up. El
HaDegel and the Reservists are 0 despite both being built on the haredi
exemption, because conscription is deliberately off this axis (Decision 6).

Also corrects revision 2: the Economic Party's 'anti-clerical' tag was dropped
on a misreading of their kashrut position as price policy. Their text asks to
take the government out of granting kashrut, which is disestablishment.
Restored, and they score -2.

Adds the first test enforcing classification coverage across all seeded
parties -- bloc, sector and religiosity. No such test existed."
git push origin master
```

---

### Task 3: Render the axis in the Political Lean detail card

**Files:**
- Modify: `services/frontend/analytics.js` (insert after line 266)
- Modify: `services/frontend/i18n.js` (after lines 84, 96, 236, 248)

**Interfaces:**
- Consumes: the `'religiosity'` key on party objects from Task 1, populated by Task 2.
- Produces: nothing downstream.

There is no frontend test suite (repo convention — plain HTML/CSS/vanilla JS, no build step), so verification is by driving the page.

- [ ] **Step 1: Add the i18n keys**

In `services/frontend/i18n.js`, in the **English** block after `analyticsSecurityLabel: 'Security:',` (line 84):

```js
    analyticsReligiosityLabel: 'Religion & state:',
```

and after `analyticsSecurityHawkish: 'Hawkish',` (line 96):

```js
    analyticsReligiositySeparationist: 'Separationist',
    analyticsReligiosityClerical: 'Clerical',
```

In the **Hebrew** block after `analyticsSecurityLabel: 'ביטחון:',` (line 236):

```js
    analyticsReligiosityLabel: 'דת ומדינה:',
```

and after `analyticsSecurityHawkish: 'ניצי',` (line 248):

```js
    analyticsReligiositySeparationist: 'הפרדתי',
    analyticsReligiosityClerical: 'קלריקלי',
```

- [ ] **Step 2: Add the detail row**

In `services/frontend/analytics.js`, inside `renderLeanDetail`, immediately after `container.appendChild(securityRow);` (line 266) and before the `const blocPct = ...` line:

```js
  const religiosity = weightedAxisAverage(previousBreakdown, 'religiosity');
  const religiosityRow = document.createElement('div');
  religiosityRow.className = 'lean-detail-row';
  const religiosityLabel = document.createElement('span');
  religiosityLabel.textContent = t('analyticsReligiosityLabel');
  religiosityRow.appendChild(religiosityLabel);
  const religiosityValue = document.createElement('span');
  religiosityValue.textContent = religiosity === null
    ? t('analyticsNoStatedPosition')
    : `${religiosity.toFixed(1)} (${religiosity < 0 ? t('analyticsReligiositySeparationist') : t('analyticsReligiosityClerical')})`;
  religiosityRow.appendChild(religiosityValue);
  container.appendChild(religiosityRow);
```

This deliberately mirrors the security row above it, including its `< 0` split (so exactly `0.0` reads as the clerical label — same behaviour the security row already has, and not worth diverging from for one boundary case).

- [ ] **Step 3: Verify no syntax error**

```bash
node --check services/frontend/analytics.js && node --check services/frontend/i18n.js
```

Expected: no output (both parse).

- [ ] **Step 4: Drive the page and confirm the row renders**

Bring up the stack the way `docs/deploy.md` documents for local verification (Postgres container, backend under its venv, frontend served with nginx so `/api/*` proxies through — serving the HTML with a bare static server will not work, because the page calls `/api/options` on the same origin). The `/run` skill covers this if the recipe has drifted.

Then open the results page, go to the Political Lean tab, and click a club badge to open the detail card. Confirm:

1. A fourth row appears reading `Religion & state: −1.4 (Separationist)` or similar.
2. Switching to Hebrew shows `דת ומדינה:` with `הפרדתי`/`קלריקלי`.
3. The value is plausible — a club whose fans skew Yisrael Beiteinu/Democrats should be negative; one skewing Shas/UTJ positive.

Use Playwright via the npm library, not the MCP server (this machine has Chromium/Firefox, not Chrome).

- [ ] **Step 5: Confirm the NULL path**

Find or construct a club whose previous-election votes are entirely Arab-party, and confirm the row shows the "no stated position" string rather than `0.0`. This is a routine case for this axis, not an edge case — it is the designed behaviour for the whole NULL set.

- [ ] **Step 6: Commit and push**

```bash
git add services/frontend/analytics.js services/frontend/i18n.js
git commit -m "Render the religion-and-state axis in the Political Lean card

Fourth detail row, using the existing generic weightedAxisAverage helper -- no
new machinery. A club with no classified parties in scope shows 'no stated
position' rather than 0.0, which for this axis is a routine case rather than an
edge one, since every Arab party is NULL by design.

The main club ranking strip still ranks on economic only; a religiosity ranking
view is a documented non-goal until there is enough vote data to know whether
the distribution is interesting."
git push origin master
```

---

## After the plan

ArgoCD syncs from `master`, so the migration Job runs `seed.sql` on the next sync and the values reach production automatically. Confirm the Jenkins host is running first (`aws ec2 describe-instances --instance-ids <id> --query 'Reservations[].Instances[].State.Name'`) — webhooks are silently discarded while it is stopped.

Per `CLAUDE.md`, implementation plans are process artifacts. Delete this file once executed; it stays recoverable in git history.
