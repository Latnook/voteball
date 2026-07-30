# Party Families and Club Traits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **DELETE THIS FILE IN THE SAME COMMIT AS TASK 8.** The repo's `CLAUDE.md` requires an executed plan
> to be deleted the moment it is executed, and `docs/superpowers/` to go with it. A plan that outlives
> its execution reads like pending work. Git history is the archive; the durable record is
> `docs/design/2026-07-30-party-families-club-traits-design.md`.

**Goal:** Add a shared, hand-authored classification layer (`families`) to `upcoming_parties` and a
Traits tab on the results page reporting what a club's fans have in common versus the national average.

**Architecture:** Two additive columns on `upcoming_parties` written by the existing unguarded ideology
`UPDATE` block; `get_options()` exposes them; `get_clubs_breakdown()` gains an `upcoming` key so the
analytics feed has per-club upcoming-election data for the first time; `analytics.js` gets a Traits tab
that computes each family's vote share per club and ranks by over-representation against the national
baseline.

**Tech Stack:** Postgres 17, Flask 3.1 / psycopg2 (no ORM), vanilla JS (no build step), pytest against
a real Postgres.

## Global Constraints

- **Design doc is authoritative:** `docs/design/2026-07-30-party-families-club-traits-design.md`. Read
  it before Task 1.
- **The vocabulary is closed at exactly 14 values.** Any value outside this list is a bug:
  `universal-conscription`, `conscription-exemption`, `conscription-split`, `conscription-by-incentive`,
  `constitutional-reform`, `judicial-restraint`, `welfare-state`, `cost-of-living`,
  `sectoral-budgeting`, `market-liberal`, `not-economy-focused`, `arab-representation`,
  `jewish-arab-partnership`, `reservist-movement`.
- **Every family value must sit on ≥2 parties.** This is the property the whole layer exists for.
- **`family_evidence` is `'record'` or `'platform'` only**, enforced by a `CHECK`.
- **Do NOT add `AND ... IS NULL` guards to the ideology `UPDATE` blocks.** They are deliberately
  unguarded — production is always already seeded and a guard makes every later edit unreachable there.
- **Do NOT touch the name/`logo_url` blocks**, which keep their `COALESCE`/`IS NULL` guards because
  admins edit those live.
- **No new source files**, so no `Dockerfile` `COPY` changes are needed. If you add a file anyway, you
  MUST update that service's `Dockerfile` — a file missing from `COPY` is absent from the image with no
  build error.
- **All three i18n language objects must carry identical key sets.** `t()` returns the key itself on a
  miss, so a gap renders `familyWelfareState` on the page rather than throwing.
- **Russian strings must be Cyrillic.** A Latin-keyboard homoglyph (`PAAM` vs `РААМ`) is visually
  identical and passes review.
- **Rendering is `createElement`/`textContent` only** — never `innerHTML` string interpolation.
- **Commit messages must NOT contain a `Claude-Session:` trailer or any `claude.ai/code/session_` URL**
  (repo rule, `CLAUDE.md`).
- **Test env:** `docker start voteball-test-db`, then
  `cd services/backend && source .venv/bin/activate` and run pytest with
  `DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable`.

---

## File Structure

| file | responsibility | change |
|---|---|---|
| `services/backend/schema.sql` | column definitions | +2 `ALTER TABLE` |
| `services/backend/seed.sql` | the values | extend the `upcoming_parties` ideology `VALUES` tuple |
| `services/backend/queries.py` | all SQL | `get_options()`, `get_clubs_breakdown()` |
| `services/backend/tests/test_migration.py` | column round-trip + constraints | +1 test |
| `services/backend/tests/test_queries.py` | seeded-data properties + query shapes | +4 tests |
| `services/frontend/i18n.js` | interface strings | +19 keys × 3 languages |
| `services/frontend/results.html` | tab button + panel | +2 elements |
| `services/frontend/analytics.js` | the Traits tab | +3 functions, wiring |
| `scripts/tests/test-i18n-parity.sh` | key-set parity across languages | new file |

---

### Task 1: Schema columns

**Files:**
- Modify: `services/backend/schema.sql` (after line 104, the `tags` ALTER)
- Test: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: nothing
- Produces: `upcoming_parties.families TEXT[]`, `upcoming_parties.family_evidence TEXT` constrained to
  `'record' | 'platform' | NULL`

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_migration.py`:

```python
def test_family_columns_round_trip_and_constrain(conn):
    cur = conn.cursor()
    cur.execute("""
        UPDATE upcoming_parties
        SET families = ARRAY['welfare-state', 'cost-of-living'], family_evidence = 'record'
        WHERE name_he = 'ש"ס'
    """)
    cur.execute("SELECT families, family_evidence FROM upcoming_parties WHERE name_he = 'ש\"ס'")
    families, evidence = cur.fetchone()
    assert families == ['welfare-state', 'cost-of-living']
    assert evidence == 'record'

    cur.execute("UPDATE upcoming_parties SET family_evidence = 'platform' WHERE name_he = 'ש\"ס'")
    cur.execute("SELECT family_evidence FROM upcoming_parties WHERE name_he = 'ש\"ס'")
    assert cur.fetchone()[0] == 'platform'

    with pytest.raises(psycopg2.errors.CheckViolation):
        cur.execute("UPDATE upcoming_parties SET family_evidence = 'vibes' WHERE name_he = 'ש\"ס'")
    conn.rollback()
    cur.close()
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
docker start voteball-test-db && sleep 3
cd services/backend && source .venv/bin/activate
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  python -m pytest tests/test_migration.py::test_family_columns_round_trip_and_constrain -v
```

Expected: FAIL — `psycopg2.errors.UndefinedColumn: column "families" of relation "upcoming_parties" does not exist`

- [ ] **Step 3: Add the columns**

In `services/backend/schema.sql`, immediately after the existing
`ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS tags TEXT[];`:

```sql
-- Families: a closed, deliberately-shared vocabulary naming what parties have in common, as opposed
-- to `tags`, which is per-party evidence and 61% singletons. family_evidence records whether the
-- assignment came from the voting record or from the platform alone -- nine upcoming parties have no
-- usable record. See docs/design/2026-07-30-party-families-club-traits-design.md.
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS families TEXT[];
ALTER TABLE upcoming_parties ADD COLUMN IF NOT EXISTS family_evidence TEXT
    CHECK (family_evidence IS NULL OR family_evidence IN ('record', 'platform'));
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  python -m pytest tests/test_migration.py::test_family_columns_round_trip_and_constrain -v
```

Expected: PASS

- [ ] **Step 5: Run the full backend suite**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -m pytest tests/ -q
```

