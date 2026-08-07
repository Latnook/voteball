# UEFA Nations League Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the UEFA Nations League as a ninth league displayed after the World Cup, with its four divisions (A–D) as headers inside one tab, and make a club that plays in two competitions count toward both leagues' results.

**Architecture:** One `leagues` row plus a new nullable `clubs.group_label` column carrying `'A'`–`'D'`. The 16 teams already present as World Cup rows are linked via `domestic_league_id`, never re-inserted. Dual-league counting is one edit to `_VOTE_LEAGUES_TOUCHED_CTE` in the worker, which is the single fragment every league-scope rollup number flows through.

**Tech Stack:** Postgres 17, Flask 3.1 backend, Python worker, vanilla JS frontend (no build step), pytest against a real Postgres container.

**Design doc:** `docs/design/2026-08-07-nations-league-design.md`. Read it before starting — every decision below is justified there.

## Global Constraints

- **Never add a `Claude-Session:` trailer or a `claude.ai/code/session_...` URL to any commit message.** This repo is public.
- **Commit and push after every task.** Never force-push.
- Test database: `docker start voteball-test-db` (or `docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17` the first time).
- Backend tests: `cd services/backend && source .venv/bin/activate && python -m pytest tests/ -v`. Install with `pip install -r requirements-dev.txt`, **not** `requirements.txt`.
- Worker tests: `cd services/worker && source .venv/bin/activate && python -m pytest tests/ -v`. The worker's tests load `services/backend/schema.sql`; the worker never creates schema.
- The `.venv`s are **not relocatable**. If a `ModuleNotFoundError` names an old path, delete and recreate the venv.
- `seed.sql` runs on **every backend pod boot** against an **already-seeded** database. A guarded statement only ever reaches a fresh database. Verify every seed change against a database seeded with the *previous* file.
- **`name_ru` must be genuine Cyrillic.** `test_seeded_russian_names_are_cyrillic` asserts `name_ru !~ '[A-Za-z]'` on all four tables.
- Adding a frontend file requires editing `services/frontend/Dockerfile`'s `COPY` line — **except** under `logos/`, which is copied as a whole directory.
- Hebrew apostrophes inside SQL string literals are doubled: `'אזרבייג''ן'`.

---

### Task 1: `clubs.group_label` column, exposed through `/api/options`

**Files:**
- Modify: `services/backend/schema.sql` (after the `sort_order` ALTER, ~line 79)
- Modify: `services/backend/queries.py:30-39` (`get_options`)
- Test: `services/backend/tests/test_queries.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `clubs.group_label TEXT` (nullable); every dict in `get_options(conn)['clubs']` gains key `'group_label'` with value `str | None`.

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_queries.py`. That file already has `import queries` at the top and a `conn` fixture from `conftest.py` that drops and recreates every table before each test — add nothing to either.

```python
def test_get_options_returns_club_group_label(conn):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO leagues (name, name_en) VALUES ('Nations League', 'Nations League') RETURNING id"
    )
    league_id = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en, group_label) "
        "VALUES (%s, 'Italy', 'Italy', 'A')",
        (league_id,)
    )
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en) VALUES (%s, 'Nowhere FC', 'Nowhere FC')",
        (league_id,)
    )
    conn.commit()
    cur.close()

    by_name = {c['name_en']: c for c in queries.get_options(conn)['clubs']}
    assert by_name['Italy']['group_label'] == 'A'
    assert by_name['Nowhere FC']['group_label'] is None


def test_rename_club_preserves_group_label(conn):
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO leagues (name, name_en) VALUES ('Nations League', 'Nations League') RETURNING id"
    )
    league_id = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO clubs (league_id, name, name_en, group_label) "
        "VALUES (%s, 'Italy', 'Italy', 'A') RETURNING id",
        (league_id,)
    )
    club_id = cur.fetchone()[0]
    conn.commit()
    cur.close()

    queries.rename_club(conn, club_id, league_id, None, 'Italy', 'איטליה', name_ru='Италия')

    cur = conn.cursor()
    cur.execute('SELECT group_label FROM clubs WHERE id = %s', (club_id,))
    assert cur.fetchone()[0] == 'A'
    cur.close()
```

The second test pins decision 5: `rename_club` must never name `group_label`, so no partial admin PATCH can blank it.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd services/backend && source .venv/bin/activate
python -m pytest tests/test_queries.py::test_get_options_returns_club_group_label tests/test_queries.py::test_rename_club_preserves_group_label -v
```

Expected: FAIL — `psycopg2.errors.UndefinedColumn: column "group_label" of relation "clubs" does not exist`.

- [ ] **Step 3: Add the column**

In `services/backend/schema.sql`, immediately after the `sort_order` ALTER and its comment:

```sql
-- Division label within the club's league -- the UEFA Nations League's A/B/C/D tiers, rendered as
-- headers inside the single Nations League tab (docs/design/2026-08-07-nations-league-design.md
-- decision 1). Nullable because every other league is undivided, and a club with no label renders
-- headerless above the first division rather than disappearing.
--
-- Deliberately NOT named by create_club/rename_club in queries.py (decision 5): those statements
-- replace every field they list, so an admin PATCH that forwarded a subset would write NULL here --
-- the same trap patchClubLeagues in admin.js already works around for the name columns.
ALTER TABLE clubs ADD COLUMN IF NOT EXISTS group_label TEXT;
```

- [ ] **Step 4: Return it from `get_options`**

In `services/backend/queries.py`, replace the clubs query and comprehension in `get_options`:

```python
    cur.execute(
        'SELECT id, league_id, domestic_league_id, name_en, name_he, name_ru, logo_url, group_label '
        'FROM clubs ORDER BY name_en'
    )
    clubs = [
        {
            'id': r[0], 'league_id': r[1], 'domestic_league_id': r[2],
            'name_en': r[3], 'name_he': r[4], 'name_ru': r[5], 'logo_url': r[6],
            'group_label': r[7],
        }
        for r in cur.fetchall()
    ]
