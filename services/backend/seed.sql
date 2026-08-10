INSERT INTO alert_state (id, last_seen_total) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;

-- Guarded by name_en (not just ON CONFLICT (name)) because the admin UI's rename/edit routes
-- always set the legacy `name` column to name_he -- once an admin has touched a league/club at
-- all (even just to add a logo_url), `name` no longer matches this literal English value on a
-- later re-run of this file, so the ON CONFLICT target alone would silently re-insert a
-- duplicate row instead of a no-op. name_en survives admin edits, so it's the stable identity
-- check here.
-- UCL/EPL get a three-way identity check (legacy name, raw name_en, post-rename canonical
-- name_en) because they're the only leagues whose name_en this file itself overwrites below
-- (to 'UEFA Champions League'/'Premier League') -- once that's happened on a prior run, neither
-- the literal 'UCL'/'EPL' token nor an admin-drifted `name` column can match the row anymore,
-- so without the canonical fallback this INSERT can't recognize the row already exists and
-- creates a duplicate league (see incident 2026-07-17: phantom 'UCL' row -> duplicate clubs ->
-- clubs_name_en_uidx crash on every backend pod boot).
INSERT INTO leagues (name)
SELECT v.name FROM (VALUES
    ('World Cup 2026'), ('UCL'), ('EPL'), ('La Liga'), ('Serie A'), ('Bundesliga'), ('Israeli Premier League'),
    ('Liga Leumit'), ('Nations League')
) AS v(name)
WHERE NOT EXISTS (
    SELECT 1 FROM leagues existing
    WHERE existing.name = v.name
       OR existing.name_en = v.name
       OR existing.name_en = (CASE v.name
            WHEN 'UCL' THEN 'UEFA Champions League'
            WHEN 'EPL' THEN 'Premier League'
            ELSE v.name END)
)
ON CONFLICT (name) DO NOTHING;

-- English spelling corrections, and they MUST run before the INSERT below, not after it.
-- Every name_en-keyed statement in this file is guarded, so editing a literal only ever reaches a
-- *fresh* database; an already-seeded one keeps the old spelling forever. Worse, the INSERT's
-- `existing.name_en = c.name` guard then stops recognizing the row, inserts a second club under the
-- new spelling, and the correction afterwards dies on clubs_name_en_uidx -- crashing init_db on
-- every pod boot (the same shape as the 2026-07-17 duplicate-league incident above).
-- Keyed on the exact superseded string, so an admin's own rename (which won't match) is never
-- overwritten. The legacy `name` column is deliberately left alone: it is internal identity only,
-- never returned by the API, and admin saves overwrite it with name_he regardless.
UPDATE clubs SET name_en = 'Curaçao' WHERE name_en = 'Curacao';

-- Same name_en guard as leagues above -- see that comment for why ON CONFLICT (league_id, name)
-- alone isn't enough once admin edits have flipped a club's legacy `name` to Hebrew.
INSERT INTO clubs (league_id, name)
SELECT l.id, c.name FROM leagues l
JOIN (VALUES
    -- Exactly the real 48 qualified teams (verified against 2026 FIFA World Cup qualification,
    -- inter-confederation play-offs resolved March 31 2026) -- not every "big name" nation
    -- qualified (e.g. Italy and Israel are correctly absent).
    ('World Cup 2026', 'Brazil'), ('World Cup 2026', 'Argentina'), ('World Cup 2026', 'France'),
    ('World Cup 2026', 'England'), ('World Cup 2026', 'Spain'), ('World Cup 2026', 'Germany'),
    ('World Cup 2026', 'Portugal'), ('World Cup 2026', 'Netherlands'),
    ('World Cup 2026', 'Belgium'), ('World Cup 2026', 'Croatia'), ('World Cup 2026', 'Uruguay'),
    ('World Cup 2026', 'Colombia'), ('World Cup 2026', 'Mexico'), ('World Cup 2026', 'USA'),
    ('World Cup 2026', 'Canada'), ('World Cup 2026', 'Japan'), ('World Cup 2026', 'South Korea'),
    ('World Cup 2026', 'Morocco'), ('World Cup 2026', 'Senegal'),
    ('World Cup 2026', 'Ghana'), ('World Cup 2026', 'Egypt'), ('World Cup 2026', 'Tunisia'),
    ('World Cup 2026', 'Algeria'), ('World Cup 2026', 'Ivory Coast'),
    ('World Cup 2026', 'Australia'), ('World Cup 2026', 'Iran'), ('World Cup 2026', 'Saudi Arabia'),
    ('World Cup 2026', 'Qatar'), ('World Cup 2026', 'Ecuador'),
    ('World Cup 2026', 'Switzerland'),
    ('World Cup 2026', 'Sweden'),
    ('World Cup 2026', 'Uzbekistan'), ('World Cup 2026', 'Jordan'), ('World Cup 2026', 'Iraq'),
    ('World Cup 2026', 'Cape Verde'), ('World Cup 2026', 'South Africa'), ('World Cup 2026', 'DR Congo'),
    ('World Cup 2026', 'Panama'), ('World Cup 2026', 'Curaçao'), ('World Cup 2026', 'Haiti'),
    ('World Cup 2026', 'Paraguay'), ('World Cup 2026', 'New Zealand'), ('World Cup 2026', 'Norway'),
    ('World Cup 2026', 'Scotland'), ('World Cup 2026', 'Austria'),
    ('World Cup 2026', 'Bosnia and Herzegovina'), ('World Cup 2026', 'Turkey'), ('World Cup 2026', 'Czech Republic'),

    ('UCL', 'Real Madrid'), ('UCL', 'Manchester City'), ('UCL', 'Bayern Munich'),
    ('UCL', 'Barcelona'), ('UCL', 'Liverpool'), ('UCL', 'Paris Saint-Germain'),
    ('UCL', 'Inter Milan'), ('UCL', 'Manchester United'),
    ('UCL', 'Arsenal'), ('UCL', 'Atlético Madrid'), ('UCL', 'Borussia Dortmund'),
    ('UCL', 'Napoli'), ('UCL', 'Porto'),
    ('UCL', 'Club Brugge'), ('UCL', 'Feyenoord'), ('UCL', 'Galatasaray'),
    ('UCL', 'Lens'), ('UCL', 'Lille'), ('UCL', 'PSV Eindhoven'),
    ('UCL', 'Shakhtar Donetsk'), ('UCL', 'Slavia Prague'), ('UCL', 'Sporting CP'),

    ('EPL', 'Aston Villa'), ('EPL', 'Bournemouth'),
    ('EPL', 'Brentford'), ('EPL', 'Brighton & Hove Albion'),
    ('EPL', 'Chelsea'), ('EPL', 'Coventry City'),
    ('EPL', 'Crystal Palace'), ('EPL', 'Everton'), ('EPL', 'Fulham'),
    ('EPL', 'Hull City'), ('EPL', 'Ipswich Town'), ('EPL', 'Leeds United'),
    ('EPL', 'Newcastle United'),
    ('EPL', 'Nottingham Forest'), ('EPL', 'Sunderland'), ('EPL', 'Tottenham Hotspur'),

    ('La Liga', 'Athletic Bilbao'), ('La Liga', 'Real Sociedad'), ('La Liga', 'Real Betis'),
    ('La Liga', 'Villarreal'), ('La Liga', 'Valencia'), ('La Liga', 'Sevilla'),
    ('La Liga', 'Osasuna'), ('La Liga', 'Celta Vigo'),
    ('La Liga', 'Rayo Vallecano'), ('La Liga', 'Getafe'), ('La Liga', 'Alavés'),
    ('La Liga', 'Espanyol'), ('La Liga', 'Deportivo de A Coruña'),
    ('La Liga', 'Elche'), ('La Liga', 'Levante'), ('La Liga', 'Málaga'),
    ('La Liga', 'Racing Santander'),

    ('Serie A', 'Roma'), ('Serie A', 'Lazio'),
    ('Serie A', 'Atalanta'), ('Serie A', 'Fiorentina'), ('Serie A', 'Bologna'),
    ('Serie A', 'Torino'), ('Serie A', 'Udinese'), ('Serie A', 'Genoa'),
    ('Serie A', 'Cagliari'), ('Serie A', 'Lecce'),
    ('Serie A', 'Parma'), ('Serie A', 'Como'), ('Serie A', 'Venezia'),
    ('Serie A', 'Monza'), ('Serie A', 'AC Milan'), ('Serie A', 'Juventus'),
    ('Serie A', 'Frosinone'), ('Serie A', 'Sassuolo'),

    ('Bundesliga', 'RB Leipzig'),
    ('Bundesliga', 'Bayer Leverkusen'), ('Bundesliga', 'Eintracht Frankfurt'), ('Bundesliga', 'VfB Stuttgart'),
    ('Bundesliga', 'Borussia Mönchengladbach'), ('Bundesliga', 'SC Freiburg'), ('Bundesliga', 'Werder Bremen'),
    ('Bundesliga', 'Union Berlin'), ('Bundesliga', 'Mainz 05'),
    ('Bundesliga', 'TSG Hoffenheim'), ('Bundesliga', 'FC Augsburg'),
    ('Bundesliga', '1. FC Köln'), ('Bundesliga', 'FC Schalke 04'), ('Bundesliga', 'Hamburger SV'),
    ('Bundesliga', 'SC Paderborn 07'), ('Bundesliga', 'SV Elversberg'),

    ('Israeli Premier League', 'Maccabi Haifa'), ('Israeli Premier League', 'Maccabi Tel Aviv'),
    ('Israeli Premier League', 'Hapoel Be''er Sheva'), ('Israeli Premier League', 'Hapoel Tel Aviv'),
    ('Israeli Premier League', 'Beitar Jerusalem'), ('Israeli Premier League', 'Maccabi Netanya'),
    ('Israeli Premier League', 'Hapoel Haifa'), ('Israeli Premier League', 'Bnei Sakhnin'),
    ('Israeli Premier League', 'Hapoel Ramat Gan Givatayim'), ('Israeli Premier League', 'Hapoel Jerusalem'),
    ('Israeli Premier League', 'Ironi Kiryat Shmona'), ('Israeli Premier League', 'Maccabi Petah Tikva'),
    ('Israeli Premier League', 'Hapoel Petah Tikva'), ('Israeli Premier League', 'Ironi Tiberias'),

    ('Liga Leumit', 'F.C. Ashdod'), ('Liga Leumit', 'Maccabi Bnei Reineh'),
    ('Liga Leumit', 'Bnei Yehuda'), ('Liga Leumit', 'Maccabi Kiryat Gat'),
    ('Liga Leumit', 'Hapoel Kfar Saba'), ('Liga Leumit', 'Hapoel Kfar Shalem'),
    ('Liga Leumit', 'Maccabi Akhi Nazareth'), ('Liga Leumit', 'Hapoel Akko'),
    ('Liga Leumit', 'Hapoel Afula'), ('Liga Leumit', 'Hapoel Rishon LeZion'),
    ('Liga Leumit', 'Hapoel Ra''anana'), ('Liga Leumit', 'F.C. Kafr Qasim'),
    ('Liga Leumit', 'F.C. Kiryat Yam'), ('Liga Leumit', 'Maccabi Herzliya'),
    ('Liga Leumit', 'Maccabi Kavilio Jaffa'), ('Liga Leumit', 'Ironi Modi''in'),

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
) AS c(league_name, name)
    ON l.name = c.league_name
    OR l.name_en = c.league_name
    OR l.name_en = (CASE c.league_name
        WHEN 'UCL' THEN 'UEFA Champions League'
        WHEN 'EPL' THEN 'Premier League'
        ELSE c.league_name END)
WHERE NOT EXISTS (
    SELECT 1 FROM clubs existing WHERE existing.league_id = l.id AND existing.name_en = c.name
)
ON CONFLICT (league_id, name) DO NOTHING;