Expected: 145 passed

- [ ] **Step 6: Commit**

```bash
git add services/backend/schema.sql services/backend/tests/test_migration.py
git commit -m "feat(schema): add families and family_evidence to upcoming_parties"
```

---

### Task 2: Seed the 18 parties

**Files:**
- Modify: `services/backend/seed.sql` — the `UPDATE upcoming_parties p SET` ideology block only
- Test: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: the columns from Task 1
- Produces: all 18 upcoming parties carry 1–3 families and a non-NULL `family_evidence`

> **This task writes NO pytest tests.** The three vocabulary property tests read `get_options()`,
> which does not expose `families` until Task 3 — committing them here would leave a red suite. They
> live in Task 3. This task proves itself with direct SQL in Steps 4–5, which is stronger for data
> anyway: it checks the real seeded rows rather than a serialisation of them.

- [ ] **Step 1: Extend the VALUES tuple**

In `services/backend/seed.sql`, in the `UPDATE upcoming_parties p SET` ideology block **only** (not the
`previous_parties` one), add the two columns to the SET list:

```sql
UPDATE upcoming_parties p SET
    bloc = v.bloc, economic = v.economic, security = v.security,
    religiosity = v.religiosity, sector = v.sector, tags = v.tags,
    families = v.families, family_evidence = v.family_evidence
FROM (VALUES
```

Then append two fields to each of the 18 rows, before the closing `)`, and update the column list.
Each row becomes `..., ARRAY[...tags...]::text[], ARRAY[...families...]::text[], '<evidence>'`:

| party | families | evidence |
|---|---|---|
| `הליכוד` | `'conscription-exemption','judicial-restraint','sectoral-budgeting'` | `record` |
| `ישר` | `'universal-conscription','constitutional-reform','cost-of-living'` | `platform` |
| `ביחד` | `'universal-conscription','constitutional-reform','cost-of-living'` | `platform` |
| `הדמוקרטים` | `'constitutional-reform','welfare-state','jewish-arab-partnership'` | `platform` |
| `כחול לבן` | `'constitutional-reform'` | `platform` |
| `ישראל ביתנו` | `'universal-conscription','constitutional-reform','market-liberal'` | `record` |
| `הציונות הדתית` | `'judicial-restraint','conscription-split','sectoral-budgeting'` | `record` |
| `עוצמה יהודית` | `'judicial-restraint','not-economy-focused','conscription-by-incentive'` | `record` |
| `חד"ש-תע"ל` | `'arab-representation','jewish-arab-partnership','welfare-state'` | `record` |
| `בל"ד` | `'arab-representation','welfare-state'` | `record` |
| `רע"ם` | `'arab-representation'` | `record` |
| `ש"ס` | `'conscription-exemption','welfare-state','sectoral-budgeting'` | `record` |
| `יהדות התורה` | `'conscription-split','welfare-state','sectoral-budgeting'` | `record` |
| `המפלגה הכלכלית` | `'cost-of-living'` | `platform` |
| `אל הדגל` | `'universal-conscription','reservist-movement','constitutional-reform'` | `platform` |
| `המילואימניקים` | `'universal-conscription','reservist-movement','constitutional-reform'` | `platform` |
| `זהות` | `'judicial-restraint','market-liberal','cost-of-living'` | `platform` |
| `נעם` | `'judicial-restraint','conscription-by-incentive','not-economy-focused'` | `record` |

Finally extend the column list at the bottom of the block:

```sql
) AS v(name_he, bloc, economic, security, religiosity, sector, tags, families, family_evidence)
WHERE p.name_he = v.name_he;
```

- [ ] **Step 2: Prove no axis value moved**

Editing 18 long lines risks a transcription error in the six ideology columns. Prove there isn't one:

```bash
cd /home/latnook/Documents/Voteball
SP=$(mktemp -d)
git show HEAD:services/backend/seed.sql > "$SP/seed-old.sql"
docker exec voteball-test-db psql -U postgres -qc "DROP DATABASE IF EXISTS famold;" >/dev/null
docker exec voteball-test-db psql -U postgres -qc "DROP DATABASE IF EXISTS famnew;" >/dev/null
docker exec voteball-test-db psql -U postgres -qc "CREATE DATABASE famold;" >/dev/null
docker exec voteball-test-db psql -U postgres -qc "CREATE DATABASE famnew;" >/dev/null
docker cp services/backend/schema.sql voteball-test-db:/tmp/schema.sql
docker cp "$SP/seed-old.sql" voteball-test-db:/tmp/seed-old.sql
docker cp services/backend/seed.sql voteball-test-db:/tmp/seed-new.sql
for db in famold famnew; do
  docker exec voteball-test-db psql -U postgres -d $db -q -f /tmp/schema.sql 2>&1 | grep -i error
done
docker exec voteball-test-db psql -U postgres -d famold -q -f /tmp/seed-old.sql 2>&1 | grep -i error
docker exec voteball-test-db psql -U postgres -d famnew -q -f /tmp/seed-new.sql 2>&1 | grep -i error
Q="SELECT name_he,bloc,economic,security,religiosity,sector,array_to_string(tags,'|') FROM upcoming_parties ORDER BY name_he;"
docker exec voteball-test-db psql -U postgres -d famold -tAc "$Q" > "$SP/old.txt"
docker exec voteball-test-db psql -U postgres -d famnew -tAc "$Q" > "$SP/new.txt"
diff "$SP/old.txt" "$SP/new.txt" && echo "PROVEN: no ideology value moved"
```

