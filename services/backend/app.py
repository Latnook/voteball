# Routes live here; SQL lives in queries.py; db.py holds only connection setup and schema bootstrap.
# Every route must guarantee conn.close() on all exit paths -- see results() and vote() for the shape.
#
# This image is built by the in-cluster Jenkins (namespace `ci`) with rootless BuildKit, scanned as an
# OCI tarball by Trivy, and pushed with skopeo -- there is no Docker daemon anywhere in the pipeline.
# See docs/cicd.md and docs/design/2026-07-30-jenkins-on-eks-design.md.
#
# Verified end to end on 2026-07-31: webhook -> guard -> BuildKit -> Trivy -> skopeo -> tag
# bump -> ArgoCD -> running pods.
import hashlib
import os
import time
import uuid
from functools import wraps

import db
import metrics
import queries
from flask import Flask, Response, jsonify, make_response, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from werkzeug.security import check_password_hash

app = Flask(__name__)

ADMIN_USERNAME = os.environ['ADMIN_USERNAME']
ADMIN_PASSWORD_HASH = os.environ['ADMIN_PASSWORD_HASH']
ADMIN_SESSION_SECRET = os.environ['ADMIN_SESSION_SECRET']

# Ballot-stuffing limits. The cookie is the primary one-vote-per-visitor mechanism, but a cookie is
# client-side and clearing it buys another ballot -- so cap how many ballots one source can cast.
# Not 1-per-IP: Israeli mobile carriers use CGNAT heavily and households share an address, so a hard
# 1 would lock out large numbers of genuine voters. A small cap stops casual re-voting and scripted
# flooding while leaving real shared connections usable.
#
# Since 2026-07-21 this is the SECOND layer, not the only one: AWS WAF on the ALB blocks any address
# exceeding 100 requests per 5 minutes to /api/vote (terraform/waf.tf), so a flood is dropped before
# it reaches a pod. The two are deliberately different in kind -- WAF counts requests and forgets,
# this counts *successful ballots* over 24h and persists. Keep both: WAF alone would let a patient
# script vote steadily under the rate limit, and this alone leaves the pods absorbing the flood.
MAX_VOTES_PER_IP = int(os.environ.get('MAX_VOTES_PER_IP', '5'))
VOTE_IP_WINDOW_HOURS = int(os.environ.get('VOTE_IP_WINDOW_HOURS', '24'))
# Salt so the stored hashes are useless outside this deployment and cannot be reversed by hashing
# the IPv4 space. Falls back to the admin secret when unset, which is already required and rotated.
VOTE_IP_SALT = os.environ.get('VOTE_IP_SALT', ADMIN_SESSION_SECRET)
# Set false only if the app is ever served over plain HTTP (it is not: the ALB redirects to HTTPS).
COOKIE_SECURE = os.environ.get('COOKIE_SECURE', 'true').lower() != 'false'

# Publish the running build's identity once per worker process. With multiprocess_mode='max' the
# workers collapse to a single series -- see metrics.py.
metrics.set_app_info()


@app.before_request
def _metrics_start_timer():
    request.environ['voteball.start'] = time.perf_counter()


@app.after_request
def _metrics_record(response):
    """Count every response and observe its latency.

    Runs for error responses too, including the 500 Flask synthesises from an unhandled exception --
    which is exactly the case this instrumentation exists for, since /health is static and the
    liveness probe is a bare TCP check, so a backend that 500s on every API call still looks Ready.

    /metrics itself is excluded: counting scrapes adds a fixed background request rate that never
    falls to zero and is indistinguishable from real traffic.
    """
    if request.path == '/metrics':
        return response
    endpoint = metrics.endpoint_label(request.url_rule)
    method = metrics.method_label(request.method)
    started = request.environ.get('voteball.start')
    if started is not None:
        metrics.LATENCY.labels(method, endpoint).observe(time.perf_counter() - started)
    metrics.REQUESTS.labels(method, endpoint, str(response.status_code)).inc()
    return response