```

- [ ] **Step 5: Run the full backend suite**

```bash
cd services/backend && source .venv/bin/activate && python -m pytest tests/ -v
```

Expected: all pass.

- [ ] **Step 6: Commit and push**

```bash
git add services/backend/schema.sql services/backend/queries.py services/backend/tests/test_queries.py
git commit -m "feat(db): add clubs.group_label for league divisions"
git push origin master
```

---

### Task 2: Count a dual-league club toward both leagues

**Files:**
- Modify: `services/worker/rollups.py:1-18` (module comment and `_VOTE_LEAGUES_TOUCHED_CTE`)
- Test: `services/worker/tests/test_rollups.py`

**Interfaces:**
- Consumes: nothing.
- Produces: no signature change. `_VOTE_LEAGUES_TOUCHED_CTE` keeps its name and its `(vote_id, league_id)` shape, so all five `_recompute_*` functions are untouched.

- [ ] **Step 1: Write the failing tests**

Append to `services/worker/tests/test_rollups.py`:

```python
def _seed_dual_league_vote(conn):
    """One ballot picking a club that plays in two leagues, filed under only one of them.

    This is the Real Madrid shape: league_id=UCL, domestic_league_id=La Liga, and the pick filed
    under La Liga because that is what dedupedTeamPicks() in vote.js chooses.
    """
    cur = conn.cursor()
    cur.execute("INSERT INTO leagues (name) VALUES ('La Liga') RETURNING id")
    la_liga = cur.fetchone()[0]
    cur.execute("INSERT INTO leagues (name) VALUES ('UCL') RETURNING id")
    ucl = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO clubs (league_id, domestic_league_id, name) "
        "VALUES (%s, %s, 'Real Madrid') RETURNING id",
        (ucl, la_liga)
    )
    club_id = cur.fetchone()[0]
    cur.execute("INSERT INTO previous_parties (name) VALUES ('Party X') RETURNING id")
    party_x = cur.fetchone()[0]
    cur.execute(
        '''INSERT INTO votes (previous_vote_status, previous_party_id, upcoming_vote_status, cookie_token)
           VALUES ('voted', %s, 'undecided', 'dual1') RETURNING id''',
        (party_x,)
    )
    vote_id = cur.fetchone()[0]
    cur.execute(
        'INSERT INTO vote_clubs (vote_id, club_id, league_id) VALUES (%s, %s, %s)',
        (vote_id, club_id, la_liga)
    )
    conn.commit()
    cur.close()
    return la_liga, ucl, club_id, party_x


def test_dual_league_club_counts_at_both_leagues_scope(conn):
    import rollups
    la_liga, ucl, _club_id, party_x = _seed_dual_league_vote(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT league_id, vote_count FROM rollup_previous '
        'WHERE club_id IS NULL AND previous_party_id = %s ORDER BY league_id',
        (party_x,)
    )
    assert sorted(cur.fetchall()) == sorted([(la_liga, 1), (ucl, 1)])
    cur.close()


def test_dual_league_club_has_exactly_one_club_scope_row(conn):
    # The reason two vote_clubs rows were rejected in favour of this CTE change: ?by=club filters on
    # club_id with NO league predicate (queries.py _results_for_filter), so a second club-scope row
    # would SUM() one voter into two.
    import rollups
    _la_liga, _ucl, club_id, party_x = _seed_dual_league_vote(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT SUM(vote_count) FROM rollup_previous WHERE club_id = %s AND previous_party_id = %s',
        (club_id, party_x)
    )
    assert cur.fetchone()[0] == 1
    cur.close()


def test_dual_league_club_does_not_change_national_totals(conn):
    import rollups
    _la_liga, _ucl, _club_id, party_x = _seed_dual_league_vote(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT SUM(vote_count) FROM rollup_national_previous WHERE previous_party_id = %s',
        (party_x,)
    )
    assert cur.fetchone()[0] == 1
    cur.close()


def test_dual_league_club_counts_at_both_leagues_in_vote_switch(conn):
    import rollups
    la_liga, ucl, _club_id, _party_x = _seed_dual_league_vote(conn)

    rollups.recompute(conn)

    cur = conn.cursor()
    cur.execute(
        'SELECT DISTINCT league_id FROM rollup_vote_switch WHERE club_id IS NULL ORDER BY league_id'
    )
    assert sorted(r[0] for r in cur.fetchall()) == sorted([la_liga, ucl])
    cur.close()
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd services/worker && source .venv/bin/activate
python -m pytest tests/test_rollups.py -k dual_league -v
```

Expected: `test_dual_league_club_counts_at_both_leagues_scope` and `..._in_vote_switch` FAIL (only `la_liga` appears — the UCL row is missing). The other two PASS already; they are regression guards for what must **not** change.

- [ ] **Step 3: Change the CTE**

In `services/worker/rollups.py`, replace lines 6–18 (the second half of the module comment plus the CTE) with:

```python
# "Distinct league touched" is derived from the CLUB's real memberships, not from the tab the pick
# was filed under. A club can play in two leagues (clubs.league_id + clubs.domestic_league_id) but
# vote_clubs.league_id records only one of them, and which one depends on which column that club
# happened to be seeded into -- so counting by it alone put Real Madrid fans in La Liga only and
# Real Betis fans in the Champions League only, though both clubs play in both competitions. See
# docs/design/2026-08-07-nations-league-design.md decision 3.
#
# UNION deduplicates, so a voter who picks three clubs in one league still yields one league-scope
# row for it. Club-scope rows are deliberately NOT expanded the same way: ?by=club filters on
# club_id with no league predicate (queries.py _results_for_filter), so a second club-scope row per
# vote would SUM() one voter into two. A vote_leagues row is a "just this league, no club" pick.
_VOTE_LEAGUES_TOUCHED_CTE = '''
    SELECT vc.vote_id, c.league_id FROM vote_clubs vc JOIN clubs c ON c.id = vc.club_id
    UNION
    SELECT vc.vote_id, c.domestic_league_id FROM vote_clubs vc JOIN clubs c ON c.id = vc.club_id
    WHERE c.domestic_league_id IS NOT NULL
    UNION
    SELECT vote_id, league_id FROM vote_leagues
'''
```

- [ ] **Step 4: Run the full worker suite**

```bash
cd services/worker && source .venv/bin/activate && python -m pytest tests/ -v
```

Expected: all pass, including the pre-existing `test_recompute_league_scope_dedups_multi_club_ballot`, `test_recompute_national_tables_count_multi_pick_vote_once` and `test_recompute_just_league_pick_counts_at_league_scope_only`.

- [ ] **Step 5: Commit and push**

```bash
git add services/worker/rollups.py services/worker/tests/test_rollups.py
git commit -m "fix(rollups): count a dual-league club toward both of its leagues"
git push origin master
```

---

### Task 3: The Nations League row and its cropped emblem

**Files:**
- Create: `services/frontend/logos/uefa-nations-league.svg`
- Modify: `services/backend/seed.sql` (leagues INSERT ~line 18; league names block ~line 255; sort_order block ~line 275; league logos block ~line 289)
- Test: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: nothing.
- Produces: a `leagues` row with `name = 'Nations League'`, `name_en = 'Nations League'`, `name_he = 'ליגת האומות'`, `name_ru = 'Лига наций УЕФА'`, `sort_order = 8`, `logo_url = '/logos/uefa-nations-league.svg'`. Tasks 4 and 5 look it up by `name = 'Nations League' OR name_en = 'Nations League'`.

- [ ] **Step 1: Build the cropped emblem**

The source SVG has **no `<text>` elements** — the wordmark is outlined paths, so this is a `viewBox` crop and no path data changes. The numbers below were measured by rendering the file and finding the flag's bounding box (`x` 23–217, flag ink ends at `y` 224; the pole continues to 277 carrying the wordmark beside it).

```bash
curl -sL -A "Mozilla/5.0" -o /tmp/nl-source.svg \
  "https://upload.wikimedia.org/wikipedia/en/8/80/UEFA_Nations_League.svg"
sed 's|width="260px" height="383px" viewBox="0 0 260 381"|width="201px" height="208px" viewBox="20 21 201 208"|' \
  /tmp/nl-source.svg > services/frontend/logos/uefa-nations-league.svg