Expected: `PROVEN: no ideology value moved`

- [ ] **Step 3: Prove the block reaches an already-seeded database**

A fresh database proves nothing about production, which is always already seeded:

```bash
docker exec voteball-test-db psql -U postgres -d famold -q -f /tmp/seed-new.sql 2>&1 | grep -i error
docker exec voteball-test-db psql -U postgres -d famold -tAc \
  "SELECT count(*) FROM upcoming_parties WHERE families IS NOT NULL AND family_evidence IS NOT NULL;"
```

Expected: `18`

- [ ] **Step 4: Prove the vocabulary properties in SQL**

```bash
docker exec voteball-test-db psql -U postgres -d famnew -tAc \
  "SELECT f, count(*) FROM upcoming_parties, unnest(families) AS f GROUP BY f HAVING count(*) < 2;"
```

Expected: **no rows** — every family value sits on ≥2 parties.

```bash
docker exec voteball-test-db psql -U postgres -d famnew -tAc \
  "SELECT count(DISTINCT f) FROM upcoming_parties, unnest(families) AS f;"
```

Expected: `14`

- [ ] **Step 5: Run the existing suite to confirm nothing regressed**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -m pytest tests/ -q
```

Expected: 145 passed (unchanged from Task 1 — this task adds no tests)

- [ ] **Step 6: Commit**

```bash
git add services/backend/seed.sql
git commit -m "data(parties): assign families to all 18 upcoming parties"
```

---

### Task 3: Expose families through `get_options()`

**Files:**
- Modify: `services/backend/queries.py:42-66` (both party `SELECT` blocks in `get_options`)
- Test: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: Task 2's seeded data
- Produces: each dict in `options['upcoming_parties']` gains `'families': list[str]` and
  `'family_evidence': str | None`; `previous_parties` entries gain `'families': []` and
  `'family_evidence': None`

- [ ] **Step 1: Write the failing tests**

Append to `services/backend/tests/test_queries.py`. Add `import collections` at the top of the file if
it is not already imported. These four tests were deliberately deferred from Task 2, which seeds the
data but cannot read it through `get_options()` yet:

```python
FAMILY_VOCABULARY = {
    'universal-conscription', 'conscription-exemption', 'conscription-split',
    'conscription-by-incentive', 'constitutional-reform', 'judicial-restraint',
    'welfare-state', 'cost-of-living', 'sectoral-budgeting', 'market-liberal',
    'not-economy-focused', 'arab-representation', 'jewish-arab-partnership',
    'reservist-movement',
}


def test_every_upcoming_party_has_families_and_evidence(conn):
    for party in queries.get_options(conn)['upcoming_parties']:
        name = party['name_he']
        assert party['families'], f'{name} has no families'
        assert party['family_evidence'] in ('record', 'platform'), \
            f'{name} has family_evidence {party["family_evidence"]!r}'


def test_family_values_come_from_the_closed_vocabulary(conn):
    for party in queries.get_options(conn)['upcoming_parties']:
        unknown = set(party['families']) - FAMILY_VOCABULARY
        assert not unknown, f'{party["name_he"]} carries unknown families {sorted(unknown)}'


def test_every_family_value_is_shared_by_at_least_two_parties(conn):
    counts = collections.Counter(
        f for p in queries.get_options(conn)['upcoming_parties'] for f in p['families']
    )
    singletons = sorted(f for f, n in counts.items() if n < 2)
    assert not singletons, f'families on only one party: {singletons}'
    assert set(counts) == FAMILY_VOCABULARY, \
        f'unused vocabulary: {sorted(FAMILY_VOCABULARY - set(counts))}'


def test_get_options_exposes_families(conn):
    options = queries.get_options(conn)

    likud = next(p for p in options['upcoming_parties'] if p['name_he'] == 'הליכוד')
    assert sorted(likud['families']) == [
        'conscription-exemption', 'judicial-restraint', 'sectoral-budgeting'
    ]
    assert likud['family_evidence'] == 'record'

    yashar = next(p for p in options['upcoming_parties'] if p['name_he'] == 'ישר')
    assert yashar['family_evidence'] == 'platform'

    # previous_parties has no family layer in this pass, but the key must exist so the frontend
    # can read both lists through one code path.
    for party in options['previous_parties']:
        assert party['families'] == []
        assert party['family_evidence'] is None
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  python -m pytest tests/test_queries.py::test_get_options_exposes_families -v
```

Expected: FAIL — `KeyError: 'families'`

- [ ] **Step 3: Add the columns to both SELECTs**

In `services/backend/queries.py`, replace the `previous_parties` block:

```python
    cur.execute(
        'SELECT id, name_en, name_he, name_ru, logo_url, bloc, economic, security, sector, religiosity, tags '
        'FROM previous_parties ORDER BY name_en'
    )
    previous_parties = [
        {
            'id': r[0], 'name_en': r[1], 'name_he': r[2], 'name_ru': r[3], 'logo_url': r[4],
            'bloc': r[5], 'economic': r[6], 'security': r[7], 'sector': r[8],
            'religiosity': r[9], 'tags': r[10] or [],
            'families': [], 'family_evidence': None,
        }
        for r in cur.fetchall()
    ]