-- Link each UCL club that also plays in a domestic league this app seeds (decision 12).
-- Paris Saint-Germain/Porto are intentionally excluded -- their domestic leagues (Ligue 1/
-- Primeira Liga) aren't seeded here, so they stay UCL-only, as do the newly-added
-- non-"big 5 league" UCL clubs (Club Brugge, Feyenoord, Galatasaray, Lens, Lille, PSV
-- Eindhoven, Shakhtar Donetsk, Slavia Prague, Sporting CP) for the same reason.
-- The UCL lookup also matches on name_en (raw or post-rename canonical) -- see the comment on
-- the leagues INSERT above for why 'UCL' alone isn't a reliable match once that row's name_en
-- has been renamed to 'UEFA Champions League'.
UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'EPL' OR name_en IN ('EPL', 'Premier League'))
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
  AND name IN ('Arsenal', 'Liverpool', 'Manchester City', 'Manchester United');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'La Liga')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
  AND name IN ('Real Madrid', 'Barcelona', 'Atlético Madrid');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'Serie A')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
  AND name IN ('Inter Milan', 'Napoli');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'Bundesliga')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
  AND name IN ('Bayern Munich', 'Borussia Dortmund');

-- Reverse-direction dual-league links: clubs whose primary league_id is their own domestic
-- league (not UCL) but that also play in the Champions League -- Chelsea, AC Milan, and
-- Juventus moved the other way (out of UCL, into their domestic league only, no link back)
-- since they didn't qualify for this UCL cycle. Functionally symmetric with the blocks above --
-- get_club_leagues/insert_vote in queries.py check both league_id and domestic_league_id.
UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
WHERE league_id = (SELECT id FROM leagues WHERE name = 'La Liga')
  AND name IN ('Real Betis', 'Villarreal');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
WHERE league_id = (SELECT id FROM leagues WHERE name = 'EPL' OR name_en IN ('EPL', 'Premier League'))
  AND name IN ('Aston Villa');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
WHERE league_id = (SELECT id FROM leagues WHERE name = 'Serie A')
  AND name IN ('Como', 'Roma');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'UCL' OR name_en IN ('UCL', 'UEFA Champions League'))
WHERE league_id = (SELECT id FROM leagues WHERE name = 'Bundesliga')
  AND name IN ('RB Leipzig', 'VfB Stuttgart');

INSERT INTO previous_parties (name) VALUES
    ('הליכוד'), ('יש עתיד'), ('הציונות הדתית'), ('המחנה הממלכתי'),
    ('ישראל ביתנו'), ('ש"ס'), ('יהדות התורה'), ('רע"ם'),
    ('חד"ש-תע"ל'), ('העבודה'), ('מרצ'), ('בל"ד'), ('אחר')
ON CONFLICT (name) DO NOTHING;

-- Rename, not a new row. המילואימניקים merged with חילי טרופר's יסודות ישראל and the joint list runs
-- as בית ציוני - המילואימניקים (launched 2026-08-05). This MUST run before the INSERT below: that
-- INSERT's ON CONFLICT matches on `name`, so on an already-seeded database the new literal would not
-- conflict with the old row -- it would add a SECOND party, leaving every vote already cast stranded
-- on an orphaned row while the ballot showed the empty new one.
--
-- Keyed on `name` rather than name_he because on a fresh database name_he is not backfilled until
-- further down this file. Sets both columns, which is what rename_upcoming_party() does (it writes
-- name = name_he). Idempotent: once renamed it matches nothing. It also deliberately does not fire
-- on a row an admin has already renamed to something else -- their edit wins.
UPDATE upcoming_parties
   SET name = 'בית ציוני - המילואימניקים', name_he = 'בית ציוני - המילואימניקים'
 WHERE name = 'המילואימניקים';

INSERT INTO upcoming_parties (name) VALUES
    ('הליכוד'), ('ישר'), ('ביחד'), ('הדמוקרטים'), ('כחול לבן'),
    ('ישראל ביתנו'), ('הציונות הדתית'), ('עוצמה יהודית'), ('חד"ש-תע"ל'),
    ('בל"ד'), ('רע"ם'), ('ש"ס'), ('יהדות התורה'),
    ('המפלגה הכלכלית'), ('אל הדגל'), ('בית ציוני - המילואימניקים'), ('זהות'), ('נעם')
ON CONFLICT (name) DO NOTHING;

-- Backfill each row's own language from the legacy `name` column.
UPDATE leagues           SET name_en = name WHERE name_en IS NULL;
UPDATE clubs             SET name_en = name WHERE name_en IS NULL;
UPDATE previous_parties  SET name_he = name WHERE name_he IS NULL;
UPDATE upcoming_parties  SET name_he = name WHERE name_he IS NULL;

-- The 16 nations that play in BOTH the 2026 World Cup and the UEFA Nations League. They keep
-- league_id = World Cup 2026 and gain the Nations League as their second league, so they appear
-- under both tabs with their existing crest and names. clubs_name_en_uidx is global, so inserting a
-- second 'France' row is impossible -- linking is the only option, and it is also what makes
-- toggleClub's mirroring ("picked in one tab, picked in the other") work with no frontend change.
--
-- Keyed on name_en rather than the legacy `name` column used by the UCL blocks above: `name` is
-- overwritten with name_he by queries.py's rename_league/rename_club on any admin save, so a
-- name-keyed match silently stops finding an admin-touched row. This runs after the name_en backfill
-- just above, since a freshly-inserted club only carries `name` until that backfill runs.
UPDATE clubs SET domestic_league_id =
    (SELECT id FROM leagues WHERE name = 'Nations League' OR name_en = 'Nations League')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'World Cup 2026' OR name_en = 'World Cup 2026')
  AND name_en IN ('Austria', 'Belgium', 'Bosnia and Herzegovina', 'Croatia', 'Czech Republic',
                  'England', 'France', 'Germany', 'Netherlands', 'Norway', 'Portugal', 'Scotland',
                  'Spain', 'Sweden', 'Switzerland', 'Turkey');

-- Relegation removals (2026-08-04): Hapoel Hadera and Hapoel Nof HaGalil dropped out of Liga Leumit
-- to the third tier, which this app does not seed, and Maccabi Kiryat Gat / Maccabi Akhi Nazareth
-- took their places in the roster above. Dropping the two from the INSERT's VALUES list is only half
-- the change: every statement in this file runs against a database that is ALREADY seeded, so
-- deleting a literal there reaches a *fresh* database only -- production keeps both clubs forever.
-- Removing a club therefore needs its own explicit statement, and this is the first one in the file.
--
-- The NOT EXISTS guard is what keeps the app bootable, and it is not optional. vote_clubs.club_id
-- references clubs(id) with NO ON DELETE CASCADE (schema.sql), so deleting a club somebody has voted
-- for raises a foreign-key violation *inside init_db* -- which runs on every backend pod boot, so the
-- failure is a CrashLoopBackOff on startup, not one failed request. The guard also encodes the policy
-- the admin API already enforces: DELETE /api/admin/clubs/<id> returns 409 while any vote references
-- the club (see delete_club_route in app.py). A roster tidy-up must never destroy a ballot; if either
-- club ever does pick up votes, it stays and the admin UI's vote-reassignment flow is the way out.
--
-- Keyed on name_en, the stable identity used by every other guarded statement here -- so a club an
-- admin has renamed through the live UI is left alone rather than silently deleted. Idempotent: a
-- no-op once the rows are gone, which is why it can run on every boot forever.
DELETE FROM clubs c
WHERE c.name_en IN ('Hapoel Hadera', 'Hapoel Nof HaGalil')
  AND NOT EXISTS (SELECT 1 FROM vote_clubs vc WHERE vc.club_id = c.id);

-- League display names.
-- One row per entity, all display languages together. COALESCE is the per-column equivalent of
-- the old "AND name_xx IS NULL" guard: it fills only what is still empty, so a name an admin has
-- renamed through the live UI is never overwritten. Do not drop it.
-- Matched on the legacy `name` OR `name_he`, and NEITHER alone is sufficient. No single column
-- identifies a league in all three states this table can be in:
--
--   fresh install (before this block)  name='UCL'            name_en='UCL'                    name_he=NULL
--   normally seeded                   name='UCL'            name_en='UEFA Champions League'  name_he='ליגת האלופות'
--   after any admin rename            name='ליגת האלופות'   name_en='UEFA Champions League'  name_he='ליגת האלופות'
--
-- name_en is rewritten unguarded for EPL/UCL by the two UPDATEs just below, on every run.
-- `name` is overwritten with name_he by queries.py's rename_league -- even on a no-op rename,
-- which is the 2026-07-17 drift that test_seed_rerun_survives_league_name_drift covers.
-- name_he is stable afterwards but NULL on a fresh install.
-- Matching on `name OR name_he` covers every state; each is unique-indexed, so at most one row
-- matches. Do not "simplify" this to one column -- both single-column forms have shipped and both
-- silently left leagues untranslated.
UPDATE leagues l SET
    name_he = COALESCE(l.name_he, v.name_he),
    name_ru = COALESCE(l.name_ru, v.name_ru)
FROM (VALUES
    ('World Cup 2026', 'מונדיאל 2026', 'Чемпионат мира 2026'),
    ('UCL', 'ליגת האלופות', 'Лига чемпионов'),
    ('EPL', 'הפרמייר ליג', 'Премьер-лига'),
    ('La Liga', 'לה ליגה', 'Ла Лига'),
    ('Serie A', 'סרייה A', 'Серия А'),
    ('Bundesliga', 'הבונדסליגה', 'Бундеслига'),
    ('Israeli Premier League', 'ליגת העל', 'Израильская Премьер-лига'),
    ('Liga Leumit', 'ליגה לאומית', 'Лига Леумит'),
    ('Nations League', 'ליגת האומות', 'Лига наций УЕФА')
) AS v(name, name_he, name_ru)
WHERE l.name = v.name OR l.name_he = v.name_he;
UPDATE leagues SET name_en = 'Premier League' WHERE name = 'EPL';
UPDATE leagues SET name_en = 'UEFA Champions League' WHERE name = 'UCL';
-- Russian renames. The COALESCE block above only FILLS an empty name_ru, so changing a value there
-- never reaches an already-seeded database -- a rename needs its own statement. Keyed on the exact
-- superseded string so an admin's own Russian name (which won't match) is never overwritten.
UPDATE leagues SET name_ru = 'Израильская Премьер-лига' WHERE name_ru = 'Лига ха-Аль';

-- Explicit league display order (see get_options in queries.py, ORDER BY sort_order NULLS LAST):
-- Israeli Premier League and Liga Leumit first (domestic leagues), then the "big 5" European
-- leagues, then UCL, then the World Cup last.
UPDATE leagues SET sort_order = 0 WHERE name = 'Israeli Premier League';
UPDATE leagues SET sort_order = 1 WHERE name_en = 'Liga Leumit';
UPDATE leagues SET sort_order = 2 WHERE name_en = 'Premier League';
UPDATE leagues SET sort_order = 3 WHERE name_en = 'La Liga';
UPDATE leagues SET sort_order = 4 WHERE name_en = 'Bundesliga';
UPDATE leagues SET sort_order = 5 WHERE name_en = 'Serie A';
UPDATE leagues SET sort_order = 6 WHERE name_en = 'UEFA Champions League';
UPDATE leagues SET sort_order = 7 WHERE name_en = 'World Cup 2026';
UPDATE leagues SET sort_order = 8 WHERE name_en = 'Nations League';

-- Only the Nations League renders division headers; see the schema.sql comment on has_divisions.
UPDATE leagues SET has_divisions = TRUE  WHERE name_en = 'Nations League';
UPDATE leagues SET has_divisions = FALSE WHERE name_en <> 'Nations League';

-- League logos/emblems. Competition emblems (unlike individual club crests) carry no per-club
-- trademark ambiguity, so these are safe to seed directly (see the World Cup national-flags note
-- above) -- admin can still override any of these via the leagues admin UI's Logo URL field.
UPDATE leagues t SET logo_url = v.logo_url
FROM (VALUES
    ('World Cup 2026', 'https://upload.wikimedia.org/wikipedia/commons/1/17/2026_FIFA_World_Cup_emblem.svg'),
    ('UCL', 'https://upload.wikimedia.org/wikipedia/commons/d/d1/UEFA_Champions_League_logo_no_text.svg'),
    ('EPL', 'https://b.fssta.com/uploads/application/soccer/competition-logos/EnglishPremierLeague.png'),
    ('La Liga', 'https://upload.wikimedia.org/wikipedia/commons/0/0f/LaLiga_logo_2023.svg'),
    ('Serie A', 'https://upload.wikimedia.org/wikipedia/commons/e/e9/Serie_A_logo_2022.svg'),
    ('Bundesliga', 'https://upload.wikimedia.org/wikipedia/he/d/df/Bundesliga_logo_%282017%29.svg'),
    ('Israeli Premier League', 'https://upload.wikimedia.org/wikipedia/en/1/17/Winnerleague.png'),
    ('Liga Leumit', 'https://upload.wikimedia.org/wikipedia/en/1/17/Winnerleague.png'),
    ('Nations League', '/logos/uefa-nations-league.svg')
) AS v(name, logo_url)
WHERE t.name = v.name
  AND t.logo_url IS NULL;

