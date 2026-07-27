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

-- League display names.
-- One row per entity, all display languages together. COALESCE is the per-column equivalent of
-- the old "AND name_xx IS NULL" guard: it fills only what is still empty, so a name an admin has
-- renamed through the live UI is never overwritten. Do not drop it.
-- Keyed on the legacy `name` column, not name_en: the two UPDATEs below rewrite name_en for
-- EPL/UCL unguarded on every run, so on an already-seeded database name_en is no longer 'EPL'
-- and a name_en-keyed block would silently skip those two leagues.
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
    ('Israeli Premier League', 'ליגת העל', 'Лига ха-Аль'),
    ('Liga Leumit', 'ליגה לאומית', 'Лига Леумит')
) AS v(name, name_he, name_ru)
WHERE l.name = v.name;
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
    ('Curacao', 'קוראסאו', 'Кюрасао'),
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
    ('Hapoel Hadera', 'הפועל חדרה', 'Хапоэль Хадера'),
    ('Hapoel Kfar Saba', 'הפועל כפר סבא', 'Хапоэль Кфар-Сава'),
    ('Hapoel Kfar Shalem', 'הפועל כפר שלם', 'Хапоэль Кфар-Шалем'),
    ('Hapoel Nof HaGalil', 'הפועל נוף הגליל', 'Хапоэль Ноф-ха-Галиль'),
    ('Hapoel Akko', 'הפועל עכו', 'Хапоэль Акко'),
    ('Hapoel Afula', 'הפועל עפולה', 'Хапоэль Афула'),
    ('Hapoel Rishon LeZion', 'הפועל ראשון לציון', 'Хапоэль Ришон-ле-Цион'),
    ('Hapoel Ra''anana', 'הפועל רעננה', 'Хапоэль Раанана'),
    ('F.C. Kafr Qasim', 'מ.ס. כפר קאסם', 'ФК Кафр-Касем'),
    ('F.C. Kiryat Yam', 'מ.ס. קריית ים', 'ФК Кирьят-Ям'),
    ('Maccabi Herzliya', 'מכבי הרצליה', 'Маккаби Герцлия'),
    ('Maccabi Kavilio Jaffa', 'מכבי קביליו יפו', 'Маккаби Кавильо Яффо'),
    ('Ironi Modi''in', 'עירוני מודיעין', 'Ирони Модиин'),
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
    ('הליכוד', 'bibi', 1, 2, 1, 'traditional', ARRAY['claims-economically-liberal', 'populist', 'nationalist', 'instrumentally-clerical']::text[]),
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
    ('המילואימניקים', 'The Reservists', 'Резервисты')
) AS v(name_he, name_en, name_ru)
WHERE p.name_he = v.name_he;

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

-- Upcoming-party classification. Independent from previous_parties even where a lineage link
-- exists (design spec Decision 1). Same unguarded rationale as the previous_parties block above.
UPDATE upcoming_parties p SET
    bloc = v.bloc, economic = v.economic, security = v.security,
    religiosity = v.religiosity, sector = v.sector, tags = v.tags