@app.route('/metrics', methods=['GET'])
def prometheus_metrics():
    """Scrape target. NOT reachable from the internet: nginx proxies only /api/*, so this path has
    no public route. In-cluster reachability is currently whatever the namespace's NetworkPolicy
    allows; the rule admitting the observability namespace to port 5000 arrives with the chart
    wiring in a later plan. Deliberately separate from /health, which the probes use."""
    payload, content_type = metrics.render_latest()
    return Response(payload, content_type=content_type)


def _client_ip():
    """The real client address, given this deployment's ALB -> nginx -> backend chain.

    Each hop APPENDS to X-Forwarded-For, so the backend sees "<client>, <alb>": the ALB appends the
    address it saw, then nginx appends the ALB's. The rightmost entry is therefore our own
    infrastructure and the one before it is what the ALB actually observed.

    We deliberately do NOT take the leftmost entry, which is the usual mistake: a client can send its
    own X-Forwarded-For and the ALB appends after it, so the leftmost value is attacker-controlled and
    would make the rate limit trivially bypassable.
    """
    forwarded = request.headers.get('X-Forwarded-For', '')
    parts = [p.strip() for p in forwarded.split(',') if p.strip()]
    if len(parts) >= 2:
        return parts[-2]
    if parts:
        return parts[-1]
    return request.remote_addr


def _ip_hash():
    """Salted one-way hash of the client address, or None if we cannot determine it."""
    ip = _client_ip()
    if not ip:
        return None
    return hashlib.sha256(f'{VOTE_IP_SALT}:{ip}'.encode()).hexdigest()

_admin_token_serializer = URLSafeTimedSerializer(ADMIN_SESSION_SECRET, salt='admin-session')
ADMIN_TOKEN_MAX_AGE = 12 * 60 * 60  # 12 hours, in seconds


def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'unauthorized'}), 401
        token = auth_header[len('Bearer '):]
        try:
            username = _admin_token_serializer.loads(token, max_age=ADMIN_TOKEN_MAX_AGE)
        except (BadSignature, SignatureExpired):
            return jsonify({'error': 'unauthorized'}), 401
        if username != ADMIN_USERNAME:
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return wrapper


_DUPLICATE_LANGUAGE_NAMES = {'en': 'English', 'he': 'Hebrew', 'ru': 'Russian'}


def _duplicate_party_error_response(err):
    language = _DUPLICATE_LANGUAGE_NAMES.get(err.language, 'Hebrew')
    return jsonify({'error': f'a party with this {language} name already exists'}), 409


def _duplicate_named_error_response(err, entity):
    language = _DUPLICATE_LANGUAGE_NAMES.get(err.language, 'Hebrew')
    return jsonify({'error': f'a {entity} with this {language} name already exists'}), 409


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


@app.route('/api/options', methods=['GET'])
def options():
    # DRILL 4 (2026-08-18 re-run, TEMPORARY -- reverted in the very next commit): an artificial delay
    # that makes this release SLOW rather than BROKEN. The CD smoke test uses `curl --max-time 15` and
    # checks for a 200, so it PASSES; only the monitoring gate's p95 check (GATE_MAX_P95_SECONDS=1.0)
    # can catch this. That distinction is the entire reason the gate exists alongside the smoke test,
    # and this drill is what proves it.
    import time as _drill_time
    _drill_time.sleep(1.5)
    conn = db.get_db()
    result = queries.get_options(conn)
    conn.close()
    return jsonify(result)


