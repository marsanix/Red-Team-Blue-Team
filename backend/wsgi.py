"""Entry point WSGI untuk gunicorn:  gunicorn wsgi:app"""
from app import create_app

app = create_app()

if __name__ == "__main__":
    # Jalur dev saja (tanpa Docker). Produksi memakai gunicorn (entrypoint.sh).
    app.run(host="0.0.0.0", port=5000)