-- Club display names.
-- One row per entity, all display languages together. COALESCE is the per-column equivalent of
-- the old "AND name_xx IS NULL" guard: it fills only what is still empty, so a name an admin has
-- renamed through the live UI is never overwritten. Do not drop it.
UPDATE clubs c SET
    name_he = COALESCE(c.name_he, v.name_he),
    name_ru = COALESCE(c.name_ru, v.name_ru)
FROM (VALUES
    -- World Cup 2026 countries
    ('Brazil', 'ברזיל', 'Бразилия'),
    ('Argentina', 'ארגנטינה', 'Аргентина'),
    ('France', 'צרפת', 'Франция'),
    ('England', 'אנגליה', 'Англия'),
    ('Spain', 'ספרד', 'Испания'),
    ('Germany', 'גרמניה', 'Германия'),
    ('Portugal', 'פורטוגל', 'Португалия'),
    ('Netherlands', 'הולנד', 'Нидерланды'),
    ('Belgium', 'בלגיה', 'Бельгия'),
    ('Croatia', 'קרואטיה', 'Хорватия'),
    ('Uruguay', 'אורוגוואי', 'Уругвай'),
    ('Colombia', 'קולומביה', 'Колумбия'),
    ('Mexico', 'מקסיקו', 'Мексика'),
    ('USA', 'ארה"ב', 'США'),
    ('Canada', 'קנדה', 'Канада'),
    ('Japan', 'יפן', 'Япония'),
    ('South Korea', 'דרום קוריאה', 'Южная Корея'),
    ('Morocco', 'מרוקו', 'Марокко'),
    ('Senegal', 'סנגל', 'Сенегал'),
    ('Ghana', 'גאנה', 'Гана'),
    ('Egypt', 'מצרים', 'Египет'),
    ('Tunisia', 'תוניסיה', 'Тунис'),
    ('Algeria', 'אלג''יריה', 'Алжир'),
    ('Ivory Coast', 'חוף השנהב', 'Кот-д''Ивуар'),
    ('Australia', 'אוסטרליה', 'Австралия'),
    ('Iran', 'איראן', 'Иран'),
    ('Saudi Arabia', 'ערב הסעודית', 'Саудовская Аравия'),
    ('Qatar', 'קטאר', 'Катар'),
    ('Ecuador', 'אקוודור', 'Эквадор'),
    ('Switzerland', 'שווייץ', 'Швейцария'),
    ('Sweden', 'שוודיה', 'Швеция'),
    ('Uzbekistan', 'אוזבקיסטן', 'Узбекистан'),
    ('Jordan', 'ירדן', 'Иордания'),
    ('Iraq', 'עיראק', 'Ирак'),
    ('Cape Verde', 'קייפ ורדה', 'Кабо-Верде'),
    ('South Africa', 'דרום אפריקה', 'ЮАР'),
    ('DR Congo', 'קונגו הדמוקרטית', 'ДР Конго'),
    ('Panama', 'פנמה', 'Панама'),
    ('Curaçao', 'קוראסאו', 'Кюрасао'),
    ('Haiti', 'האיטי', 'Гаити'),
    ('Paraguay', 'פרגוואי', 'Парагвай'),
    ('New Zealand', 'ניו זילנד', 'Новая Зеландия'),
    ('Norway', 'נורווגיה', 'Норвегия'),
    ('Scotland', 'סקוטלנד', 'Шотландия'),
    ('Austria', 'אוסטריה', 'Австрия'),
    ('Bosnia and Herzegovina', 'בוסניה והרצגובינה', 'Босния и Герцеговина'),
    ('Turkey', 'טורקיה', 'Турция'),
    ('Czech Republic', 'צ''כיה', 'Чехия'),
    -- UCL clubs
    ('Real Madrid', 'ריאל מדריד', 'Реал Мадрид'),
    ('Manchester City', 'מנצ''סטר סיטי', 'Манчестер Сити'),
    ('Bayern Munich', 'באיירן מינכן', 'Бавария'),
    ('Barcelona', 'ברצלונה', 'Барселона'),
    ('Liverpool', 'ליברפול', 'Ливерпуль'),
    ('Paris Saint-Germain', 'פריז סן ז''רמן', 'Пари Сен-Жермен'),
    ('Inter Milan', 'אינטר מילאנו', 'Интернационале'),
    ('Juventus', 'יובנטוס', 'Ювентус'),
    ('Manchester United', 'מנצ''סטר יונייטד', 'Манчестер Юнайтед'),
    ('Chelsea', 'צ''לסי', 'Челси'),
    ('Arsenal', 'ארסנל', 'Арсенал'),
    ('AC Milan', 'מילאן', 'Милан'),
    ('Atlético Madrid', 'אתלטיקו מדריד', 'Атлетико Мадрид'),
    ('Borussia Dortmund', 'בורוסיה דורטמונד', 'Боруссия Дортмунд'),
    ('Napoli', 'נאפולי', 'Наполи'),
    ('Porto', 'פורטו', 'Порту'),
    ('Benfica', 'בנפיקה', 'Бенфика'),
    ('Ajax', 'אייאקס', 'Аякс'),
    -- EPL clubs not already covered by UCL
    ('Aston Villa', 'אסטון וילה', 'Астон Вилла'),
    ('Bournemouth', 'בורנמות''', 'Борнмут'),
    ('Brentford', 'ברנטפורד', 'Брентфорд'),
    ('Brighton & Hove Albion', 'ברייטון אנד הוב אלביון', 'Брайтон энд Хоув Альбион'),
    ('Crystal Palace', 'קריסטל פאלאס', 'Кристал Пэлас'),
    ('Everton', 'אברטון', 'Эвертон'),
    ('Fulham', 'פולהאם', 'Фулхэм'),
    ('Ipswich Town', 'איפסוויץ'' טאון', 'Ипсвич Таун'),
    ('Leicester City', 'לסטר סיטי', 'Лестер Сити'),
    ('Newcastle United', 'ניוקאסל יונייטד', 'Ньюкасл Юнайтед'),
    ('Nottingham Forest', 'נוטינגהאם פורסט', 'Ноттингем Форест'),
    ('Southampton', 'סאות''המפטון', 'Саутгемптон'),
    ('Tottenham Hotspur', 'טוטנהאם הוטספר', 'Тоттенхэм Хотспур'),
    ('West Ham United', 'ווסט האם יונייטד', 'Вест Хэм Юнайтед'),
    ('Wolverhampton Wanderers', 'וולברהמפטון וונדררס', 'Вулверхэмптон Уондерерс'),
    -- La Liga clubs not already covered by UCL
    ('Athletic Bilbao', 'אתלטיק בילבאו', 'Атлетик Бильбао'),
    ('Real Sociedad', 'ריאל סוסיאדד', 'Реал Сосьедад'),
    ('Real Betis', 'ריאל בטיס', 'Реал Бетис'),
    ('Villarreal', 'ויאריאל', 'Вильярреал'),
    ('Valencia', 'ולנסיה', 'Валенсия'),
    ('Sevilla', 'סביליה', 'Севилья'),
    ('Girona', 'ז''ירונה', 'Жирона'),
    ('Osasuna', 'אוססונה', 'Осасуна'),
    ('Celta Vigo', 'סלטה ויגו', 'Сельта'),
    ('Rayo Vallecano', 'ראיו ואייקאנו', 'Райо Вальекано'),
    ('Getafe', 'חטאפה', 'Хетафе'),
    ('Las Palmas', 'לאס פלמאס', 'Лас-Пальмас'),
    ('Alavés', 'אלאבס', 'Алавес'),
    ('Espanyol', 'אספניול', 'Эспаньол'),
    ('Leganes', 'לגאנס', 'Леганес'),
    ('Mallorca', 'מיורקה', 'Мальорка'),
    ('Valladolid', 'ויאדוליד', 'Вальядолид'),
    -- Serie A clubs not already covered by UCL
    ('Roma', 'רומא', 'Рома'),
    ('Lazio', 'לאציו', 'Лацио'),
    ('Atalanta', 'אטלנטה', 'Аталанта'),
    ('Fiorentina', 'פיורנטינה', 'Фиорентина'),
    ('Bologna', 'בולוניה', 'Болонья'),
    ('Torino', 'טורינו', 'Торино'),
    ('Udinese', 'אודינזה', 'Удинезе'),
    ('Genoa', 'ג''נואה', 'Дженоа'),
    ('Cagliari', 'קליארי', 'Кальяри'),
    ('Verona', 'ורונה', 'Верона'),
    ('Lecce', 'לצ''ה', 'Лечче'),
    ('Parma', 'פארמה', 'Парма'),
    ('Como', 'קומו', 'Комо'),
    ('Venezia', 'ונציה', 'Венеция'),
    ('Empoli', 'אמפולי', 'Эмполи'),
    ('Monza', 'מונצה', 'Монца'),
    -- Bundesliga clubs not already covered by UCL
    ('RB Leipzig', 'ר. ב. לייפציג', 'РБ Лейпциг'),
    ('Bayer Leverkusen', 'באייר לברקוזן', 'Байер 04'),
    ('Eintracht Frankfurt', 'איינטרכט פרנקפורט', 'Айнтрахт Франкфурт'),
    ('VfB Stuttgart', 'שטוטגרט', 'Штутгарт'),
    ('Borussia Mönchengladbach', 'בורוסיה מנשנגלדבך', 'Боруссия Мёнхенгладбах'),
    ('SC Freiburg', 'פרייבורג', 'Фрайбург'),
    ('Werder Bremen', 'וורדר ברמן', 'Вердер'),
    ('Union Berlin', 'אוניון ברלין', 'Унион Берлин'),
    ('Mainz 05', 'מיינץ 05', 'Майнц 05'),
    ('Wolfsburg', 'וולפסבורג', 'Вольфсбург'),
    ('TSG Hoffenheim', 'הופנהיים', 'Хоффенхайм'),
    ('FC Augsburg', 'אוגסבורג', 'Аугсбург'),
    ('VfL Bochum', 'בוכום', 'Бохум'),
    ('FC Heidenheim', 'היידנהיים', 'Хайденхайм'),
    ('Holstein Kiel', 'הולשטיין קיל', 'Хольштайн Киль'),
    ('St. Pauli', 'זנקט פאולי', 'Санкт-Паули'),
    -- Israeli Premier League clubs
    ('Maccabi Haifa', 'מכבי חיפה', 'Маккаби Хайфа'),
    ('Maccabi Tel Aviv', 'מכבי תל אביב', 'Маккаби Тель-Авив'),
    ('Hapoel Be''er Sheva', 'הפועל באר שבע', 'Хапоэль Беэр-Шева'),
    ('Hapoel Tel Aviv', 'הפועל תל אביב', 'Хапоэль Тель-Авив'),
    ('Beitar Jerusalem', 'בית"ר ירושלים', 'Бейтар Иерусалим'),
    ('Maccabi Netanya', 'מכבי נתניה', 'Маккаби Нетания'),
    ('Hapoel Haifa', 'הפועל חיפה', 'Хапоэль Хайфа'),
    ('Bnei Sakhnin', 'בני סכנין', 'Бней Сахнин'),
    ('Hapoel Ramat Gan Givatayim', 'הפועל רמת-גן גבעתיים', 'Хапоэль Рамат-Ган Гиватаим'),
    ('Hapoel Jerusalem', 'הפועל ירושלים', 'Хапоэль Иерусалим'),
    ('Ironi Kiryat Shmona', 'עירוני קריית שמונה', 'Ирони Кирьят-Шмона'),
    ('Maccabi Petah Tikva', 'מכבי פתח תקווה', 'Маккаби Петах-Тиква'),
    ('Hapoel Petah Tikva', 'הפועל פתח תקווה', 'Хапоэль Петах-Тиква'),
    ('Ironi Tiberias', 'עירוני טבריה', 'Ирони Тверия'),
    -- Liga Leumit clubs
    ('F.C. Ashdod', 'מ.ס. אשדוד', 'Ашдод'),
    ('Maccabi Bnei Reineh', 'מכבי בני ריינה', 'Маккаби Бней Рейне'),
    ('Bnei Yehuda', 'בני יהודה', 'Бней Иегуда'),
    ('Maccabi Kiryat Gat', 'מכבי קריית גת', 'Маккаби Кирьят-Гат'),
    ('Hapoel Kfar Saba', 'הפועל כפר סבא', 'Хапоэль Кфар-Сава'),
    ('Hapoel Kfar Shalem', 'הפועל כפר שלם', 'Хапоэль Кфар-Шалем'),
    ('Maccabi Akhi Nazareth', 'מכבי אחי נצרת', 'Маккаби Ахей Нацрат'),
    ('Hapoel Akko', 'הפועל עכו', 'Хапоэль Акко'),
    ('Hapoel Afula', 'הפועל עפולה', 'Хапоэль Афула'),
    ('Hapoel Rishon LeZion', 'הפועל ראשון לציון', 'Хапоэль Ришон-ле-Цион'),
    ('Hapoel Ra''anana', 'הפועל רעננה', 'Хапоэль Раанана'),
    ('F.C. Kafr Qasim', 'מ.ס. כפר קאסם', 'ФК Кафр-Касем'),
    ('F.C. Kiryat Yam', 'מ.ס. קריית ים', 'ФК Кирьят-Ям'),
    ('Maccabi Herzliya', 'מכבי הרצליה', 'Маккаби Герцлия'),
    ('Maccabi Kavilio Jaffa', 'מכבי קביליו יפו', 'Маккаби Кавильо Яффо'),
    ('Ironi Modi''in', 'עירוני מודיעין', 'Ирони Модиин'),
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
    ('Liechtenstein', 'ליכטנשטיין', 'Лихтенштейн'),
    -- changes -- see scripts/sync-seed-from-rds.sh)
    ('1. FC Köln', 'פ. צ. קלן', 'Кёльн'),
    ('FC Schalke 04', 'שאלקה 04', 'Шальке 04'),
    ('Hamburger SV', 'המבורג', 'Гамбург'),
    ('SC Paderborn 07', 'פאדרבורן 07', 'Падерборн 07'),
    ('SV Elversberg', 'אלוורסברג', 'Эльферсберг'),
    ('Deportivo de A Coruña', 'דפורטיבו דה א-קורוניה', 'Депортиво Ла-Корунья'),
    ('Elche', 'אלצ''ה', 'Эльче'),
    ('Levante', 'לבאנטה', 'Леванте'),
    ('Málaga', 'מאלגה', 'Малага'),
    ('Racing Santander', 'ראסינג סנטנדר', 'Расинг Сантандер'),
    ('Coventry City', 'קובנטרי סיטי', 'Ковентри Сити'),
    ('Hull City', 'האל סיטי', 'Халл Сити'),
    ('Leeds United', 'לידס יונייטד', 'Лидс Юнайтед'),
    ('Frosinone', 'פרוזינונה', 'Фрозиноне'),
    ('Club Brugge', 'קלאב ברוז''', 'Брюгге'),
    ('Feyenoord', 'פיינורד', 'Фейеноорд'),
    ('Galatasaray', 'גלאטסראיי', 'Галатасарай'),
    ('Lens', 'לאנס', 'Ланс'),
    ('Lille', 'ליל', 'Лилль'),
    ('PSV Eindhoven', 'פ.ס.וו. איינדהובן', 'ПСВ'),
    ('Shakhtar Donetsk', 'שחטאר דונצק', 'Шахтёр Донецк'),
    ('Slavia Prague', 'סלביה פראג', 'Славия Прага'),
    ('Sporting CP', 'ספורטינג ליסבון', 'Спортинг Лиссабон'),
    ('Sunderland', 'סנדרלנד', 'Сандерленд'),
    ('Sassuolo', 'ססואולו', 'Сассуоло')
) AS v(name_en, name_he, name_ru)
WHERE c.name_en = v.name_en;