```

- [ ] **Step 2: Verify the crop applied and renders**

```bash
grep -c 'viewBox="20 21 201 208"' services/frontend/logos/uefa-nations-league.svg   # expect 1
grep -c '<text' services/frontend/logos/uefa-nations-league.svg                     # expect 0
rsvg-convert -w 402 -h 416 services/frontend/logos/uefa-nations-league.svg -o /tmp/nl-check.png
```

Open `/tmp/nl-check.png`. Expected: the multicoloured waving flag on its pole, **no lettering of any kind**. If any part of "UEFA" is visible, reduce the viewBox height; if the flag's bottom tip is clipped, raise it.

No `Dockerfile` edit is needed — `services/frontend/logos/` is copied as a whole directory, unlike every other frontend file.

- [ ] **Step 3: Write the failing test**

Append to `services/backend/tests/test_migration.py`:

```python
def test_nations_league_is_seeded_after_the_world_cup(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT name_en, name_he, name_ru, sort_order, logo_url FROM leagues "
        "WHERE name_en = 'Nations League'"
    )
    row = cur.fetchone()
    assert row is not None, 'Nations League league row is missing'
    name_en, name_he, name_ru, sort_order, logo_url = row
    assert (name_he, name_ru) == ('ליגת האומות', 'Лига наций УЕФА')
    assert logo_url == '/logos/uefa-nations-league.svg'

    cur.execute("SELECT sort_order FROM leagues WHERE name_en = 'World Cup 2026'")
    world_cup_order = cur.fetchone()[0]
    assert sort_order > world_cup_order
    cur.close()
```

- [ ] **Step 4: Run it to verify it fails**

```bash
cd services/backend && source .venv/bin/activate
python -m pytest tests/test_migration.py::test_nations_league_is_seeded_after_the_world_cup -v
```

Expected: FAIL on `Nations League league row is missing`.

- [ ] **Step 5: Add the league to `seed.sql`**

Four edits.

**(a)** In the leagues `INSERT`'s `VALUES`, add to the end of the list:

```sql
    ('Liga Leumit'), ('Nations League')
```

**(b)** In the league display-names `VALUES` block, add a row:

```sql
    ('Nations League', 'ליגת האומות', 'Лига наций УЕФА')
```

**(c)** After the existing `sort_order` statements:

```sql
UPDATE leagues SET sort_order = 8 WHERE name_en = 'Nations League';
```

**(d)** In the league logos `VALUES` block, add a row. Self-hosted rather than hotlinked because the file is a crop this repo produced:

```sql
    ('Nations League', '/logos/uefa-nations-league.svg')
```

- [ ] **Step 6: Update the seeded league count**

In `services/backend/tests/test_migration.py::test_seeded_row_counts`, change the leagues assertion from `8` to `9`.

- [ ] **Step 7: Run the full backend suite**

```bash
cd services/backend && source .venv/bin/activate && python -m pytest tests/ -v
```

Expected: all pass.

- [ ] **Step 8: Commit and push**

```bash
git add services/backend/seed.sql services/backend/tests/test_migration.py services/frontend/logos/uefa-nations-league.svg
git commit -m "feat(seed): add the UEFA Nations League with a text-free emblem"
git push origin master
```

---

### Task 4: The 38 new national teams

**Files:**
- Modify: `services/backend/seed.sql` (clubs INSERT `VALUES`; club names block; a new crest block; a new division-label block)
- Test: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: the `Nations League` row from Task 3; `clubs.group_label` from Task 1.
- Produces: 38 new `clubs` rows with `league_id` = Nations League, all four name columns populated, `logo_url` set, and `group_label` in `'A'|'B'|'C'|'D'`. Task 5 adds the remaining 16 by linking.

- [ ] **Step 1: Write the failing tests**

Append to `services/backend/tests/test_migration.py`:

```python
NATIONS_LEAGUE_INSERTED_NATIONS = [
    'Albania', 'Andorra', 'Armenia', 'Azerbaijan', 'Belarus', 'Bulgaria', 'Cyprus', 'Denmark',
    'Estonia', 'Faroe Islands', 'Finland', 'Georgia', 'Gibraltar', 'Greece', 'Hungary', 'Iceland',
    'Israel', 'Italy', 'Kazakhstan', 'Kosovo', 'Latvia', 'Liechtenstein', 'Lithuania', 'Luxembourg',
    'Malta', 'Moldova', 'Montenegro', 'North Macedonia', 'Northern Ireland', 'Poland',
    'Republic of Ireland', 'Romania', 'San Marino', 'Serbia', 'Slovakia', 'Slovenia', 'Ukraine',
    'Wales',
]


def test_nations_league_inserted_nations_are_seeded_with_divisions(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en, c.group_label
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id
           WHERE l.name_en = 'Nations League'"""
    )
    seeded = dict(cur.fetchall())
    assert sorted(seeded) == sorted(NATIONS_LEAGUE_INSERTED_NATIONS)
    assert all(label in ('A', 'B', 'C', 'D') for label in seeded.values()), seeded
    cur.close()


def test_every_nations_league_team_has_a_crest_and_three_names(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'
             AND (c.logo_url IS NULL OR c.name_he IS NULL OR c.name_ru IS NULL)"""
    )
    assert cur.fetchall() == []
    cur.close()
```

Both tests join on `c.league_id` only — the 16 linked nations arrive in Task 5 via `domestic_league_id`, and the full 54-team, four-division assertion lives there. Nothing committed by this task is expected to fail.

- [ ] **Step 2: Run to verify it fails**

```bash
cd services/backend && source .venv/bin/activate
python -m pytest tests/test_migration.py -k nations_league -v
```

Expected: FAIL — the divisions query returns `{}`.

- [ ] **Step 3: Insert the 38 clubs**

In `seed.sql`'s clubs `INSERT ... VALUES` block, after the `Liga Leumit` rows (add a comma to the previous final tuple):

```sql
    -- UEFA Nations League: the 38 nations NOT already seeded as World Cup 2026 teams. The other 16
    -- are linked via domestic_league_id further down -- clubs_name_en_uidx is global, so a second
    -- 'France' row is impossible, and they keep their existing crest and names.
    ('Nations League', 'Italy'), ('Nations League', 'Serbia'), ('Nations League', 'Greece'),
    ('Nations League', 'Denmark'), ('Nations League', 'Wales'), ('Nations League', 'Slovenia'),
    ('Nations League', 'North Macedonia'), ('Nations League', 'Hungary'),
    ('Nations League', 'Ukraine'), ('Nations League', 'Georgia'),
    ('Nations League', 'Northern Ireland'), ('Nations League', 'Israel'),
    ('Nations League', 'Republic of Ireland'), ('Nations League', 'Kosovo'),
    ('Nations League', 'Poland'), ('Nations League', 'Romania'),
    ('Nations League', 'Albania'), ('Nations League', 'Finland'), ('Nations League', 'Belarus'),
    ('Nations League', 'San Marino'), ('Nations League', 'Montenegro'),
    ('Nations League', 'Armenia'), ('Nations League', 'Cyprus'), ('Nations League', 'Latvia'),
    ('Nations League', 'Kazakhstan'), ('Nations League', 'Slovakia'),
    ('Nations League', 'Faroe Islands'), ('Nations League', 'Moldova'),
    ('Nations League', 'Iceland'), ('Nations League', 'Bulgaria'), ('Nations League', 'Estonia'),
    ('Nations League', 'Luxembourg'), ('Nations League', 'Gibraltar'), ('Nations League', 'Malta'),
    ('Nations League', 'Andorra'), ('Nations League', 'Lithuania'),
    ('Nations League', 'Azerbaijan'), ('Nations League', 'Liechtenstein')