def _validate_team_picks(conn, team_picks):
    """Returns an error message string if team_picks is invalid, else None. A ballot names 0-3
    specific clubs per league (never mixed with a "just this league" pick in that same league),
    across any number of leagues, with at least one pick required overall."""
    if not isinstance(team_picks, list) or not team_picks:
        return 'team_picks must be a non-empty list'

    league_ids = queries.get_all_league_ids(conn)
    clubs_map = queries.get_clubs_league_map(conn)

    picks_by_league = {}
    club_id_first_league = {}
    for pick in team_picks:
        if not isinstance(pick, dict):
            return 'each team pick must be an object with league_id and club_id'
        league_id = pick.get('league_id')
        club_id = pick.get('club_id')
        if not isinstance(league_id, int) or league_id not in league_ids:
            return 'each team pick needs a valid league_id'
        if club_id is not None:
            if not isinstance(club_id, int) or club_id not in clubs_map:
                return 'club_id must be null or reference an existing club'
            club_leagues = clubs_map[club_id]
            if league_id not in (club_leagues['league_id'], club_leagues['domestic_league_id']):
                return 'club_id is not votable under the given league_id'
            # A dual-league club (league_id + domestic_league_id both set) is only ever meant to be
            # picked once per ballot -- the frontend now mirrors its checkbox across both league
            # tabs and submits a single canonical pick, so seeing it under two *different* leagues
            # here means a stale/non-standard client, not two distinct real picks. A same-league
            # repeat is a different, pre-existing case, left to the per-league dedup check below so
            # its more specific error message still applies.
            first_league = club_id_first_league.setdefault(club_id, league_id)
            if first_league != league_id:
                return 'club_id picked under more than one league'
        picks_by_league.setdefault(league_id, []).append(club_id)

    for club_ids in picks_by_league.values():
        specific = [c for c in club_ids if c is not None]
        if len(specific) < len(club_ids) and specific:
            return 'a league cannot mix "just this league" with specific club picks'
        if len(club_ids) - len(specific) > 1:
            return 'a league can only have one "just this league" pick'
        if len(specific) > 3:
            return 'select at most 3 clubs per league'
        if len(specific) != len(set(specific)):
            return 'duplicate club pick in the same league'

    return None


@app.route('/api/vote', methods=['POST'])
def vote():
    token = request.cookies.get('voteball_token')
    is_new_token = token is None
    if is_new_token:
        token = uuid.uuid4().hex

    body = request.get_json(force=True, silent=True) or {}

    if body.get('upcoming_vote_status') == 'considering' and not body.get('upcoming_party_ids'):
        metrics.VOTES_REJECTED.labels(reason='considering-without-parties').inc()
        return jsonify({'error': 'select at least one upcoming party when status is considering'}), 400
    if len(body.get('upcoming_party_ids') or []) > 3:
        metrics.VOTES_REJECTED.labels(reason='too-many-parties').inc()
        return jsonify({'error': 'select at most 3 upcoming parties'}), 400

    ip_hash = _ip_hash()

    conn = db.get_db()
    try:
        team_picks = body.get('team_picks')
        picks_error = _validate_team_picks(conn, team_picks)
        if picks_error:
            metrics.VOTES_REJECTED.labels(reason='invalid-team-picks').inc()
            return jsonify({'error': picks_error}), 400

        # Second line of defence behind the cookie: cap ballots per source address. Checked before
        # the insert so a blocked attempt writes nothing.
        if queries.count_recent_votes_by_ip(conn, ip_hash, VOTE_IP_WINDOW_HOURS) >= MAX_VOTES_PER_IP:
            metrics.VOTES_REJECTED.labels(reason='rate-limited').inc()
            return jsonify({'error': 'Too many votes from this connection. Try again later.'}), 429

        vote_id = queries.insert_vote(
            conn,
            team_picks=team_picks,
            previous_vote_status=body.get('previous_vote_status'),
            previous_party_id=body.get('previous_party_id'),
            upcoming_vote_status=body.get('upcoming_vote_status'),
            upcoming_party_ids=body.get('upcoming_party_ids', []),
            cookie_token=token,
            ip_hash=ip_hash,
        )
    except ValueError:
        metrics.VOTES_REJECTED.labels(reason='duplicate').inc()
        return jsonify({'error': 'You have already voted'}), 409
    except Exception:
        metrics.VOTES_REJECTED.labels(reason='invalid-data').inc()
        return jsonify({'error': 'invalid vote data'}), 400
    finally:
        conn.close()

    metrics.VOTES_CAST.inc()
    resp = make_response(jsonify({'vote_id': vote_id}), 201)
    if is_new_token:
        # httponly: JS cannot read or forge it, so the dedup token can't be tampered with from the
        # page. secure: never sent over plain HTTP. samesite=Lax: not sent on cross-site POSTs, so a
        # third-party page cannot silently spend a visitor's ballot.
        resp.set_cookie('voteball_token', token, max_age=31536000,
                        httponly=True, secure=COOKIE_SECURE, samesite='Lax')
    return resp