-- World Cup 2026 national-team crests: each nation's football-federation badge, via Wikimedia's
-- stable upload URLs. These replace the flagcdn.com national flags this block used to seed -- a
-- badge reads as a football crest alongside the club crests in every other league, where a flag
-- read as a country picker. Like competition emblems, federation badges carry no per-club
-- trademark ambiguity, so they are safe to seed directly (club and party logo_url values are still
-- left NULL for admin curation).
--
-- The guard accepts two states -- never seeded (NULL) and still carrying the flag this file seeded
-- (a flagcdn.com URL) -- so an already-seeded production database moves to the crest, while a logo
-- an admin set through the admin UI is neither, and is never overwritten. That is the same
-- guarantee as the plain "AND logo_url IS NULL" guard used elsewhere in this file, widened by
-- exactly one known-seeded value; see services/backend/CLAUDE.md on why these stay guarded at all.
UPDATE clubs c SET logo_url = v.logo_url
FROM (VALUES
    ('Brazil', 'https://upload.wikimedia.org/wikipedia/commons/3/32/Confedera%C3%A7%C3%A3o_Brasileira_de_Futebol_logo_%282020%29.svg'),
    ('Argentina', 'https://upload.wikimedia.org/wikipedia/en/c/c1/Argentina_national_football_team_logo.svg'),
    ('France', 'https://upload.wikimedia.org/wikipedia/en/f/f4/France_NT_2026_logo.svg'),
    ('England', 'https://upload.wikimedia.org/wikipedia/en/8/8b/England_national_football_team_crest.svg'),
    ('Spain', 'https://upload.wikimedia.org/wikipedia/en/3/39/Spain_national_football_team_crest.svg'),
    ('Germany', 'https://upload.wikimedia.org/wikipedia/en/e/e3/DFBEagle.svg'),
    ('Portugal', 'https://upload.wikimedia.org/wikipedia/en/e/e4/Portugal_national_football_team_logo.svg'),
    ('Netherlands', 'https://upload.wikimedia.org/wikipedia/en/7/78/Netherlands_national_football_team_logo.svg'),
    ('Belgium', 'https://upload.wikimedia.org/wikipedia/en/f/f9/Royal_Belgian_FA_logo_2019.svg'),
    ('Croatia', 'https://upload.wikimedia.org/wikipedia/en/e/ea/Croatia_national_football_team_logo.svg'),
    ('Uruguay', 'https://upload.wikimedia.org/wikipedia/en/4/43/Uruguay_national_football_team_seal.svg'),
    ('Colombia', 'https://upload.wikimedia.org/wikipedia/commons/2/29/FCF-Logo-2023.svg'),
    ('Mexico', 'https://upload.wikimedia.org/wikipedia/en/3/3f/Mexico_national_football_team_crest.svg'),
    ('USA', 'https://upload.wikimedia.org/wikipedia/commons/1/1e/United_States_Soccer_Federation_logo.svg'),
    ('Canada', 'https://upload.wikimedia.org/wikipedia/commons/6/69/Canadian_Soccer_Association_logo.svg'),
    ('Japan', 'https://upload.wikimedia.org/wikipedia/en/8/84/Japan_national_football_team_crest.svg'),
    ('South Korea', 'https://upload.wikimedia.org/wikipedia/en/4/41/South_Korea_national_football_team.svg'),
    ('Morocco', 'https://upload.wikimedia.org/wikipedia/en/d/d0/Royal_Moroccan_Football_Federation_logo.svg'),
    ('Senegal', 'https://upload.wikimedia.org/wikipedia/en/1/16/Senegalese_Football_Federation_logo.svg'),
    ('Ghana', 'https://upload.wikimedia.org/wikipedia/en/9/9c/Ghana_Football_Association_logo_%282001%29.svg'),
    ('Egypt', 'https://upload.wikimedia.org/wikipedia/en/f/f8/Egyptian_Football_Association_logo.svg'),
    ('Tunisia', 'https://upload.wikimedia.org/wikipedia/en/c/c4/Tunisia_national_football_team_logo.png'),
    ('Algeria', 'https://upload.wikimedia.org/wikipedia/en/2/2d/Algerian_NT_%28logo%29.png'),
    ('Ivory Coast', 'https://upload.wikimedia.org/wikipedia/en/0/09/Ivory_Coast_national_football_team_logo.svg'),
    ('Australia', 'https://upload.wikimedia.org/wikipedia/commons/c/cf/Australia_national_football_team_badge.svg'),
    ('Iran', 'https://upload.wikimedia.org/wikipedia/en/d/d6/Football_Federation_Islamic_Republic_of_Iran_logo.svg'),
    ('Saudi Arabia', 'https://upload.wikimedia.org/wikipedia/en/e/ee/Saudi_Arabia_national_football_team_logo.svg'),
    ('Qatar', 'https://upload.wikimedia.org/wikipedia/en/3/3a/Qatar_Football_Association_logo.svg'),
    ('Ecuador', 'https://upload.wikimedia.org/wikipedia/commons/e/e3/Logo_de_la_Federaci%C3%B3n_Ecuatoriana_de_F%C3%BAtbol_%282%29.svg'),
    ('Switzerland', 'https://upload.wikimedia.org/wikipedia/en/a/a0/Swiss_Football_Association_logo.svg'),
    ('Sweden', 'https://upload.wikimedia.org/wikipedia/en/3/3f/Sweden_national_football_team_badge.svg'),
    ('Uzbekistan', 'https://upload.wikimedia.org/wikipedia/en/3/3d/Uzbekistan_Football_Association.svg'),
    ('Jordan', 'https://upload.wikimedia.org/wikipedia/commons/5/54/Jordan_national_football_team_logo_2024.svg'),
    ('Iraq', 'https://upload.wikimedia.org/wikipedia/commons/2/24/Iraq_National_Team_Badge_2021_v1.svg'),
    ('Cape Verde', 'https://upload.wikimedia.org/wikipedia/en/c/ce/Cape_Verdean_Football_Federation_logo.svg'),
    ('South Africa', 'https://upload.wikimedia.org/wikipedia/en/e/e7/South_Africa_national_soccer_team_logo.svg'),
    ('DR Congo', 'https://upload.wikimedia.org/wikipedia/en/6/62/Congolese_Association_Football_Federation_logo.png'),
    ('Panama', 'https://upload.wikimedia.org/wikipedia/en/e/ee/Panamanian_Football_Federation_logo_2024.svg'),
    ('Curaçao', 'https://upload.wikimedia.org/wikipedia/en/1/1c/Curacao_Football_Federation.svg'),
    ('Haiti', 'https://upload.wikimedia.org/wikipedia/en/e/e7/Federation_Haitienne_de_Football.png'),
    ('Paraguay', 'https://upload.wikimedia.org/wikipedia/commons/1/14/Asociaci%C3%B3n_Paraguaya_de_F%C3%BAtbol_logo.svg'),
    ('New Zealand', 'https://upload.wikimedia.org/wikipedia/en/3/3a/New_Zealand_Football_Crest_2022.svg'),
    ('Norway', 'https://upload.wikimedia.org/wikipedia/en/6/6c/Norway_national_football_team_logo.svg'),
    ('Scotland', 'https://upload.wikimedia.org/wikipedia/en/5/50/Scotland_national_football_team_logo_2014.svg'),
    ('Austria', 'https://upload.wikimedia.org/wikipedia/en/b/b7/Austria_national_football_team_crest.svg'),
    ('Bosnia and Herzegovina', 'https://upload.wikimedia.org/wikipedia/en/d/da/Football_Association_of_Bosnia_and_Herzegovina_logo.svg'),
    ('Turkey', 'https://upload.wikimedia.org/wikipedia/commons/7/71/Roundel_flag_of_Turkey.svg'),
    ('Czech Republic', 'https://upload.wikimedia.org/wikipedia/en/7/76/Czech_Republic_national_football_team_logo.svg')
) AS v(name_en, logo_url)
WHERE c.name_en = v.name_en
  AND (c.logo_url IS NULL OR c.logo_url LIKE 'https://flagcdn.com/%');

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

