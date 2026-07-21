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
    ('Liga Leumit')
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
    ('World Cup 2026', 'Panama'), ('World Cup 2026', 'Curacao'), ('World Cup 2026', 'Haiti'),
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
    ('Liga Leumit', 'Bnei Yehuda'), ('Liga Leumit', 'Hapoel Hadera'),
    ('Liga Leumit', 'Hapoel Kfar Saba'), ('Liga Leumit', 'Hapoel Kfar Shalem'),
    ('Liga Leumit', 'Hapoel Nof HaGalil'), ('Liga Leumit', 'Hapoel Akko'),
    ('Liga Leumit', 'Hapoel Afula'), ('Liga Leumit', 'Hapoel Rishon LeZion'),
    ('Liga Leumit', 'Hapoel Ra''anana'), ('Liga Leumit', 'F.C. Kafr Qasim'),
    ('Liga Leumit', 'F.C. Kiryat Yam'), ('Liga Leumit', 'Maccabi Herzliya'),
    ('Liga Leumit', 'Maccabi Kavilio Jaffa'), ('Liga Leumit', 'Ironi Modi''in')
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

INSERT INTO upcoming_parties (name) VALUES
    ('הליכוד'), ('ישר'), ('ביחד'), ('הדמוקרטים'), ('כחול לבן'),
    ('ישראל ביתנו'), ('הציונות הדתית'), ('עוצמה יהודית'), ('חד"ש-תע"ל'),
    ('בל"ד'), ('רע"ם'), ('ש"ס'), ('יהדות התורה'),
    ('המפלגה הכלכלית'), ('אל הדגל'), ('המילואימניקים')
ON CONFLICT (name) DO NOTHING;

-- Backfill each row's own language from the legacy `name` column.
UPDATE leagues           SET name_en = name WHERE name_en IS NULL;
UPDATE clubs             SET name_en = name WHERE name_en IS NULL;
UPDATE previous_parties  SET name_he = name WHERE name_he IS NULL;
UPDATE upcoming_parties  SET name_he = name WHERE name_he IS NULL;

-- Leagues
UPDATE leagues SET name_he = 'מונדיאל 2026' WHERE name_en = 'World Cup 2026' AND name_he IS NULL;
UPDATE leagues SET name_he = 'ליגת האלופות' WHERE name_en = 'UCL' AND name_he IS NULL;
UPDATE leagues SET name_he = 'הפרמייר ליג' WHERE name_en = 'EPL' AND name_he IS NULL;
UPDATE leagues SET name_he = 'לה ליגה' WHERE name_en = 'La Liga' AND name_he IS NULL;
UPDATE leagues SET name_he = 'סרייה A' WHERE name_en = 'Serie A' AND name_he IS NULL;
UPDATE leagues SET name_he = 'הבונדסליגה' WHERE name_en = 'Bundesliga' AND name_he IS NULL;
UPDATE leagues SET name_he = 'ליגת העל' WHERE name_en = 'Israeli Premier League' AND name_he IS NULL;
UPDATE leagues SET name_he = 'ליגה לאומית' WHERE name_en = 'Liga Leumit' AND name_he IS NULL;
UPDATE leagues SET name_en = 'Premier League' WHERE name = 'EPL';
UPDATE leagues SET name_en = 'UEFA Champions League' WHERE name = 'UCL';

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

-- League logos/emblems. Competition emblems (unlike individual club crests) carry no per-club
-- trademark ambiguity, so these are safe to seed directly (see the World Cup national-flags note
-- above) -- admin can still override any of these via the leagues admin UI's Logo URL field.
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/1/17/2026_FIFA_World_Cup_emblem.svg' WHERE name = 'World Cup 2026' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/d/d1/UEFA_Champions_League_logo_no_text.svg' WHERE name = 'UCL' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://b.fssta.com/uploads/application/soccer/competition-logos/EnglishPremierLeague.png' WHERE name = 'EPL' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/0/0f/LaLiga_logo_2023.svg' WHERE name = 'La Liga' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/e/e9/Serie_A_logo_2022.svg' WHERE name = 'Serie A' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/d/df/Bundesliga_logo_%282017%29.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name = 'Bundesliga' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/1/17/Winnerleague.png' WHERE name = 'Israeli Premier League' AND logo_url IS NULL;
UPDATE leagues SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/1/17/Winnerleague.png' WHERE name = 'Liga Leumit' AND logo_url IS NULL;

-- World Cup 2026 countries
UPDATE clubs SET name_he = 'ברזיל' WHERE name_en = 'Brazil' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארגנטינה' WHERE name_en = 'Argentina' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צרפת' WHERE name_en = 'France' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אנגליה' WHERE name_en = 'England' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ספרד' WHERE name_en = 'Spain' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גרמניה' WHERE name_en = 'Germany' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פורטוגל' WHERE name_en = 'Portugal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הולנד' WHERE name_en = 'Netherlands' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בלגיה' WHERE name_en = 'Belgium' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קרואטיה' WHERE name_en = 'Croatia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אורוגוואי' WHERE name_en = 'Uruguay' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קולומביה' WHERE name_en = 'Colombia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מקסיקו' WHERE name_en = 'Mexico' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארה"ב' WHERE name_en = 'USA' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קנדה' WHERE name_en = 'Canada' AND name_he IS NULL;
UPDATE clubs SET name_he = 'יפן' WHERE name_en = 'Japan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'דרום קוריאה' WHERE name_en = 'South Korea' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מרוקו' WHERE name_en = 'Morocco' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סנגל' WHERE name_en = 'Senegal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גאנה' WHERE name_en = 'Ghana' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מצרים' WHERE name_en = 'Egypt' AND name_he IS NULL;
UPDATE clubs SET name_he = 'תוניסיה' WHERE name_en = 'Tunisia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלג''יריה' WHERE name_en = 'Algeria' AND name_he IS NULL;
UPDATE clubs SET name_he = 'חוף השנהב' WHERE name_en = 'Ivory Coast' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוסטרליה' WHERE name_en = 'Australia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איראן' WHERE name_en = 'Iran' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ערב הסעודית' WHERE name_en = 'Saudi Arabia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קטאר' WHERE name_en = 'Qatar' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אקוודור' WHERE name_en = 'Ecuador' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שווייץ' WHERE name_en = 'Switzerland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שוודיה' WHERE name_en = 'Sweden' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוזבקיסטן' WHERE name_en = 'Uzbekistan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ירדן' WHERE name_en = 'Jordan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'עיראק' WHERE name_en = 'Iraq' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קייפ ורדה' WHERE name_en = 'Cape Verde' AND name_he IS NULL;
UPDATE clubs SET name_he = 'דרום אפריקה' WHERE name_en = 'South Africa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קונגו הדמוקרטית' WHERE name_en = 'DR Congo' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פנמה' WHERE name_en = 'Panama' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קוראסאו' WHERE name_en = 'Curacao' AND name_he IS NULL;
UPDATE clubs SET name_he = 'האיטי' WHERE name_en = 'Haiti' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרגוואי' WHERE name_en = 'Paraguay' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ניו זילנד' WHERE name_en = 'New Zealand' AND name_he IS NULL;
UPDATE clubs SET name_he = 'נורווגיה' WHERE name_en = 'Norway' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סקוטלנד' WHERE name_en = 'Scotland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוסטריה' WHERE name_en = 'Austria' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בוסניה והרצגובינה' WHERE name_en = 'Bosnia and Herzegovina' AND name_he IS NULL;
UPDATE clubs SET name_he = 'טורקיה' WHERE name_en = 'Turkey' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צ''כיה' WHERE name_en = 'Czech Republic' AND name_he IS NULL;

