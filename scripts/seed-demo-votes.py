#!/usr/bin/env python3
"""Populate a Voteball deployment with demo ballots so the results dashboard has something to show.

    ./scripts/seed-demo-votes.py [count] [base-url]
    ./scripts/seed-demo-votes.py 500 https://voteball.example.com

Defaults to 500 ballots against http://localhost:8080. Every ballot goes through the public
/api/vote endpoint, so this exercises the same validation a real visitor would.

The results tables are computed by the worker, not at write time -- if the worker is not running,
recompute them by hand afterwards:

    python -c "import db, rollups; c=db.get_db(); rollups.recompute(c); c.close()"

The point of the poll is the correlation between football fandom and party choice, so the data is
skewed the way the real thesis expects rather than being uniform noise — otherwise every chart is a
flat line and the screenshots say nothing. Skews are illustrative demo data, not a claim about any
real fan base.
"""
import json
import random
import sys
import urllib.error
import urllib.request

BASE = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8080"
random.seed(20260720)  # reproducible screenshots

# Israeli Premier League club -> weighted previous-election party leanings (party ids from /api/options)
LIKUD, YESH_ATID, RZP, NAT_UNITY, YB, SHAS, UTJ, RAAM, HADASH, LABOR, MERETZ, BALAD, OTHER = (
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)

CLUB_LEAN = {
    142: [(LIKUD, 46), (RZP, 20), (SHAS, 10), (YB, 6), (NAT_UNITY, 6), (YESH_ATID, 6), (UTJ, 4), (OTHER, 2)],   # Beitar Jerusalem
    139: [(YESH_ATID, 30), (NAT_UNITY, 22), (LABOR, 12), (LIKUD, 16), (MERETZ, 8), (YB, 7), (OTHER, 5)],        # Maccabi Tel Aviv
    141: [(LABOR, 24), (MERETZ, 22), (YESH_ATID, 20), (HADASH, 12), (NAT_UNITY, 12), (LIKUD, 6), (OTHER, 4)],   # Hapoel Tel Aviv
    138: [(YESH_ATID, 24), (LIKUD, 20), (NAT_UNITY, 18), (LABOR, 14), (MERETZ, 8), (SHAS, 8), (OTHER, 8)],      # Maccabi Haifa
    140: [(LIKUD, 34), (SHAS, 16), (YESH_ATID, 16), (NAT_UNITY, 12), (RZP, 10), (YB, 6), (OTHER, 6)],           # Hapoel Be'er Sheva
    145: [(RAAM, 34), (HADASH, 30), (BALAD, 20), (LABOR, 6), (MERETZ, 5), (OTHER, 5)],                          # Bnei Sakhnin
    147: [(MERETZ, 22), (LABOR, 20), (YESH_ATID, 20), (HADASH, 14), (NAT_UNITY, 14), (OTHER, 10)],              # Hapoel Jerusalem
    144: [(LABOR, 22), (YESH_ATID, 22), (NAT_UNITY, 18), (LIKUD, 14), (MERETZ, 12), (OTHER, 12)],               # Hapoel Haifa
    143: [(LIKUD, 30), (YESH_ATID, 20), (SHAS, 14), (NAT_UNITY, 14), (YB, 12), (OTHER, 10)],                    # Maccabi Netanya
    148: [(LIKUD, 32), (YB, 20), (NAT_UNITY, 16), (YESH_ATID, 14), (RZP, 10), (OTHER, 8)],                      # Ironi Kiryat Shmona
}
IPL_CLUBS = list(CLUB_LEAN)
OTHER_IPL = [146, 149, 150, 151]
LIGA_LEUMIT = [152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167]
# Club ids are NOT in per-league bands, and a Champions League club may be voted under either its UCL
# entry or its domestic league -- so build the real (club -> valid league ids) map from the API.
def load_clubs():
    with urllib.request.urlopen(BASE + "/api/options", timeout=15) as r:
        opts = json.load(r)
    valid = {}
    for c in opts["clubs"]:
        ls = [c["league_id"]]
        if c.get("domestic_league_id"):
            ls.append(c["domestic_league_id"])
        valid[c["id"]] = ls
    return valid, opts


