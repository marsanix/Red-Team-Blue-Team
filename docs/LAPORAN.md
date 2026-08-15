# LAPORAN TEKNIS — Layanan API Web dengan Bypass JWT (Simulasi Red Team & Blue Team)

**Mata Kuliah** : Network Programming & Administration  
**Kelas** : IFN41 | **Prodi** : Informatika PJJ S1  
**Dosen** : Abdul Azzam Ajhari, S.Kom., M.Kom.  
**Kelompok** : 5  
**Anggota** :

| No | Nama | NIM |
|----|------|-----|
| 1 | Marsani | 230401010282 |
| 2 | Muhammad Saifulloh | 220401010207 |
| 3 | Kristian Hananiel Hura | 220401010289 |
| 4 | Sukandar | 240401020175 |

> **Nama file PDF sesuai petunjuk:** `KODEMK_NAMA_NIM.pdf` (diisi per anggota).
> Laporan ini disusun sebagai materi utama; setiap anggota wajib memahami dan
> memparafrasekan bagian yang disajikan pada presentasi/video.

---

## Abstrak

Project ini membangun layanan API web (Python Flask) yang di-deploy sebagai
microservices di atas Docker dengan topologi **DMZ** dan IP statis. Layanan
menyediakan autentikasi JWT serta transfer data **sinkron** (REST) dan
**asinkron** (WebSocket & job queue). Sesuai skenario ujian, aplikasi sengaja
membawa kerentanan pada pemrosesan JWT (percaya terhadap nilai `alg` pada
header token) sehingga dapat diserang dengan teknik **bypass JWT**. Tim Red
Team menyerang memakai Burp Suite (Repeater/Intruder) tanpa automated
scanner, sementara Tim Blue Team menangkap dan menganalisis lalu lintas
dengan tshark/Wireshark (BPF), memblokir penyerang, dan menulis ulang kode
sebagai remediasi. Laporan ini memaparkan arsitektur, metodologi serangan,
analisis forensik dari level paket, serta langkah hardening.

---

## 1. Pendahuluan

### 1.1 Latar Belakang

Dalam keamanan jaringan, *offensive security* (Red Team) dan *defensive
security* (Blue Team) adalah dua sisi yang saling melengkapi. Memahami cara
menyerang membantu memahami cara bertahan. Ujian ini mensimulasikan dua
kelompok: satu membangun layanan (Fase 1), satu menyerang (Fase 2), dan
satunya lagi menganalisis serta meremediasi (Fase 3). Skenario aplikasi
diarahkan pada kerentanan **JSON Web Token (JWT)**: pengguna biasa yang
seharusnya tidak dapat mengakses data `customers` (khusus admin) ternyata
dapat membukanya setelah memanipulasi token.

### 1.2 Tujuan

1. Membangun server API/WebSocket dari awal (Flask) dengan autentikasi dan
   transfer data sinkron & asinkron.
2. Meng-deploy layanan di Docker dengan topologi DMZ, IP statis, dan
   firewall lokal (UFW/iptables) yang membatasi port dan rate koneksi.
3. Melakukan serangan manual (Burp Suite Repeater/Intruder) untuk
   melewati autentikasi JWT tanpa memutus koneksi server.
4. Menganalisis lalu lintas (tshark/Wireshark + BPF), menemukan jejak
   eksploitasi dari level paket, memblokir penyerang, dan menutup celah.

---

## 2. Tinjauan Pustaka Ringkas

- **JWT (RFC 7519)**: token berformat `header.payload.signature`, base64url.
  Header memuat algoritma (`alg`). Kelemahan klasik: aplikasi mempercayai
  `alg` dari header → serangan **algorithm confusion** (`alg=none`,
  RSA→HMAC), brute-force secret lemah, dan *claim tampering* (ubah `role`).
- **DMZ (Demilitarized Zone)**: zona jaringan antara internet/eksternal dan
  jaringan internal; hanya service publik (mis. web server) yang diletakkan
  di DMZ, database di internal.
- **Docker microservices**: aplikasi dipecah menjadi container kecil
  (nginx, Flask, MySQL) yang saling terhubung lewat network virtual; IP
  statis membantu topologi yang dapat dipetakan.
- **Firewall (UFW/iptables)**: UFW adalah frontend iptables. Rate limiting
  koneksi/detik memakai modul `hashlimit`/`recent`. Untuk traffic container,
  aturan ditempatkan di chain `DOCKER-USER`.
