"""App factory Flask untuk backend UAS Kelompok 5.

Fase 1 - Network Programming & Administration.
Microservice backend memakai:
- Flask + Flask-SQLAlchemy (REST API sinkron)
- flask-sock (WebSocket asinkron)
- ThreadPoolExecutor (job asinkron)
"""
from flask import Flask, jsonify
from flask_sock import Sock
from werkzeug.exceptions import HTTPException

from app.config import Config
from app.models import db

sock = Sock()


def create_app() -> Flask:
    app = Flask(__name__)
    app.config.from_object(Config)

    db.init_app(app)

    # Import di dalam fungsi agar tidak terjadi circular import.
    # urutan import penting: jobs membutuhkan broadcast dari ws.
    from app import jobs, routes, ws  # noqa: F401  (mendaftarkan blueprint & route WS)
    app.register_blueprint(routes.bp)
    app.register_blueprint(jobs.bp)

    # Panggil setelah seluruh @sock.route terdaftar.
    sock.init_app(app)

    register_error_handlers(app)
    return app


def register_error_handlers(app: Flask) -> None:
    """Seluruh error HTTP dikembalikan dalam format JSON (untuk API)."""

    @app.errorhandler(HTTPException)
    def handle_http_exception(exc: HTTPException):
        return jsonify({"error": exc.description, "status": exc.code}), exc.code

    @app.errorhandler(Exception)
    def handle_unexpected(_exc: Exception):
        app.logger.exception("Unhandled error")
        return jsonify({"error": "Internal server error", "status": 500}), 500