```

Spelled **Liechtenstein** — the source roster read "Lichtenstein".

- [ ] **Step 4: Add their names**

In the club display-names `VALUES` block, after the Liga Leumit rows:

```sql
    -- UEFA Nations League nations not already listed above as World Cup teams
    ('Italy', 'איטליה', 'Италия'),
    ('Serbia', 'סרביה', 'Сербия'),
    ('Greece', 'יוון', 'Греция'),
    ('Denmark', 'דנמרק', 'Дания'),
    ('Wales', 'ויילס', 'Уэльс'),
    ('Slovenia', 'סלובניה', 'Словения'),
    ('North Macedonia', 'צפון מקדוניה', 'Северная Македония'),
    ('Hungary', 'הונגריה', 'Венгрия'),
    ('Ukraine', 'אוקראינה', 'Украина'),
    ('Georgia', 'גאורגיה', 'Грузия'),
    ('Northern Ireland', 'צפון אירלנד', 'Северная Ирландия'),
    ('Israel', 'ישראל', 'Израиль'),
    ('Republic of Ireland', 'אירלנד', 'Ирландия'),
    ('Kosovo', 'קוסובו', 'Косово'),
    ('Poland', 'פולין', 'Польша'),
    ('Romania', 'רומניה', 'Румыния'),
    ('Albania', 'אלבניה', 'Албания'),
    ('Finland', 'פינלנד', 'Финляндия'),
    ('Belarus', 'בלארוס', 'Беларусь'),
    ('San Marino', 'סן מרינו', 'Сан-Марино'),
    ('Montenegro', 'מונטנגרו', 'Черногория'),
    ('Armenia', 'ארמניה', 'Армения'),
    ('Cyprus', 'קפריסין', 'Кипр'),
    ('Latvia', 'לטביה', 'Латвия'),
    ('Kazakhstan', 'קזחסטן', 'Казахстан'),
    ('Slovakia', 'סלובקיה', 'Словакия'),
    ('Faroe Islands', 'איי פארו', 'Фарерские острова'),
    ('Moldova', 'מולדובה', 'Молдова'),
    ('Iceland', 'איסלנד', 'Исландия'),
    ('Bulgaria', 'בולגריה', 'Болгария'),
    ('Estonia', 'אסטוניה', 'Эстония'),
    ('Luxembourg', 'לוקסמבורג', 'Люксембург'),
    ('Gibraltar', 'גיברלטר', 'Гибралтар'),
    ('Malta', 'מלטה', 'Мальта'),
    ('Andorra', 'אנדורה', 'Андорра'),
    ('Lithuania', 'ליטא', 'Литва'),
    ('Azerbaijan', 'אזרבייג''ן', 'Азербайджан'),
    ('Liechtenstein', 'ליכטנשטיין', 'Лихтенштейн')
```

Note the doubled apostrophe in `'אזרבייג''ן'`.

- [ ] **Step 5: Add their crests**

A **new** block, placed after the existing World Cup crest block. All 38 URLs were HEAD-checked and return 200.

**Do not add the 16 linked teams here.** This block is keyed on `name_en`, and a `VALUES` block *joins* — a duplicate key lets Postgres match arbitrarily rather than resolving by file order.

```sql
-- UEFA Nations League national-team crests: federation badges, same sourcing rule as the World Cup
-- block above. Only the 38 nations this file inserts -- the 16 that are also World Cup teams already
-- carry a crest from that block, and repeating a name_en key here would make the join ambiguous.
UPDATE clubs c SET logo_url = v.logo_url
FROM (VALUES
    ('Italy', 'https://upload.wikimedia.org/wikipedia/commons/b/bf/Logo_Italy_National_Football_Team_-_2023.svg'),
    ('Serbia', 'https://upload.wikimedia.org/wikipedia/en/e/eb/Football_Association_of_Serbia_logo.svg'),
    ('Greece', 'https://upload.wikimedia.org/wikipedia/commons/5/50/Greece_National_Football_Team.svg'),
    ('Denmark', 'https://upload.wikimedia.org/wikipedia/commons/9/9d/Dansk_boldspil_union_logo.svg'),
    ('Wales', 'https://upload.wikimedia.org/wikipedia/en/d/dc/Wales_national_football_team_logo.svg'),
    ('Slovenia', 'https://upload.wikimedia.org/wikipedia/en/9/99/Slovenia_national_football_team.svg'),
    ('North Macedonia', 'https://upload.wikimedia.org/wikipedia/commons/3/34/Coat_of_arms_of_the_President_of_North_Macedonia.svg'),
    ('Hungary', 'https://upload.wikimedia.org/wikipedia/commons/3/34/Coat_of_arms_of_Hungary.svg'),
    ('Ukraine', 'https://upload.wikimedia.org/wikipedia/commons/9/9b/Logo_F%C3%A9d%C3%A9ration_Ukraine_Football_2016.svg'),
    ('Georgia', 'https://upload.wikimedia.org/wikipedia/en/9/9c/Georgia_national_football_team_crest.svg'),
    ('Northern Ireland', 'https://upload.wikimedia.org/wikipedia/en/2/25/Irish_Football_Association_logo.svg'),
    ('Israel', 'https://upload.wikimedia.org/wikipedia/en/5/5a/Israel_Football_Association_logo.svg'),
    ('Republic of Ireland', 'https://upload.wikimedia.org/wikipedia/en/f/f8/Republic_of_Ireland_national_football_team_crest.svg'),
    ('Kosovo', 'https://upload.wikimedia.org/wikipedia/commons/8/85/Kosovo_National_Football_Team.svg'),
    ('Poland', 'https://upload.wikimedia.org/wikipedia/commons/c/c9/Herb_Polski.svg'),
    ('Romania', 'https://upload.wikimedia.org/wikipedia/en/e/ef/Romania_national_football_team_logo.svg'),
    ('Albania', 'https://upload.wikimedia.org/wikipedia/commons/3/30/Stema_e_Fanell%C3%ABs_s%C3%AB_Komb%C3%ABtares.svg'),
    ('Finland', 'https://upload.wikimedia.org/wikipedia/commons/8/80/Finland_national_football_team_crest.png'),
    ('Belarus', 'https://upload.wikimedia.org/wikipedia/commons/4/48/Coat_of_arms_of_Belarus_(2020%E2%80%93present).svg'),
    ('San Marino', 'https://upload.wikimedia.org/wikipedia/commons/3/30/San-marino-logo.png'),
    ('Montenegro', 'https://upload.wikimedia.org/wikipedia/en/7/78/Football_Association_of_Montenegro_logo.svg'),
    ('Armenia', 'https://upload.wikimedia.org/wikipedia/commons/0/0f/Coat_of_arms_of_Armenia.svg'),
    ('Cyprus', 'https://upload.wikimedia.org/wikipedia/en/6/6b/Cyprus_national_football_team_logo.png'),
    ('Latvia', 'https://upload.wikimedia.org/wikipedia/en/7/7b/Latvia_national_team_logo.png'),
    ('Kazakhstan', 'https://upload.wikimedia.org/wikipedia/en/0/08/Kazakhstan_Football_Federation_logo.svg'),
    ('Slovakia', 'https://upload.wikimedia.org/wikipedia/en/8/8a/Slovak_Football_Association_logo.svg'),
    ('Faroe Islands', 'https://upload.wikimedia.org/wikipedia/commons/b/b5/Faroe_Islands_Football_Association_logo.svg'),
    ('Moldova', 'https://upload.wikimedia.org/wikipedia/en/c/c9/Moldova_national_football_team.svg'),
    ('Iceland', 'https://upload.wikimedia.org/wikipedia/en/6/6d/Iceland_national_football_team_logo.svg'),
    ('Bulgaria', 'https://upload.wikimedia.org/wikipedia/en/1/11/Bgnatcrest.png'),
    ('Estonia', 'https://upload.wikimedia.org/wikipedia/en/a/a2/Estonian_Football_Association_logo.svg'),
    ('Luxembourg', 'https://upload.wikimedia.org/wikipedia/en/9/9d/Luxembourg_national_football_team_crest.png'),
    ('Gibraltar', 'https://upload.wikimedia.org/wikipedia/en/f/fe/Gibraltar_Football_Association_(2020).svg'),
    ('Malta', 'https://upload.wikimedia.org/wikipedia/commons/b/b3/Malta_national_football_team_crest.svg'),
    ('Andorra', 'https://upload.wikimedia.org/wikipedia/commons/4/4e/Coat_of_arms_of_Andorra.svg'),
    ('Lithuania', 'https://upload.wikimedia.org/wikipedia/en/8/89/Badge_of_Lithuania_national_football_teams.png'),
    ('Azerbaijan', 'https://upload.wikimedia.org/wikipedia/en/5/5e/AFFA_logo.png'),
    ('Liechtenstein', 'https://upload.wikimedia.org/wikipedia/commons/c/c0/Crown_of_Liechtenstein.svg')
) AS v(name_en, logo_url)
WHERE c.name_en = v.name_en
  AND c.logo_url IS NULL;