- **BPF & Wireshark/tshark**: Berkeley Packet Filter dipakai sebagai
  capture filter (`-f`) untuk menangkap hanya paket yang relevan; display
  filter untuk menganalisis PCAP.

---

## 3. Arsitektur Sistem & Topologi Jaringan

### 3.1 Diagram topologi

```
                        TAILNET (100.64.0.0/10)  <- WireGuard / CGNAT
   ┌──────────────┐   ┌──────────────┐   ┌──────────────────────────────┐
   │  RED TEAM    │   │ BLUE TEAM    │   │        SERVER (Docker)        │
   │  Burp Suite  │   │ tshark/WShark│   │                              │
   └──────┬───────┘   └──────┬───────┘   │  ┌────────────────────────┐  │
          │                  │           │  │ NETWORK dmz 10.10.0.0/24│  │
          └──────────────────┴──► host   │  │  nginx ─10.10.0.10       │  │
                                   port 80  │   └──────┬─────────────┘  │
                                    (Tailscale)│          │ proxy_pass   │
                                   ┌──────────┼──────────┼────────────┐  │
                                   │ NETWORK internal 10.10.1.0/24    │  │
                                   │  flask ─10.10.1.11   mysql 10.10.1.12 │
                                   └──────────────┬───────────────────┘  │
                                                  │ (flask juga di dmz)  │
                                             10.10.0.11 (dmz)
```

- **Network dmz (10.10.0.0/24)** : nginx `10.10.0.10`, backend `10.10.0.11`.
- **Network internal (10.10.1.0/24)** : backend `10.10.1.11`, MySQL `10.10.1.12`.
- Hanya nginx yang di-publish ke host (port 80). Backend & MySQL **tidak**
  di-publish → server MySQL tidak terjangkau dari network dmz maupun host
  → segmentasi DMZ yang nyata.
- Host (Ubuntu) terhubung Tailscale; Red/Blue Team mengakses `host:80 →
  nginx → flask`.

### 3.2 Alur request

```
Attacker ──Tailscale──> nginx:80 ──proxy_pass──> flask:5000 ──SQL──> mysql:3306
                        (DMZ)         (dmz+internal)          (internal)
```

### 3.3 Kelebihan arsitektur (materi penilaian "Arsitektur Jaringan")

- **Efisiensi koneksi**: nginx menangani koneksi dari luar, backend hanya
  melayani proxy internal → pemisahan beban dan *TLS termination point* di
  satu tempat.
- **Routing**: `proxy_pass` dengan nama service (`flask:5000`) memakai
  Docker DNS; WebSocket di-route khusus dengan header upgrade.
- **Segmentasi**: tiga lapis (eksternal → DMZ → internal) membatasi
  *lateral movement* bila satu container dibobol.

---

## 4. Implementasi — Fase 1 (Network Programming & Administration)

### 4.1 Pemrograman: server API/WebSocket

Backend ditulis **dari awal** memakai Python Flask. Struktur:

```
backend/app/
├── __init__.py    # app factory + error handler JSON
├── config.py      # WEAK_SECRET (JWT, sengaja lemah) vs SECRET_KEY (session)
├── models.py      # User, Customer (SQLAlchemy)
├── auth.py        # decoder JWT (INTI KERENTANAN)
├── routes.py      # REST sinkron: register/login/profile/customers/health/api
├── ws.py          # WebSocket asinkron (/ws/notifications)
└── jobs.py        # job queue asinkron (ThreadPoolExecutor)
```

**Transfer data sinkron** — REST request/response:

| Method | Path | Auth | Fungsi |
|--------|------|------|--------|
| POST | `/api/register` | - | Mendaftar (role default `user`) |
| POST | `/api/login` | - | Login → JWT (HS256) |
| GET | `/api/profile` | JWT | Profil pengguna |
| GET | `/api/customers` | JWT + `role=admin` | **Target bypass** |
| GET | `/api` | - | Index endpoint (misconfiguration) |
| GET | `/api/health` | - | Health check |

**Transfer data asinkron**:
- WebSocket `/ws/notifications` (flask-sock) — pesan welcome, echo, dan
  broadcast notifikasi saat job selesai.
- Job queue `POST /api/jobs` → `202` + `job_id`; `GET /api/jobs/<id>` untuk
  polling hasil. Proses berjalan di `ThreadPoolExecutor`.