```

and the `upcoming_parties` block:

```python
    cur.execute(
        'SELECT id, name_en, name_he, name_ru, logo_url, bloc, economic, security, sector, religiosity, tags, '
        'families, family_evidence '
        'FROM upcoming_parties ORDER BY name_en'
    )
    upcoming_parties = [
        {
            'id': r[0], 'name_en': r[1], 'name_he': r[2], 'name_ru': r[3], 'logo_url': r[4],
            'bloc': r[5], 'economic': r[6], 'security': r[7], 'sector': r[8],
            'religiosity': r[9], 'tags': r[10] or [],
            'families': r[11] or [], 'family_evidence': r[12],
        }
        for r in cur.fetchall()
    ]
```

- [ ] **Step 4: Run the family tests and confirm they pass**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -m pytest tests/test_queries.py -k family -v
```

Expected: PASS — this also greens the three tests written in Task 2.

- [ ] **Step 5: Run the full suite**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -m pytest tests/ -q
```

Expected: 149 passed

- [ ] **Step 6: Commit**

```bash
git add services/backend/queries.py services/backend/tests/test_queries.py
git commit -m "feat(api): expose families and family_evidence from /api/options"
```

---

### Task 4: `get_clubs_breakdown()` returns upcoming votes

**Files:**
- Modify: `services/backend/queries.py:268-279`
- Test: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `/api/results/clubs-breakdown` returns
  `[{'club_id': int, 'previous': [{'party_id', 'count'}], 'upcoming': [{'party_id', 'count'}]}]`

**Why this task exists:** the analytics tab's only per-club feed is previous-election data. Without
this, the Traits tab has no numerator.

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_queries.py`. Follow the existing vote-inserting fixtures in this
file for how to build a vote — reuse whichever helper the neighbouring `get_clubs_breakdown` or
rollup tests already use rather than inventing one:

```python
def test_clubs_breakdown_returns_both_elections(conn, seeded_ids):
    rows = queries.get_clubs_breakdown(conn)
    assert rows, 'expected at least one club row'
    for row in rows:
        assert 'club_id' in row
        assert isinstance(row['previous'], list)
        assert isinstance(row['upcoming'], list)
        for entry in row['previous'] + row['upcoming']:
            assert set(entry) == {'party_id', 'count'}
```

If no `seeded_ids` fixture exists, drop that parameter and rely on `conn` plus whatever vote-creation
helper the file already defines; the assertions do not depend on specific counts.

- [ ] **Step 2: Run it and confirm it fails**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  python -m pytest tests/test_queries.py::test_clubs_breakdown_returns_both_elections -v
```

Expected: FAIL — `KeyError: 'upcoming'`

- [ ] **Step 3: Add the upcoming query**

Replace `get_clubs_breakdown` in `services/backend/queries.py`:

```python
def get_clubs_breakdown(conn):
    cur = conn.cursor()
    by_club = {}

    cur.execute(
        'SELECT club_id, previous_party_id, SUM(vote_count) FROM rollup_previous '
        'WHERE club_id IS NOT NULL GROUP BY club_id, previous_party_id'
    )
    for club_id, party_id, count in cur.fetchall():
        by_club.setdefault(club_id, {'previous': [], 'upcoming': []})
        by_club[club_id]['previous'].append({'party_id': party_id, 'count': count})

    cur.execute(
        'SELECT club_id, upcoming_party_id, SUM(vote_count) FROM rollup_upcoming '
        'WHERE club_id IS NOT NULL GROUP BY club_id, upcoming_party_id'
    )
    for club_id, party_id, count in cur.fetchall():
        by_club.setdefault(club_id, {'previous': [], 'upcoming': []})
        by_club[club_id]['upcoming'].append({'party_id': party_id, 'count': count})

    cur.close()
    return [
        {'club_id': club_id, 'previous': rows['previous'], 'upcoming': rows['upcoming']}
        for club_id, rows in by_club.items()
    ]
```

Note `setdefault` in both loops: a club with upcoming votes but no previous ones must still appear.

- [ ] **Step 4: Run the test and the full suite**

```bash
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  python -m pytest tests/test_queries.py::test_clubs_breakdown_returns_both_elections -v
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -m pytest tests/ -q
```

Expected: PASS, then 150 passed

- [ ] **Step 5: Commit**

```bash
git add services/backend/queries.py services/backend/tests/test_queries.py
git commit -m "feat(api): return per-club upcoming breakdown from clubs-breakdown"
```

---

### Task 5: i18n strings

**Files:**
- Modify: `services/frontend/i18n.js` — all three language objects
- Create: `scripts/tests/test-i18n-parity.sh`

> **BLOCKED ON HUMAN REVIEW.** The exact en/he/ru strings come from `docs/i18n/family-strings.csv`,
> which the repo owner reviews and corrects. **Do not dispatch this task until that file is approved,
> and then use its contents verbatim** — the strings below are the pre-review draft and may differ.
> Read the CSV, not this plan, for the final text.

**Interfaces:**
- Consumes: the approved `docs/i18n/family-strings.csv`
- Produces: keys `familyUniversalConscription`, `familyConscriptionExemption`,
  `familyConscriptionSplit`, `familyConscriptionByIncentive`, `familyConstitutionalReform`,
  `familyJudicialRestraint`, `familyWelfareState`, `familyCostOfLiving`, `familySectoralBudgeting`,
  `familyMarketLiberal`, `familyNotEconomyFocused`, `familyArabRepresentation`,
  `familyJewishArabPartnership`, `familyReservistMovement`, plus `analyticsTabTraits`,
  `analyticsTraitsNationalAvg`, `analyticsTraitsNone`, `analyticsTraitsEvidenceRecord`,
  `analyticsTraitsEvidencePlatform` — 19 keys in each of `en`, `he`, `ru`.

- [ ] **Step 1: Write the parity check first**

Create `scripts/tests/test-i18n-parity.sh`, following the offline pattern of
`scripts/tests/test-sync-values.sh`:

```bash
#!/usr/bin/env bash
# Asserts all three DICTIONARY language objects in i18n.js carry identical key sets.
# t() returns the key itself on a miss, so a gap renders "familyWelfareState" on the page
# rather than throwing -- nothing else in the repo catches that.
set -euo pipefail
I18N="${1:-$(dirname "$0")/../../services/frontend/i18n.js}"

