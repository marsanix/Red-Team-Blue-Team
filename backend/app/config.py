"""Konfigurasi aplikasi.

Catatan keamanan (untuk laporan teknis):
- WEAK_SECRET dipakai untuk menandatangani JWT dan memang *sengaja* dibuat
  lemah serta di-hardcode agar dapat diserang tim Red Team (bypass JWT /
  brute-force secret). Ini adalah kerentanan yang akan ditutup pada Fase 3.
- SECRET_KEY dipakai Flask untuk session; sengaja dipisah dari WEAK_SECRET
  agar penjelasan "secret lemah vs secret kuat" tetap jelas.
"""
import os


class Config:
    # --- Secret JWT (VULN: lemah & hardcoded -> bisa di-forge / brute-force) ---
    WEAK_SECRET = os.environ.get("JWT_WEAK_SECRET", "rahasia-super-lemah")

    # --- Secret session Flask (bukan bagian dari kerentanan) ---
    SECRET_KEY = os.environ.get("FLASK_SECRET_KEY", "session-secret-kelompok5")

    # --- Koneksi ke container MySQL (network internal, tidak di-publish) ---
    DB_HOST = os.environ.get("DB_HOST", "mysql")
    DB_PORT = os.environ.get("DB_PORT", "3306")
    DB_NAME = os.environ.get("DB_NAME", "uas_db")
    DB_USER = os.environ.get("DB_USER", "uas_user")
    DB_PASSWORD = os.environ.get("DB_PASSWORD", "uas_pass")

    SQLALCHEMY_DATABASE_URI = (
        f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
