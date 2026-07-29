---
name: voteball-api
description: The Voteball backend's full HTTP API surface — every route in services/backend/app.py with its method, auth requirement, request body, validation rules and error codes. Use when adding, changing, calling or debugging any /api/* or /health endpoint, or when wiring a frontend page or admin screen to the backend.
---

# Voteball API surface

Authoritative list of every route in `services/backend/app.py`. Verify against
`grep -oE "@app\.route\('[^']+'" services/backend/app.py` — this table has drifted before (ten
clubs/leagues admin routes went undocumented until the 2026-07-26 audit).

Admin routes (`/api/admin/...`) are gated by the `require_admin` decorator in `app.py`, which verifies
an `Authorization: Bearer <token>` header. Reuse that decorator for any new admin route — don't
hand-roll the check.

| Route | Method | Auth | Notes |
|---|---|---|---|
| `/health` | GET | none | liveness/readiness probe target |
| `/api/options` | GET | none | leagues/clubs/previous_parties/upcoming_parties (each with `name_en`/`name_he`/`name_ru`), consumed by both frontend pages |
| `/api/vote` | POST | none, cookie-deduped | body `{"team_picks": [{"league_id", "club_id"}, ...], "previous_vote_status", "previous_party_id", "upcoming_vote_status", "upcoming_party_ids"}`; `team_picks` needs ≥1 entry, ≤3 non-null `club_id` picks per distinct `league_id`, and a `club_id: null` ("just this league") entry can't coexist with specific-club entries in the same league; each `club_id`/`league_id` pair is validated against that club's real `{league_id, domestic_league_id}`; sets `voteball_token` cookie (1yr); 409 on repeat vote; 400 if `upcoming_vote_status=considering` with no `upcoming_party_ids`, or if `upcoming_party_ids` has more than 3 entries — client also validates all of this before submitting |
| `/api/results` | GET | none | `?by=club\|league&id=N`, `?by=party&type=previous\|upcoming&id=N` (also returns a national `crosstab` of the other party type), or `?by=all` (national totals); reads the worker-computed rollup tables — `by=league` and `by=all` read the dedup/national-scoped rows so a multi-team ballot isn't over-counted |
| `/api/results/segment` | GET | none | `?previous_party_id=P[&club_id=C\|&league_id=L]`; the "voters like you" migration cut — club/league-scoped if given, else national; returns `{"upcoming": [...], "total": N}` |
| `/api/admin/login` | POST | none | body `{"username", "password"}`; returns `{"token"}` on success, `401` on any failure |
| `/api/admin/previous-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/previous-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/previous-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; moves every vote's `previous_party_id` from `<id>` to `target_id`, returns `{"reassigned": N}` |
| `/api/admin/upcoming-parties` | POST | Bearer token | create; 409 if the name already exists |
| `/api/admin/upcoming-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove; DELETE returns 409 if any votes still reference the party |
| `/api/admin/upcoming-parties/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; returns `{"count": N}` of votes that would move |
| `/api/admin/upcoming-parties/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; reassigns every vote's `<id>` pick to `target_id` (collision-safe against the ≤3-pick cap), returns `{"reassigned": N}` |
| `/api/admin/votes` | GET | Bearer token | list all votes (no `cookie_token` in the response); each vote carries `team_picks: [{"league_id", "club_id"}, ...]` (assembled from separate queries against `vote_clubs`/`vote_leagues`, not a joined `array_agg`, to avoid cartesian-inflating `upcoming_party_ids` alongside it) |
| `/api/admin/votes/<id>` | DELETE | Bearer token | remove one vote; cascades to its `vote_clubs`/`vote_leagues`/`vote_upcoming_parties` rows |
| `/api/results/switch` | GET | none | `?league_id=N&club_id=N` (both optional); vote-switch view — how voters moved between previous and upcoming parties |
| `/api/results/clubs-breakdown` | GET | none | no params; per-club totals across all leagues |
| `/api/admin/leagues` | POST | Bearer token | create; body `{"name_en", "name_he", ...}` (`name_ru` optional) |
| `/api/admin/leagues/<id>` | PATCH/DELETE | Bearer token | rename/remove |
| `/api/admin/leagues/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; rows that would move |
| `/api/admin/leagues/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; moves votes off `<id>` |
| `/api/admin/clubs` | POST | Bearer token | create; body needs `name_en`, `name_he` and an integer `league_id` (`name_ru`, `logo_url` optional) |
| `/api/admin/clubs/<id>` | PATCH/DELETE | Bearer token | rename/remove; PATCH takes the same body as create |
| `/api/admin/clubs/<id>/reassign-count` | GET | Bearer token | `?target_id=N`; rows that would move |
| `/api/admin/clubs/<id>/reassign` | POST | Bearer token | body `{"target_id": N}`; moves votes off `<id>` |

`docs/admin-guide.md` covers the admin routes in plain language, including the clubs/leagues CRUD
block under "Managing leagues and clubs (the Teams tab)"; the design doc is
`docs/design/2026-07-15-clubs-leagues-admin-crud-design.md`.