**Kerentanan inti (`auth.py`)** — decoder mempercayai `alg` dari header:

```python
alg = header.get("alg")
if alg == "none":
    return json.loads(_b64url_decode(parts[1]))   # token tanpa signature diterima
if alg == "HS256":
    return jwt.decode(token, Config.WEAK_SECRET, algorithms=["HS256"])
```

Dan endpoint `/api/customers` **tidak mengecek ulang role ke database** —
hanya membaca klaim `role` dari token:

```python
if claims.get("role") != "admin":
    abort(403, "Akses khusus admin")
```

### 4.2 Administrasi: deploy Docker + firewall

**Docker Compose** (`docker-compose.yml`) — 3 service, 2 network bridge,
IP statis, healthcheck, `restart: unless-stopped`. MySQL hanya di network
internal. Backend memakai `python:3.12-slim`; nginx `nginx:1.27-alpine`;
database `mysql:8.4`.

**Firewall host** (`infrastructure/firewall/firewall.sh`):
- **UFW**: default deny incoming; buka SSH dan port 80/443 hanya dari
  subnet Tailscale `100.64.0.0/10`.
- **iptables DOCKER-USER** (karena traffic container lewat FORWARD, bukan
  INPUT): ESTABLISHED diizinkan → subnet Tailscale diizinkan → lainnya
  ditolak → rate limit koneksi NEW **10/detik** (burst 20) per source IP
  via modul `hashlimit`.
- **nginx `limit_req`**: 10 request/detik per IP (burst 20, `nodelay`) —
  lapis rate-limit di level aplikasi/proxy.

---

## 5. Metodologi Red Team — Fase 2

Alat: **Burp Suite** (Repeater & Intruder). Tidak ada automated scanner;
semua manipulasi manual, dan server **tidak diputus** koneksinya.

### 5.1 Reconnaissance

1. `GET /api` → daftar seluruh endpoint (misconfiguration).
2. Enumerasi path umum → status 200/301/405/404 memetakan endpoint.
3. Trigger error (auth kosong) → respons mengonfirmasi skema
   `Authorization: Bearer <JWT>`.
4. Burp **Site map** mengumpulkan semua request.

Langkah lengkap: `docs/RECON.md`.

### 5.2 Eksploitasi

1. **Dapatkan token sah**: `POST /api/login` → JWT `role=user`.
2. **Bypass `alg=none`**: header token diubah menjadi `{"alg":"none"}`
   dan payload menjadi `{"role":"admin",...}`, tanpa signature. Server
   menerimanya → `GET /api/customers` mengembalikan **200 OK**.
   Token: `eyJhbGciOiJub25l...` (diakhiri titik).
3. **Forge HS256**: secret lemah (`rahasia-super-lemah`) di-hardcode di
   source. Attacker menandatangani token palsu `role=admin` dengan HMAC
   yang sama → **200 OK**.
4. **Brute-force secret (offline)**: hashcat mode 16500 / john memecah
   secret dari token sah.
5. **Payload injection WebSocket**: `/ws/notifications` terbuka; attacker
   mengirim pesan palsu yang di-echo/broadcast.

### 5.3 Hasil & bukti

| Vektor | Sebelum (user) | Setelah (bypass) |
|--------|----------------|------------------|
| `alg=none` | 403 | **200** |
| forge HS256 | 403 | **200** |

Server tetap hidup; tidak ada flooding. Semua request terekam PCAP oleh
Blue Team. Walkthrough penuh: `docs/RED_TEAM.md`.

---

## 6. Analisis Blue Team — Fase 3

### 6.1 Capture

```bash
sudo tshark -i any -f "tcp port 80" -w red_team.pcap
```

### 6.2 BPF & isolasi paket mencurigakan

| Kebutuhan | Filter |
|-----------|--------|
| Hanya IP attacker | `-f "tcp port 80 and host 100.101.102.103"` |
| Hanya POST | `-Y "http.request.method == POST"` |
| Cari JWT (prefix `eyJ`) | `-Y "frame contains \"eyJ\""` |
| Akses ke target | `-Y "http.request.uri contains \"customers\""` |
| Timeline | `-T fields -e frame.time -e ip.src -e http.request.method -e http.request.uri` |

### 6.3 Temuan anomali (dari level paket)

