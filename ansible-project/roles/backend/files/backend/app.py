import uuid
from flask import Flask, jsonify, request, make_response
import db
import queries

app = Flask(__name__)


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


if __name__ == '__main__':
    conn = db.get_db()
    db.init_db(conn)
    conn.close()
    app.run(host='0.0.0.0', port=5000)
