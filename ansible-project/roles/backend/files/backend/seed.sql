INSERT INTO alert_state (id, last_seen_total) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;

INSERT INTO leagues (name) VALUES
    ('World Cup 2026'), ('UCL'), ('EPL'), ('La Liga'), ('Serie A'), ('Bundesliga'), ('Israeli Premier League')
ON CONFLICT (name) DO NOTHING;

INSERT INTO clubs (league_id, name)
SELECT l.id, c.name FROM leagues l
JOIN (VALUES
    ('World Cup 2026', 'Brazil'), ('World Cup 2026', 'Argentina'), ('World Cup 2026', 'France'),
    ('World Cup 2026', 'England'), ('World Cup 2026', 'Spain'), ('World Cup 2026', 'Germany'),
    ('World Cup 2026', 'Portugal'), ('World Cup 2026', 'Netherlands'), ('World Cup 2026', 'Italy'),
    ('World Cup 2026', 'Belgium'), ('World Cup 2026', 'Croatia'), ('World Cup 2026', 'Uruguay'),
    ('World Cup 2026', 'Colombia'), ('World Cup 2026', 'Mexico'), ('World Cup 2026', 'USA'),
    ('World Cup 2026', 'Canada'), ('World Cup 2026', 'Japan'), ('World Cup 2026', 'South Korea'),
    ('World Cup 2026', 'Morocco'), ('World Cup 2026', 'Senegal'), ('World Cup 2026', 'Nigeria'),
    ('World Cup 2026', 'Ghana'), ('World Cup 2026', 'Egypt'), ('World Cup 2026', 'Tunisia'),
    ('World Cup 2026', 'Algeria'), ('World Cup 2026', 'Ivory Coast'), ('World Cup 2026', 'Cameroon'),
    ('World Cup 2026', 'Australia'), ('World Cup 2026', 'Iran'), ('World Cup 2026', 'Saudi Arabia'),
    ('World Cup 2026', 'Qatar'), ('World Cup 2026', 'Ecuador'), ('World Cup 2026', 'Chile'),
    ('World Cup 2026', 'Peru'), ('World Cup 2026', 'Poland'), ('World Cup 2026', 'Switzerland'),
    ('World Cup 2026', 'Denmark'), ('World Cup 2026', 'Sweden'), ('World Cup 2026', 'Serbia'),
    ('World Cup 2026', 'Israel'),

    ('UCL', 'Real Madrid'), ('UCL', 'Manchester City'), ('UCL', 'Bayern Munich'),
    ('UCL', 'Barcelona'), ('UCL', 'Liverpool'), ('UCL', 'Paris Saint-Germain'),
    ('UCL', 'Inter Milan'), ('UCL', 'Juventus'), ('UCL', 'Manchester United'),
    ('UCL', 'Chelsea'), ('UCL', 'Arsenal'), ('UCL', 'AC Milan'),
    ('UCL', 'Atletico Madrid'), ('UCL', 'Borussia Dortmund'), ('UCL', 'Napoli'),
    ('UCL', 'Porto'), ('UCL', 'Benfica'), ('UCL', 'Ajax'),

    ('EPL', 'Aston Villa'), ('EPL', 'Bournemouth'),
    ('EPL', 'Brentford'), ('EPL', 'Brighton & Hove Albion'),
    ('EPL', 'Crystal Palace'), ('EPL', 'Everton'), ('EPL', 'Fulham'),
    ('EPL', 'Ipswich Town'), ('EPL', 'Leicester City'),
    ('EPL', 'Newcastle United'),
    ('EPL', 'Nottingham Forest'), ('EPL', 'Southampton'), ('EPL', 'Tottenham Hotspur'),
    ('EPL', 'West Ham United'), ('EPL', 'Wolverhampton Wanderers'),

    ('La Liga', 'Athletic Bilbao'), ('La Liga', 'Real Sociedad'), ('La Liga', 'Real Betis'),
    ('La Liga', 'Villarreal'), ('La Liga', 'Valencia'), ('La Liga', 'Sevilla'),
    ('La Liga', 'Girona'), ('La Liga', 'Osasuna'), ('La Liga', 'Celta Vigo'),
    ('La Liga', 'Rayo Vallecano'), ('La Liga', 'Getafe'), ('La Liga', 'Las Palmas'),
    ('La Liga', 'Alaves'), ('La Liga', 'Espanyol'), ('La Liga', 'Leganes'),
    ('La Liga', 'Mallorca'), ('La Liga', 'Valladolid'),

    ('Serie A', 'Roma'), ('Serie A', 'Lazio'),
    ('Serie A', 'Atalanta'), ('Serie A', 'Fiorentina'), ('Serie A', 'Bologna'),
    ('Serie A', 'Torino'), ('Serie A', 'Udinese'), ('Serie A', 'Genoa'),
    ('Serie A', 'Cagliari'), ('Serie A', 'Verona'), ('Serie A', 'Lecce'),
    ('Serie A', 'Parma'), ('Serie A', 'Como'), ('Serie A', 'Venezia'),
    ('Serie A', 'Empoli'), ('Serie A', 'Monza'),

    ('Bundesliga', 'RB Leipzig'),
    ('Bundesliga', 'Bayer Leverkusen'), ('Bundesliga', 'Eintracht Frankfurt'), ('Bundesliga', 'VfB Stuttgart'),
    ('Bundesliga', 'Borussia Monchengladbach'), ('Bundesliga', 'SC Freiburg'), ('Bundesliga', 'Werder Bremen'),
    ('Bundesliga', 'Union Berlin'), ('Bundesliga', 'Mainz 05'), ('Bundesliga', 'Wolfsburg'),
    ('Bundesliga', 'Hoffenheim'), ('Bundesliga', 'FC Augsburg'), ('Bundesliga', 'VfL Bochum'),
    ('Bundesliga', 'FC Heidenheim'), ('Bundesliga', 'Holstein Kiel'), ('Bundesliga', 'St. Pauli'),

    ('Israeli Premier League', 'Maccabi Haifa'), ('Israeli Premier League', 'Maccabi Tel Aviv'),
    ('Israeli Premier League', 'Hapoel Beer Sheva'), ('Israeli Premier League', 'Hapoel Tel Aviv'),
    ('Israeli Premier League', 'Beitar Jerusalem'), ('Israeli Premier League', 'Maccabi Netanya'),
    ('Israeli Premier League', 'Hapoel Haifa'), ('Israeli Premier League', 'Bnei Sakhnin'),
    ('Israeli Premier League', 'Ashdod'), ('Israeli Premier League', 'Hapoel Jerusalem'),
    ('Israeli Premier League', 'Kiryat Shmona'), ('Israeli Premier League', 'Maccabi Bnei Reineh'),
    ('Israeli Premier League', 'Hapoel Petah Tikva'), ('Israeli Premier League', 'Hapoel Kfar Saba')
) AS c(league_name, name) ON l.name = c.league_name
ON CONFLICT (league_id, name) DO NOTHING;

