"""Modul autentikasi JWT — INI ADALAH INTI KERENTANAN APLIKASI.

Pendekatan yang benar (Fase 3 / patch):
  jwt.decode(token, SECRET, algorithms=["HS256"])
  -> library menolak token jika algoritma bukan whitelist, termasuk alg=none.

Pendekatan RENTAN (Fase 1, sengaja):
  decoder di bawah membaca nilai `alg` dari HEADER token lalu mempercayainya.
  Akibatnya:
    - alg="none"  -> token DITERIMA tanpa verifikasi tanda tangan.
    - alg="HS256" -> diverifikasi memakai WEAK_SECRET yang lemah & hardcoded.
  (Antipattern nyata di dunia nyata, mis. kelas CVE "JWT algorithm confusion".
   PyJWT 2.x sendiri sudah menolak alg=none, karena itu verifikasi `none`
   ditulis manual di bawah — sesuai cara aplikasi lama yang rentan bekerja.)
"""
import base64
import hashlib
import hmac
import json

import jwt

from app.config import Config


def _b64url_decode(segment: str) -> bytes:
    """Base64URL decode tanpa padding (Burp/script sering kirim tanpa '=')."""
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(payload: dict) -> str:
    """Menandatangani JWT dengan HS256 (jalur normal aplikasi, secret lemah)."""
    return jwt.encode(payload, Config.WEAK_SECRET, algorithm="HS256")


def decode_token(token: str) -> dict:
    """DECODER RENTAN: mempercayai nilai `alg` dari header token.

    Format yang diterima:
      - `header.payload.signature`  (3 segmen)
      - `header.payload.`           (3 segmen, signature kosong -> alg=none)
      - `header.payload`            (2 segmen, toleransi -> alg=none)
    """
    parts = token.split(".")
    if len(parts) not in (2, 3):
        raise ValueError("token bukan JWT (harus 2 atau 3 segmen)")

    try:
        header = json.loads(_b64url_decode(parts[0]))
    except Exception as exc:
        raise ValueError(f"header token tidak valid: {exc}") from exc

    alg = header.get("alg", "HS256")

    if alg == "none":
        # VULN #1: token tanpa tanda tangan diterima apa adanya.
        # Payload tidak divalidasi (iat/exp ikut diabaikan).
        try:
            return json.loads(_b64url_decode(parts[1]))
        except Exception as exc:
            raise ValueError(f"payload token tidak valid: {exc}") from exc

    if alg == "HS256":
        # VULN #2: verifikasi memakai secret yang lemah & hardcoded.
        try:
            return jwt.decode(token, Config.WEAK_SECRET, algorithms=["HS256"])
        except jwt.InvalidTokenError as exc:
            raise ValueError(f"tanda tangan HS256 tidak valid: {exc}") from exc

    raise ValueError(f"algoritma tidak didukung: {alg}")


def forge_none_token(payload: dict) -> str:
    """Membuat token alg=none (dipakai Red Team / script demo)."""
    header = {"alg": "none", "typ": "JWT"}
    h = _b64url_encode(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    return f"{h}.{p}."


def forge_hs256_token(payload: dict, secret: str = Config.WEAK_SECRET) -> str:
    """Membuat token HS256 dengan secret yang diketahui (forge)."""
    header = {"alg": "HS256", "typ": "JWT"}
    h = _b64url_encode(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{h}.{p}".encode()
    signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url_encode(signature)}"