```

- [ ] **Step 6: Add the division labels**

A new block, after the crest block. It covers **all 54** — including the 16 linked in Task 5, whose rows already exist.

```sql
-- UEFA Nations League divisions. UNGUARDED, deliberately: nothing else in the app writes
-- group_label (it is absent from create_club/rename_club by design -- see the schema.sql comment),
-- so there is no admin edit to protect, and promotion/relegation between the four divisions has to
-- be able to reach an already-seeded production database. A guarded form would make every future
-- division change unreachable there, which is the same trap the ideology-axis UPDATEs avoid.
-- Keyed on name_en, the stable identity: the legacy `name` column drifts to name_he on any admin save.
UPDATE clubs c SET group_label = v.group_label
FROM (VALUES
    ('Belgium', 'A'), ('Croatia', 'A'), ('Czech Republic', 'A'), ('Denmark', 'A'),
    ('England', 'A'), ('France', 'A'), ('Germany', 'A'), ('Greece', 'A'),
    ('Italy', 'A'), ('Netherlands', 'A'), ('Norway', 'A'), ('Portugal', 'A'),
    ('Serbia', 'A'), ('Spain', 'A'), ('Turkey', 'A'), ('Wales', 'A'),

    ('Austria', 'B'), ('Bosnia and Herzegovina', 'B'), ('Georgia', 'B'), ('Hungary', 'B'),
    ('Israel', 'B'), ('Kosovo', 'B'), ('North Macedonia', 'B'), ('Northern Ireland', 'B'),
    ('Poland', 'B'), ('Republic of Ireland', 'B'), ('Romania', 'B'), ('Scotland', 'B'),
    ('Slovenia', 'B'), ('Sweden', 'B'), ('Switzerland', 'B'), ('Ukraine', 'B'),

    ('Albania', 'C'), ('Armenia', 'C'), ('Belarus', 'C'), ('Bulgaria', 'C'),
    ('Cyprus', 'C'), ('Estonia', 'C'), ('Faroe Islands', 'C'), ('Finland', 'C'),
    ('Iceland', 'C'), ('Kazakhstan', 'C'), ('Latvia', 'C'), ('Luxembourg', 'C'),
    ('Moldova', 'C'), ('Montenegro', 'C'), ('San Marino', 'C'), ('Slovakia', 'C'),

    ('Andorra', 'D'), ('Azerbaijan', 'D'), ('Gibraltar', 'D'), ('Liechtenstein', 'D'),
    ('Lithuania', 'D'), ('Malta', 'D')
) AS v(name_en, group_label)
WHERE c.name_en = v.name_en;
```

- [ ] **Step 7: Update the seeded club count**

In `test_seeded_row_counts`, change the clubs assertion from `167` to `205`.

- [ ] **Step 8: Run the full backend suite**

```bash
cd services/backend && source .venv/bin/activate && python -m pytest tests/ -v
```

Expected: **all pass**. `test_seeded_russian_names_are_cyrillic` is the one to watch — if it fails, a name above contains a Latin homoglyph (e.g. a Latin `C` inside `Сербия`).

- [ ] **Step 9: Commit and push**

```bash
git add services/backend/seed.sql services/backend/tests/test_migration.py
git commit -m "feat(seed): add the 38 Nations League nations with crests and divisions"
git push origin master
```

---

### Task 5: Link the 16 nations already seeded as World Cup teams

**Files:**
- Modify: `services/backend/seed.sql` (after the existing UCL `domestic_league_id` blocks)
- Test: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: the Nations League row (Task 3), the division labels (Task 4).
- Produces: 16 existing `clubs` rows gain `domestic_league_id` = Nations League, keeping `league_id` = World Cup 2026. After this, 54 clubs are votable under the Nations League.

- [ ] **Step 1: Write the failing test**

Append to `services/backend/tests/test_migration.py`:

```python
LINKED_WORLD_CUP_NATIONS = [
    'Austria', 'Belgium', 'Bosnia and Herzegovina', 'Croatia', 'Czech Republic', 'England',
    'France', 'Germany', 'Netherlands', 'Norway', 'Portugal', 'Scotland', 'Spain', 'Sweden',
    'Switzerland', 'Turkey',
]


