# RECON — Mendapatkan Daftar Endpoint (Fase 2, Red Team)

Tujuan fase ini: **memetakan permukaan serangan** (list endpoint, metode HTTP,
mekanisme autentikasi) sebelum melakukan eksploitasi. Semua langkah memakai
perintah manual (`curl`) atau fitur manual Burp Suite — **bukan** automated
vulnerability scanner (dilarang di soal).

> Ganti `<host>` dengan IP tailnet server, mis. `http://100.101.102.103`.

---

## Langkah 1 — Fingerprinting / banner grab

Kenali teknologi yang dipakai dari header respons.

```bash
curl -I http://<host>/api/health
```

Contoh keluaran:

```
HTTP/1.1 200 OK
Server: nginx                          # web server = nginx (versi disembunyikan: server_tokens off)
Content-Type: application/json
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
```

Yang bisa disimpulkan: ada nginx sebagai reverse proxy, aplikasi JSON API.

## Langkah 2 — Enumerasi path umum (manual)

Coba jalur yang umum ada di aplikasi Flask:

```bash
for p in api api/health api/register api/login api/profile api/customers api/jobs docs swagger openapi.json; do
  echo "== /$p =="
  curl -s -o /dev/null -w "%{http_code}\n" "http://<host>/$p"
done
```

Perhatikan **kode status yang berbeda** (200/301/404/405) — itu petunjuk
endpoint yang ada. Misalnya `404` berarti path tidak ada; `405 Method Not
Allowed` berarti path ADA tapi metode salah.

## Langkah 3 — GET `/api` (index endpoint)

Aplikasi ini sengaja menyediakan index endpoint — cara tercepat mendapatkan
seluruh list:

```bash
curl -s http://<host>/api | python -m json.tool
```

Keluaran memperlihatkan seluruh endpoint:

```
{
  "endpoints": {
    "POST /api/register":  "Daftar akun baru (role default: user)",
    "POST /api/login":     "Login, mengembalikan access_token (JWT)",
    "GET /api/profile":    "Profil pengguna yang sedang login (perlu JWT)",
    "GET /api/customers":  "Data customers - KHUSUS ADMIN",
    "GET /api/health":     "Health check",
    "POST /api/jobs":      "Submit job asinkron",
    "GET /api/jobs/<id>":  "Cek status job asinkron",
    "WS /ws/notifications": "WebSocket notifikasi asinkron"
  },
  ...
}
```

> **Catatan untuk laporan**: membuka daftar endpoint seperti ini adalah
> *misconfiguration* (informasi bocor tanpa autentikasi) dan mempercepat
> reconnaissance lawan.

## Langkah 4 — Enumerasi error / behavior endpoint

Cara lain memetakan endpoint adalah dengan **mengamati perilaku error**:

```bash
# path random -> respon 404 JSON, memperlihatkan format respons aplikasi
curl -s http://<host>/api/randomxyz

# metode salah -> 405, mengonfirmasi endpoint & metode yang valid
curl -s -X DELETE http://<host>/api/login

# endpoint butuh auth? -> 401, konfirmasi skema auth
curl -s http://<host>/api/profile
```

Contoh:

```json
{"error":"Token tidak ditemukan (Authorization: Bearer <token>)","status":401}
```

Ini mengonfirmasi: **autentikasi memakai JWT di header `Authorization: Bearer`**.

## Langkah 5 — Memakai Burp Suite (sitemap & target)

1. Buka Burp Suite → tab **Proxy → Intercept**.
2. Set browser proxy ke `127.0.0.1:8080` (Burp).
3. Akses `http://<host>/api` dan beberapa endpoint di browser.
4. Buka tab **Target → Site map**: semua request muncul otomatis → daftar
   endpoint lengkap dengan metode HTTP.
5. **Repeater**: klik kanan request → *Send to Repeater* untuk manipulasi
   header/badan (dipakai di RED_TEAM.md).

## Langkah 6 — Menemukan WebSocket

WebSocket muncul sebagai jalur `/ws/notifications` di index endpoint.
Verifikasi handshake-nya:

```bash
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     http://<host>/ws/notifications
```

Respons `101 Switching Protocols` menandakan WebSocket aktif — kandidat untuk
*payload injection* di soket yang terbuka.

---

## Ringkasan Hasil Recon

| # | Endpoint | Metode | Auth | Keterangan |
|---|----------|--------|------|------------|
| 1 | `/api` | GET | Tidak | Daftar endpoint (bocor) |
| 2 | `/api/health` | GET | Tidak | Status |
| 3 | `/api/register` | POST | Tidak | Membuat akun (role=user) |
| 4 | `/api/login` | POST | Tidak | Login → JWT |
| 5 | `/api/profile` | GET | JWT | Profil pemilik token |
| 6 | `/api/customers` | GET | JWT (admin) | Target utama (bypass) |
| 7 | `/api/jobs` | POST | Tidak | Job asinkron |
| 8 | `/api/jobs/<id>` | GET | Tidak | Status job |
| 9 | `/ws/notifications` | WS | Tidak | WebSocket |

**Vektor yang akan dieksploitasi (RED_TEAM.md):** endpoint `#4` (mendapatkan
JWT) dan `#6` (bypass role admin), dengan teknik memanipulasi token JWT.