@app.route('/api/results', methods=['GET'])
def results():
    by = request.args.get('by')
    conn = db.get_db()
    try:
        if by == 'club':
            club_id = request.args.get('id', type=int)
            result = queries.get_results_by_club(conn, club_id)
        elif by == 'league':
            league_id = request.args.get('id', type=int)
            result = queries.get_results_by_league(conn, league_id)
        elif by == 'party':
            party_type = request.args.get('type')
            party_id = request.args.get('id', type=int)
            if party_type not in ('previous', 'upcoming'):
                return jsonify({'error': "type must be 'previous' or 'upcoming'"}), 400
            result = queries.get_results_by_party(conn, party_type, party_id)
        elif by == 'all':
            result = queries.get_results_all(conn)
        else:
            return jsonify({'error': "by must be 'club', 'league', 'party', or 'all'"}), 400
    finally:
        conn.close()

    return jsonify(result)


@app.route('/api/results/segment', methods=['GET'])
def results_segment():
    previous_party_id = request.args.get('previous_party_id', type=int)
    if previous_party_id is None:
        return jsonify({'error': 'previous_party_id is required'}), 400
    club_id = request.args.get('club_id', type=int)
    league_id = request.args.get('league_id', type=int)

    conn = db.get_db()
    try:
        result = queries.get_results_segment(conn, previous_party_id, club_id=club_id, league_id=league_id)
    finally:
        conn.close()
    return jsonify(result)


@app.route('/api/results/switch', methods=['GET'])
def results_switch():
    league_id = request.args.get('league_id', type=int)
    club_id = request.args.get('club_id', type=int)

    conn = db.get_db()
    try:
        result = queries.get_results_switch(conn, league_id=league_id, club_id=club_id)
    finally:
        conn.close()

    return jsonify(result)


@app.route('/api/results/clubs-breakdown', methods=['GET'])
def results_clubs_breakdown():
    conn = db.get_db()
    try:
        result = queries.get_clubs_breakdown(conn)
    finally:
        conn.close()

    return jsonify(result)


@app.route('/api/admin/login', methods=['POST'])
def admin_login():
    body = request.get_json(force=True, silent=True) or {}
    username = body.get('username', '')
    password = body.get('password', '')

    # Always run both checks - an early return on a bad username would make this endpoint
    # measurably faster for wrong-username requests than wrong-password ones, leaking
    # which was true via timing.
    username_ok = username == ADMIN_USERNAME
    password_ok = check_password_hash(ADMIN_PASSWORD_HASH, password)
    if not (username_ok and password_ok):
        return jsonify({'error': 'invalid username or password'}), 401

    token = _admin_token_serializer.dumps(ADMIN_USERNAME)
    return jsonify({'token': token})