-- World Cup 2026 national flags, via flagcdn.com's stable per-country-code SVG URLs. Unlike club
-- crests, national flags carry no trademark/licensing ambiguity, so these are safe to seed directly
-- (see CLAUDE.md/redesign plan -- club and party logo_url values are left NULL for admin curation).
UPDATE clubs SET logo_url = 'https://flagcdn.com/br.svg' WHERE name_en = 'Brazil' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ar.svg' WHERE name_en = 'Argentina' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/fr.svg' WHERE name_en = 'France' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/gb-eng.svg' WHERE name_en = 'England' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/es.svg' WHERE name_en = 'Spain' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/de.svg' WHERE name_en = 'Germany' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/pt.svg' WHERE name_en = 'Portugal' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/nl.svg' WHERE name_en = 'Netherlands' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/be.svg' WHERE name_en = 'Belgium' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/hr.svg' WHERE name_en = 'Croatia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/uy.svg' WHERE name_en = 'Uruguay' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/co.svg' WHERE name_en = 'Colombia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/mx.svg' WHERE name_en = 'Mexico' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/us.svg' WHERE name_en = 'USA' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ca.svg' WHERE name_en = 'Canada' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/jp.svg' WHERE name_en = 'Japan' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/kr.svg' WHERE name_en = 'South Korea' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ma.svg' WHERE name_en = 'Morocco' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/sn.svg' WHERE name_en = 'Senegal' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/gh.svg' WHERE name_en = 'Ghana' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/eg.svg' WHERE name_en = 'Egypt' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/tn.svg' WHERE name_en = 'Tunisia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/dz.svg' WHERE name_en = 'Algeria' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ci.svg' WHERE name_en = 'Ivory Coast' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/au.svg' WHERE name_en = 'Australia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ir.svg' WHERE name_en = 'Iran' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/sa.svg' WHERE name_en = 'Saudi Arabia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/qa.svg' WHERE name_en = 'Qatar' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ec.svg' WHERE name_en = 'Ecuador' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ch.svg' WHERE name_en = 'Switzerland' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/se.svg' WHERE name_en = 'Sweden' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/uz.svg' WHERE name_en = 'Uzbekistan' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/jo.svg' WHERE name_en = 'Jordan' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/iq.svg' WHERE name_en = 'Iraq' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/cv.svg' WHERE name_en = 'Cape Verde' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/za.svg' WHERE name_en = 'South Africa' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/cd.svg' WHERE name_en = 'DR Congo' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/pa.svg' WHERE name_en = 'Panama' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/cw.svg' WHERE name_en = 'Curacao' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ht.svg' WHERE name_en = 'Haiti' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/py.svg' WHERE name_en = 'Paraguay' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/nz.svg' WHERE name_en = 'New Zealand' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/no.svg' WHERE name_en = 'Norway' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/gb-sct.svg' WHERE name_en = 'Scotland' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/at.svg' WHERE name_en = 'Austria' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/ba.svg' WHERE name_en = 'Bosnia and Herzegovina' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/tr.svg' WHERE name_en = 'Turkey' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://flagcdn.com/cz.svg' WHERE name_en = 'Czech Republic' AND logo_url IS NULL;

-- UCL clubs
UPDATE clubs SET name_he = 'ריאל מדריד' WHERE name_en = 'Real Madrid' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מנצ''סטר סיטי' WHERE name_en = 'Manchester City' AND name_he IS NULL;
UPDATE clubs SET name_he = 'באיירן מינכן' WHERE name_en = 'Bayern Munich' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברצלונה' WHERE name_en = 'Barcelona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ליברפול' WHERE name_en = 'Liverpool' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פריז סן ז''רמן' WHERE name_en = 'Paris Saint-Germain' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אינטר מילאן' WHERE name_en = 'Inter Milan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'יובנטוס' WHERE name_en = 'Juventus' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מנצ''סטר יונייטד' WHERE name_en = 'Manchester United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צ''לסי' WHERE name_en = 'Chelsea' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארסנל' WHERE name_en = 'Arsenal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מילאן' WHERE name_en = 'AC Milan' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אתלטיקו מדריד' WHERE name_en = 'Atlético Madrid' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורוסיה דורטמונד' WHERE name_en = 'Borussia Dortmund' AND name_he IS NULL;
UPDATE clubs SET name_he = 'נאפולי' WHERE name_en = 'Napoli' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פורטו' WHERE name_en = 'Porto' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בנפיקה' WHERE name_en = 'Benfica' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אייאקס' WHERE name_en = 'Ajax' AND name_he IS NULL;

-- EPL clubs not already covered by UCL
UPDATE clubs SET name_he = 'אסטון וילה' WHERE name_en = 'Aston Villa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורנמות''' WHERE name_en = 'Bournemouth' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברנטפורד' WHERE name_en = 'Brentford' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברייטון אנד הוב אלביון' WHERE name_en = 'Brighton & Hove Albion' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קריסטל פאלאס' WHERE name_en = 'Crystal Palace' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אברטון' WHERE name_en = 'Everton' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פולהאם' WHERE name_en = 'Fulham' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איפסוויץ'' טאון' WHERE name_en = 'Ipswich Town' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לסטר סיטי' WHERE name_en = 'Leicester City' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ניוקאסל יונייטד' WHERE name_en = 'Newcastle United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'נוטינגהאם פורסט' WHERE name_en = 'Nottingham Forest' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סאות''המפטון' WHERE name_en = 'Southampton' AND name_he IS NULL;
UPDATE clubs SET name_he = 'טוטנהאם הוטספר' WHERE name_en = 'Tottenham Hotspur' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ווסט האם יונייטד' WHERE name_en = 'West Ham United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וולברהמפטון וונדררס' WHERE name_en = 'Wolverhampton Wanderers' AND name_he IS NULL;

-- La Liga clubs not already covered by UCL
UPDATE clubs SET name_he = 'אתלטיק בילבאו' WHERE name_en = 'Athletic Bilbao' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ריאל סוסיאדד' WHERE name_en = 'Real Sociedad' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ריאל בטיס' WHERE name_en = 'Real Betis' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ויאריאל' WHERE name_en = 'Villarreal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ולנסיה' WHERE name_en = 'Valencia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סביליה' WHERE name_en = 'Sevilla' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ז''ירונה' WHERE name_en = 'Girona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוססונה' WHERE name_en = 'Osasuna' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סלטה ויגו' WHERE name_en = 'Celta Vigo' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ראיו ואייקאנו' WHERE name_en = 'Rayo Vallecano' AND name_he IS NULL;
UPDATE clubs SET name_he = 'חטאפה' WHERE name_en = 'Getafe' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לאס פלמאס' WHERE name_en = 'Las Palmas' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלאבס' WHERE name_en = 'Alavés' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אספניול' WHERE name_en = 'Espanyol' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לגאנס' WHERE name_en = 'Leganes' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מיורקה' WHERE name_en = 'Mallorca' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ויאדוליד' WHERE name_en = 'Valladolid' AND name_he IS NULL;