python3 - "$I18N" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
body = src.split('const DICTIONARY = {', 1)[1]

blocks, depth, cur, lang = {}, 0, [], None
for line in body.split('\n'):
    m = re.match(r'\s{2}([a-z]{2}): \{\s*$', line)
    if m and depth == 0:
        lang, depth, cur = m.group(1), 1, []
        continue
    if depth:
        if re.match(r'\s{2}\},?\s*$', line):
            blocks[lang], depth = cur, 0
            continue
        cur.append(line)

keys = {l: set(re.findall(r"^\s*([A-Za-z0-9_]+):", '\n'.join(v), re.M)) for l, v in blocks.items()}
print(f"languages: {sorted(keys)}  sizes: { {l: len(k) for l, k in keys.items()} }")

fail = False
base = keys.get('en', set())
for lang, k in sorted(keys.items()):
    missing, extra = sorted(base - k), sorted(k - base)
    if missing:
        print(f"  {lang}: MISSING {missing}"); fail = True
    if extra:
        print(f"  {lang}: EXTRA {extra}"); fail = True

cyrillic = re.compile(r'[Ѐ-ӿ]')
latin = re.compile(r'[A-Za-z]')
for line in blocks.get('ru', []):
    m = re.match(r"\s*(family[A-Za-z0-9_]*): '([^']*)'", line)
    if m and cyrillic.search(m.group(2)) and latin.search(m.group(2)):
        print(f"  ru: MIXED SCRIPT in {m.group(1)}: {m.group(2)!r}"); fail = True

sys.exit(1 if fail else 0)
PY
echo "i18n parity OK"
```

Then `chmod +x scripts/tests/test-i18n-parity.sh`.

- [ ] **Step 2: Run it against the current file — it must pass before you add anything**

```bash
scripts/tests/test-i18n-parity.sh
```

Expected: `i18n parity OK`. If it reports pre-existing drift, fix that first and commit separately —
do not fold an unrelated fix into this feature.

- [ ] **Step 3: Add the English keys**

In the `en:` object of `services/frontend/i18n.js`, next to the other `analytics*` keys:

```js
    analyticsTabTraits: 'Shared traits',
    analyticsTraitsNationalAvg: 'national average {pct}%',
    analyticsTraitsNone: 'No trait stands out for this club yet.',
    analyticsTraitsEvidenceRecord: 'from voting record',
    analyticsTraitsEvidencePlatform: 'from stated platform',
    familyUniversalConscription: 'Universal conscription',
    familyConscriptionExemption: 'Yeshiva draft exemption',
    familyConscriptionSplit: 'Split on conscription',
    familyConscriptionByIncentive: 'Enlistment by incentive',
    familyConstitutionalReform: 'Constitution & checks',
    familyJudicialRestraint: 'Curbing the courts',
    familyWelfareState: 'Welfare state',
    familyCostOfLiving: 'Cost of living',
    familySectoralBudgeting: 'Sectoral budgeting',
    familyMarketLiberal: 'Free market',
    familyNotEconomyFocused: 'Not economy-focused',
    familyArabRepresentation: 'Arab representation',
    familyJewishArabPartnership: 'Jewish-Arab partnership',
    familyReservistMovement: 'Reservist movement',
```

- [ ] **Step 4: Add the Hebrew keys**

In the `he:` object:

```js
    analyticsTabTraits: 'מאפיינים משותפים',
    analyticsTraitsNationalAvg: 'ממוצע ארצי {pct}%',
    analyticsTraitsNone: 'עדיין אין מאפיין בולט למועדון הזה.',
    analyticsTraitsEvidenceRecord: 'לפי דפוסי הצבעה בכנסת',
    analyticsTraitsEvidencePlatform: 'לפי המצע המוצהר',
    familyUniversalConscription: 'גיוס לכולם',
    familyConscriptionExemption: 'פטור לבני ישיבות',
    familyConscriptionSplit: 'מחלוקת פנימית על הגיוס',
    familyConscriptionByIncentive: 'גיוס בעידוד ולא בכפייה',
    familyConstitutionalReform: 'חוקה ואיזונים',
    familyJudicialRestraint: 'ריסון בתי המשפט',
    familyWelfareState: 'מדינת רווחה',
    familyCostOfLiving: 'יוקר המחיה',
    familySectoralBudgeting: 'תקצוב מגזרי',
    familyMarketLiberal: 'שוק חופשי',
    familyNotEconomyFocused: 'לא ממוקדת בכלכלה',
    familyArabRepresentation: 'ייצוג ערבי',
    familyJewishArabPartnership: 'שותפות יהודית-ערבית',
    familyReservistMovement: 'תנועת המילואימניקים',