1. Satu IP attacker mengirim banyak `POST /api/register` & `/api/login`
   → persiapan akun (anomali kuantitas).
2. `GET /api/customers` diikuti respons **403** lalu **200** dari IP sama
   → perubahan hak akses tanpa perubahan akun.
3. **Follow TCP stream** pada request yang sukses → token
   `Authorization: Bearer eyJ...` di-decode: header `{"alg":"none"}`,
   payload `{"role":"admin",...}`, **tanpa signature** → bukti bypass JWT.
4. Paket WebSocket dengan pesan palsu → injeksi di soket terbuka.

### 6.4 Pemetaan vektor serangan

```
Recon (GET /api, path enum) ──> register/login (JWT sah, role=user)
   └─> customers 403 ──> manipulasi token (alg=none / forge HS256, role=admin)
        └─> customers 200 (data bocor)  +  WS injection
```

### 6.5 Remediasi (menutup celah)

1. **Patch `auth.py`** — verifikasi dengan whitelist algoritma + signature
   wajib (lihat `docs/BLUE_TEAM.md` §5.1).
2. **Patch `routes.py`** — role dicek ke **database**, bukan klaim token.
3. **Blokir IP attacker** di firewall:
   ```bash
   sudo iptables -I DOCKER-USER 1 -s 100.101.102.103 -j DROP
   ```
4. **Hardening** — lihat `docs/HARDENING.md`: base image, non-root user,
   secret dari environment, WebSocket ber-autentikasi, rate limit.

### 6.6 Verifikasi perbaikan

- Token `alg=none` & forge HS256 → kini **401/403**.
- User biasa tetap 403 di `/api/customers`; admin (`admin/admin123`) → 200.
- IP yang diblokir → timeout (bukan respons HTTP).

---

## 7. Jawaban Pertanyaan Base Image

*(Soal meminta saran image container Linux paling kecil yang tetap memenuhi
semua kebutuhan.)*

**Kesimpulan: bukan selalu yang terkecil — yang terkecil yang tetap
deterministik.** Rincian:

- **nginx** → `nginx:1.27-alpine` (kecil & resmi).
- **Backend** → `python:3.12-slim`, bukan alpine: wheel binary
  `cryptography` (dibutuhkan PyMySQL) dan gunicorn lebih andal di glibc
  (Debian/slim); alpine (musl) berisiko gagal/membutuhkan kompiler.
- **Database** → `mysql:8.4` (sesuai syarat "MySQL"; tidak ada varian alpine
  resmi). `mariadb:11` lebih ringan tetapi bukan MySQL.

Trade-off: hemat ±75 MB di backend dengan alpine tidak sebanding dengan
risiko build tidak deterministik pada project yang harus direproduksi.

---

## 8. Kesimpulan & Saran

**Kesimpulan.**
1. Layanan API/WebSocket (Flask) berhasil dibangun dengan autentikasi JWT
   serta transfer data sinkron dan asinkron di atas Docker microservices
   bertopologi DMZ + IP statis.
2. Firewall (UFW + iptables DOCKER-USER + nginx `limit_req`) membatasi
   port dan rate koneksi per detik.
3. Bypass JWT (alg=none & forge HS256) berhasil dieksekusi secara manual
   tanpa memutus server, membuktikan bahaya *algorithm confusion* dan
   *claim tampering*.
4. Analisis PCAP dengan BPF berhasil mengisolasi token anomali dan memetakan
   vektor serangan dari level paket, lalu ditutup lewat patch kode & firewall.

**Saran.**
- Gunakan secret acak dari environment, whitelist algoritma JWT, dan selalu
  validasi role ke database.
- Terapkan rate limit di lebih dari satu lapis (transport + aplikasi).
- Terus pantau log & aktifkan TLS (HTTPS) untuk produksi.

---

## Lampiran

- `docs/RECON.md` — langkah recon (list endpoint).
- `docs/RED_TEAM.md` — walkthrough serangan Burp Suite.
- `docs/BLUE_TEAM.md` — analisis tshark/BPF & patch.
- `docs/HARDENING.md` — base image & checklist hardening.
- `scripts/bypass_jwt.py` — PoC bypass (reproduksibel).
- `scripts/smoke_test.sh` — tes end-to-end.
- `infrastructure/firewall/firewall.sh` — aturan firewall.
- `infrastructure/tailscale/setup.md` — setup Tailscale.
