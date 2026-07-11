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

    ('EPL', 'Arsenal'), ('EPL', 'Aston Villa'), ('EPL', 'Bournemouth'),
    ('EPL', 'Brentford'), ('EPL', 'Brighton & Hove Albion'), ('EPL', 'Chelsea'),
    ('EPL', 'Crystal Palace'), ('EPL', 'Everton'), ('EPL', 'Fulham'),
    ('EPL', 'Ipswich Town'), ('EPL', 'Leicester City'), ('EPL', 'Liverpool'),
    ('EPL', 'Manchester City'), ('EPL', 'Manchester United'), ('EPL', 'Newcastle United'),
    ('EPL', 'Nottingham Forest'), ('EPL', 'Southampton'), ('EPL', 'Tottenham Hotspur'),
    ('EPL', 'West Ham United'), ('EPL', 'Wolverhampton Wanderers'),

    ('La Liga', 'Real Madrid'), ('La Liga', 'Barcelona'), ('La Liga', 'Atletico Madrid'),
    ('La Liga', 'Athletic Bilbao'), ('La Liga', 'Real Sociedad'), ('La Liga', 'Real Betis'),
    ('La Liga', 'Villarreal'), ('La Liga', 'Valencia'), ('La Liga', 'Sevilla'),
    ('La Liga', 'Girona'), ('La Liga', 'Osasuna'), ('La Liga', 'Celta Vigo'),
    ('La Liga', 'Rayo Vallecano'), ('La Liga', 'Getafe'), ('La Liga', 'Las Palmas'),
    ('La Liga', 'Alaves'), ('La Liga', 'Espanyol'), ('La Liga', 'Leganes'),
    ('La Liga', 'Mallorca'), ('La Liga', 'Valladolid'),

    ('Serie A', 'Inter Milan'), ('Serie A', 'AC Milan'), ('Serie A', 'Juventus'),
    ('Serie A', 'Napoli'), ('Serie A', 'Roma'), ('Serie A', 'Lazio'),
    ('Serie A', 'Atalanta'), ('Serie A', 'Fiorentina'), ('Serie A', 'Bologna'),
    ('Serie A', 'Torino'), ('Serie A', 'Udinese'), ('Serie A', 'Genoa'),
    ('Serie A', 'Cagliari'), ('Serie A', 'Verona'), ('Serie A', 'Lecce'),
    ('Serie A', 'Parma'), ('Serie A', 'Como'), ('Serie A', 'Venezia'),
    ('Serie A', 'Empoli'), ('Serie A', 'Monza'),

    ('Bundesliga', 'Bayern Munich'), ('Bundesliga', 'Borussia Dortmund'), ('Bundesliga', 'RB Leipzig'),
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
