from flask import Flask, render_template, request, make_response, g
from flask_wtf.csrf import CSRFProtect
from redis import Redis
import os
import socket
import secrets
import json
import logging

# Read options and Redis configuration from environment variables
option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
redis_host = os.getenv('REDIS_HOST', 'redis')  # Default to 'redis' for compatibility
redis_port = int(os.getenv('REDIS_PORT', 6379))  # Default Redis port is 6379
hostname = socket.gethostname()

app = Flask(__name__)
app.config['SECRET_KEY'] = os.getenv('FLASK_SECRET_KEY', secrets.token_hex(32))
csrf = CSRFProtect(app)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

def get_redis():
    if not hasattr(g, 'redis'):
        g.redis = Redis(host=redis_host, port=redis_port, db=0, socket_timeout=5)
    return g.redis

@app.route("/", methods=['POST','GET'])
@app.route("/vote", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = secrets.token_hex(16)

    vote = None

    if request.method == 'POST':
        redis = get_redis()
        vote = request.form['vote']
        app.logger.info('Received vote for %s', vote)
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        redis.rpush('votes', data)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    cookie_is_secure = request.is_secure or request.headers.get('X-Forwarded-Proto', '').lower() == 'https'
    resp.set_cookie('voter_id', voter_id, secure=cookie_is_secure, httponly=True, samesite='Lax')
    return resp


if __name__ == "__main__":
    debug_mode = False
    bind_host = '127.0.0.1'
    bind_port = int(os.getenv('PORT', 80))
    app.run(host=bind_host, port=bind_port, debug=debug_mode, threaded=True)