@app.route('/api/admin/upcoming-parties', methods=['POST'])
@require_admin
def create_upcoming_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_upcoming_party(conn, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url}), 201


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_upcoming_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_upcoming_party(conn, party_id, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url})


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['DELETE'])
@require_admin
def delete_upcoming_party_route(party_id):
    conn = db.get_db()
    try:
        referencing = queries.count_votes_for_upcoming_party(conn, party_id)
        if referencing > 0:
            return jsonify({'error': f'{referencing} vote(s) still reference this party'}), 409
        deleted = queries.delete_upcoming_party(conn, party_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


@app.route('/api/admin/upcoming-parties/<int:source_id>/reassign-count', methods=['GET'])
@require_admin
def upcoming_party_reassign_count_route(source_id):
    target_id = request.args.get('target_id', type=int)
    if target_id is None:
        return jsonify({'error': 'target_id is required'}), 400
    conn = db.get_db()
    try:
        count = queries.count_votes_for_upcoming_party(conn, source_id)
    finally:
        conn.close()
    return jsonify({'count': count})


@app.route('/api/admin/upcoming-parties/<int:source_id>/reassign', methods=['POST'])
@require_admin
def reassign_upcoming_party_route(source_id):
    body = request.get_json(force=True, silent=True) or {}
    target_id = body.get('target_id')
    if not isinstance(target_id, int):
        return jsonify({'error': 'target_id is required'}), 400
    if target_id == source_id:
        return jsonify({'error': 'target_id must differ from source party'}), 400
    conn = db.get_db()
    try:
        if not queries.upcoming_party_exists(conn, target_id):
            return jsonify({'error': 'target party not found'}), 404
        reassigned = queries.reassign_upcoming_party_votes(conn, source_id, target_id)
    finally:
        conn.close()
    return jsonify({'reassigned': reassigned})


@app.route('/api/admin/previous-parties', methods=['POST'])
@require_admin
def create_previous_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_previous_party(conn, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url}), 201


@app.route('/api/admin/previous-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_previous_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_previous_party(conn, party_id, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_party_error_response(err)
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url})