-- Serie A clubs not already covered by UCL
UPDATE clubs SET name_he = 'רומא' WHERE name_en = 'Roma' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לאציו' WHERE name_en = 'Lazio' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אטלנטה' WHERE name_en = 'Atalanta' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פיורנטינה' WHERE name_en = 'Fiorentina' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בולוניה' WHERE name_en = 'Bologna' AND name_he IS NULL;
UPDATE clubs SET name_he = 'טורינו' WHERE name_en = 'Torino' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אודינזה' WHERE name_en = 'Udinese' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ג''נואה' WHERE name_en = 'Genoa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קליארי' WHERE name_en = 'Cagliari' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ורונה' WHERE name_en = 'Verona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לצ''ה' WHERE name_en = 'Lecce' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פארמה' WHERE name_en = 'Parma' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קומו' WHERE name_en = 'Como' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ונציה' WHERE name_en = 'Venezia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אמפולי' WHERE name_en = 'Empoli' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מונצה' WHERE name_en = 'Monza' AND name_he IS NULL;

-- Bundesliga clubs not already covered by UCL
UPDATE clubs SET name_he = 'ר. ב. לייפציג' WHERE name_en = 'RB Leipzig' AND name_he IS NULL;
UPDATE clubs SET name_he = 'באייר לברקוזן' WHERE name_en = 'Bayer Leverkusen' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איינטרכט פרנקפורט' WHERE name_en = 'Eintracht Frankfurt' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שטוטגרט' WHERE name_en = 'VfB Stuttgart' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורוסיה מנשנגלדבך' WHERE name_en = 'Borussia Mönchengladbach' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרייבורג' WHERE name_en = 'SC Freiburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וורדר ברמן' WHERE name_en = 'Werder Bremen' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוניון ברלין' WHERE name_en = 'Union Berlin' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מיינץ 05' WHERE name_en = 'Mainz 05' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וולפסבורג' WHERE name_en = 'Wolfsburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הופנהיים' WHERE name_en = 'TSG Hoffenheim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוגסבורג' WHERE name_en = 'FC Augsburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בוכום' WHERE name_en = 'VfL Bochum' AND name_he IS NULL;
UPDATE clubs SET name_he = 'היידנהיים' WHERE name_en = 'FC Heidenheim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הולשטיין קיל' WHERE name_en = 'Holstein Kiel' AND name_he IS NULL;
UPDATE clubs SET name_he = 'זנקט פאולי' WHERE name_en = 'St. Pauli' AND name_he IS NULL;

-- Israeli Premier League clubs
UPDATE clubs SET name_he = 'מכבי חיפה' WHERE name_en = 'Maccabi Haifa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי תל אביב' WHERE name_en = 'Maccabi Tel Aviv' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל באר שבע' WHERE name_en = 'Hapoel Be''er Sheva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל תל אביב' WHERE name_en = 'Hapoel Tel Aviv' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בית"ר ירושלים' WHERE name_en = 'Beitar Jerusalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי נתניה' WHERE name_en = 'Maccabi Netanya' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל חיפה' WHERE name_en = 'Hapoel Haifa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בני סכנין' WHERE name_en = 'Bnei Sakhnin' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל רמת-גן גבעתיים' WHERE name_en = 'Hapoel Ramat Gan Givatayim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל ירושלים' WHERE name_en = 'Hapoel Jerusalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'עירוני קריית שמונה' WHERE name_en = 'Ironi Kiryat Shmona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי פתח תקווה' WHERE name_en = 'Maccabi Petah Tikva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל פתח תקווה' WHERE name_en = 'Hapoel Petah Tikva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'עירוני טבריה' WHERE name_en = 'Ironi Tiberias' AND name_he IS NULL;

-- Liga Leumit clubs
UPDATE clubs SET name_he = 'מ.ס. אשדוד' WHERE name_en = 'F.C. Ashdod' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי בני ריינה' WHERE name_en = 'Maccabi Bnei Reineh' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בני יהודה' WHERE name_en = 'Bnei Yehuda' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל חדרה' WHERE name_en = 'Hapoel Hadera' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל כפר סבא' WHERE name_en = 'Hapoel Kfar Saba' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל כפר שלם' WHERE name_en = 'Hapoel Kfar Shalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל נוף הגליל' WHERE name_en = 'Hapoel Nof HaGalil' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל עכו' WHERE name_en = 'Hapoel Akko' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל עפולה' WHERE name_en = 'Hapoel Afula' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל ראשון לציון' WHERE name_en = 'Hapoel Rishon LeZion' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל רעננה' WHERE name_en = 'Hapoel Ra''anana' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מ.ס. כפר קאסם' WHERE name_en = 'F.C. Kafr Qasim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מ.ס. קריית ים' WHERE name_en = 'F.C. Kiryat Yam' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי הרצליה' WHERE name_en = 'Maccabi Herzliya' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי קביליו יפו' WHERE name_en = 'Maccabi Kavilio Jaffa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'עירוני מודיעין' WHERE name_en = 'Ironi Modi''in' AND name_he IS NULL;

