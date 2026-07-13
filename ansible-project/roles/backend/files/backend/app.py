import uuid
import os
from functools import wraps
from flask import Flask, jsonify, request, make_response
import db
import queries

app = Flask(__name__)

ADMIN_SECRET = os.environ['ADMIN_SECRET']


def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if request.headers.get('X-Admin-Secret') != ADMIN_SECRET:
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return wrapper


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


@app.route('/api/options', methods=['GET'])
def options():
    conn = db.get_db()
    result = queries.get_options(conn)
    conn.close()
    return jsonify(result)


@app.route('/api/vote', methods=['POST'])
def vote():
    token = request.cookies.get('voteball_token')
    is_new_token = token is None
    if is_new_token:
        token = uuid.uuid4().hex

    body = request.get_json(force=True, silent=True) or {}

    if body.get('upcoming_vote_status') == 'considering' and not body.get('upcoming_party_ids'):
        return jsonify({'error': 'select at least one upcoming party when status is considering'}), 400
    if len(body.get('upcoming_party_ids') or []) > 3:
        return jsonify({'error': 'select at most 3 upcoming parties'}), 400

    conn = db.get_db()
    try:
        vote_id = queries.insert_vote(
            conn,
            league_id=body.get('league_id'),
            club_id=body.get('club_id'),
            previous_vote_status=body.get('previous_vote_status'),
            previous_party_id=body.get('previous_party_id'),
            upcoming_vote_status=body.get('upcoming_vote_status'),
            upcoming_party_ids=body.get('upcoming_party_ids', []),
            cookie_token=token,
        )
    except ValueError:
        return jsonify({'error': 'You have already voted'}), 409
    except Exception:
        return jsonify({'error': 'invalid vote data'}), 400
    finally:
        conn.close()

    resp = make_response(jsonify({'vote_id': vote_id}), 201)
    if is_new_token:
        resp.set_cookie('voteball_token', token, max_age=31536000, httponly=True, samesite='Lax')
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
        else:
            return jsonify({'error': "by must be 'club', 'league', or 'party'"}), 400
    finally:
        conn.close()

    return jsonify(result)


@app.route('/api/admin/upcoming-parties', methods=['POST'])
@require_admin
def create_upcoming_party_route():
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_upcoming_party(conn, name)
    except queries.DuplicatePartyNameError:
        return jsonify({'error': 'a party with this name already exists'}), 409
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name': name}), 201


@app.route('/api/admin/upcoming-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_upcoming_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_upcoming_party(conn, party_id, name)
    except queries.DuplicatePartyNameError:
        return jsonify({'error': 'a party with this name already exists'}), 409
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name': name})


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
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        party_id = queries.create_previous_party(conn, name)
    except queries.DuplicatePartyNameError:
        return jsonify({'error': 'a party with this name already exists'}), 409
    finally:
        conn.close()
    return jsonify({'id': party_id, 'name': name}), 201


@app.route('/api/admin/previous-parties/<int:party_id>', methods=['PATCH'])
@require_admin
def rename_previous_party_route(party_id):
    body = request.get_json(force=True, silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    conn = db.get_db()
    try:
        updated = queries.rename_previous_party(conn, party_id, name)
    except queries.DuplicatePartyNameError:
        return jsonify({'error': 'a party with this name already exists'}), 409
    finally:
        conn.close()
    if not updated:
        return jsonify({'error': 'not found'}), 404
    return jsonify({'id': party_id, 'name': name})


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