-- Link each UCL club that also plays in a domestic league this app seeds (decision 12).
-- Paris Saint-Germain/Porto/Benfica/Ajax are intentionally excluded -- their domestic
-- leagues (Ligue 1/Primeira Liga/Eredivisie) aren't seeded here, so they stay UCL-only.
UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'EPL')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name IN ('Arsenal', 'Chelsea', 'Liverpool', 'Manchester City', 'Manchester United');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'La Liga')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name IN ('Real Madrid', 'Barcelona', 'Atletico Madrid');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'Serie A')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name IN ('Inter Milan', 'AC Milan', 'Juventus', 'Napoli');

UPDATE clubs SET domestic_league_id = (SELECT id FROM leagues WHERE name = 'Bundesliga')
WHERE league_id = (SELECT id FROM leagues WHERE name = 'UCL')
  AND name IN ('Bayern Munich', 'Borussia Dortmund');

INSERT INTO previous_parties (name) VALUES
    ('הליכוד'), ('יש עתיד'), ('הציונות הדתית'), ('המחנה הממלכתי'),
    ('ישראל ביתנו'), ('ש"ס'), ('יהדות התורה'), ('רע"ם'),
    ('חד"ש-תע"ל'), ('העבודה'), ('מרצ'), ('בל"ד'), ('הבית היהודי'), ('אחר')
ON CONFLICT (name) DO NOTHING;