-- Admin-curated club logos, synced from the live RDS instance (added via the admin UI's Logo
-- URL field for the full Israeli Premier League roster) so a fresh install matches current
-- production data. Also folds in the Hapoel Ramat Gan Givatayim / Maccabi Petah Tikva / Ironi
-- Tiberias promotion swap (Ashdod, Maccabi Bnei Reineh, and Hapoel Kfar Saba relegated out) and
-- the Hapoel Be'er Sheva / Ironi Kiryat Shmona name_en corrections above.
UPDATE clubs t SET logo_url = v.logo_url
FROM (VALUES
    ('Maccabi Haifa', 'https://upload.wikimedia.org/wikipedia/he/1/1e/%D7%A1%D7%9E%D7%9C_%D7%9E%D7%9B%D7%91%D7%99_%D7%97%D7%99%D7%A4%D7%94_2023.png'),
    ('Maccabi Tel Aviv', 'https://upload.wikimedia.org/wikipedia/he/4/45/Maccabi_Tel_Aviv_FC.png'),
    ('Hapoel Be''er Sheva', 'https://upload.wikimedia.org/wikipedia/en/8/85/Logo-hapoel-positive.svg'),
    ('Hapoel Tel Aviv', 'https://upload.wikimedia.org/wikipedia/en/a/ac/Hapoel_Tel_Aviv_F.C.png'),
    ('Beitar Jerusalem', 'https://upload.wikimedia.org/wikipedia/en/6/61/Beitar_Jerusalem.png'),
    ('Maccabi Netanya', 'https://upload.wikimedia.org/wikipedia/he/b/bc/MaccabiNetanyaNewlogo2021.png'),
    ('Hapoel Haifa', 'https://upload.wikimedia.org/wikipedia/en/e/e4/Hapoel_Haifa_New_Logo.png'),
    ('Bnei Sakhnin', 'https://upload.wikimedia.org/wikipedia/he/b/bb/Hapo%C3%83%C2%ABl_Bnei_Sakhnin.png'),
    ('Hapoel Ramat Gan Givatayim', 'https://upload.wikimedia.org/wikipedia/en/9/91/Hapoel_ramat-gan.svg'),
    ('Hapoel Jerusalem', 'https://upload.wikimedia.org/wikipedia/en/5/5d/FC_Hapoel_Jerusalem_2021.png'),
    ('Ironi Kiryat Shmona', 'https://upload.wikimedia.org/wikipedia/en/d/d1/Hapoel_Ironi_Kiryat_Shmona_badge.png'),
    ('Maccabi Petah Tikva', 'https://upload.wikimedia.org/wikipedia/he/9/93/MPT_FC_2024.png'),
    ('Hapoel Petah Tikva', 'https://upload.wikimedia.org/wikipedia/he/6/63/Hapoel_Petach_Tikva_logo.png'),
    ('Ironi Tiberias', 'https://upload.wikimedia.org/wikipedia/he/8/84/Ironi_logo_new.gif'),

    -- Liga Leumit club logos. F.C. Kiryat Yam has no Wikimedia crest. It used to hotlink the club's
    -- Instagram profile picture, which was wrong for three independent reasons: the URL is signed and
    -- expires (`oe=`), the CDN may refuse hotlinks, and -- the one that actually bit -- browsers with
    -- tracker blocking (uBlock, Firefox ETP, Brave, Safari ITP) drop *.fbcdn.net requests outright.
    -- The crest was therefore invisible to many visitors while `curl` fetched it happily, which is a
    -- failure no server-side check can detect. It is now served from our own origin instead.
    ('F.C. Ashdod', 'https://upload.wikimedia.org/wikipedia/he/5/5b/Ashdod.png'),
    ('Maccabi Bnei Reineh', 'https://upload.wikimedia.org/wikipedia/he/f/f7/MaccabiBneiReine2022.png'),
    ('Bnei Yehuda', 'https://upload.wikimedia.org/wikipedia/en/f/f5/Bnei_Jehuda_Tel_Aviv_FC.svg'),
    -- Maccabi Kiryat Gat has no Wikimedia crest either, so it is served from our own origin for the
    -- same three reasons as F.C. Kiryat Yam below -- the club's only artwork is on *.fbcdn.net, whose
    -- URLs are signed and expire, and which tracker blockers drop outright in the browser. Unlike
    -- Kiryat Yam this row carries the plain IS NULL guard, because there is no bad value to correct:
    -- the club is new to the roster, so it has never had a logo_url at all.
    ('Maccabi Kiryat Gat', '/logos/kiryat-gat.png'),
    ('Hapoel Kfar Saba', 'https://upload.wikimedia.org/wikipedia/he/8/87/Hapoel_Kfar_Saba_FC_Logo.png'),
    ('Hapoel Kfar Shalem', 'https://upload.wikimedia.org/wikipedia/he/9/90/Hapoel_Kfar_Shalem_Logo.png'),
    ('Maccabi Akhi Nazareth', 'https://upload.wikimedia.org/wikipedia/he/3/37/Akhi_Nazareth_FC_Maalouf.png'),
    ('Hapoel Akko', 'https://upload.wikimedia.org/wikipedia/he/7/75/Hapoelakko.png'),
    ('Hapoel Afula', 'https://upload.wikimedia.org/wikipedia/en/0/01/Hapoel_Afula_F.C.png'),
    ('Hapoel Rishon LeZion', 'https://upload.wikimedia.org/wikipedia/he/c/ce/Hap-rish.png'),
    ('Hapoel Ra''anana', 'https://upload.wikimedia.org/wikipedia/en/3/3f/HapoelRaanana.png'),
    ('F.C. Kafr Qasim', 'https://upload.wikimedia.org/wikipedia/he/6/6f/FC_Kafr_Qasim_Logo.png'),
    ('Maccabi Herzliya', 'https://upload.wikimedia.org/wikipedia/he/f/f5/Maccabi_Herzliya.png'),
    ('Maccabi Kavilio Jaffa', 'https://upload.wikimedia.org/wikipedia/he/8/88/MaccabiJaffaCrestNew2018.png'),
    ('Ironi Modi''in', 'https://upload.wikimedia.org/wikipedia/he/d/d6/IroniModiinFC.png'),

    -- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh.
    ('Sassuolo', 'https://upload.wikimedia.org/wikipedia/en/1/1c/US_Sassuolo_Calcio_logo.svg'),
    ('Sunderland', 'https://upload.wikimedia.org/wikipedia/en/7/77/Logo_Sunderland.svg'),

    -- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh.
    ('1. FC Köln', 'https://upload.wikimedia.org/wikipedia/commons/0/01/1._FC_Koeln_Logo_2014%E2%80%93.svg'),
    ('AC Milan', 'https://upload.wikimedia.org/wikipedia/commons/d/d0/Logo_of_AC_Milan.svg'),
    ('Alavés', 'https://upload.wikimedia.org/wikipedia/en/f/f8/Deportivo_Alaves_logo_%282020%29.svg'),
    ('Arsenal', 'https://upload.wikimedia.org/wikipedia/en/5/53/Arsenal_FC.svg'),
    ('Aston Villa', 'https://upload.wikimedia.org/wikipedia/en/9/9a/Aston_Villa_FC_new_crest.svg'),
    ('Atalanta', 'https://upload.wikimedia.org/wikipedia/en/f/f2/Atalanta_BC_new_logo.svg'),
    ('Athletic Bilbao', 'https://upload.wikimedia.org/wikipedia/en/9/98/Club_Athletic_Bilbao_logo.svg'),
    ('Atlético Madrid', 'https://upload.wikimedia.org/wikipedia/en/f/f9/Atletico_Madrid_Logo_2024.svg'),
    ('Barcelona', 'https://upload.wikimedia.org/wikipedia/en/4/47/FC_Barcelona_%28crest%29.svg'),
    ('Bayer Leverkusen', 'https://upload.wikimedia.org/wikipedia/en/5/59/Bayer_04_Leverkusen_logo.svg'),
    ('Bayern Munich', 'https://upload.wikimedia.org/wikipedia/commons/8/8d/FC_Bayern_M%C3%BCnchen_logo_%282024%29.svg'),
    ('Bologna', 'https://upload.wikimedia.org/wikipedia/commons/5/5b/Bologna_F.C._1909_logo.svg'),
    ('Borussia Dortmund', 'https://upload.wikimedia.org/wikipedia/commons/6/67/Borussia_Dortmund_logo.svg'),
    ('Borussia Mönchengladbach', 'https://upload.wikimedia.org/wikipedia/commons/8/81/Borussia_M%C3%B6nchengladbach_logo.svg'),
    ('Bournemouth', 'https://upload.wikimedia.org/wikipedia/en/e/e5/AFC_Bournemouth_%282013%29.svg'),
    ('Brentford', 'https://upload.wikimedia.org/wikipedia/en/2/2a/Brentford_FC_crest.svg'),
    ('Brighton & Hove Albion', 'https://upload.wikimedia.org/wikipedia/en/d/d0/Brighton_and_Hove_Albion_FC_crest.svg'),
    ('Cagliari', 'https://upload.wikimedia.org/wikipedia/en/6/61/Cagliari_Calcio_1920.svg'),
    ('Celta Vigo', 'https://upload.wikimedia.org/wikipedia/en/1/12/RC_Celta_de_Vigo_logo.svg'),
    ('Chelsea', 'https://upload.wikimedia.org/wikipedia/en/c/cc/Chelsea_FC.svg'),
    ('Club Brugge', 'https://upload.wikimedia.org/wikipedia/commons/9/97/Club_brugge.png'),
    ('Como', 'https://upload.wikimedia.org/wikipedia/commons/9/99/Calcio_Como_-_logo_%28Italy%2C_2019-%29.svg'),
    ('Coventry City', 'https://upload.wikimedia.org/wikipedia/en/7/7b/Coventry_City_FC_crest.svg'),
    ('Crystal Palace', 'https://upload.wikimedia.org/wikipedia/en/a/a2/Crystal_Palace_FC_logo_%282022%29.svg'),
    ('Deportivo de A Coruña', 'https://upload.wikimedia.org/wikipedia/en/5/56/RC_Deportivo_A_Coru%C3%B1a_logo_2026.svg'),
    ('Eintracht Frankfurt', 'https://upload.wikimedia.org/wikipedia/en/7/7e/Eintracht_Frankfurt_crest.svg'),
    ('Elche', 'https://upload.wikimedia.org/wikipedia/en/a/a7/Elche_CF_logo.svg'),
    ('Espanyol', 'https://upload.wikimedia.org/wikipedia/en/9/92/RCD_Espanyol_crest.svg'),
    ('Everton', 'https://upload.wikimedia.org/wikipedia/en/7/7c/Everton_FC_logo.svg'),
    ('FC Augsburg', 'https://upload.wikimedia.org/wikipedia/en/c/c5/FC_Augsburg_logo.svg'),
    ('FC Schalke 04', 'https://upload.wikimedia.org/wikipedia/commons/6/6d/FC_Schalke_04_Logo.svg'),
    ('Feyenoord', 'https://upload.wikimedia.org/wikipedia/commons/f/f9/Feyenoord_logo_since_2024.svg'),
    ('Fiorentina', 'https://upload.wikimedia.org/wikipedia/commons/8/8c/ACF_Fiorentina_-_logo_%28Italy%2C_2022%29.svg'),
    ('Frosinone', 'https://upload.wikimedia.org/wikipedia/en/0/0b/Frosinone_Calcio_logo.svg'),
    ('Fulham', 'https://upload.wikimedia.org/wikipedia/en/e/eb/Fulham_FC_%28shield%29.svg'),
    ('Galatasaray', 'https://upload.wikimedia.org/wikipedia/commons/0/07/Galatasaray_S.K._Logo_2026_5-stars.svg'),
    ('Genoa', 'https://upload.wikimedia.org/wikipedia/en/2/2c/Genoa_CFC_crest.svg'),
    ('Getafe', 'https://upload.wikimedia.org/wikipedia/en/4/46/Getafe_logo.svg'),
    ('Hamburger SV', 'https://upload.wikimedia.org/wikipedia/commons/f/f7/Hamburger_SV_logo.svg'),
    ('Hull City', 'https://upload.wikimedia.org/wikipedia/en/5/54/Hull_City_A.F.C._logo.svg'),
    ('Inter Milan', 'https://upload.wikimedia.org/wikipedia/commons/0/05/FC_Internazionale_Milano_2021.svg'),
    ('Ipswich Town', 'https://upload.wikimedia.org/wikipedia/en/4/43/Ipswich_Town.svg'),
    ('Juventus', 'https://upload.wikimedia.org/wikipedia/commons/e/ed/Juventus_FC_-_logo_black_%28Italy%2C_2020%29.svg'),
    ('Lazio', 'https://upload.wikimedia.org/wikipedia/en/c/ce/S.S._Lazio_badge.svg'),
    ('Lecce', 'https://upload.wikimedia.org/wikipedia/en/2/23/US_Lecce_crest.svg'),
    ('Leeds United', 'https://upload.wikimedia.org/wikipedia/en/5/54/Leeds_United_F.C._logo.svg'),
    ('Lens', 'https://upload.wikimedia.org/wikipedia/en/c/cc/RC_Lens_logo.svg'),
    ('Levante', 'https://upload.wikimedia.org/wikipedia/en/7/7b/Levante_Uni%C3%B3n_Deportiva%2C_S.A.D._logo.svg'),
    ('Lille', 'https://upload.wikimedia.org/wikipedia/en/3/3f/Lille_OSC_2018_logo.svg'),
    ('Liverpool', 'https://upload.wikimedia.org/wikipedia/en/0/0c/Liverpool_FC.svg'),
    ('Mainz 05', 'https://upload.wikimedia.org/wikipedia/commons/1/1b/1._FSV_Mainz_05_logo.svg'),
    ('Manchester City', 'https://upload.wikimedia.org/wikipedia/en/e/eb/Manchester_City_FC_badge.svg'),
    ('Manchester United', 'https://upload.wikimedia.org/wikipedia/en/7/7a/Manchester_United_FC_crest.svg'),
    ('Monza', 'https://upload.wikimedia.org/wikipedia/en/a/a7/AC_Monza_logo_%282021%29.svg'),
    ('Málaga', 'https://upload.wikimedia.org/wikipedia/en/6/6d/M%C3%A1laga_CF.svg'),
    ('Napoli', 'https://upload.wikimedia.org/wikipedia/commons/4/4d/SSC_Napoli_2025_%28white_and_azure%29.svg'),
    ('Newcastle United', 'https://upload.wikimedia.org/wikipedia/en/5/56/Newcastle_United_Logo.svg'),
    ('Nottingham Forest', 'https://upload.wikimedia.org/wikipedia/en/e/e5/Nottingham_Forest_F.C._logo.svg'),
    ('Osasuna', 'https://upload.wikimedia.org/wikipedia/en/3/38/CA_Osasuna_2024_crest.svg'),
    ('PSV Eindhoven', 'https://upload.wikimedia.org/wikipedia/en/0/05/PSV_Eindhoven.svg'),
    ('Paris Saint-Germain', 'https://upload.wikimedia.org/wikipedia/en/a/a7/Paris_Saint-Germain_F.C..svg'),
    ('Parma', 'https://upload.wikimedia.org/wikipedia/commons/9/97/Logo_Parma_Calcio_1913_%28adozione_2016%29.svg'),
    ('Porto', 'https://upload.wikimedia.org/wikipedia/en/f/f1/FC_Porto.svg'),
    ('RB Leipzig', 'https://upload.wikimedia.org/wikipedia/en/0/04/RB_Leipzig_2014_logo.svg'),
    ('Racing Santander', 'https://upload.wikimedia.org/wikipedia/en/f/f5/Racing_de_Santander_logo.svg'),
    ('Rayo Vallecano', 'https://upload.wikimedia.org/wikipedia/en/d/d8/Rayo_Vallecano_logo.svg'),
    ('Real Betis', 'https://upload.wikimedia.org/wikipedia/en/2/2f/Real_Betis_2022_logo.svg'),
    ('Real Madrid', 'https://upload.wikimedia.org/wikipedia/en/5/56/Real_Madrid_CF.svg'),
    ('Real Sociedad', 'https://upload.wikimedia.org/wikipedia/en/f/f1/Real_Sociedad_logo.svg'),
    ('Roma', 'https://upload.wikimedia.org/wikipedia/en/f/f7/AS_Roma_logo_%282017%29.svg'),
    ('SC Freiburg', 'https://upload.wikimedia.org/wikipedia/en/6/6d/SC_Freiburg_logo.svg'),
    ('SC Paderborn 07', 'https://upload.wikimedia.org/wikipedia/commons/6/67/SC_Paderborn_07_Logo_new.svg'),
    ('SV Elversberg', 'https://upload.wikimedia.org/wikipedia/commons/d/d4/SV_Elversberg_Logo_2021.svg'),
    ('Sevilla', 'https://upload.wikimedia.org/wikipedia/en/3/3b/Sevilla_FC_logo.svg'),
    ('Shakhtar Donetsk', 'https://upload.wikimedia.org/wikipedia/en/a/a1/FC_Shakhtar_Donetsk.svg'),
    ('Slavia Prague', 'https://upload.wikimedia.org/wikipedia/commons/2/2b/SK_Slavia_Praha_full_logo.svg'),
    ('Sporting CP', 'https://upload.wikimedia.org/wikipedia/commons/e/e7/Sporting_Clube_de_Portugal_2026.svg'),
    ('TSG Hoffenheim', 'https://upload.wikimedia.org/wikipedia/commons/e/e7/Logo_TSG_Hoffenheim.svg'),
    ('Torino', 'https://upload.wikimedia.org/wikipedia/en/2/2e/Torino_FC_Logo.svg'),
    ('Tottenham Hotspur', 'https://upload.wikimedia.org/wikipedia/en/b/b4/Tottenham_Hotspur.svg'),
    ('Udinese', 'https://upload.wikimedia.org/wikipedia/en/c/ce/Udinese_Calcio_logo.svg'),
    ('Union Berlin', 'https://upload.wikimedia.org/wikipedia/commons/4/44/1._FC_Union_Berlin_Logo.svg'),
    ('Valencia', 'https://upload.wikimedia.org/wikipedia/en/c/ce/Valenciacf.svg'),
    ('Venezia', 'https://upload.wikimedia.org/wikipedia/en/3/39/Venezia_FC_crest.svg'),
    ('VfB Stuttgart', 'https://upload.wikimedia.org/wikipedia/commons/e/eb/VfB_Stuttgart_1893_Logo.svg'),
    ('Villarreal', 'https://upload.wikimedia.org/wikipedia/en/b/b9/Villarreal_CF_logo-en.svg'),
    ('Werder Bremen', 'https://upload.wikimedia.org/wikipedia/commons/b/be/SV-Werder-Bremen-Logo.svg')
) AS v(name_en, logo_url)
WHERE t.name_en = v.name_en
  AND t.logo_url IS NULL;