@app.route('/api/admin/previous-parties/<int:party_id>', methods=['DELETE'])
@require_admin
def delete_previous_party_route(party_id):
    conn = db.get_db()
    try:
        referencing = queries.count_votes_for_previous_party(conn, party_id)
        if referencing > 0:
            return jsonify({'error': f'{referencing} vote(s) still reference this party'}), 409
        deleted = queries.delete_previous_party(conn, party_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


@app.route('/api/admin/previous-parties/<int:source_id>/reassign-count', methods=['GET'])
@require_admin
def previous_party_reassign_count_route(source_id):
    target_id = request.args.get('target_id', type=int)
    if target_id is None:
        return jsonify({'error': 'target_id is required'}), 400
    conn = db.get_db()
    try:
        count = queries.count_votes_for_previous_party(conn, source_id)
    finally:
        conn.close()
    return jsonify({'count': count})


@app.route('/api/admin/previous-parties/<int:source_id>/reassign', methods=['POST'])
@require_admin
def reassign_previous_party_route(source_id):
    body = request.get_json(force=True, silent=True) or {}
    target_id = body.get('target_id')
    if not isinstance(target_id, int):
        return jsonify({'error': 'target_id is required'}), 400
    if target_id == source_id:
        return jsonify({'error': 'target_id must differ from source party'}), 400
    conn = db.get_db()
    try:
        if not queries.previous_party_exists(conn, target_id):
            return jsonify({'error': 'target party not found'}), 404
        reassigned = queries.reassign_previous_party_votes(conn, source_id, target_id)
    finally:
        conn.close()
    return jsonify({'reassigned': reassigned})


@app.route('/api/admin/leagues', methods=['POST'])
@require_admin
def create_league_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        league_id = queries.create_league(conn, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_named_error_response(err, 'league')
    finally:
        conn.close()
    return jsonify({'id': league_id, 'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url}), 201


@app.route('/api/admin/leagues/<int:league_id>', methods=['PATCH'])
@require_admin
def rename_league_route(league_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_league(conn, league_id, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicatePartyNameError as err:
        return _duplicate_named_error_response(err, 'league')
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': league_id, 'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url})


@app.route('/api/admin/leagues/<int:league_id>', methods=['DELETE'])
@require_admin
def delete_league_route(league_id):
    conn = db.get_db()
    try:
        referencing_clubs = queries.count_clubs_for_league(conn, league_id)
        if referencing_clubs > 0:
            return jsonify({'error': f'{referencing_clubs} club(s) still belong to this league'}), 409
        referencing_votes = queries.count_votes_for_league(conn, league_id)
        if referencing_votes > 0:
            return jsonify({'error': f'{referencing_votes} vote(s) still reference this league'}), 409
        deleted = queries.delete_league(conn, league_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


@app.route('/api/admin/leagues/<int:source_id>/reassign-count', methods=['GET'])
@require_admin
def league_reassign_count_route(source_id):
    target_id = request.args.get('target_id', type=int)
    if target_id is None:
        return jsonify({'error': 'target_id is required'}), 400
    conn = db.get_db()
    try:
        count = queries.count_votes_for_league(conn, source_id)
    finally:
        conn.close()
    return jsonify({'count': count})


@app.route('/api/admin/leagues/<int:source_id>/reassign', methods=['POST'])
@require_admin
def reassign_league_route(source_id):
    body = request.get_json(force=True, silent=True) or {}
    target_id = body.get('target_id')
    if not isinstance(target_id, int):
        return jsonify({'error': 'target_id is required'}), 400
    if target_id == source_id:
        return jsonify({'error': 'target_id must differ from source league'}), 400
    conn = db.get_db()
    try:
        if not queries.league_exists(conn, target_id):
            return jsonify({'error': 'target league not found'}), 404
        if queries.count_clubs_for_league(conn, source_id) > 0:
            return jsonify({'error': 'source league still has clubs; move or delete them first'}), 400
        reassigned = queries.reassign_league_votes(conn, source_id, target_id)
    finally:
        conn.close()
    return jsonify({'reassigned': reassigned})


@app.route('/api/admin/clubs', methods=['POST'])
@require_admin
def create_club_route():
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    league_id = body.get('league_id')
    if not isinstance(league_id, int):
        return jsonify({'error': 'league_id is required'}), 400
    domestic_league_id = body.get('domestic_league_id')
    if domestic_league_id is not None and not isinstance(domestic_league_id, int):
        return jsonify({'error': 'domestic_league_id must be an integer or null'}), 400
    if domestic_league_id is not None and domestic_league_id == league_id:
        return jsonify({'error': 'domestic_league_id must differ from league_id'}), 400
    conn = db.get_db()
    try:
        if not queries.league_exists(conn, league_id):
            return jsonify({'error': 'league not found'}), 404
        if domestic_league_id is not None and not queries.league_exists(conn, domestic_league_id):
            return jsonify({'error': 'domestic league not found'}), 404
        club_id = queries.create_club(conn, league_id, domestic_league_id, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicateClubNameError as err:
        return _duplicate_named_error_response(err, 'club')
    finally:
        conn.close()
    return jsonify({
        'id': club_id, 'league_id': league_id, 'domestic_league_id': domestic_league_id,
        'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url,
    }), 201


@app.route('/api/admin/clubs/<int:club_id>', methods=['PATCH'])
@require_admin
def rename_club_route(club_id):
    body = request.get_json(force=True, silent=True) or {}
    name_en = body.get('name_en', '').strip()
    name_he = body.get('name_he', '').strip()
    name_ru = (body.get('name_ru') or '').strip() or None
    logo_url = (body.get('logo_url') or '').strip() or None
    if not name_en or not name_he:
        return jsonify({'error': 'name_en and name_he are required'}), 400
    league_id = body.get('league_id')
    if not isinstance(league_id, int):
        return jsonify({'error': 'league_id is required'}), 400
    domestic_league_id = body.get('domestic_league_id')
    if domestic_league_id is not None and not isinstance(domestic_league_id, int):
        return jsonify({'error': 'domestic_league_id must be an integer or null'}), 400
    if domestic_league_id is not None and domestic_league_id == league_id:
        return jsonify({'error': 'domestic_league_id must differ from league_id'}), 400
    conn = db.get_db()
    try:
        if not queries.league_exists(conn, league_id):
            return jsonify({'error': 'league not found'}), 404
        if domestic_league_id is not None and not queries.league_exists(conn, domestic_league_id):
            return jsonify({'error': 'domestic league not found'}), 404
        updated = queries.rename_club(conn, club_id, league_id, domestic_league_id, name_en, name_he, name_ru=name_ru, logo_url=logo_url)
    except queries.DuplicateClubNameError as err:
        return _duplicate_named_error_response(err, 'club')
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({
        'id': club_id, 'league_id': league_id, 'domestic_league_id': domestic_league_id,
        'name_en': name_en, 'name_he': name_he, 'name_ru': name_ru, 'logo_url': logo_url,
    })


@app.route('/api/admin/clubs/<int:club_id>', methods=['DELETE'])
@require_admin
def delete_club_route(club_id):
    conn = db.get_db()
    try:
        referencing = queries.count_votes_for_club(conn, club_id)
        if referencing > 0:
            return jsonify({'error': f'{referencing} vote(s) still reference this club'}), 409
        deleted = queries.delete_club(conn, club_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


@app.route('/api/admin/clubs/<int:source_id>/reassign-count', methods=['GET'])
@require_admin
def club_reassign_count_route(source_id):
    target_id = request.args.get('target_id', type=int)
    if target_id is None:
        return jsonify({'error': 'target_id is required'}), 400
    conn = db.get_db()
    try:
        count = queries.count_votes_for_club(conn, source_id)
    finally:
        conn.close()
    return jsonify({'count': count})


@app.route('/api/admin/clubs/<int:source_id>/reassign', methods=['POST'])
@require_admin
def reassign_club_route(source_id):
    body = request.get_json(force=True, silent=True) or {}
    target_id = body.get('target_id')
    if not isinstance(target_id, int):
        return jsonify({'error': 'target_id is required'}), 400
    if target_id == source_id:
        return jsonify({'error': 'target_id must differ from source club'}), 400
    conn = db.get_db()
    try:
        source_leagues = queries.get_club_leagues(conn, source_id)
        if source_leagues is None:
            return jsonify({'error': 'not found'}), 404
        target_leagues = queries.get_club_leagues(conn, target_id)
        if target_leagues is None:
            return jsonify({'error': 'target club not found'}), 404
        source_set = {v for v in (source_leagues['league_id'], source_leagues['domestic_league_id']) if v is not None}
        target_set = {v for v in (target_leagues['league_id'], target_leagues['domestic_league_id']) if v is not None}
        if not source_set.issubset(target_set):
            return jsonify({'error': 'target club does not cover every league the source club is votable under'}), 400
        reassigned = queries.reassign_club_votes(conn, source_id, target_id)
    finally:
        conn.close()
    return jsonify({'reassigned': reassigned})


@app.route('/api/admin/votes', methods=['GET'])
@require_admin
def get_votes_route():
    conn = db.get_db()
    try:
        votes = queries.get_votes(conn)
    finally:
        conn.close()
    return jsonify({'votes': votes})


@app.route('/api/admin/votes/<int:vote_id>', methods=['DELETE'])
@require_admin
def delete_vote_route(vote_id):
    conn = db.get_db()
    try:
        deleted = queries.delete_vote(conn, vote_id)
    finally:
        conn.close()
    if not deleted:
        return jsonify({'error': 'not found'}), 404
    return '', 204


if __name__ == '__main__':
    conn = db.get_db()
    db.init_db(conn)
    conn.close()
    app.run(host='0.0.0.0', port=5000)
