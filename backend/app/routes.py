"""REST API SINKRON (Fase 1): autentikasi & transfer data sinkron via HTTP.

Endpoint yang (sengaja) terbuka untuk mendukung reconnaissance Red Team:
  GET /api          -> index/daftar endpoint (misconfiguration)
  GET /api/health   -> health check
"""
import datetime as _dt

from flask import Blueprint, abort, jsonify, request

from app.auth import decode_token, make_token
from app.models import Customer, User, db

bp = Blueprint("api", __name__, url_prefix="/api")


def _require_token() -> dict:
    """Ambil & verifikasi JWT dari header Authorization. Abort 401 bila invalid."""
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        abort(401, "Token tidak ditemukan (Authorization: Bearer <token>)")
    token = auth[len("Bearer "):].strip()
    try:
        return decode_token(token)
    except Exception as exc:  # noqa: BLE001 - semua error auth -> 401
        abort(401, f"Token tidak valid: {exc}")


@bp.get("")
def api_index():
    """Daftar endpoint (sengaja dibuka - untuk bahan reconnaissance)."""
    return jsonify({
        "service": "API UAS Kelompok 5 - Network Programming & Administration",
        "version": "1.0",
        "authentication": "JWT (Bearer) - lihat POST /api/login",
        "endpoints": {
            "POST /api/register": "Daftar akun baru (role default: user)",
            "POST /api/login": "Login, mengembalikan access_token (JWT)",
            "GET /api/profile": "Profil pengguna yang sedang login (perlu JWT)",
            "GET /api/customers": "Data customers - KHUSUS ADMIN",
            "GET /api/health": "Health check",
            "POST /api/jobs": "Submit job asinkron",
            "GET /api/jobs/<job_id>": "Cek status job asinkron",
            "WS /ws/notifications": "WebSocket notifikasi asinkron",
        },
    })


@bp.get("/health")
def health():
    return jsonify({"status": "ok", "service": "flask-backend", "version": "1.0"})


@bp.post("/register")
def register():
    """Registrasi akun baru. Role default = user."""
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    fullname = (data.get("fullname") or "").strip()

    if not username or not password or not fullname:
        abort(400, "Field wajib: username, password, fullname")

    # Parameterized query via SQLAlchemy -> aman dari SQL injection.
    if User.query.filter_by(username=username).first():
        abort(409, "Username sudah terdaftar")

    user = User(username=username, fullname=fullname, role="user")
    user.set_password(password)
    db.session.add(user)
    db.session.commit()

    return jsonify({"message": "Registrasi berhasil", "user": user.to_dict()}), 201


@bp.post("/login")
def login():
    """Login; jika valid mengembalikan JWT bertanda tangan HS256."""
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""

    user = User.query.filter_by(username=username).first()
    if not user or not user.check_password(password):
        abort(401, "Username atau password salah")

    now = _dt.datetime.now(_dt.timezone.utc)
    payload = {
        "sub": user.id,
        "username": user.username,
        "role": user.role,
        "iat": int(now.timestamp()),
        "exp": int((now + _dt.timedelta(hours=2)).timestamp()),
    }
    token = make_token(payload)

    return jsonify({
        "access_token": token,
        "token_type": "Bearer",
        "expires_in": 7200,
        "user": user.to_dict(),
    })


@bp.get("/profile")
def profile():
    """Profil pengguna yang sedang login (butuh JWT valid)."""
    claims = _require_token()
    user = db.session.get(User, claims.get("sub"))
    if not user:
        abort(401, "User tidak ditemukan")
    return jsonify({"profile": user.to_dict()})


@bp.get("/customers")
def customers():
    """Data customers - KHUSUS ADMIN.

    VULN (inti skenario): role dipercaya langsung dari klaim JWT tanpa dicek
    ulang ke database. Attacker yang berhasil mem-bypass JWT (alg=none atau
    forge HS256) dan mengisi role=admin dapat mengakses data ini padahal di
    database tetap user biasa.
    """
    claims = _require_token()
    if claims.get("role") != "admin":
        abort(403, "Akses khusus admin")

    customers = Customer.query.all()
    return jsonify({"customers": [c.to_dict() for c in customers]})
