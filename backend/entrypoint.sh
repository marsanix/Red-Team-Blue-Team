#!/bin/sh
# Entry point backend: tunggu MySQL -> buat tabel + seed admin -> jalankan gunicorn.
set -e

echo "[entrypoint] Menunggu MySQL siap..."
python - <<'PY'
import os
import time

import pymysql

host = os.environ.get("DB_HOST", "mysql")
port = int(os.environ.get("DB_PORT", "3306"))
user = os.environ.get("DB_USER", "uas_user")
password = os.environ.get("DB_PASSWORD", "uas_pass")
database = os.environ.get("DB_NAME", "uas_db")

for attempt in range(30):
    try:
        conn = pymysql.connect(
            host=host, port=port, user=user, password=password,
            database=database, connect_timeout=3,
        )
        conn.close()
        print("[entrypoint] MySQL siap.")
        break
    except Exception as exc:  # noqa: BLE001
        print(f"[entrypoint] Percobaan {attempt + 1}/30 gagal: {exc}")
        time.sleep(2)
else:
    print("[entrypoint] GAGAL: MySQL tidak merespons setelah 30 percobaan.")
    raise SystemExit(1)
PY

echo "[entrypoint] Membuat tabel & seed akun admin..."
python - <<'PY'
from app import create_app
from app.models import User, db

app = create_app()
with app.app_context():
    db.create_all()
    if not User.query.filter_by(username="admin").first():
        admin = User(username="admin", fullname="Administrator UAS", role="admin")
        admin.set_password("admin123")
        db.session.add(admin)
        db.session.commit()
        print("[entrypoint] Akun admin dibuat -> admin / admin123")
    else:
        print("[entrypoint] Akun admin sudah ada.")
PY

echo "[entrypoint] Menjalankan gunicorn (gthread, 1 worker, timeout 0)..."
exec gunicorn -w 1 --worker-class gthread --threads 16 --timeout 0 \
    --bind 0.0.0.0:5000 wsgi:app