VALID_LEAGUES, OPTIONS = load_clubs()
# Non-Israeli clubs, for the "I also follow a European team" picks
FOREIGN = [c["id"] for c in OPTIONS["clubs"] if c["league_id"] in (2, 3, 4, 5, 6)]

# previous party -> likely upcoming choices (the vote-switch story the results page visualises)
SWITCH = {
    LIKUD:      [(1, 42), (12, 14), (8, 12), (7, 10), (13, 8), (16, 8), (14, 6)],
    YESH_ATID:  [(2, 30), (5, 22), (4, 18), (16, 12), (3, 10), (15, 8)],
    RZP:        [(7, 40), (8, 30), (1, 18), (13, 12)],
    NAT_UNITY:  [(5, 34), (2, 20), (4, 16), (16, 16), (1, 14)],
    YB:         [(6, 46), (1, 18), (5, 16), (2, 12), (16, 8)],
    SHAS:       [(12, 58), (1, 20), (13, 12), (7, 10)],
    UTJ:        [(13, 62), (12, 18), (1, 12), (7, 8)],
    RAAM:       [(11, 56), (9, 24), (10, 12), (4, 8)],
    HADASH:     [(9, 54), (10, 22), (11, 14), (4, 10)],
    LABOR:      [(4, 46), (2, 20), (3, 16), (5, 10), (15, 8)],
    MERETZ:     [(4, 48), (3, 20), (9, 14), (2, 10), (15, 8)],
    BALAD:      [(10, 50), (9, 26), (11, 16), (4, 8)],
    OTHER:      [(1, 20), (2, 18), (4, 16), (16, 16), (14, 16), (3, 14)],
}


def pick(weighted):
    total = sum(w for _, w in weighted)
    r = random.uniform(0, total)
    upto = 0
    for val, w in weighted:
        upto += w
        if upto >= r:
            return val
    return weighted[-1][0]


def post(path, payload):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def make_ballot():
    picks = []
    # Everyone picks an Israeli club (that's the correlation we want to show)
    if random.random() < 0.86:
        club = pick([(c, 10) for c in IPL_CLUBS] + [(c, 2) for c in OTHER_IPL])
        picks.append({"league_id": 7, "club_id": club})
    else:
        club = None
        picks.append({"league_id": 8, "club_id": random.choice(LIGA_LEUMIT)})

    # Many fans also follow a European team; pick a league the club is actually votable under
    if random.random() < 0.55:
        fc = random.choice(FOREIGN)
        picks.append({"league_id": random.choice(VALID_LEAGUES[fc]), "club_id": fc})
    # Some follow a second Israeli club... not allowed to mix null+specific, so add another specific
    if random.random() < 0.18 and club:
        second = random.choice([c for c in IPL_CLUBS + OTHER_IPL if c != club])
        picks.append({"league_id": 7, "club_id": second})

    lean = CLUB_LEAN.get(club, [(p, 8) for p in (LIKUD, YESH_ATID, NAT_UNITY, SHAS, LABOR, YB, OTHER)])
    voted = random.random() < 0.88
    prev = pick(lean) if voted else None

    r = random.random()
    if not voted:
        up_status, ups = ("undecided", [])
    elif r < 0.70:
        up_status, ups = ("considering", [pick(SWITCH[prev])])
    elif r < 0.90:
        n = random.choice([2, 2, 3])
        opts = SWITCH[prev]
        ups = []
        while len(ups) < n and len(ups) < len(opts):
            c = pick(opts)
            if c not in ups:
                ups.append(c)
        up_status = "considering"
    else:
        up_status, ups = ("undecided", [])

    return {
        "team_picks": picks,
        "previous_vote_status": "voted" if voted else "did_not_vote",
        "previous_party_id": prev,
        "upcoming_vote_status": up_status,
        "upcoming_party_ids": ups,
    }


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 500
    print(f"Posting {n} demo ballots to {BASE} ...")
    codes = {}
    for _ in range(n):
        c = post("/api/vote", make_ballot())
        codes[c] = codes.get(c, 0) + 1
    print("response codes:", codes)


if __name__ == "__main__":
    main()