INSERT INTO upcoming_parties (name) VALUES
    ('הליכוד'), ('ישר'), ('ביחד'), ('הדמוקרטים'), ('כחול לבן'),
    ('ישראל ביתנו'), ('הציונות הדתית'), ('עוצמה יהודית'), ('חד"ש-תע"ל'),
    ('בל"ד'), ('המפלגה הכלכלית'), ('אל הדגל'), ('המילואימניקים')
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
UPDATE leagues SET name_en = 'Premier League' WHERE name = 'EPL';
UPDATE leagues SET name_en = 'UEFA Champions League' WHERE name = 'UCL';

-- World Cup 2026 countries
UPDATE clubs SET name_he = 'ברזיל' WHERE name_en = 'Brazil' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ארגנטינה' WHERE name_en = 'Argentina' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צרפת' WHERE name_en = 'France' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אנגליה' WHERE name_en = 'England' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ספרד' WHERE name_en = 'Spain' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גרמניה' WHERE name_en = 'Germany' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פורטוגל' WHERE name_en = 'Portugal' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הולנד' WHERE name_en = 'Netherlands' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איטליה' WHERE name_en = 'Italy' AND name_he IS NULL;
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
UPDATE clubs SET name_he = 'ניגריה' WHERE name_en = 'Nigeria' AND name_he IS NULL;
UPDATE clubs SET name_he = 'גאנה' WHERE name_en = 'Ghana' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מצרים' WHERE name_en = 'Egypt' AND name_he IS NULL;
UPDATE clubs SET name_he = 'תוניסיה' WHERE name_en = 'Tunisia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אלג''יריה' WHERE name_en = 'Algeria' AND name_he IS NULL;
UPDATE clubs SET name_he = 'חוף השנהב' WHERE name_en = 'Ivory Coast' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קמרון' WHERE name_en = 'Cameroon' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוסטרליה' WHERE name_en = 'Australia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איראן' WHERE name_en = 'Iran' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ערב הסעודית' WHERE name_en = 'Saudi Arabia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'קטאר' WHERE name_en = 'Qatar' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אקוודור' WHERE name_en = 'Ecuador' AND name_he IS NULL;
UPDATE clubs SET name_he = 'צ''ילה' WHERE name_en = 'Chile' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרו' WHERE name_en = 'Peru' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פולין' WHERE name_en = 'Poland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שווייץ' WHERE name_en = 'Switzerland' AND name_he IS NULL;
UPDATE clubs SET name_he = 'דנמרק' WHERE name_en = 'Denmark' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שוודיה' WHERE name_en = 'Sweden' AND name_he IS NULL;
UPDATE clubs SET name_he = 'סרביה' WHERE name_en = 'Serbia' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ישראל' WHERE name_en = 'Israel' AND name_he IS NULL;

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
UPDATE clubs SET name_he = 'אתלטיקו מדריד' WHERE name_en = 'Atletico Madrid' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורוסיה דורטמונד' WHERE name_en = 'Borussia Dortmund' AND name_he IS NULL;
UPDATE clubs SET name_he = 'נאפולי' WHERE name_en = 'Napoli' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פורטו' WHERE name_en = 'Porto' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בנפיקה' WHERE name_en = 'Benfica' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אייאקס' WHERE name_en = 'Ajax' AND name_he IS NULL;