def test_shared_nations_are_linked_not_duplicated(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT name_en, COUNT(*) FROM clubs WHERE name_en = ANY(%s) GROUP BY name_en HAVING COUNT(*) > 1",
        (LINKED_WORLD_CUP_NATIONS,)
    )
    assert cur.fetchall() == [], 'a shared nation was inserted twice instead of linked'

    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues wc ON wc.id = c.league_id AND wc.name_en = 'World Cup 2026'
           JOIN leagues nl ON nl.id = c.domestic_league_id AND nl.name_en = 'Nations League'
           WHERE c.name_en = ANY(%s)""",
        (LINKED_WORLD_CUP_NATIONS,)
    )
    assert sorted(r[0] for r in cur.fetchall()) == sorted(LINKED_WORLD_CUP_NATIONS)
    cur.close()


def test_nations_league_has_54_votable_teams(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT COUNT(*) FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'"""
    )
    assert cur.fetchone()[0] == 54
    cur.close()


def test_nations_league_divisions_are_fully_populated(conn):
    cur = conn.cursor()
    cur.execute(
        """SELECT c.group_label, COUNT(*)
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'
           GROUP BY c.group_label"""
    )
    assert dict(cur.fetchall()) == {'A': 16, 'B': 16, 'C': 16, 'D': 6}
    cur.close()


def test_every_nations_league_team_including_linked_has_a_crest(conn):
    # The 16 linked nations must keep the crest and names their World Cup row already carries --
    # they are deliberately absent from the Nations League crest block (a duplicate name_en key in a
    # VALUES block makes the join ambiguous), so this is what proves they were not left blank.
    cur = conn.cursor()
    cur.execute(
        """SELECT c.name_en
           FROM clubs c
           JOIN leagues l ON l.id = c.league_id OR l.id = c.domestic_league_id
           WHERE l.name_en = 'Nations League'
             AND (c.logo_url IS NULL OR c.name_he IS NULL OR c.name_ru IS NULL)"""
    )
    assert cur.fetchall() == []
    cur.close()
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd services/backend && source .venv/bin/activate
python -m pytest tests/test_migration.py -k "shared_nations or 54_votable or divisions_are_fully or including_linked" -v
```

Expected: FAIL — the link join returns no rows, the count is 38, and the divisions read `{'A': 5, 'B': 11, 'C': 16, 'D': 6}`.

- [ ] **Step 3: Add the link statement**

In `seed.sql`, after the last of the existing `domestic_league_id` blocks:

```sql
-- The 16 nations that play in BOTH the 2026 World Cup and the UEFA Nations League. They keep
-- league_id = World Cup 2026 and gain the Nations League as their second league, so they appear
-- under both tabs with their existing crest and names. clubs_name_en_uidx is global, so inserting a
-- second 'France' row is impossible -- linking is the only option, and it is also what makes
-- toggleClub's mirroring ("picked in one tab, picked in the other") work with no frontend change.
--
-- Keyed on name_en rather than the legacy `name` column used by the UCL blocks above: `name` is
-- overwritten with name_he by queries.py's rename_league/rename_club on any admin save, so a
-- name-keyed match silently stops finding an admin-touched row.
UPDATE clubs SET domestic_league_id =
    (SELECT id FROM leagues WHERE name = 'Nations League' OR name_en = 'Nations League')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'World Cup 2026' OR name_en = 'World Cup 2026')
  AND name_en IN ('Austria', 'Belgium', 'Bosnia and Herzegovina', 'Croatia', 'Czech Republic',
                  'England', 'France', 'Germany', 'Netherlands', 'Norway', 'Portugal', 'Scotland',
                  'Spain', 'Sweden', 'Switzerland', 'Turkey');
```

- [ ] **Step 4: Run the full backend suite**

```bash
cd services/backend && source .venv/bin/activate && python -m pytest tests/ -v
```

Expected: all pass. `test_nations_league_divisions_are_fully_populated` now returns `{'A': 16, 'B': 16, 'C': 16, 'D': 6}` — that jump from `{'A': 5, 'B': 11, ...}` is what proves the link statement matched all 16 rows rather than some of them.

- [ ] **Step 5: Prove the change reaches an already-seeded database**

Every guarded statement in `seed.sql` only ever reaches a fresh database. This is the check that matters, and a fresh database proves nothing.

```bash
git stash                      # back to the pre-Nations-League seed.sql
docker exec voteball-test-db psql -U postgres -c 'DROP DATABASE IF EXISTS oldseed;'
docker exec voteball-test-db psql -U postgres -c 'CREATE DATABASE oldseed;'
docker exec -i voteball-test-db psql -U postgres -d oldseed < services/backend/schema.sql
docker exec -i voteball-test-db psql -U postgres -d oldseed < services/backend/seed.sql
git stash pop                  # back to the new seed.sql
docker exec -i voteball-test-db psql -U postgres -d oldseed < services/backend/schema.sql
docker exec -i voteball-test-db psql -U postgres -d oldseed < services/backend/seed.sql
docker exec voteball-test-db psql -U postgres -d oldseed -c \
  "SELECT group_label, COUNT(*) FROM clubs c JOIN leagues l
     ON l.id = c.league_id OR l.id = c.domestic_league_id
   WHERE l.name_en = 'Nations League' GROUP BY group_label ORDER BY group_label;"
```

Expected: `A 16 / B 16 / C 16 / D 6`. Then run the whole file a third time against `oldseed` and confirm the counts are unchanged — `init_db` runs it on every pod boot, so it has to be idempotent.

- [ ] **Step 6: Commit and push**

```bash
git add services/backend/seed.sql services/backend/tests/test_migration.py
git commit -m "feat(seed): link the 16 shared World Cup nations into the Nations League"
git push origin master
```

---

### Task 6: Division headers on the voting form

**Files:**
- Modify: `services/frontend/i18n.js` (all three language objects)
- Modify: `services/frontend/vote.js:126-163` (`renderTeamGrid`, plus a new helper above it)
- Modify: `services/frontend/style.css` (near the `.card-grid` rules, ~line 426)
- Test: `scripts/tests/test-i18n-parity.sh`

**Interfaces:**
- Consumes: `club.group_label` from `/api/options` (Task 1), populated by Task 4.
- Produces: `groupedClubsForLeague(leagueId)` returning `Array<{label: string|null, clubs: Array<club>}>`; i18n key `voteTeamGroupHeader`; CSS class `.team-group-header`.

- [ ] **Step 1: Add the i18n key to all three languages**

In `services/frontend/i18n.js`, add next to `voteClubPlaceholderOption` in **each** of the `en`, `he` and `ru` objects. All three must carry the same key and the same `{label}` token — `t()` returns the key itself on a miss, so a gap renders `voteTeamGroupHeader` on the page instead of throwing.

```js
  // en
  voteTeamGroupHeader: 'League {label}',
  // he
  voteTeamGroupHeader: 'ליגה {label}',
  // ru
  voteTeamGroupHeader: 'Лига {label}',