```

- [ ] **Step 5: Add the Russian keys — Cyrillic only**

In the `ru:` object:

```js
    analyticsTabTraits: 'Общие черты',
    analyticsTraitsNationalAvg: 'в среднем по стране {pct}%',
    analyticsTraitsNone: 'Пока нет выраженной черты для этого клуба.',
    analyticsTraitsEvidenceRecord: 'по результатам голосований',
    analyticsTraitsEvidencePlatform: 'по заявленной программе',
    familyUniversalConscription: 'Всеобщий призыв',
    familyConscriptionExemption: 'Освобождение ешив от призыва',
    familyConscriptionSplit: 'Раскол по призыву',
    familyConscriptionByIncentive: 'Призыв через стимулы',
    familyConstitutionalReform: 'Конституция и сдержки',
    familyJudicialRestraint: 'Ограничение судов',
    familyWelfareState: 'Социальное государство',
    familyCostOfLiving: 'Стоимость жизни',
    familySectoralBudgeting: 'Секторальное финансирование',
    familyMarketLiberal: 'Свободный рынок',
    familyNotEconomyFocused: 'Экономика не в приоритете',
    familyArabRepresentation: 'Арабское представительство',
    familyJewishArabPartnership: 'Еврейско-арабское партнёрство',
    familyReservistMovement: 'Движение резервистов',
```

- [ ] **Step 6: Run the parity check**

```bash
scripts/tests/test-i18n-parity.sh
```

Expected: `i18n parity OK`, with all three sizes equal and each 19 larger than before.

- [ ] **Step 7: Commit**

```bash
git add services/frontend/i18n.js scripts/tests/test-i18n-parity.sh
git commit -m "feat(i18n): add family trait strings and a language key-parity check"
```

---

### Task 6: Traits tab markup

**Files:**
- Modify: `services/frontend/results.html:57-65`

**Interfaces:**
- Consumes: `analyticsTabTraits` from Task 5
- Produces: `<button data-tab="traits">` and `<div id="traits-tab" class="analytics-tab" hidden>`

- [ ] **Step 1: Add the tab button**

After the `switching` button in the `#analytics-tabs` pill group:

```html
        <button type="button" data-tab="traits" aria-pressed="false" data-i18n="analyticsTabTraits">Shared traits</button>
```

- [ ] **Step 2: Add the panel**

After `<div id="switching-tab" class="analytics-tab" hidden></div>`:

```html
      <div id="traits-tab" class="analytics-tab" hidden></div>
```

- [ ] **Step 3: Verify the tab switches**

Serve the frontend and click through. The existing delegated handler at `analytics.js:32` reads
`btn.dataset.tab` and `switchAnalyticsTab` toggles `#<tab>-tab`, so no JS is needed for switching —
the panel should appear empty when selected.

- [ ] **Step 4: Commit**

```bash
git add services/frontend/results.html
git commit -m "feat(results): add the Shared traits tab shell"
```

---

### Task 7: Traits tab computation and rendering

**Files:**
- Modify: `services/frontend/analytics.js`

**Interfaces:**
- Consumes: `clubsBreakdown[].upcoming` (Task 4), `analyticsOptionsData.upcoming_parties[].families`
  (Task 3), the i18n keys (Task 5), `#traits-tab` (Task 6)
- Produces: `familyShare(upcomingBreakdown, family)`, `nationalUpcomingBreakdown()`,
  `renderTraitsTab()`

- [ ] **Step 1: Add the family label map and share function**

Near `LEAN_AXES`, add:

```js
// The closed family vocabulary, mapped to its i18n key. Values not in this map are ignored rather
// than rendered raw -- seed data and frontend can drift, and a raw kebab-case string on the page is
// worse than a missing row.
const FAMILY_LABEL_KEYS = {
  'universal-conscription': 'familyUniversalConscription',
  'conscription-exemption': 'familyConscriptionExemption',
  'conscription-split': 'familyConscriptionSplit',
  'conscription-by-incentive': 'familyConscriptionByIncentive',
  'constitutional-reform': 'familyConstitutionalReform',
  'judicial-restraint': 'familyJudicialRestraint',
  'welfare-state': 'familyWelfareState',
  'cost-of-living': 'familyCostOfLiving',
  'sectoral-budgeting': 'familySectoralBudgeting',
  'market-liberal': 'familyMarketLiberal',
  'not-economy-focused': 'familyNotEconomyFocused',
  'arab-representation': 'familyArabRepresentation',
  'jewish-arab-partnership': 'familyJewishArabPartnership',
  'reservist-movement': 'familyReservistMovement',
};

// Share of votes backing parties carrying `family`, counted ONLY over votes for parties that have a
// position on that family's dimension -- i.e. parties with a non-empty families array. A party with
// no families was never asked the question, so counting its voters in the denominator would answer a
// question they were not asked. Same rule as weightedAxisAverage's NULL-axis skip (Decision 8).
// Returns null when no vote in this breakdown is positioned at all.
function familyShare(upcomingBreakdown, family) {
  let withFamily = 0;
  let positioned = 0;
  upcomingBreakdown.forEach(r => {
    const party = partyById(r.party_id, 'upcoming_parties');
    if (!party || !party.families || party.families.length === 0) return;
    positioned += r.count;
    if (party.families.includes(family)) withFamily += r.count;
  });
  return positioned > 0 ? { share: withFamily / positioned, positioned } : null;
}
```

- [ ] **Step 2: Add the national baseline**

Next to `nationalPreviousBreakdown`, add:

```js
let nationalUpcomingData = null;

// National upcoming-party breakdown for the Traits baseline. Deliberately NOT a sum over
// clubsBreakdown (rollup_upcoming WHERE club_id IS NOT NULL): that would double-count multi-club
// ballots and silently drop league-only voters. /api/results?by=all reads the worker-computed,
// deduped rollup_national_upcoming -- same reasoning as nationalPreviousBreakdown above.
async function nationalUpcomingBreakdown() {
  if (!nationalUpcomingData) {
    const data = await fetchJSON('/api/results?by=all');
    nationalUpcomingData = data.upcoming;
  }
  return nationalUpcomingData;
}
```

- [ ] **Step 3: Add the renderer with its own club picker**

**There is no global "selected club" in this file.** The Lean tab renders *every* eligible club as a
strip and drives a detail card through `selectClub()`; the Switching tab builds its own `<select>` and
re-renders on change. Traits follows the **Switching** pattern — self-contained picker, no shared state:

```js
// Clubs with enough upcoming-election votes to say anything about. Mirrors allLeanClubRows()'s
// threshold and World-Cup filter, but counts the UPCOMING breakdown rather than the previous one.
function traitsEligibleClubs() {
  const wcLeagueId = worldCupLeagueId();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      const total = entry.upcoming.reduce((sum, r) => sum + r.count, 0);
      return { club, total, upcoming: entry.upcoming };
    })
    .filter(row => row !== null && row.total >= LEAN_MIN_VOTES)
    .filter(row => diversityIncludeWorldCup || row.club.league_id !== wcLeagueId)
    .sort((a, b) => localizedName(a.club).localeCompare(localizedName(b.club)));
}

// Top 3 families by over-representation against the national baseline. Only positive gaps are shown:
// a club whose fans are merely average on everything gets the empty-state line rather than filler.
// Shares do NOT sum to 100 -- one vote feeds every family its party carries -- so this renders as a
// list, never as a composition.
function renderTraitsRows(container, row, national) {
  container.innerHTML = '';
  const rows = Object.keys(FAMILY_LABEL_KEYS)
    .map(family => {
      const here = familyShare(row.upcoming, family);
      const base = familyShare(national, family);
      if (!here || !base) return null;
      return { family, share: here.share, base: base.share, gap: here.share - base.share };
    })
    .filter(r => r !== null && r.gap > 0)
    .sort((a, b) => b.gap - a.gap)
    .slice(0, 3);

  if (rows.length === 0) {
    const p = document.createElement('p');
    p.className = 'note';
    p.textContent = t('analyticsTraitsNone');
    container.appendChild(p);
    return;
  }

  rows.forEach(r => {
    const line = document.createElement('div');
    line.className = 'lean-detail-row';

    const label = document.createElement('span');
    label.textContent = t(FAMILY_LABEL_KEYS[r.family]);
    line.appendChild(label);

    const value = document.createElement('span');
    value.textContent = `${Math.round(r.share * 100)}% · `
      + t('analyticsTraitsNationalAvg').replace('{pct}', String(Math.round(r.base * 100)))
      + ` · +${Math.round(r.gap * 100)}`;
    line.appendChild(value);

    container.appendChild(line);
  });
}

async function renderTraitsTab() {
  const tab = document.getElementById('traits-tab');
  tab.innerHTML = '';

  const eligible = traitsEligibleClubs();
  if (!eligible.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('analyticsTooFewVotes');
    tab.appendChild(empty);
    return;
  }

  const field = document.createElement('label');
  field.className = 'field';
  const labelSpan = document.createElement('span');
  labelSpan.textContent = t('analyticsPickClub');
  field.appendChild(labelSpan);
  const picker = document.createElement('select');
  picker.id = 'traits-club-picker';
  eligible.forEach((row, i) => {
    const opt = document.createElement('option');
    opt.value = String(row.club.id);
    opt.textContent = localizedName(row.club);
    if (i === 0) opt.selected = true;
    picker.appendChild(opt);
  });
  field.appendChild(picker);
  tab.appendChild(field);

  const rowsContainer = document.createElement('div');
  rowsContainer.className = 'card';
  tab.appendChild(rowsContainer);

  const national = await nationalUpcomingBreakdown();
  const draw = () => {
    const row = eligible.find(r => String(r.club.id) === picker.value) || eligible[0];
    renderTraitsRows(rowsContainer, row, national);
  };
  picker.addEventListener('change', draw);
  draw();
}
```

`clubById` (`analytics.js:54`), `worldCupLeagueId`, `diversityIncludeWorldCup` and `localizedName` all
already exist — confirm each name against the file before use rather than trusting this listing.

- [ ] **Step 4: Wire it into the three render call sites**

`renderTraitsTab` is async while its siblings are not, so call it without awaiting — the tab paints
when its fetch resolves, exactly as the Lean tab's national view already does. Add
`renderTraitsTab();` beside each existing `renderSwitchingTab();` call (three sites, around
`analytics.js:672-681`).

- [ ] **Step 5: Verify in a browser**

```bash
cd services/frontend && python3 -m http.server 8000
```

Check, against a club with ≥10 upcoming votes:
- the Traits tab lists up to 3 families, highest gap first
- percentages do **not** sum to 100 (expected — they overlap)
- a club under 10 votes shows the too-few-votes line
- switching language to Hebrew and Russian relabels every row and flips RTL
- no raw kebab-case string (`welfare-state`) appears anywhere on the page

- [ ] **Step 6: Commit**

```bash
git add services/frontend/analytics.js
git commit -m "feat(results): compute and render club shared traits"
```

---

### Task 8: Documentation, and delete this plan