-- Served from our own origin (services/frontend/logos/kiryat-yam.png), cropped from the club's
-- square artwork to a transparent circle. The IS NULL guard is deliberately widened here: every
-- other row must not clobber admin edits, but this one has to CORRECT a known-bad value that is
-- already in the database, which a plain `IS NULL` guard would silently skip forever. That is why
-- it stays a single statement rather than joining the VALUES block above, which carries the plain
-- guard for all 118 other clubs.
UPDATE clubs SET logo_url = '/logos/kiryat-yam.png' WHERE name_en = 'F.C. Kiryat Yam' AND (logo_url IS NULL OR logo_url LIKE '%fbcdn.net%');

-- Previous Knesset party display names.
-- One row per entity, all display languages together. COALESCE is the per-column equivalent of
-- the old "AND name_xx IS NULL" guard: it fills only what is still empty, so a name an admin has
-- renamed through the live UI is never overwritten. Do not drop it.
UPDATE previous_parties p SET
    name_en = COALESCE(p.name_en, v.name_en),
    name_ru = COALESCE(p.name_ru, v.name_ru)
FROM (VALUES
    ('הליכוד', 'Likud', 'Ликуд'),
    ('יש עתיד', 'Yesh Atid', 'Еш Атид'),
    ('הציונות הדתית', 'Religious Zionist Party', 'Ха-Цийонут ха-Датит'),
    ('המחנה הממלכתי', 'National Unity', 'Ха-Махане ха-Мамлахти'),
    ('ישראל ביתנו', 'Yisrael Beiteinu', 'Наш дом Израиль'),
    ('ש"ס', 'Shas', 'ШАС'),
    ('יהדות התורה', 'United Torah Judaism', 'Яхадут ха-Тора'),
    ('רע"ם', 'Ra''am', 'РААМ'),
    ('חד"ש-תע"ל', 'Hadash-Ta''al', 'ХАДАШ-ТААЛ'),
    ('העבודה', 'Labor', 'Авода'),
    ('מרצ', 'Meretz', 'МЕРЕЦ'),
    ('בל"ד', 'Balad', 'БАЛАД'),
    ('אחר', 'Other', 'Другое')
) AS v(name_he, name_en, name_ru)
WHERE p.name_he = v.name_he;

-- Admin-curated party logos, synced from the live RDS instance (added via the admin UI's
-- Logo URL field, not originally seeded) so a fresh install matches current production data.
UPDATE previous_parties t SET logo_url = v.logo_url
FROM (VALUES
    ('הליכוד', 'https://upload.wikimedia.org/wikipedia/commons/5/50/Likud_Logo.svg'),
    ('יש עתיד', 'https://upload.wikimedia.org/wikipedia/he/1/12/%D7%99%D7%A9_%D7%A2%D7%AA%D7%99%D7%93_%D7%9C%D7%95%D7%92%D7%95.svg'),
    ('הציונות הדתית', 'https://upload.wikimedia.org/wikipedia/he/c/c2/%D7%9C%D7%95%D7%92%D7%95_%D7%94%D7%A6%D7%99%D7%95%D7%A0%D7%95%D7%AA_%D7%94%D7%93%D7%AA%D7%99%D7%AA_2022.svg'),
    ('המחנה הממלכתי', 'https://upload.wikimedia.org/wikipedia/he/e/e0/%D7%9C%D7%95%D7%92%D7%95_%D7%94%D7%9E%D7%97%D7%A0%D7%94_%D7%94%D7%9E%D7%9E%D7%9C%D7%9B%D7%AA%D7%99_%D7%90%D7%95%D7%92%D7%95%D7%A1%D7%98_2022.svg'),
    ('ישראל ביתנו', 'https://upload.wikimedia.org/wikipedia/he/a/a4/%D7%9C%D7%95%D7%92%D7%95_%D7%99%D7%A9%D7%A8%D7%90%D7%9C_%D7%91%D7%99%D7%AA%D7%A0%D7%95_2022.svg'),
    ('ש"ס', 'https://upload.wikimedia.org/wikipedia/he/0/05/Shas_logo.svg'),
    ('יהדות התורה', 'https://upload.wikimedia.org/wikipedia/he/9/97/%D7%99%D7%94%D7%93%D7%95%D7%AA_%D7%94%D7%AA%D7%95%D7%A8%D7%94_%D7%9C%D7%95%D7%92%D7%95_2019.svg'),
    ('רע"ם', 'https://upload.wikimedia.org/wikipedia/he/0/08/%D7%94%D7%A8%D7%A9%D7%99%D7%9E%D7%94_%D7%94%D7%A2%D7%A8%D7%91%D7%99%D7%AA_%D7%94%D7%9E%D7%90%D7%95%D7%97%D7%93%D7%AA_%D7%9C%D7%95%D7%92%D7%95_2021.svg'),
    ('חד"ש-תע"ל', 'https://upload.wikimedia.org/wikipedia/he/e/eb/%D7%9C%D7%95%D7%92%D7%95_%D7%97%D7%93%D7%B4%D7%A9_%D7%AA%D7%A2%D7%B4%D7%9C_2022_%28%D7%A2%D7%91%D7%A8%D7%99%D7%AA%29.svg'),
    ('העבודה', 'https://upload.wikimedia.org/wikipedia/commons/f/f8/HaAvoda_Logo.svg'),
    ('מרצ', 'https://upload.wikimedia.org/wikipedia/he/f/ff/%D7%9C%D7%95%D7%92%D7%95_%D7%9E%D7%A8%D7%A6_%D7%99%D7%95%D7%9C%D7%99_2022.svg'),
    ('בל"ד', 'https://upload.wikimedia.org/wikipedia/he/1/19/Balad.svg')
) AS v(name_he, logo_url)
WHERE t.name_he = v.name_he
  AND t.logo_url IS NULL;