-- Clubs added via admin UI roster edits (real-world 2025-26 season roster/UCL qualification
-- changes -- see scripts/sync-seed-from-rds.sh)
UPDATE clubs SET name_he = 'פ. צ. קלן' WHERE name_en = '1. FC Köln' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שאלקה 04' WHERE name_en = 'FC Schalke 04' AND name_he IS NULL;
UPDATE clubs SET name_he = 'המבורג' WHERE name_en = 'Hamburger SV' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פאדרבורן 07' WHERE name_en = 'SC Paderborn 07' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלוורסברג' WHERE name_en = 'SV Elversberg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'דפורטיבו דה א-קורוניה' WHERE name_en = 'Deportivo de A Coruña' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלצ''ה' WHERE name_en = 'Elche' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לבאנטה' WHERE name_en = 'Levante' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מאלגה' WHERE name_en = 'Málaga' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ראסינג סנטנדר' WHERE name_en = 'Racing Santander' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קובנטרי סיטי' WHERE name_en = 'Coventry City' AND name_he IS NULL;
UPDATE clubs SET name_he = 'האל סיטי' WHERE name_en = 'Hull City' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לידס יונייטד' WHERE name_en = 'Leeds United' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרוזינונה' WHERE name_en = 'Frosinone' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קלאב ברוז''' WHERE name_en = 'Club Brugge' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פיינורד' WHERE name_en = 'Feyenoord' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גלאטסראיי' WHERE name_en = 'Galatasaray' AND name_he IS NULL;
UPDATE clubs SET name_he = 'לאנס' WHERE name_en = 'Lens' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ליל' WHERE name_en = 'Lille' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פ.ס.וו. איינדהובן' WHERE name_en = 'PSV Eindhoven' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שחטאר דונצק' WHERE name_en = 'Shakhtar Donetsk' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סלביה פראג' WHERE name_en = 'Slavia Prague' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ספורטינג ליסבון' WHERE name_en = 'Sporting CP' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סנדרלנד' WHERE name_en = 'Sunderland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ססואולו' WHERE name_en = 'Sassuolo' AND name_he IS NULL;

-- Admin-curated club logos, synced from the live RDS instance (added via the admin UI's Logo
-- URL field for the full Israeli Premier League roster) so a fresh install matches current
-- production data. Also folds in the Hapoel Ramat Gan Givatayim / Maccabi Petah Tikva / Ironi
-- Tiberias promotion swap (Ashdod, Maccabi Bnei Reineh, and Hapoel Kfar Saba relegated out) and
-- the Hapoel Be'er Sheva / Ironi Kiryat Shmona name_en corrections above.
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/1/1e/%D7%A1%D7%9E%D7%9C_%D7%9E%D7%9B%D7%91%D7%99_%D7%97%D7%99%D7%A4%D7%94_2023.png?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_en = 'Maccabi Haifa' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/4/45/Maccabi_Tel_Aviv_FC.png?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_en = 'Maccabi Tel Aviv' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/8/85/Logo-hapoel-positive.svg' WHERE name_en = 'Hapoel Be''er Sheva' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/a/ac/Hapoel_Tel_Aviv_F.C.png' WHERE name_en = 'Hapoel Tel Aviv' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/6/61/Beitar_Jerusalem.png' WHERE name_en = 'Beitar Jerusalem' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/b/bc/MaccabiNetanyaNewlogo2021.png?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_en = 'Maccabi Netanya' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/e/e4/Hapoel_Haifa_New_Logo.png' WHERE name_en = 'Hapoel Haifa' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/b/bb/Hapo%C3%83%C2%ABl_Bnei_Sakhnin.png?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_en = 'Bnei Sakhnin' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/9/91/Hapoel_ramat-gan.svg' WHERE name_en = 'Hapoel Ramat Gan Givatayim' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/5d/FC_Hapoel_Jerusalem_2021.png' WHERE name_en = 'Hapoel Jerusalem' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/d/d1/Hapoel_Ironi_Kiryat_Shmona_badge.png' WHERE name_en = 'Ironi Kiryat Shmona' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/9/93/MPT_FC_2024.png?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_en = 'Maccabi Petah Tikva' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/6/63/Hapoel_Petach_Tikva_logo.png' WHERE name_en = 'Hapoel Petah Tikva' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/8/84/Ironi_logo_new.gif?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_en = 'Ironi Tiberias' AND logo_url IS NULL;

-- Liga Leumit club logos. F.C. Kiryat Yam has no Wikimedia crest. It used to hotlink the club's
-- Instagram profile picture, which was wrong for three independent reasons: the URL is signed and
-- expires (`oe=`), the CDN may refuse hotlinks, and -- the one that actually bit -- browsers with
-- tracker blocking (uBlock, Firefox ETP, Brave, Safari ITP) drop *.fbcdn.net requests outright.
-- The crest was therefore invisible to many visitors while `curl` fetched it happily, which is a
-- failure no server-side check can detect. It is now served from our own origin instead.
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/5/5b/Ashdod.png' WHERE name_en = 'F.C. Ashdod' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/f/f7/MaccabiBneiReine2022.png' WHERE name_en = 'Maccabi Bnei Reineh' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f5/Bnei_Jehuda_Tel_Aviv_FC.svg' WHERE name_en = 'Bnei Yehuda' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/8/81/HapoelHaderaFC.svg' WHERE name_en = 'Hapoel Hadera' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/8/87/Hapoel_Kfar_Saba_FC_Logo.png' WHERE name_en = 'Hapoel Kfar Saba' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/9/90/Hapoel_Kfar_Shalem_Logo.png' WHERE name_en = 'Hapoel Kfar Shalem' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/9/95/%D7%A0%D7%95%D7%A4%D7%94%D7%92%D7%9C%D7%99%D7%9C.png' WHERE name_en = 'Hapoel Nof HaGalil' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/7/75/Hapoelakko.png' WHERE name_en = 'Hapoel Akko' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/0/01/Hapoel_Afula_F.C.png' WHERE name_en = 'Hapoel Afula' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/c/ce/Hap-rish.png' WHERE name_en = 'Hapoel Rishon LeZion' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/3/3f/HapoelRaanana.png' WHERE name_en = 'Hapoel Ra''anana' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/6/6f/FC_Kafr_Qasim_Logo.png' WHERE name_en = 'F.C. Kafr Qasim' AND logo_url IS NULL;
-- Served from our own origin (services/frontend/logos/kiryat-yam.png), cropped from the club's
-- square artwork to a transparent circle. The IS NULL guard is deliberately widened here: every
-- other row must not clobber admin edits, but this one has to CORRECT a known-bad value that is
-- already in the database, which a plain `IS NULL` guard would silently skip forever.
UPDATE clubs SET logo_url = '/logos/kiryat-yam.png' WHERE name_en = 'F.C. Kiryat Yam' AND (logo_url IS NULL OR logo_url LIKE '%fbcdn.net%');
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/f/f5/Maccabi_Herzliya.png' WHERE name_en = 'Maccabi Herzliya' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/8/88/MaccabiJaffaCrestNew2018.png' WHERE name_en = 'Maccabi Kavilio Jaffa' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/d/d6/IroniModiinFC.png' WHERE name_en = 'Ironi Modi''in' AND logo_url IS NULL;

-- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh.
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/1/1c/US_Sassuolo_Calcio_logo.svg' WHERE name_en = 'Sassuolo' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/7/77/Logo_Sunderland.svg' WHERE name_en = 'Sunderland' AND logo_url IS NULL;

-- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh.
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/0/01/1._FC_Koeln_Logo_2014%E2%80%93.svg' WHERE name_en = '1. FC Köln' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/d/d0/Logo_of_AC_Milan.svg' WHERE name_en = 'AC Milan' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f8/Deportivo_Alaves_logo_%282020%29.svg' WHERE name_en = 'Alavés' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/53/Arsenal_FC.svg' WHERE name_en = 'Arsenal' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/9/9a/Aston_Villa_FC_new_crest.svg' WHERE name_en = 'Aston Villa' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f2/Atalanta_BC_new_logo.svg' WHERE name_en = 'Atalanta' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/9/98/Club_Athletic_Bilbao_logo.svg' WHERE name_en = 'Athletic Bilbao' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f9/Atletico_Madrid_Logo_2024.svg' WHERE name_en = 'Atlético Madrid' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/4/47/FC_Barcelona_%28crest%29.svg' WHERE name_en = 'Barcelona' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/59/Bayer_04_Leverkusen_logo.svg' WHERE name_en = 'Bayer Leverkusen' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/8/8d/FC_Bayern_M%C3%BCnchen_logo_%282024%29.svg' WHERE name_en = 'Bayern Munich' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/5/5b/Bologna_F.C._1909_logo.svg' WHERE name_en = 'Bologna' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/6/67/Borussia_Dortmund_logo.svg' WHERE name_en = 'Borussia Dortmund' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/8/81/Borussia_M%C3%B6nchengladbach_logo.svg' WHERE name_en = 'Borussia Mönchengladbach' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/e/e5/AFC_Bournemouth_%282013%29.svg' WHERE name_en = 'Bournemouth' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/2/2a/Brentford_FC_crest.svg' WHERE name_en = 'Brentford' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/d/d0/Brighton_and_Hove_Albion_FC_crest.svg' WHERE name_en = 'Brighton & Hove Albion' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/6/61/Cagliari_Calcio_1920.svg' WHERE name_en = 'Cagliari' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/1/12/RC_Celta_de_Vigo_logo.svg' WHERE name_en = 'Celta Vigo' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/c/cc/Chelsea_FC.svg' WHERE name_en = 'Chelsea' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/d/d0/Club_Brugge_KV_logo.svg' WHERE name_en = 'Club Brugge' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/9/99/Calcio_Como_-_logo_%28Italy%2C_2019-%29.svg' WHERE name_en = 'Como' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/7/7b/Coventry_City_FC_crest.svg' WHERE name_en = 'Coventry City' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/a/a2/Crystal_Palace_FC_logo_%282022%29.svg' WHERE name_en = 'Crystal Palace' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/56/RC_Deportivo_A_Coru%C3%B1a_logo_2026.svg' WHERE name_en = 'Deportivo de A Coruña' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/7/7e/Eintracht_Frankfurt_crest.svg' WHERE name_en = 'Eintracht Frankfurt' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/a/a7/Elche_CF_logo.svg' WHERE name_en = 'Elche' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/9/92/RCD_Espanyol_crest.svg' WHERE name_en = 'Espanyol' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/7/7c/Everton_FC_logo.svg' WHERE name_en = 'Everton' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/c/c5/FC_Augsburg_logo.svg' WHERE name_en = 'FC Augsburg' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/6/6d/FC_Schalke_04_Logo.svg' WHERE name_en = 'FC Schalke 04' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/f/f9/Feyenoord_logo_since_2024.svg' WHERE name_en = 'Feyenoord' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/8/8c/ACF_Fiorentina_-_logo_%28Italy%2C_2022%29.svg' WHERE name_en = 'Fiorentina' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/0/0b/Frosinone_Calcio_logo.svg' WHERE name_en = 'Frosinone' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/e/eb/Fulham_FC_%28shield%29.svg' WHERE name_en = 'Fulham' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/0/07/Galatasaray_S.K._Logo_2026_5-stars.svg' WHERE name_en = 'Galatasaray' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/2/2c/Genoa_CFC_crest.svg' WHERE name_en = 'Genoa' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/4/46/Getafe_logo.svg' WHERE name_en = 'Getafe' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/f/f7/Hamburger_SV_logo.svg' WHERE name_en = 'Hamburger SV' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/54/Hull_City_A.F.C._logo.svg' WHERE name_en = 'Hull City' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/0/05/FC_Internazionale_Milano_2021.svg' WHERE name_en = 'Inter Milan' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/4/43/Ipswich_Town.svg' WHERE name_en = 'Ipswich Town' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/e/ed/Juventus_FC_-_logo_black_%28Italy%2C_2020%29.svg' WHERE name_en = 'Juventus' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/c/ce/S.S._Lazio_badge.svg' WHERE name_en = 'Lazio' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/2/23/US_Lecce_crest.svg' WHERE name_en = 'Lecce' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/54/Leeds_United_F.C._logo.svg' WHERE name_en = 'Leeds United' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/c/cc/RC_Lens_logo.svg' WHERE name_en = 'Lens' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/7/7b/Levante_Uni%C3%B3n_Deportiva%2C_S.A.D._logo.svg' WHERE name_en = 'Levante' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/3/3f/Lille_OSC_2018_logo.svg' WHERE name_en = 'Lille' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/0/0c/Liverpool_FC.svg' WHERE name_en = 'Liverpool' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/1/1b/1._FSV_Mainz_05_logo.svg' WHERE name_en = 'Mainz 05' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/e/eb/Manchester_City_FC_badge.svg' WHERE name_en = 'Manchester City' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/7/7a/Manchester_United_FC_crest.svg' WHERE name_en = 'Manchester United' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/a/a7/AC_Monza_logo_%282021%29.svg' WHERE name_en = 'Monza' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/6/6d/M%C3%A1laga_CF.svg' WHERE name_en = 'Málaga' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/4/4d/SSC_Napoli_2025_%28white_and_azure%29.svg' WHERE name_en = 'Napoli' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/56/Newcastle_United_Logo.svg' WHERE name_en = 'Newcastle United' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/e/e5/Nottingham_Forest_F.C._logo.svg' WHERE name_en = 'Nottingham Forest' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/3/38/CA_Osasuna_2024_crest.svg' WHERE name_en = 'Osasuna' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/0/05/PSV_Eindhoven.svg' WHERE name_en = 'PSV Eindhoven' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/a/a7/Paris_Saint-Germain_F.C..svg' WHERE name_en = 'Paris Saint-Germain' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/9/97/Logo_Parma_Calcio_1913_%28adozione_2016%29.svg' WHERE name_en = 'Parma' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f1/FC_Porto.svg' WHERE name_en = 'Porto' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/0/04/RB_Leipzig_2014_logo.svg' WHERE name_en = 'RB Leipzig' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f5/Racing_de_Santander_logo.svg' WHERE name_en = 'Racing Santander' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/d/d8/Rayo_Vallecano_logo.svg' WHERE name_en = 'Rayo Vallecano' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/2/2f/Real_Betis_2022_logo.svg' WHERE name_en = 'Real Betis' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/5/56/Real_Madrid_CF.svg' WHERE name_en = 'Real Madrid' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f1/Real_Sociedad_logo.svg' WHERE name_en = 'Real Sociedad' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/f/f7/AS_Roma_logo_%282017%29.svg' WHERE name_en = 'Roma' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/6/6d/SC_Freiburg_logo.svg' WHERE name_en = 'SC Freiburg' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/6/67/SC_Paderborn_07_Logo_new.svg' WHERE name_en = 'SC Paderborn 07' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/d/d4/SV_Elversberg_Logo_2021.svg' WHERE name_en = 'SV Elversberg' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/3/3b/Sevilla_FC_logo.svg' WHERE name_en = 'Sevilla' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/a/a1/FC_Shakhtar_Donetsk.svg' WHERE name_en = 'Shakhtar Donetsk' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/2/2b/SK_Slavia_Praha_full_logo.svg' WHERE name_en = 'Slavia Prague' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/e/e7/Sporting_Clube_de_Portugal_2026.svg' WHERE name_en = 'Sporting CP' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/e/e7/Logo_TSG_Hoffenheim.svg' WHERE name_en = 'TSG Hoffenheim' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/2/2e/Torino_FC_Logo.svg' WHERE name_en = 'Torino' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/b/b4/Tottenham_Hotspur.svg' WHERE name_en = 'Tottenham Hotspur' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/c/ce/Udinese_Calcio_logo.svg' WHERE name_en = 'Udinese' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/4/44/1._FC_Union_Berlin_Logo.svg' WHERE name_en = 'Union Berlin' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/c/ce/Valenciacf.svg' WHERE name_en = 'Valencia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/3/39/Venezia_FC_crest.svg' WHERE name_en = 'Venezia' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/e/eb/VfB_Stuttgart_1893_Logo.svg' WHERE name_en = 'VfB Stuttgart' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/en/b/b9/Villarreal_CF_logo-en.svg' WHERE name_en = 'Villarreal' AND logo_url IS NULL;
UPDATE clubs SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/b/be/SV-Werder-Bremen-Logo.svg' WHERE name_en = 'Werder Bremen' AND logo_url IS NULL;

-- Previous Knesset parties
UPDATE previous_parties SET name_en = 'Likud' WHERE name_he = 'הליכוד' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Yesh Atid' WHERE name_he = 'יש עתיד' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Religious Zionist Party' WHERE name_he = 'הציונות הדתית' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'National Unity' WHERE name_he = 'המחנה הממלכתי' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Yisrael Beiteinu' WHERE name_he = 'ישראל ביתנו' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Shas' WHERE name_he = 'ש"ס' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'United Torah Judaism' WHERE name_he = 'יהדות התורה' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Ra''am' WHERE name_he = 'רע"ם' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Hadash-Ta''al' WHERE name_he = 'חד"ש-תע"ל' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Labor' WHERE name_he = 'העבודה' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Meretz' WHERE name_he = 'מרצ' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Balad' WHERE name_he = 'בל"ד' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Other' WHERE name_he = 'אחר' AND name_en IS NULL;

-- Admin-curated party logos, synced from the live RDS instance (added via the admin UI's
-- Logo URL field, not originally seeded) so a fresh install matches current production data.
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/5/50/Likud_Logo.svg' WHERE name_he = 'הליכוד' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/1/12/%D7%99%D7%A9_%D7%A2%D7%AA%D7%99%D7%93_%D7%9C%D7%95%D7%92%D7%95.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'יש עתיד' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/c/c2/%D7%9C%D7%95%D7%92%D7%95_%D7%94%D7%A6%D7%99%D7%95%D7%A0%D7%95%D7%AA_%D7%94%D7%93%D7%AA%D7%99%D7%AA_2022.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'הציונות הדתית' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/e/e0/%D7%9C%D7%95%D7%92%D7%95_%D7%94%D7%9E%D7%97%D7%A0%D7%94_%D7%94%D7%9E%D7%9E%D7%9C%D7%9B%D7%AA%D7%99_%D7%90%D7%95%D7%92%D7%95%D7%A1%D7%98_2022.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'המחנה הממלכתי' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/a/a4/%D7%9C%D7%95%D7%92%D7%95_%D7%99%D7%A9%D7%A8%D7%90%D7%9C_%D7%91%D7%99%D7%AA%D7%A0%D7%95_2022.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'ישראל ביתנו' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/0/05/Shas_logo.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'ש"ס' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/9/97/%D7%99%D7%94%D7%93%D7%95%D7%AA_%D7%94%D7%AA%D7%95%D7%A8%D7%94_%D7%9C%D7%95%D7%92%D7%95_2019.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'יהדות התורה' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/0/08/%D7%94%D7%A8%D7%A9%D7%99%D7%9E%D7%94_%D7%94%D7%A2%D7%A8%D7%91%D7%99%D7%AA_%D7%94%D7%9E%D7%90%D7%95%D7%97%D7%93%D7%AA_%D7%9C%D7%95%D7%92%D7%95_2021.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'רע"ם' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/e/eb/%D7%9C%D7%95%D7%92%D7%95_%D7%97%D7%93%D7%B4%D7%A9_%D7%AA%D7%A2%D7%B4%D7%9C_2022_%28%D7%A2%D7%91%D7%A8%D7%99%D7%AA%29.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'חד"ש-תע"ל' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/f/f8/HaAvoda_Logo.svg' WHERE name_he = 'העבודה' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/f/ff/%D7%9C%D7%95%D7%92%D7%95_%D7%9E%D7%A8%D7%A6_%D7%99%D7%95%D7%9C%D7%99_2022.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'מרצ' AND logo_url IS NULL;
UPDATE previous_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/1/19/Balad.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'בל"ד' AND logo_url IS NULL;

-- Party ideology classification (docs/design/2026-07-16-party-categorization-analytics-design.md
-- Appendix). Provisional: platforms aren't fully released and more splits/merges may happen before
-- candidate lists lock -- revise via this file + scripts/sync-seed-from-rds.sh as needed.
UPDATE previous_parties SET bloc = 'bibi', economic = 1, security = 2, sector = 'traditional',
    tags = ARRAY['claims-economically-liberal', 'populist', 'nationalist']
    WHERE name_he = 'הליכוד' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = 0, security = 0, sector = 'secular',
    tags = ARRAY['liberal-zionist', 'centrist']
    WHERE name_he = 'יש עתיד' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right']
    WHERE name_he = 'הציונות הדתית' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'unaligned', economic = 1, security = NULL, sector = 'secular',
    tags = ARRAY['centrist', 'avoids-security-topic', 'leans-traditional']
    WHERE name_he = 'המחנה הממלכתי' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = 2, security = 2, sector = 'secular',
    tags = ARRAY['anti-clerical', 'revisionist-zionist']
    WHERE name_he = 'ישראל ביתנו' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'ש"ס' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'יהדות התורה' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = 0, security = NULL, sector = 'arab',
    tags = ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues']
    WHERE name_he = 'רע"ם' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -3, security = -2, sector = 'arab',
    tags = ARRAY['communist', 'arab-nationalist', 'pro-two-state']
    WHERE name_he = 'חד"ש-תע"ל' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['social-democrat']
    WHERE name_he = 'העבודה' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['social-democrat']
    WHERE name_he = 'מרצ' AND bloc IS NULL;
UPDATE previous_parties SET bloc = 'opposition', economic = -2, security = -3, sector = 'arab',
    tags = ARRAY['palestinian-nationalist', 'non-zionist']
    WHERE name_he = 'בל"ד' AND bloc IS NULL;
-- 'אחר' (Other) intentionally left fully NULL -- it is a catch-all, not a real party with ideology.

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

-- Upcoming election parties
UPDATE upcoming_parties SET name_en = 'Likud' WHERE name_he = 'הליכוד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yashar' WHERE name_he = 'ישר' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Together' WHERE name_he = 'ביחד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Democrats' WHERE name_he = 'הדמוקרטים' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Blue and White' WHERE name_he = 'כחול לבן' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yisrael Beiteinu' WHERE name_he = 'ישראל ביתנו' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Religious Zionist Party' WHERE name_he = 'הציונות הדתית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Otzma Yehudit' WHERE name_he = 'עוצמה יהודית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Hadash-Ta''al' WHERE name_he = 'חד"ש-תע"ל' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Balad' WHERE name_he = 'בל"ד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Ra''am' WHERE name_he = 'רע"ם' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Shas' WHERE name_he = 'ש"ס' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'United Torah Judaism' WHERE name_he = 'יהדות התורה' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Economic Party' WHERE name_he = 'המפלגה הכלכלית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'El HaDegel' WHERE name_he = 'אל הדגל' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Reservists' WHERE name_he = 'המילואימניקים' AND name_en IS NULL;

-- Admin-curated data synced from the live RDS instance via scripts/sync-seed-from-rds.sh.
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/1/14/Together-logo-29April.svg' WHERE name_he = 'ביחד' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/c/cd/Logo_%D7%94%D7%9E%D7%99%D7%9C%D7%95%D7%90%D7%99%D7%9E%D7%99%D7%A0%D7%99%D7%A7%D7%99%D7%9D_-_%D7%93%D7%95%D7%A8_%D7%94%D7%A0%D7%99%D7%A6%D7%97%D7%95%D7%9F.png' WHERE name_he = 'המילואימניקים' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/c/c9/%D7%94%D7%9E%D7%A4%D7%9C%D7%92%D7%94_%D7%94%D7%9B%D7%9C%D7%9B%D7%9C%D7%99%D7%AA_%D7%94%D7%97%D7%93%D7%A9%D7%94_%D7%9C%D7%95%D7%92%D7%95.svg' WHERE name_he = 'המפלגה הכלכלית' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/9/97/%D7%99%D7%94%D7%93%D7%95%D7%AA_%D7%94%D7%AA%D7%95%D7%A8%D7%94_%D7%9C%D7%95%D7%92%D7%95_2019.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'יהדות התורה' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/6/61/Yashar_party_logo.png' WHERE name_he = 'ישר' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/0/08/%D7%94%D7%A8%D7%A9%D7%99%D7%9E%D7%94_%D7%94%D7%A2%D7%A8%D7%91%D7%99%D7%AA_%D7%94%D7%9E%D7%90%D7%95%D7%97%D7%93%D7%AA_%D7%9C%D7%95%D7%92%D7%95_2021.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'רע"ם' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/0/05/Shas_logo.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'ש"ס' AND logo_url IS NULL;

-- Admin-curated party logos, synced from the live RDS instance (see previous_parties above).
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/5/50/Likud_Logo.svg' WHERE name_he = 'הליכוד' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/b/b5/The_Democrats_led_by_Yair_Golan.svg' WHERE name_he = 'הדמוקרטים' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/a/a6/%D7%9C%D7%95%D7%92%D7%95_%D7%9B%D7%97%D7%95%D7%9C_%D7%9C%D7%91%D7%9F_2021.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'כחול לבן' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/a/a4/%D7%9C%D7%95%D7%92%D7%95_%D7%99%D7%A9%D7%A8%D7%90%D7%9C_%D7%91%D7%99%D7%AA%D7%A0%D7%95_2022.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'ישראל ביתנו' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/c/c2/%D7%9C%D7%95%D7%92%D7%95_%D7%94%D7%A6%D7%99%D7%95%D7%A0%D7%95%D7%AA_%D7%94%D7%93%D7%AA%D7%99%D7%AA_2022.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'הציונות הדתית' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/9/9f/%D7%A2%D7%95%D7%A6%D7%9E%D7%94_%D7%99%D7%94%D7%95%D7%93%D7%99%D7%AA_%D7%9C%D7%95%D7%92%D7%95_2021.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'עוצמה יהודית' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/e/eb/%D7%9C%D7%95%D7%92%D7%95_%D7%97%D7%93%D7%B4%D7%A9_%D7%AA%D7%A2%D7%B4%D7%9C_2022_%28%D7%A2%D7%91%D7%A8%D7%99%D7%AA%29.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'חד"ש-תע"ל' AND logo_url IS NULL;
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/he/1/19/Balad.svg?utm_source=he.wikipedia.org&utm_campaign=index&utm_content=original' WHERE name_he = 'בל"ד' AND logo_url IS NULL;
-- El HaDegel is a new movement with no Wikimedia logo; this is the square Star-of-David emblem
-- (transparent, from the party's own Webflow CDN "webclip" app-icon) rather than the old low-res
-- Google thumbnail, which had a dark navy background baked in and rendered as a dark box on the
-- logo chip. Non-Wikimedia host, so if it ever 404s the frontend falls back to a generated monogram.
UPDATE upcoming_parties SET logo_url = 'https://cdn.prod.website-files.com/674ed46d57366b6a64400c3c/67501afebb4a91b0d0b7c6b9_el-hadegel-webclip.svg' WHERE name_he = 'אל הדגל' AND logo_url IS NULL;

-- Party ideology classification for upcoming_parties -- independent from previous_parties even where
-- a lineage link exists (see party_lineage below and design spec Decision 1).
UPDATE upcoming_parties SET bloc = 'bibi', economic = 1, security = 2, sector = 'traditional',
    tags = ARRAY['claims-economically-liberal', 'populist', 'nationalist']
    WHERE name_he = 'הליכוד' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 0, security = 0, sector = 'secular',
    tags = ARRAY['new-party', 'undefined-ideology']
    WHERE name_he = 'ישר' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 1, security = NULL, sector = 'secular',
    tags = ARRAY['liberal-zionist', 'constitutionalist', 'avoids-security-topic']
    WHERE name_he = 'ביחד' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['progressive', 'social-democrat', 'liberal-zionist']
    WHERE name_he = 'הדמוקרטים' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 0, security = 0, sector = 'secular',
    tags = ARRAY['centrist', 'hard-to-classify-bloc']
    WHERE name_he = 'כחול לבן' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 2, security = 2, sector = 'secular',
    tags = ARRAY['anti-clerical', 'revisionist-zionist']
    WHERE name_he = 'ישראל ביתנו' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right']
    WHERE name_he = 'הציונות הדתית' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'kahanist', 'jewish-supremacist', 'far-right']
    WHERE name_he = 'עוצמה יהודית' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = -3, security = -2, sector = 'arab',
    tags = ARRAY['communist', 'arab-nationalist', 'pro-two-state']
    WHERE name_he = 'חד"ש-תע"ל' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = -2, security = -3, sector = 'arab',
    tags = ARRAY['palestinian-nationalist', 'non-zionist']
    WHERE name_he = 'בל"ד' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'opposition', economic = 0, security = NULL, sector = 'arab',
    tags = ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues']
    WHERE name_he = 'רע"ם' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'ש"ס' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'bibi', economic = -2, security = 1, sector = 'haredi',
    tags = ARRAY['ultra-orthodox', 'religious-conservative']
    WHERE name_he = 'יהדות התורה' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['populist', 'anti-corruption', 'anti-clerical']
    WHERE name_he = 'המפלגה הכלכלית' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['reservist-focused', 'anti-conscription-exemption']
    WHERE name_he = 'אל הדגל' AND bloc IS NULL;
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['reservist-focused', 'anti-conscription-exemption']
    WHERE name_he = 'המילואימניקים' AND bloc IS NULL;

-- ---------------------------------------------------------------------------------------------
-- Classification revision, 2026-07-21. The block above is guarded with `AND bloc IS NULL` so it
-- only ever fires on a fresh database -- which means editing it in place would NOT reach an
-- already-seeded instance. Revisions therefore append an UNGUARDED block like this one, and
-- future revisions append another below it (so a party's current values are the LAST ones set).
-- Unguarded is safe here: nothing in the app writes these five columns (the admin party endpoints
-- only rename), so re-running seed.sql just rewrites identical values.
--
-- Only `upcoming_parties` is touched. The `previous_parties` rows describe each party as it stood
-- at the PREVIOUS election and stay frozen -- back-dating a 2026 platform onto them would defeat
-- the point of keeping the two tables independent (design doc Decision 1).
--
-- Sources: the Democrats' primary results (2026-07-20 -- list weighted by rank, so the top of the
-- list drives the read); be-yahad.org.il/plans/{education,yoker,meshartim,negev,kiryat-shmona};
-- kachollavan.org.il's principles booklet, "Israel Mitazemet" security doctrine and 8-point public
-- service plan; beytenu.org.il/party-platform.

-- The Democrats: the realized list confirms the dovish/social-democratic wings over the security
-- wing -- and all three military figures on it point dovish (Golan #1, Ronen #7 who led the
-- ceasefire protest movement, Sheffer #11 who signed the pilots' letter). Axes therefore unchanged;
-- what the old tags missed is religious pluralism (Kariv #3, Fink #5, Dabush #13), Jewish-Arab
-- partnership (Bashir #10) and the party's protest-movement intake (Ronen #7, Radman #9, Avital #15).
UPDATE upcoming_parties SET bloc = 'opposition', economic = -2, security = -1, sector = 'secular',
    tags = ARRAY['progressive', 'social-democrat', 'liberal-zionist', 'religious-pluralism',
                 'jewish-arab-partnership', 'protest-movement-rooted', 'two-state']
    WHERE name_he = 'הדמוקרטים';

-- Together: still no stated conflict position, so `security` stays NULL -- but not because they
-- dodge the topic. It is a LIST of two parties that stayed legally separate (Bennett 2026 +
-- Yesh Atid): Bennett rules out a Palestinian state, Yesh Atid's platform supports one. That is a
-- genuine internal split, which the replacement tag now says. The five published plans do sharpen
-- the anti-clerical read (defund religious school networks, 60% core curriculum as a funding
-- condition, break the kosher-certification monopoly, universal conscription with benefit cuts for
-- non-servers) and the economic one (competition/import liberalization, offset by heavy targeted
-- spending on servers and the periphery -- net still +1, right of Yesh Atid, left of Beiteinu).
UPDATE upcoming_parties SET bloc = 'opposition', economic = 1, security = NULL, sector = 'secular',
    tags = ARRAY['liberal-zionist', 'constitutionalist', 'internally-split-on-conflict',
                 'anti-clerical', 'universal-conscription', 'pro-competition', 'periphery-development']
    WHERE name_he = 'ביחד';

-- Blue & White: the substantive correction in this pass, security 0 -> +2. "Israel Mitazemet" is an
-- explicit hawkish doctrine -- no Palestinian state, permanent Israeli security control over all
-- territory, expansion of settlement, the Trump plan's voluntary-emigration track for Gaza,
-- proactive targeted killings, and a declared shift from SOLVING the conflict to SHRINKING it.
-- Not +3: they keep the peace treaties, Palestinian freedom of movement, a regional moderate
-- alliance and an international civil administration in Gaza, so they sit below the annexationist
-- pole. `unaligned` holds -- both documents campaign for a broad consensus government "not
-- dependent on the extremes" -- and economic stays 0 ("free economy combined with social justice",
-- imports and competition alongside strengthening public health and education).
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 0, security = 2, sector = 'secular',
    tags = ARRAY['centrist', 'hard-to-classify-bloc', 'statist', 'security-hawk',
                 'no-palestinian-state', 'pro-settlement', 'unity-government', 'public-service-reform']
    WHERE name_he = 'כחול לבן';

-- Yisrael Beiteinu: the platform confirms every existing axis rather than moving any -- privatizing
-- Ashdod Port and Haifa Airport and ending child allowances from the fifth child (+2 economic);
-- preemptive strikes, cutting Gaza's water/electricity/fuel, no Palestinian state (+2 security);
-- abolishing the religious councils, civil marriage, ending yeshiva stipends (secular). The bloc is
-- now pinned down rather than inferred: they want a statutory ban on an indicted person forming a
-- government. Tags expanded to record what the platform actually commits to.
UPDATE upcoming_parties SET bloc = 'opposition', economic = 2, security = 2, sector = 'secular',
    tags = ARRAY['anti-clerical', 'revisionist-zionist', 'civil-marriage', 'universal-conscription',
                 'free-market', 'governance-reform', 'anti-indicted-pm', 'hardline-on-gaza']
    WHERE name_he = 'ישראל ביתנו';

-- Classification revision 2, 2026-07-21. Same unguarded-append rule as the block above.
-- Sources: hakalkalit.org's full platform; El HaDegel's English policy document
-- (elhadegel.co.il); the Religious Zionism primary candidate field.

-- Religious Zionism: TAGS ONLY, and deliberately so -- the primary has not been held, so the
-- candidate field has no ORDER and cannot be rank-weighted the way the Democrats' list was. What
-- the field does show is a party more concentrated in the settlement movement and the judicial
-- overhaul than the old tags recorded (Strook, Sukkot, Rothman, and Rahamim as Yesha Council CEO;
-- Sofer and Solomon are gone). No axis moves: security is already pinned at the +3 maximum, and
-- economic 0 + `claims-economically-liberal` already captures the gap between Smotrich's rhetoric
-- and his finance-ministry record. Recheck after the primary produces an actual order.
UPDATE upcoming_parties SET bloc = 'bibi', economic = 0, security = 3, sector = 'religious_zionist',
    tags = ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist',
                 'far-right', 'settler-movement', 'judicial-overhaul', 'annexationist']
    WHERE name_he = 'הציונות הדתית';

-- The Economic Party: all four axes held on review, tags rewritten. The platform is an unusual
-- fusion -- a large tax cut (VAT 18->12, marginal income 50->40, corporate 50->40) and abolition of
-- all tariffs and import quotas, fused with aggressive trust-busting (declare the exclusive
-- importers monopolies, dissolve the production councils, stop approving mergers, a state-co-funded
-- bank). Economic stays +1 rather than +2 precisely because that second half is real state
-- expansion, not standard right-economics, and +1 keeps the fusion visible.
-- `anti-clerical` is replaced by `kashrut-liberalization`: they do want to break the Rabbinate's
-- kashrut monopoly, but the motive stated is competition (it is listed under cost-of-living, not
-- religion-and-state) and their haredi section is warm -- integration into the workforce, framed as
-- something the economy needs. That is not anti-clericalism in the Yisrael Beiteinu sense.
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 0, sector = 'secular',
    tags = ARRAY['populist', 'anti-corruption', 'anti-monopoly', 'tax-cutting', 'free-trade',
                 'consumer-protection', 'kashrut-liberalization', 'single-issue-economy']
    WHERE name_he = 'המפלגה הכלכלית';

-- El HaDegel: security 0 -> +2. The old two-tag row read them as a single-issue reservist party;
-- their policy document is a full program. On security it commits to asserting sovereignty over
-- "areas essential to its security", reserves "the right to take territorial action", promises
-- preemptive strikes, and rejects BOTH Oslo and conflict management -- Palestinians get
-- self-governance, never a state. Not +3: they are secular-nationalist rather than messianic, and
-- neighbours who abandon terror are offered development and self-rule, so they sit below Religious
-- Zionism's pole. Economic stays +1 for the same reason as Together -- eliminating ministries and a
-- 30% budget cut, offset by massive periphery infrastructure and a strategic-industry program.
-- The constitutional material (Basic Law supermajorities, a 16-minister cap, tiered judicial
-- review, an 8-year PM term limit) and the "El HaDegel Service" Basic Law drafting every citizen,
-- with refusal forfeiting economic and employment rights, were entirely unrecorded before.
UPDATE upcoming_parties SET bloc = 'unaligned', economic = 1, security = 2, sector = 'secular',
    tags = ARRAY['reservist-focused', 'anti-conscription-exemption', 'universal-conscription',
                 'sovereignty-annexation', 'preemptive-security-doctrine', 'anti-two-state',
                 'constitutionalist', 'governance-reform', 'core-curriculum']
    WHERE name_he = 'אל הדגל';
-- ---------------------------------------------------------------------------------------------

-- The Joint List is temporarily removed from upcoming_parties (admin decision, 2026-07-16) --
-- left commented rather than deleted so it's a one-line restore if/when it should come back.
-- INSERT INTO upcoming_parties (name, name_en, name_he) VALUES ('הרשימה המשותפת', 'The Joint List', 'הרשימה המשותפת') ON CONFLICT (name) DO NOTHING;
