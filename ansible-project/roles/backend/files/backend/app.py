from flask import Flask, jsonify
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


if __name__ == '__main__':
    conn = db.get_db()
    db.init_db(conn)
    conn.close()
    app.run(host='0.0.0.0', port=5000)