```

`t()` takes no arguments beyond the key; interpolation is the established `.replace('{token}', value)` call at the use site (see `results.js:210`).

- [ ] **Step 2: Run the parity test**

```bash
scripts/tests/test-i18n-parity.sh
```

Expected: `i18n parity OK`. If it reports `MISSING`, one language object did not get the key.

- [ ] **Step 3: Add the grouping helper**

In `services/frontend/vote.js`, directly below `clubsForLeague`:

```js
// Divisions inside a single league tab -- the UEFA Nations League's A/B/C/D tiers. A league whose
// clubs carry no group_label yields one unlabelled group, so every other league renders exactly as
// before. Unlabelled clubs inside a labelled league come FIRST and headerless: group_label is
// seed-only (the admin club endpoints deliberately never name it), so a club added through the
// admin UI has none, and dropping it would be a silent disappearance.
// clubsForLeague already sorts by localised name and filter() preserves order, so each division is
// alphabetical in the current language for free.
function groupedClubsForLeague(leagueId) {
  const clubs = clubsForLeague(leagueId);
  const labels = [...new Set(clubs.map(c => c.group_label).filter(Boolean))].sort();
  if (labels.length === 0) return [{ label: null, clubs }];

  const groups = [];
  const unlabelled = clubs.filter(c => !c.group_label);
  if (unlabelled.length > 0) groups.push({ label: null, clubs: unlabelled });
  labels.forEach(label => groups.push({ label, clubs: clubs.filter(c => c.group_label === label) }));
  return groups;
}
```

- [ ] **Step 4: Render the headers**

In `renderTeamGrid`, replace the `clubsForLeague(selectedLeagueId).forEach(c => { ... })` loop with a nested loop that emits a header before each labelled group. The card-building body is unchanged:

```js
  const atCap = entry.clubIds.size >= 3;
  groupedClubsForLeague(selectedLeagueId).forEach(group => {
    if (group.label !== null) {
      const header = document.createElement('h3');
      header.className = 'team-group-header';
      header.textContent = t('voteTeamGroupHeader').replace('{label}', group.label);
      grid.appendChild(header);
    }
    group.clubs.forEach(c => {
      const isChecked = entry.clubIds.has(c.id);
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'pick-card';
      card.setAttribute('aria-pressed', String(isChecked));
      card.dataset.clubId = c.id;
      if (!isChecked && atCap) {
        card.disabled = true;
        card.setAttribute('aria-disabled', 'true');
      }
      card.appendChild(logoEl(c, localizedName(c)));
      const name = document.createElement('span');
      name.className = 'card-name';
      name.textContent = localizedName(c);
      card.appendChild(name);
      card.addEventListener('click', () => toggleClub(selectedLeagueId, c.id));
      grid.appendChild(card);
    });
  });
```

- [ ] **Step 5: Style the header**

`#team-grid` has class `card-grid`, a `repeat(auto-fill, minmax(150px, 1fr))` grid, so a header must be told to span the whole row or it will sit in one 150px cell. Add near the `.card-grid` rules in `services/frontend/style.css`:

```css
/* Division heading inside a league's card grid (Nations League A-D). grid-column: 1 / -1 makes it
   span every column of the auto-fill grid; without it the heading occupies a single card cell. */
.team-group-header {
  grid-column: 1 / -1;
  margin: 0.5rem 0 0;
  font-size: 0.95rem;
  font-weight: 600;
  color: var(--muted);
  letter-spacing: 0.04em;
}
```

`--muted` is defined three times in this stylesheet (light default, and two dark-mode overrides), so the heading follows the theme with no extra rule.

- [ ] **Step 6: Verify in a browser**

Serve the frontend against a seeded backend and open the voting form. Confirm:
- The Nations League tab appears **last**, after the World Cup, with the text-free flag emblem.
- Four headers read **League A / League B / League C / League D**, in that order, teams alphabetical under each.
- Switching to Hebrew shows `ליגה A` and re-sorts; Russian shows `Лига A` and re-sorts.
- Every other league tab looks exactly as before, with no stray heading.

- [ ] **Step 7: Commit and push**

```bash
git add services/frontend/i18n.js services/frontend/vote.js services/frontend/style.css
git commit -m "feat(vote): render Nations League divisions as headers in the team grid"
git push origin master
```

---

### Task 7: REMOVED — not implemented

**Dropped at the repo owner's request, 2026-08-07, before any work started.** "It doesn't matter
which tab a pick came from."

This task would have tracked the originating league of each pick (`pickOriginLeague`) so that
picking France under the World Cup tab showed "World Cup 2026 — France" on the review screen rather
than "Nations League — France". It only ever affected that label.

It is cleanly droppable because Task 3's rollup change already counts a dual-league club toward
**both** of its leagues at league scope, so tab origin decides no total. `dedupedTeamPicks()` keeps
its existing behaviour: a dual-league pick is filed under `domestic_league_id`. No other task
consumes `pickOriginLeague`, and `vote.js` is otherwise untouched by this plan except for Task 6's
division headers.

Task numbering is left unchanged so the ledger, briefs and commit history stay aligned.

### Task 8: Results dropdown groups, and keep national teams out of the diversity ranking

**Files:**
- Modify: `services/frontend/results.js:332-346` (`renderClubPickerOptions`)
- Modify: `services/frontend/analytics.js:50-53, 62, 72, 297, 308, 733, 742`

**Interfaces:**
- Consumes: `club.group_label` (Task 1).
- Produces: `nationalTeamLeagueIds()` in `analytics.js` returning `Set<number>`, replacing `worldCupLeagueId()`.

- [ ] **Step 1: Group the club dropdown**

In `results.js`, replace the body of `renderClubPickerOptions`'s `forEach` with an `<optgroup>`-aware version. A 54-entry flat list is the problem being solved:

```js
function renderClubPickerOptions() {
  const leaguePicker = document.getElementById('league-picker');
  const clubPicker = document.getElementById('club-picker');
  const previousValue = clubPicker.value;
  clubPicker.querySelectorAll('option:not(:first-child), optgroup').forEach(o => o.remove());
  const leagueId = parseInt(leaguePicker.value, 10);
  const clubs = optionsData.clubs.filter(c => c.league_id === leagueId || c.domestic_league_id === leagueId);

  // Divisions (Nations League A-D) become <optgroup> headings; an undivided league is one flat list,
  // exactly as before. Sorted labels, unlabelled clubs first -- same rule as the voting form's grid.
  const labels = [...new Set(clubs.map(c => c.group_label).filter(Boolean))].sort();
  const appendOption = (parent, c) => {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = localizedName(c);
    parent.appendChild(opt);
  };

  sortByLocalizedName(clubs.filter(c => !c.group_label)).forEach(c => appendOption(clubPicker, c));
  labels.forEach(label => {
    const group = document.createElement('optgroup');
    group.label = t('voteTeamGroupHeader').replace('{label}', label);
    sortByLocalizedName(clubs.filter(c => c.group_label === label)).forEach(c => appendOption(group, c));
    clubPicker.appendChild(group);
  });

  if (previousValue) clubPicker.value = previousValue;
}
```

Note the `option:not(:first-child), optgroup` selector — the original only removed options, so `<optgroup>`s would accumulate on every league change.