-- EPL clubs not already covered by UCL
UPDATE clubs SET name_he = 'אסטון וילה' WHERE name_en = 'Aston Villa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורנמות''' WHERE name_en = 'Bournemouth' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברנטפורד' WHERE name_en = 'Brentford' AND name_he IS NULL;
UPDATE clubs SET name_he = 'ברייטון והוב אלביון' WHERE name_en = 'Brighton & Hove Albion' AND name_he IS NULL;
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
UPDATE clubs SET name_he = 'אלאבס' WHERE name_en = 'Alaves' AND name_he IS NULL;
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
UPDATE clubs SET name_he = 'לייפציג' WHERE name_en = 'RB Leipzig' AND name_he IS NULL;
UPDATE clubs SET name_he = 'באייר לברקוזן' WHERE name_en = 'Bayer Leverkusen' AND name_he IS NULL;
UPDATE clubs SET name_he = 'איינטרכט פרנקפורט' WHERE name_en = 'Eintracht Frankfurt' AND name_he IS NULL;
UPDATE clubs SET name_he = 'שטוטגרט' WHERE name_en = 'VfB Stuttgart' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בורוסיה מנשנגלדבך' WHERE name_en = 'Borussia Monchengladbach' AND name_he IS NULL;
UPDATE clubs SET name_he = 'פרייבורג' WHERE name_en = 'SC Freiburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וורדר ברמן' WHERE name_en = 'Werder Bremen' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוניון ברלין' WHERE name_en = 'Union Berlin' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מיינץ 05' WHERE name_en = 'Mainz 05' AND name_he IS NULL;
UPDATE clubs SET name_he = 'וולפסבורג' WHERE name_en = 'Wolfsburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הופנהיים' WHERE name_en = 'Hoffenheim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'אוגסבורג' WHERE name_en = 'FC Augsburg' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בוכום' WHERE name_en = 'VfL Bochum' AND name_he IS NULL;
UPDATE clubs SET name_he = 'היידנהיים' WHERE name_en = 'FC Heidenheim' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הולשטיין קיל' WHERE name_en = 'Holstein Kiel' AND name_he IS NULL;
UPDATE clubs SET name_he = 'זנקט פאולי' WHERE name_en = 'St. Pauli' AND name_he IS NULL;

-- Israeli Premier League clubs
UPDATE clubs SET name_he = 'מכבי חיפה' WHERE name_en = 'Maccabi Haifa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי תל אביב' WHERE name_en = 'Maccabi Tel Aviv' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל באר שבע' WHERE name_en = 'Hapoel Beer Sheva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל תל אביב' WHERE name_en = 'Hapoel Tel Aviv' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בית"ר ירושלים' WHERE name_en = 'Beitar Jerusalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי נתניה' WHERE name_en = 'Maccabi Netanya' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל חיפה' WHERE name_en = 'Hapoel Haifa' AND name_he IS NULL;
UPDATE clubs SET name_he = 'בני סכנין' WHERE name_en = 'Bnei Sakhnin' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מ.ס. אשדוד' WHERE name_en = 'Ashdod' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל ירושלים' WHERE name_en = 'Hapoel Jerusalem' AND name_he IS NULL;
UPDATE clubs SET name_he = 'עירוני קריית שמונה' WHERE name_en = 'Kiryat Shmona' AND name_he IS NULL;
UPDATE clubs SET name_he = 'מכבי בני ריינה' WHERE name_en = 'Maccabi Bnei Reineh' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל פתח תקווה' WHERE name_en = 'Hapoel Petah Tikva' AND name_he IS NULL;
UPDATE clubs SET name_he = 'הפועל כפר סבא' WHERE name_en = 'Hapoel Kfar Saba' AND name_he IS NULL;

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
UPDATE previous_parties SET name_en = 'Jewish Home' WHERE name_he = 'הבית היהודי' AND name_en IS NULL;
UPDATE previous_parties SET name_en = 'Other' WHERE name_he = 'אחר' AND name_en IS NULL;

-- Upcoming election parties
UPDATE upcoming_parties SET name_en = 'Likud' WHERE name_he = 'הליכוד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yesh' WHERE name_he = 'ישר' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yachad' WHERE name_he = 'ביחד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Democrats' WHERE name_he = 'הדמוקרטים' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Blue and White' WHERE name_he = 'כחול לבן' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Yisrael Beiteinu' WHERE name_he = 'ישראל ביתנו' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Religious Zionist Party' WHERE name_he = 'הציונות הדתית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Otzma Yehudit' WHERE name_he = 'עוצמה יהודית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Hadash-Ta''al' WHERE name_he = 'חד"ש-תע"ל' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'Balad' WHERE name_he = 'בל"ד' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Economic Party' WHERE name_he = 'המפלגה הכלכלית' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'El HaDegel' WHERE name_he = 'אל הדגל' AND name_en IS NULL;
UPDATE upcoming_parties SET name_en = 'The Reservists' WHERE name_he = 'המילואימניקים' AND name_en IS NULL;

-- New party: The Joint List (not a backfill target)
INSERT INTO upcoming_parties (name, name_en, name_he) VALUES ('הרשימה המשותפת', 'The Joint List', 'הרשימה המשותפת') ON CONFLICT (name) DO NOTHING;