FROM (VALUES
    ('הליכוד', 'bibi', 1, 2, 1, 'traditional', ARRAY['claims-economically-liberal', 'populist', 'nationalist', 'instrumentally-clerical']::text[]),
    ('ישר', 'opposition', 0, 1, -2, 'secular', ARRAY['new-party', 'centrist', 'liberal-zionist', 'statist', 'security-hawk', 'no-palestinian-state', 'anti-annexation', 'universal-conscription', 'core-curriculum', 'constitutionalist', 'governance-reform', 'anti-monopoly', 'periphery-development']::text[]),
    ('ביחד', 'opposition', 1, NULL, -2, 'secular', ARRAY['liberal-zionist', 'constitutionalist', 'internally-split-on-conflict', 'anti-clerical', 'universal-conscription', 'pro-competition', 'periphery-development', 'anti-monopoly', 'free-trade', 'kashrut-liberalization']::text[]),
    ('הדמוקרטים', 'opposition', -2, -1, -3, 'secular', ARRAY['progressive', 'social-democrat', 'liberal-zionist', 'religious-pluralism', 'jewish-arab-partnership', 'protest-movement-rooted', 'two-state']::text[]),
    ('כחול לבן', 'unaligned', 0, 2, -1, 'secular', ARRAY['centrist', 'hard-to-classify-bloc', 'statist', 'security-hawk', 'no-palestinian-state', 'pro-settlement', 'unity-government', 'public-service-reform']::text[]),
    ('ישראל ביתנו', 'opposition', 2, 2, -3, 'secular', ARRAY['anti-clerical', 'revisionist-zionist', 'civil-marriage', 'universal-conscription', 'free-market', 'governance-reform', 'anti-indicted-pm', 'hardline-on-gaza']::text[]),
    ('הציונות הדתית', 'bibi', 0, 3, 3, 'religious_zionist', ARRAY['claims-economically-liberal', 'not-economy-focused', 'ultranationalist', 'far-right', 'settler-movement', 'judicial-overhaul', 'annexationist', 'opposes-hostage-deals', 'halakhic-state']::text[]),
    ('עוצמה יהודית', 'bibi', 0, 3, 3, 'religious_zionist', ARRAY['claims-economically-liberal', 'not-economy-focused', 'kahanist', 'jewish-supremacist', 'far-right']::text[]),
    ('חד"ש-תע"ל', 'opposition', -3, -2, NULL, 'arab', ARRAY['communist', 'arab-nationalist', 'pro-two-state', 'jewish-arab-partnership', 'civil-rights-focused', 'pro-joint-list', 'negev-bedouin-representation']::text[]),
    ('בל"ד', 'opposition', -2, -3, -3, 'arab', ARRAY['palestinian-nationalist', 'non-zionist', 'state-of-all-its-citizens', 'secular-democratic-state', 'pro-two-state', 'right-of-return', 'anti-privatization', 'progressive-taxation', 'affirmative-action', 'opposes-arab-conscription', 'program-unchanged-since-2018']::text[]),
    ('רע"ם', 'opposition', 0, -2, NULL, 'arab', ARRAY['islamist', 'conservative', 'focuses-on-arab-israeli-civil-issues', 'pro-two-state']::text[]),
    ('ש"ס', 'bibi', -2, 1, 2, 'haredi', ARRAY['ultra-orthodox', 'religious-conservative']::text[]),
    ('יהדות התורה', 'bibi', -2, 1, 2, 'haredi', ARRAY['ultra-orthodox', 'religious-conservative']::text[]),
    ('המפלגה הכלכלית', 'unaligned', 1, 0, -2, 'secular', ARRAY['populist', 'anti-corruption', 'anti-monopoly', 'tax-cutting', 'free-trade', 'consumer-protection', 'kashrut-liberalization', 'single-issue-economy', 'anti-clerical']::text[]),
    ('אל הדגל', 'unaligned', 1, 2, 0, 'secular', ARRAY['reservist-focused', 'anti-conscription-exemption', 'universal-conscription', 'sovereignty-annexation', 'preemptive-security-doctrine', 'anti-two-state', 'constitutionalist', 'governance-reform', 'core-curriculum']::text[]),
    ('המילואימניקים', 'unaligned', 1, 2, 0, 'secular', ARRAY['reservist-focused', 'anti-conscription-exemption', 'universal-conscription', 'service-conditioned-citizenship', 'sanctions-on-non-servers', 'anti-netanyahu', 'territorial-control-gaza', 'anti-two-state', 'pro-settlement', 'constitutionalist', 'governance-reform', 'statist', 'excludes-haredi-and-arab-parties']::text[])
) AS v(name_he, bloc, economic, security, religiosity, sector, tags)
WHERE p.name_he = v.name_he;

-- Logo corrections. Unguarded, unlike the logo statements earlier in this file: each replaces a
-- value that was actively wrong, and a guarded statement could never reach an already-seeded
-- database. Rationale (including the misattribution these fix) is in docs/party-classifications.md.
-- NOTE: being unguarded, these two DO overwrite an admin-edited logo for these rows.
UPDATE leagues SET logo_url = 'https://assets.laliga.com/assets/logos/LL_RGB_h_color/LL_RGB_h_color.png'
    WHERE name = 'La Liga';
UPDATE upcoming_parties SET logo_url = 'https://upload.wikimedia.org/wikipedia/commons/f/f1/%D7%94%D7%9E%D7%99%D7%9C%D7%95%D7%90%D7%99%D7%9E%D7%A0%D7%99%D7%A7%D7%99%D7%9D_%D7%9C%D7%95%D7%92%D7%95_%D7%95%D7%95%D7%99%D7%A7%D7%99%D7%A4%D7%93%D7%99%D7%94.jpg'
    WHERE name_he = 'המילואימניקים';

-- The Joint List is temporarily removed from upcoming_parties (admin decision, 2026-07-16) --
-- left commented rather than deleted so it's a one-line restore if/when it should come back.
-- INSERT INTO upcoming_parties (name, name_en, name_he) VALUES ('הרשימה המשותפת', 'The Joint List', 'הרשימה המשותפת') ON CONFLICT (name) DO NOTHING;