-- Party ideology classification. The VALUES below are authoritative; the REASONING for every one
-- of them lives in docs/party-classifications.md. Do not restate reasoning in this file -- if a
-- number here needs justifying, justify it there and leave this table plain.
--
-- These UPDATEs are deliberately UNGUARDED, unlike the name/logo_url statements above. Production
-- is always already seeded, so an `AND bloc IS NULL` guard would make every later edit to this
-- table unreachable in production. Unguarded is safe for these six columns specifically: nothing
-- in the app ever writes them (the admin party endpoints only rename), so re-running seed.sql
-- rewrites identical values. Names and logo_url keep their `IS NULL` guards for the opposite
-- reason -- admins DO edit those live, and an unguarded write would destroy their edits.
--
-- 'אחר' (Other) is absent on purpose: it is a catch-all ballot option, not a party, and every
-- ideology column stays NULL. test_migration.py asserts that.
UPDATE previous_parties p SET
    bloc = v.bloc, economic = v.economic, security = v.security,
    religiosity = v.religiosity, sector = v.sector, tags = v.tags
FROM (VALUES
    ('הליכוד', 'bibi', 1, 2, 2, 'traditional', ARRAY['claims-economically-liberal', 'populist', 'nationalist', 'instrumentally-clerical']::text[]),
    ('יש עתיד', 'opposition', 0, 0, -2, 'secular', ARRAY['liberal-zionist', 'centrist']::text[]),
    ('הציונות הדתית', 'bibi', 0, 3, 3, 'religious_zionist', ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right']::text[]),
    ('המחנה הממלכתי', 'unaligned', 1, NULL, -1, 'secular', ARRAY['centrist', 'avoids-security-topic', 'leans-traditional']::text[]),
    ('ישראל ביתנו', 'opposition', 2, 2, -3, 'secular', ARRAY['anti-clerical', 'revisionist-zionist']::text[]),
    ('ש"ס', 'bibi', -2, 1, 2, 'haredi', ARRAY['ultra-orthodox', 'religious-conservative']::text[]),
    ('יהדות התורה', 'bibi', -2, 1, 2, 'haredi', ARRAY['ultra-orthodox', 'religious-conservative']::text[]),
    ('רע"ם', 'opposition', 0, NULL, NULL, 'arab', ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues']::text[]),
    ('חד"ש-תע"ל', 'opposition', -3, -2, NULL, 'arab', ARRAY['communist', 'arab-nationalist', 'pro-two-state']::text[]),
    ('העבודה', 'opposition', -2, -1, -2, 'secular', ARRAY['social-democrat']::text[]),
    ('מרצ', 'opposition', -2, -1, -2, 'secular', ARRAY['social-democrat']::text[]),
    ('בל"ד', 'opposition', -2, -3, -3, 'arab', ARRAY['palestinian-nationalist', 'non-zionist']::text[])
) AS v(name_he, bloc, economic, security, religiosity, sector, tags)
WHERE p.name_he = v.name_he;

-- Party lineage: continuity between previous and upcoming parties (identity, splits, merges).
-- See design spec Appendix -- Yashar, The Economic Party, El HaDegel, The Reservists, and Blue and
-- White (as an independent brand) have no seeded predecessor; 'אחר' has no successor.
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הליכוד' AND u.name_he = 'הליכוד'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'יש עתיד' AND u.name_he = 'ביחד'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הציונות הדתית' AND u.name_he = 'הציונות הדתית'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הציונות הדתית' AND u.name_he = 'עוצמה יהודית'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'הציונות הדתית' AND u.name_he = 'נעם'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'המחנה הממלכתי' AND u.name_he = 'כחול לבן'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'ישראל ביתנו' AND u.name_he = 'ישראל ביתנו'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'ש"ס' AND u.name_he = 'ש"ס'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'יהדות התורה' AND u.name_he = 'יהדות התורה'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'רע"ם' AND u.name_he = 'רע"ם'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'חד"ש-תע"ל' AND u.name_he = 'חד"ש-תע"ל'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'העבודה' AND u.name_he = 'הדמוקרטים'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'מרצ' AND u.name_he = 'הדמוקרטים'
ON CONFLICT DO NOTHING;
INSERT INTO party_lineage (previous_party_id, upcoming_party_id)
SELECT p.id, u.id FROM previous_parties p, upcoming_parties u
WHERE p.name_he = 'בל"ד' AND u.name_he = 'בל"ד'
ON CONFLICT DO NOTHING;

-- Upcoming election party display names.
-- One row per entity, all display languages together. COALESCE is the per-column equivalent of
-- the old "AND name_xx IS NULL" guard: it fills only what is still empty, so a name an admin has
-- renamed through the live UI is never overwritten. Do not drop it.
UPDATE upcoming_parties p SET
    name_en = COALESCE(p.name_en, v.name_en),
    name_ru = COALESCE(p.name_ru, v.name_ru)
FROM (VALUES
    ('הליכוד', 'Likud', 'Ликуд'),
    ('ישר', 'Yashar', 'Яшар'),
    ('ביחד', 'Together', 'Бейахад'),
    ('הדמוקרטים', 'The Democrats', 'Ха-Демократим'),
    ('כחול לבן', 'Blue and White', 'Кахоль-лаван'),
    ('ישראל ביתנו', 'Yisrael Beiteinu', 'Наш дом Израиль'),
    ('הציונות הדתית', 'Religious Zionist Party', 'Ха-Цийонут ха-Датит'),
    ('עוצמה יהודית', 'Otzma Yehudit', 'Оцма Йехудит'),
    ('חד"ש-תע"ל', 'Hadash-Ta''al', 'ХАДАШ-ТААЛ'),
    ('בל"ד', 'Balad', 'БАЛАД'),
    ('רע"ם', 'Ra''am', 'РААМ'),
    ('ש"ס', 'Shas', 'ШАС'),
    ('יהדות התורה', 'United Torah Judaism', 'Яхадут ха-Тора'),
    ('המפלגה הכלכלית', 'The Economic Party', 'Экономическая партия'),
    ('אל הדגל', 'El HaDegel', 'Эль ха-Дегель'),
    ('בית ציוני - המילואימניקים', 'The Reservists', 'Резервисты'),
    ('זהות', 'Zehut', 'Зеут'),
    ('נעם', 'Noam', 'Ноам')
) AS v(name_he, name_en, name_ru)
WHERE p.name_he = v.name_he;

-- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh.
UPDATE upcoming_parties t SET logo_url = v.logo_url
FROM (VALUES
    ('ביחד', 'https://upload.wikimedia.org/wikipedia/commons/1/14/Together-logo-29April.svg'),
    -- Self-hosted: the list's only artwork is on *.fbcdn.net, whose URLs are signed and expire and
    -- which tracker blockers drop in the browser (the F.C. Kiryat Yam failure). Cropped and its
    -- background removed, but otherwise the party's own blue lockup, shown UNCHANGED in both themes
    -- -- 'The Reservists' is in SKIP_RECOLOR_PARTIES in services/frontend/logos.js, because its Star
    -- of David is a knockout and a recolour cannot lift a hole. That file and
    -- docs/party-classifications.md carry the reasoning.
    ('בית ציוני - המילואימניקים', '/logos/beit-tzioni-miluimnikim.png'),
    ('המפלגה הכלכלית', 'https://upload.wikimedia.org/wikipedia/he/c/c9/%D7%94%D7%9E%D7%A4%D7%9C%D7%92%D7%94_%D7%94%D7%9B%D7%9C%D7%9B%D7%9C%D7%99%D7%AA_%D7%94%D7%97%D7%93%D7%A9%D7%94_%D7%9C%D7%95%D7%92%D7%95.svg'),
    ('יהדות התורה', 'https://upload.wikimedia.org/wikipedia/he/9/97/%D7%99%D7%94%D7%93%D7%95%D7%AA_%D7%94%D7%AA%D7%95%D7%A8%D7%94_%D7%9C%D7%95%D7%92%D7%95_2019.svg'),
    ('ישר', 'https://upload.wikimedia.org/wikipedia/commons/6/61/Yashar_party_logo.png'),
    ('רע"ם', 'https://upload.wikimedia.org/wikipedia/he/0/08/%D7%94%D7%A8%D7%A9%D7%99%D7%9E%D7%94_%D7%94%D7%A2%D7%A8%D7%91%D7%99%D7%AA_%D7%94%D7%9E%D7%90%D7%95%D7%97%D7%93%D7%AA_%D7%9C%D7%95%D7%92%D7%95_2021.svg'),
    ('ש"ס', 'https://upload.wikimedia.org/wikipedia/he/0/05/Shas_logo.svg'),

    -- Admin-curated party logos, synced from the live RDS instance (see previous_parties above).
    ('הליכוד', 'https://upload.wikimedia.org/wikipedia/commons/5/50/Likud_Logo.svg'),
    ('הדמוקרטים', 'https://upload.wikimedia.org/wikipedia/commons/b/b5/The_Democrats_led_by_Yair_Golan.svg'),
    ('כחול לבן', 'https://upload.wikimedia.org/wikipedia/he/a/a6/%D7%9C%D7%95%D7%92%D7%95_%D7%9B%D7%97%D7%95%D7%9C_%D7%9C%D7%91%D7%9F_2021.svg'),
    ('ישראל ביתנו', 'https://upload.wikimedia.org/wikipedia/he/a/a4/%D7%9C%D7%95%D7%92%D7%95_%D7%99%D7%A9%D7%A8%D7%90%D7%9C_%D7%91%D7%99%D7%AA%D7%A0%D7%95_2022.svg'),
    -- 2026 rebrand, UPCOMING TABLE ONLY -- previous_parties keeps the 2022 logo, because that row is
    -- the current Knesset faction. Self-hosted because neither Wikimedia revision works in both
    -- themes: the published PNG has the white background baked in (100% opaque, so it trips
    -- recolorLogoForDark()'s solid-tile guard and renders as a white plate on the dark cards), and
    -- the earlier revision it replaced is a white-ink knockout that is invisible in light mode. This
    -- is that PNG with the outer white flood-filled to transparent, which leaves the #31698C
    -- wordmark below the recolour threshold and the teal בראשות bar (luminance 0.518) just above it.
    ('הציונות הדתית', '/logos/religious-zionism-2026.png'),
    ('עוצמה יהודית', 'https://upload.wikimedia.org/wikipedia/he/9/9f/%D7%A2%D7%95%D7%A6%D7%9E%D7%94_%D7%99%D7%94%D7%95%D7%93%D7%99%D7%AA_%D7%9C%D7%95%D7%92%D7%95_2021.svg'),
    ('חד"ש-תע"ל', 'https://upload.wikimedia.org/wikipedia/he/e/eb/%D7%9C%D7%95%D7%92%D7%95_%D7%97%D7%93%D7%B4%D7%A9_%D7%AA%D7%A2%D7%B4%D7%9C_2022_%28%D7%A2%D7%91%D7%A8%D7%99%D7%AA%29.svg'),
    ('בל"ד', 'https://upload.wikimedia.org/wikipedia/he/1/19/Balad.svg'),
    ('זהות', 'https://upload.wikimedia.org/wikipedia/commons/d/d4/ZehutParty.svg'),
    -- Noam's current campaign banner ("נעם לישראל, בראשות אבי מעוז"). It is an opaque JPEG, not a
    -- transparent SVG, so logos.js skips the dark-mode recolour (>90% opaque pixels = solid tile) --
    -- correct here, since the artwork is already light lettering on a dark navy field.
    ('נעם', 'https://upload.wikimedia.org/wikipedia/commons/6/6e/%D7%A1%D7%9E%D7%9C_%D7%9E%D7%A4%D7%9C%D7%92%D7%AA_%D7%A0%D7%A2%D7%9D_j%2Cul.jpg'),
    -- El HaDegel is a new movement with no Wikimedia logo; this is the square Star-of-David emblem
    -- (transparent, from the party's own Webflow CDN "webclip" app-icon) rather than the old low-res
    -- Google thumbnail, which had a dark navy background baked in and rendered as a dark box on the
    -- logo chip. Non-Wikimedia host, so if it ever 404s the frontend falls back to a generated monogram.
    ('אל הדגל', 'https://cdn.prod.website-files.com/674ed46d57366b6a64400c3c/67501afebb4a91b0d0b7c6b9_el-hadegel-webclip.svg')
) AS v(name_he, logo_url)
WHERE t.name_he = v.name_he
  AND t.logo_url IS NULL;

-- Upcoming-party classification. Independent from previous_parties even where a lineage link
-- exists (design spec Decision 1). Same unguarded rationale as the previous_parties block above.
UPDATE upcoming_parties p SET
    bloc = v.bloc, economic = v.economic, security = v.security,
    religiosity = v.religiosity, sector = v.sector, tags = v.tags,
    families = v.families, family_evidence = v.family_evidence
FROM (VALUES
    ('הליכוד', 'bibi', 1, 2, 2, 'traditional', ARRAY['claims-economically-liberal', 'populist', 'nationalist', 'instrumentally-clerical']::text[], ARRAY['conscription-exemption','judicial-restraint','sectoral-budgeting']::text[], 'record'),
    ('ישר', 'opposition', 1, 1, -2, 'secular', ARRAY['new-party', 'centrist', 'liberal-zionist', 'statist', 'security-hawk', 'no-palestinian-state', 'anti-annexation', 'universal-conscription', 'core-curriculum', 'constitutionalist', 'governance-reform', 'anti-monopoly', 'periphery-development', 'tax-cutting', 'public-service-reform', 'service-conditioned-citizenship', 'sanctions-on-non-servers', 'reservist-focused', 'agricultural-protectionism']::text[], ARRAY['universal-conscription','constitutional-reform','cost-of-living']::text[], 'platform'),
    ('ביחד', 'opposition', 1, NULL, -2, 'secular', ARRAY['liberal-zionist', 'constitutionalist', 'internally-split-on-conflict', 'anti-clerical', 'universal-conscription', 'pro-competition', 'periphery-development', 'anti-monopoly', 'free-trade', 'kashrut-liberalization']::text[], ARRAY['universal-conscription','constitutional-reform','cost-of-living']::text[], 'platform'),
    ('הדמוקרטים', 'opposition', -2, -1, -3, 'secular', ARRAY['progressive', 'social-democrat', 'liberal-zionist', 'religious-pluralism', 'jewish-arab-partnership', 'protest-movement-rooted', 'two-state', 'anti-annexation', 'anti-settler-violence', 'universal-conscription', 'core-curriculum', 'civil-marriage', 'anti-indicted-pm', 'regional-normalization', 'lgbt-rights']::text[], ARRAY['constitutional-reform','welfare-state','jewish-arab-partnership','universal-conscription']::text[], 'platform'),
    ('כחול לבן', 'unaligned', 0, 2, -2, 'secular', ARRAY['centrist', 'hard-to-classify-bloc', 'statist', 'security-hawk', 'no-palestinian-state', 'pro-settlement', 'unity-government', 'public-service-reform', 'universal-conscription', 'sanctions-on-non-servers', 'arab-civil-service', 'scholar-exemption-retained', 'core-curriculum', 'state-haredi-education', 'reservist-focused']::text[], ARRAY['constitutional-reform','universal-conscription']::text[], 'platform'),
    ('ישראל ביתנו', 'opposition', 2, 2, -3, 'secular', ARRAY['anti-clerical', 'revisionist-zionist', 'civil-marriage', 'universal-conscription', 'free-market', 'governance-reform', 'anti-indicted-pm', 'hardline-on-gaza']::text[], ARRAY['universal-conscription','constitutional-reform','market-liberal']::text[], 'record'),
    ('הציונות הדתית', 'bibi', 0, 3, 3, 'religious_zionist', ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right', 'settler-movement', 'judicial-overhaul', 'annexationist', 'opposes-hostage-deals', 'halakhic-state', 'anti-two-state']::text[], ARRAY['judicial-restraint','conscription-split','sectoral-budgeting']::text[], 'record'),
    ('עוצמה יהודית', 'bibi', 0, 3, 3, 'religious_zionist', ARRAY['claims-economically-liberal', 'not-economy-focused', 'kahanist', 'jewish-supremacist', 'far-right']::text[], ARRAY['judicial-restraint','not-economy-focused','conscription-by-incentive']::text[], 'record'),
    ('חד"ש-תע"ל', 'opposition', -3, -2, NULL, 'arab', ARRAY['communist', 'arab-nationalist', 'pro-two-state', 'jewish-arab-partnership', 'civil-rights-focused', 'pro-joint-list', 'negev-bedouin-representation']::text[], ARRAY['arab-representation','jewish-arab-partnership','welfare-state']::text[], 'record'),
    ('בל"ד', 'opposition', -2, -3, -3, 'arab', ARRAY['palestinian-nationalist', 'non-zionist', 'state-of-all-its-citizens', 'secular-democratic-state', 'pro-two-state', 'right-of-return', 'anti-privatization', 'progressive-taxation', 'affirmative-action', 'opposes-arab-conscription', 'program-unchanged-since-2018']::text[], ARRAY['arab-representation','welfare-state']::text[], 'record'),
    ('רע"ם', 'opposition', 0, -2, NULL, 'arab', ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues', 'pro-two-state']::text[], ARRAY['arab-representation']::text[], 'record'),
    ('ש"ס', 'bibi', -2, 1, 2, 'haredi', ARRAY['ultra-orthodox', 'religious-conservative']::text[], ARRAY['conscription-exemption','welfare-state','sectoral-budgeting']::text[], 'record'),
    ('יהדות התורה', 'bibi', -2, 1, 2, 'haredi', ARRAY['ultra-orthodox', 'religious-conservative']::text[], ARRAY['conscription-split','welfare-state','sectoral-budgeting']::text[], 'record'),
    ('המפלגה הכלכלית', 'unaligned', 1, 0, -2, 'secular', ARRAY['populist', 'anti-corruption', 'anti-monopoly', 'tax-cutting', 'free-trade', 'consumer-protection', 'kashrut-liberalization', 'single-issue-economy', 'anti-clerical']::text[], ARRAY['cost-of-living']::text[], 'platform'),
    ('אל הדגל', 'unaligned', 1, 2, -2, 'secular', ARRAY['reservist-focused', 'anti-conscription-exemption', 'universal-conscription', 'service-conditioned-citizenship', 'sanctions-on-non-servers', 'core-curriculum', 'sovereignty-annexation', 'preemptive-security-doctrine', 'territorial-price-doctrine', 'anti-two-state', 'voluntary-emigration-incentives', 'constitutionalist', 'governance-reform', 'term-limits', 'state-commission-of-inquiry', 'pm-immunity-protections', 'municipal-devolution', 'deregulation', 'cost-of-living', 'workforce-integration']::text[], ARRAY['universal-conscription','reservist-movement','constitutional-reform','cost-of-living']::text[], 'platform'),
    ('בית ציוני - המילואימניקים', 'unaligned', 1, 2, -2, 'secular', ARRAY['reservist-focused', 'anti-conscription-exemption', 'universal-conscription', 'service-conditioned-citizenship', 'sanctions-on-non-servers', 'core-curriculum', 'anti-netanyahu', 'territorial-control-gaza', 'anti-two-state', 'pro-settlement', 'periphery-development', 'anti-monopoly', 'free-trade', 'cost-of-living', 'constitutionalist', 'governance-reform', 'statist', 'excludes-haredi-and-arab-parties']::text[], ARRAY['universal-conscription','reservist-movement','constitutional-reform','cost-of-living']::text[], 'platform'),
    ('זהות', 'bibi', 3, 3, 2, 'religious_zionist', ARRAY['libertarian', 'small-government', 'flat-tax', 'deregulation', 'privatization', 'anti-monopoly', 'cannabis-legalization', 'gun-rights', 'sovereignty-annexation', 'anti-two-state', 'population-transfer', 'permanent-residency-not-citizenship', 'state-institutions-bound-to-halakha', 'ends-state-religious-funding', 'jewish-law-parallel-jurisdiction', 'communitarian-devolution', 'temple-mount-centred', 'professional-army', 'extra-parliamentary']::text[], ARRAY['judicial-restraint','market-liberal','cost-of-living']::text[], 'platform'),
    ('נעם', 'bibi', NULL, 3, 3, 'religious_zionist', ARRAY['hardal', 'religious-fundamentalist', 'single-issue-jewish-identity', 'not-economy-focused', 'halakhic-state', 'rabbinate-as-fourth-branch', 'rabbinic-authority-led', 'anti-lgbt', 'anti-progressive', 'family-values', 'opposes-western-wall-compromise', 'education-system-focused', 'anti-judicial-review', 'sovereignty-annexation', 'anti-two-state']::text[], ARRAY['judicial-restraint','conscription-by-incentive','not-economy-focused']::text[], 'record')
) AS v(name_he, bloc, economic, security, religiosity, sector, tags, families, family_evidence)
WHERE p.name_he = v.name_he;

-- Logo corrections. Unguarded, unlike the logo statements earlier in this file: each replaces a
-- value that was actively wrong, and a guarded statement could never reach an already-seeded
-- database. Rationale (including the misattribution these fix) is in docs/party-classifications.md.
-- NOTE: being unguarded, these DO overwrite an admin-edited logo for these rows.
UPDATE leagues SET logo_url = 'https://assets.laliga.com/assets/logos/LL_RGB_h_color/LL_RGB_h_color.png'
    WHERE name = 'La Liga';
UPDATE upcoming_parties SET logo_url = '/logos/beit-tzioni-miluimnikim.png'
    WHERE name_he = 'בית ציוני - המילואימניקים';
-- Scoped to upcoming_parties on purpose: previous_parties.'הציונות הדתית' is the current Knesset
-- faction and keeps its 2022 logo. See the tuple in the guarded block above for why this one is
-- self-hosted rather than a Wikimedia URL.
UPDATE upcoming_parties SET logo_url = '/logos/religious-zionism-2026.png'
    WHERE name_he = 'הציונות הדתית';

-- Strip Wikipedia's utm_* referral params from stored logo URLs. 26 of the seeded URLs were copied
-- out of he.wikipedia.org with "?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original"
-- attached; upload.wikimedia.org ignores the query string when serving the file, so the params did
-- nothing except send referral tracking to Wikimedia on every page load.
--
-- This has to be its own statement, and it has to be unguarded. The literals above are all guarded
-- by "logo_url IS NULL", so cleaning them at the source only ever reaches a FRESH database -- an
-- already-seeded one keeps the cruft forever. Unguarded is safe here in a way it would not be for a
-- whole URL: it only ever removes a meaningless suffix, so an admin-curated logo keeps pointing at
-- the same image. Idempotent -- the LIKE makes it a no-op once clean.
UPDATE leagues          SET logo_url = split_part(logo_url, '?utm_source=', 1) WHERE logo_url LIKE '%?utm_source=%';
UPDATE clubs            SET logo_url = split_part(logo_url, '?utm_source=', 1) WHERE logo_url LIKE '%?utm_source=%';
UPDATE previous_parties SET logo_url = split_part(logo_url, '?utm_source=', 1) WHERE logo_url LIKE '%?utm_source=%';
UPDATE upcoming_parties SET logo_url = split_part(logo_url, '?utm_source=', 1) WHERE logo_url LIKE '%?utm_source=%';

-- The Joint List is temporarily removed from upcoming_parties (admin decision, 2026-07-16) --
-- left commented rather than deleted so it's a one-line restore if/when it should come back.
-- INSERT INTO upcoming_parties (name, name_en, name_he) VALUES ('הרשימה המשותפת', 'The Joint List', 'הרשימה המשותפת') ON CONFLICT (name) DO NOTHING;