- [ ] **Step 2: Widen the analytics national-team filter**

`analytics.js` keeps national teams out of the club-diversity ranking by comparing against the single World Cup league id. Thirty-eight more countries would swamp that ranking. Replace `worldCupLeagueId` (lines 50–53) with:

```js
// Leagues whose "clubs" are national teams. The diversity ranking compares clubs to each other, and
// a national side is not a club -- listing them together makes the ranking meaningless. Matched by
// name_en because these are seeded identities, not ids, and the ids differ per deployment.
const NATIONAL_TEAM_LEAGUES = new Set(['World Cup 2026', 'Nations League']);

function nationalTeamLeagueIds() {
  return new Set(
    analyticsOptionsData.leagues
      .filter(l => NATIONAL_TEAM_LEAGUES.has(l.name_en))
      .map(l => l.id)
  );
}
```

Then at each of the three call sites (lines 62, 297, 733) replace `const wcLeagueId = worldCupLeagueId();` with:

```js
  const nationalLeagueIds = nationalTeamLeagueIds();
```

and at each of the three filters (lines 72, 308, 742) replace `row.club.league_id !== wcLeagueId` with:

```js
    .filter(row => diversityIncludeWorldCup || !nationalLeagueIds.has(row.club.league_id))
```

The 16 linked nations keep `league_id` = World Cup 2026, so they are covered by the World Cup entry; the 38 new ones have `league_id` = Nations League.

- [ ] **Step 3: Confirm no stale references remain**

```bash
grep -n "worldCupLeagueId\|wcLeagueId" services/frontend/analytics.js
```

Expected: no output.

- [ ] **Step 4: Verify in a browser**

- On `/results`, choose the Nations League: the club dropdown shows four `League A`–`League D` groups, alphabetical within each, and re-labels when the language changes.
- Choose an undivided league (Premier League): one flat list, no group headings.
- Switch leagues repeatedly: group headings are replaced, not accumulated.
- On the analytics view, the diversity ranking contains no national teams while its World Cup toggle is off.

- [ ] **Step 5: Commit and push**

```bash
git add services/frontend/results.js services/frontend/analytics.js
git commit -m "feat(results): group the club picker by division; exclude national teams from diversity"
git push origin master
```

---

### Task 9: Dark-mode crest review, documentation, and plan deletion

**Files:**
- Modify: `services/frontend/logos.js:33-51` (`OUTLINE_CLUBS`), only if the review finds offenders
- Modify: `CLAUDE.md` (Architecture section)
- Modify: `docs/design/2026-08-07-nations-league-design.md` (add a Verification outcome section)
- Delete: `docs/superpowers/plans/2026-08-07-nations-league.md` (this file)

**Interfaces:**
- Consumes: everything above.
- Produces: no code interface.

- [ ] **Step 1: Review the 38 new crests in dark mode**

`OUTLINE_CLUBS` (keyed by `name_en`) lists crests that are dark artwork on transparency and vanish into a dark card. Several of the new badges are candidates — Germany's black DFB eagle is already seeded and already handled, but among the new ones check at least Belarus, Armenia, Andorra, Hungary, North Macedonia and Poland, which are single-colour coats of arms.

Open the voting form in dark mode, select the Nations League tab, and look at all four divisions. Add the `name_en` of any crest that is illegible to `OUTLINE_CLUBS`, with a comment naming the artwork:

```js
  // UEFA Nations League coats of arms that are dark line art on transparency, same class as the
  // World Cup crests above.
  'Belarus',
```

Only add crests you actually saw fail. An unnecessary entry gives a light outline to artwork that did not need one.

- [ ] **Step 2: Update the root `CLAUDE.md`**

In the Architecture section, where the rollup tables and league/club scoping are described, add a sentence recording the new rule — this is the kind of thing that is invisible in the code and expensive to rediscover:

```markdown
**A club that plays in two leagues counts toward BOTH at league scope.** `_VOTE_LEAGUES_TOUCHED_CTE`
in `services/worker/rollups.py` derives "which leagues did this vote touch" from `clubs.league_id`
*and* `clubs.domestic_league_id`, not from `vote_clubs.league_id` (which records only the tab the
pick was filed under). Club-scope rows are deliberately **not** expanded the same way — `?by=club`
filters on `club_id` with no league predicate, so a second club-scope row per vote would count one
voter twice. See `docs/design/2026-08-07-nations-league-design.md` decision 3.
```

Also note in the same section that `clubs.group_label` carries the Nations League A–D divisions and is seed-only by design.

- [ ] **Step 3: Record the verification outcome in the design doc**

Append a `## Verification outcome` section to `docs/design/2026-08-07-nations-league-design.md` stating what actually happened — in particular the before/after league totals from the first recompute, and anything that behaved differently from the design. This section is the durable record; the plan is not.

- [ ] **Step 4: Run every suite**

```bash
cd services/backend && source .venv/bin/activate && python -m pytest tests/ -v && deactivate
cd ../worker && source .venv/bin/activate && python -m pytest tests/ -v && deactivate
cd ../..
scripts/tests/test-i18n-parity.sh
scripts/tests/test-frontend-seo.sh
```

Expected: all pass. `test-frontend-seo.sh` also asserts `Dockerfile` `COPY` coverage — it should pass without a Dockerfile change, since the only new file is under `logos/`.

- [ ] **Step 5: Delete this plan and commit everything together**

The plan must be deleted **in the same commit as the last task** — a plan that outlives its execution reads like pending work. `docs/superpowers/` is the superpowers workflow's default output path and regenerates every time; deleting it once is not a fix, the deletion has to happen at the end of every plan.

```bash
rm -rf docs/superpowers
git add -A
git commit -m "docs: record Nations League verification outcome and dark-mode crest review"
git push origin master
```

---

## Self-review

**Spec coverage.** Design decisions 1–7 map to tasks: 1 → Task 1 (column) and Tasks 3–4 (data); 2 → Task 5; 3 → Task 2; 4 → **withdrawn, Task 7 removed**; 5 → Task 1 Step 1's `test_rename_club_preserves_group_label`; 6 → Tasks 6 and 8; 7 → Task 3 Steps 1–2. The design's "Files this touches" table is covered except `logos.js`, which is Task 9 Step 1, and the `analytics.js` note, which is Task 8 Step 2. The verification section maps to Task 5 Step 5 (already-seeded proof), Task 2 (rollup deltas), and Tasks 6–8 (browser checks).

**Deferred.** The design's "measure the rollup delta on real data" applies at deploy time, not in this plan — Task 9 Step 3 is where the numbers get recorded.

**Type consistency.** `groupedClubsForLeague` returns `{label, clubs}` in Task 6 and is not reused elsewhere; Task 8 reimplements the same grouping inline against `<optgroup>` rather than importing it, because `results.js` and `vote.js` share no module. `nationalTeamLeagueIds()` returns a `Set` and every call site uses `.has()`. `pickOriginLeague` is a `Map` and every call site uses `.get`/`.set`/`.delete`. The i18n key is `voteTeamGroupHeader` in Tasks 6 and 8.
