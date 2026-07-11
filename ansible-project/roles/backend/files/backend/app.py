from flask import Flask, jsonify
import db

app = Flask(__name__)


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


if __name__ == '__main__':
    conn = db.get_db()
    db.init_db(conn)
    conn.close()
    app.run(host='0.0.0.0', port=5000)