**Files:**
- Modify: `docs/design/2026-07-30-party-families-club-traits-design.md` (Verification outcome)
- Modify: `.claude/skills/voteball-api/SKILL.md` (clubs-breakdown response)
- Delete: `docs/superpowers/plans/2026-07-30-party-families-club-traits.md` and the
  `docs/superpowers/` tree

- [ ] **Step 1: Update the API skill**

`/api/results/clubs-breakdown` now returns an `upcoming` key per club. Update its response
description — the skill is the documented API surface and drifts silently otherwise.

- [ ] **Step 2: Fill in the design doc's Verification outcome**

Replace `*To be filled in after implementation, per the convention in this directory.*` with what
actually happened: test counts, anything the design got wrong, and any assignment that looked wrong
once real percentages appeared.

- [ ] **Step 3: Delete the plan and its directory**

```bash
git rm -r docs/superpowers/
```

This is required, not optional — `CLAUDE.md` mandates deleting an executed plan in the same commit as
the last task, and `docs/superpowers/` is the superpowers workflow's default output path, so it
regenerates every time a feature goes through this workflow.

- [ ] **Step 4: Full verification**

```bash
docker start voteball-test-db && sleep 3
cd services/backend && source .venv/bin/activate
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable python -m pytest tests/ -q
cd ../.. && scripts/tests/test-i18n-parity.sh
```

Expected: 150 passed, `i18n parity OK`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(families): record the verification outcome and remove the executed plan"
git push origin master
```

---

---

### Task 9: Local demo with fake votes (BEFORE any merge to master)

**Files:**
- Create: `scripts/dev/seed-fake-votes.py` (dev-only, never referenced by the app or any image)

**Interfaces:**
- Consumes: everything from Tasks 1–7
- Produces: a locally running stack with enough votes that the Traits tab has something to show

**Why:** the repo owner asked to see this working locally before it reaches `master`. Production has
single-digit votes, and `LEAN_MIN_VOTES = 10` means the tab renders an empty state until a club clears
ten upcoming-election votes. Without fake data there is nothing to look at.

- [ ] **Step 1: Write the generator**

Create `scripts/dev/seed-fake-votes.py`. It must:
- take `--votes N` (default 400) and `--db-url`, defaulting to the local test container
- for each fake vote: insert into `votes`, attach 1–3 `vote_clubs` rows drawn from real seeded clubs,
  and attach 1–3 `vote_upcoming_parties` rows
- **deliberately skew** a handful of named clubs toward particular parties, so the Traits tab shows
  real over-representation rather than noise — e.g. one club skewed toward `ש"ס`/`יהדות התורה`
  (should surface `welfare-state` + `sectoral-budgeting`), one toward `ישר`/`ביחד` (should surface
  `universal-conscription` + `constitutional-reform`), one toward `הציונות הדתית`/`עוצמה יהודית`
  (should surface `judicial-restraint`)
- print the skew map it used, so the rendered output can be checked against intent

It must NOT be added to any `Dockerfile` `COPY` line — this is a local dev tool and must never ship
in an image.

- [ ] **Step 2: Run the whole stack locally against the test database**

Seed schema + seed into a local database, run the generator, then start the backend and frontend
locally. Follow `docs/deploy.md` / the backend README for the local run; do not touch AWS.

- [ ] **Step 3: Check the rendered output against the skew map**

For each skewed club, confirm the Traits tab surfaces the families predicted in Step 1. If a club
skewed toward Shas and UTJ does **not** surface `welfare-state`, either the computation or a family
assignment is wrong — investigate before merging.

Also confirm: percentages do not sum to 100, the empty state appears for an unskewed club, and
Hebrew/Russian relabel every row.

- [ ] **Step 4: Screenshot and hand to the repo owner**

Capture the Traits tab in all three languages and send them. **Stop here — merging to `master` is the
owner's call, not the implementer's.** Jenkins is running, so a merge deploys to production.

- [ ] **Step 5: Commit**

```bash
git add scripts/dev/seed-fake-votes.py
git commit -m "chore(dev): fake-vote generator for local Traits verification"
```

---

## Self-Review

**Spec coverage:** every section of the design doc maps to a task — schema → 1, seed data → 2,
backend `get_options` → 3, backend `get_clubs_breakdown` → 4, i18n → 5, frontend markup → 6, frontend
compute/render → 7, docs → 8. The four tests the design names are in Tasks 1–4; Decision 8's
denominator rule is implemented in Task 7 Step 1 and commented there.

**Deliberate addition beyond the design:** `scripts/tests/test-i18n-parity.sh` (Task 5). The design
warns that `t()` returns the key on a miss and nothing in the repo catches that; 19 keys × 3 languages
is where it would bite. Flagged here so a reviewer can reject it without rejecting the feature.

**Known soft spots for the implementer:**
- Task 4 Step 1's fixture depends on this repo's existing vote-creation helpers, which vary across
  `test_queries.py`. Reuse the neighbouring rollup tests' approach rather than the sketch.
- Task 7's first draft called a `selectedClub()` helper that **does not exist** — there is no global
  selected-club state in `analytics.js`. The corrected task builds its own `<select>`, following
  `renderSwitchingTab`. Every helper it now names (`clubById`, `worldCupLeagueId`,
  `diversityIncludeWorldCup`, `localizedName`, `partyById`, `fetchJSON`) was verified to exist before
  this plan was committed.
- The `scripts/tests/test-i18n-parity.sh` parser in Task 5 was run against the current `i18n.js`
  before being written down: it finds all three languages at **157 keys each, currently in parity**.
  It should therefore pass unmodified at Task 5 Step 2, and report 176 each after Step 5.
