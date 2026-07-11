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
        conn.close()
        return jsonify({'error': 'You have already voted'}), 409
    conn.close()

    resp = make_response(jsonify({'vote_id': vote_id}), 201)
    if is_new_token:
        resp.set_cookie('voteball_token', token, max_age=31536000, httponly=True, samesite='Lax')
    return resp


if __name__ == '__main__':
    conn = db.get_db()
    db.init_db(conn)
    conn.close()
    app.run(host='0.0.0.0', port=5000)
