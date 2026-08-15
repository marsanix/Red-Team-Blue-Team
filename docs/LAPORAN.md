## LAPORAN TEKNIS - Layanan API Web dengan Bypass JWT (Simulasi Red Team & Blue Team)

**Mata Kuliah** : Network Programming & Administration
**Kelas** : IFN41 | **Prodi** : Informatika PJJ S1
**Dosen** : Abdul Azzam Ajhari, S.Kom., M.Kom.
**Kelompok** : 5
**Anggota** :

| No | Nama                   | NIM          |
| -- | ---------------------- | ------------ |
| 1  | Marsani                | 230401010282 |
| 2  | Muhammad Saifulloh     | 220401010207 |
| 3  | Kristian Hananiel Hura | 220401010289 |
| 4  | Sukandar               | 240401020175 |

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

- **JWT (RFC 7519; Jones, Bradley, & Sakimura, 2015)**: token berformat
  `header.payload.signature`, base64url. Header memuat algoritma (`alg`).
  Kelemahan klasik: aplikasi mempercayai `alg` dari header → serangan
  **algorithm confusion** (`alg=none`, RSA→HMAC), brute-force secret lemah,
  dan *claim tampering* (ubah `role`). Panduan pengamanan tertuang di RFC
  8725 (Sheffer, Hardt, & Jones, 2020); kasus nyata diteliti oleh McLean
  (2015) dan Opirskyy & Kunakh (2026).
- **DMZ (Demilitarized Zone)**: zona jaringan antara internet/eksternal dan
  jaringan internal; hanya service publik (mis. web server) yang diletakkan
  di DMZ, database di internal (Kurose & Ross, 2021).
- **Docker microservices**: aplikasi dipecah menjadi container kecil
  (nginx, Flask, MySQL) yang saling terhubung lewat network virtual; IP
  statis membantu topologi yang dapat dipetakan (Newman, 2021).
- **Firewall (UFW/iptables)**: UFW adalah frontend iptables. Rate limiting
  koneksi/detik memakai modul `hashlimit`/`recent`. Untuk traffic container,
  aturan ditempatkan di chain `DOCKER-USER` (Rash, 2007).
- **BPF & Wireshark/tshark**: Berkeley Packet Filter dipakai sebagai
  capture filter (`-f`) untuk menangkap hanya paket yang relevan; display
  filter untuk menganalisis PCAP (Sanders, 2017).

---

## 3. Arsitektur Sistem & Topologi Jaringan

### 3.1 Diagram topologi

```
                        TAILNET (100.64.0.0/10)  <- WireGuard / CGNAT
   ┌──────────────┐   ┌──────────────┐
   │  RED TEAM    │   │ BLUE TEAM    │
   │  Burp Suite  │   │ tshark/WShark│
   └──────┬───────┘   └──────┬───────┘
          └──────────────────┴──►  IP tailnet web server (tailscale0:80)
                                    │  (container nginx = NODE TAILNET)
                                    │
                    ┌───────────────┴────────────────┐
                    │         SERVER (Docker)         │
                    │  NETWORK dmz 10.10.0.0/24       │
                    │    nginx 10.10.0.10 (+tailscale0)│
                    │       │ proxy_pass              │
                    │       └──► flask 10.10.0.11     │
                    │  NETWORK internal 10.10.2.0/24  │
                    │    flask 10.10.2.11 ──► mysql 10.10.2.12 │
                    └────────────────────────────────┘
```

- **Host Docker = mesin Blue Team** (bukan server Ubuntu terpisah). Docker
  Desktop/Engine berjalan di salah satu laptop anggota Blue Team; seluruh
  stack (`nginx`, `flask`, `mysql`) hidup sebagai container di mesin itu.
- **Network dmz (10.10.0.0/24)** : nginx `10.10.0.10`, backend `10.10.0.11`.
- **Network internal (10.10.2.0/24)** : backend `10.10.2.11`, MySQL `10.10.2.12`.
- Hanya nginx yang di-publish ke host (port host). Backend & MySQL **tidak**
  di-publish → server MySQL tidak terjangkau dari network dmz maupun host
  → segmentasi DMZ yang nyata.
- **Web server = node tailnet** (Donenfeld, 2017): `tailscaled` berjalan di
  dalam container nginx (interface `tailscale0`). **Red Team dan anggota Blue
  Team lainnya** (selain host) bergabung ke tailnet yang sama, lalu menyerang/
  menganalisis langsung `http://<ip-tailnet-nginx>/ → nginx → flask`, bukan
  lewat port host. Port host tetap ada untuk dev & fallback.
- **Firewall untuk jalur serangan di dalam container**: karena attacker masuk
  lewat `tailscale0` (di dalam container), penerapan firewall (iptables) juga
  dilakukan di dalam container nginx - lihat §4.2 dan §6.5.

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

## 4. Implementasi - Fase 1 (Network Programming & Administration)

### 4.1 Pemrograman: server API/WebSocket

Backend ditulis **dari awal** memakai Python Flask (Grinberg, 2018), dengan
pola pemrograman jaringan Python (Rhodes & Goerzen, 2017). Struktur:

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

**Transfer data sinkron** - REST request/response:

| Method | Path               | Auth                | Fungsi                            |
| ------ | ------------------ | ------------------- | --------------------------------- |
| POST   | `/api/register`  | -                   | Mendaftar (role default`user`)  |
| POST   | `/api/login`     | -                   | Login → JWT (HS256)              |
| GET    | `/api/profile`   | JWT                 | Profil pengguna                   |
| GET    | `/api/customers` | JWT +`role=admin` | **Target bypass**           |
| GET    | `/api`           | -                   | Index endpoint (misconfiguration) |
| GET    | `/api/health`    | -                   | Health check                      |

**Transfer data asinkron**:

- WebSocket `/ws/notifications` (protokol RFC 6455; Fette & Melnikov,
  2011, diakses via flask-sock) - pesan welcome, echo, dan
  broadcast notifikasi saat job selesai.
- Job queue `POST /api/jobs` → `202` + `job_id`; `GET /api/jobs/<id>` untuk
  polling hasil. Proses berjalan di `ThreadPoolExecutor`.

**Kerentanan inti (`auth.py`)** - decoder mempercayai `alg` dari header:

```python
alg = header.get("alg")
if alg == "none":
    return json.loads(_b64url_decode(parts[1]))   # token tanpa signature diterima
if alg == "HS256":
    return jwt.decode(token, Config.WEAK_SECRET, algorithms=["HS256"])
```

Dan endpoint `/api/customers` **tidak mengecek ulang role ke database** -
hanya membaca klaim `role` dari token:

```python
if claims.get("role") != "admin":
    abort(403, "Akses khusus admin")
```

### 4.2 Administrasi: deploy Docker + firewall

**Docker Compose** (`docker-compose.yml`, Kane & Matthias, 2018) - 3 service,
2 network bridge, IP statis, healthcheck, `restart: unless-stopped`. MySQL
hanya di network internal. Backend memakai `python:3.12-slim`; web server
di-build dari `nginx/Dockerfile` (nginx + tailscale + wireshark-cli +
iptables, berbasis `nginx:1.27-alpine`); database `mysql:8.4`.

**Tailscale pada web server**: container nginx adalah **node tailnet** -
`tailscaled` berjalan di dalam container (cap `NET_ADMIN`, device
`/dev/net/tun`). Attacker dan Blue Team menyerang/menganalisis langsung
`http://<ip-tailnet-nginx>/`, bukan lewat port host (Donenfeld, 2017). Auth
key diisi via `TS_AUTHKEY` di `.env`; jika kosong (mode dev), tailscale
dilewati dan nginx tetap jalan. Detail: `infrastructure/tailscale/setup.md`.

**Firewall (dua lapis)**. Karena jalur serangan utama masuk lewat tailnet ke
dalam container, penerapan firewall yang paling relevan dilakukan **di dalam
container nginx** (container adalah Linux kecil berbasis Alpine, iptables
sudah terpasang). Firewall host bersifat opsional/tambahan.

*Lapis 1 - firewall DI DALAM container web server (utama untuk skenario ini):*

- Web server berjalan sebagai container Linux (Alpine) yang **punya
  iptables** (`cap_add: NET_ADMIN, NET_RAW` di `docker-compose.yml`).
  Aturan membatasi interface `tailscale0` tempat attacker masuk:
  ```bash
  docker exec nginx sh -c \
    'iptables -I INPUT 1 -i tailscale0 -s <ip-attacker> -j DROP'   # blokir IP
  docker exec nginx sh -c \
    'iptables -I INPUT 1 -i tailscale0 -p tcp --dport 80 -m hashlimit \
     --hashlimit-above 10/sec --hashlimit-burst 20 --hashlimit-mode srcip \
     --hashlimit-name http --jump DROP'                            # rate limit
  ```

  Diuji: aturan `DROP` untuk IP host berhasil memblokir akses (timeout) dan
  dihapus tanpa sisa (lihat Lampiran). Ini menjawab pertanyaan soal: **tidak
  perlu mengganti image nginx** - image `nginx:1.27-alpine` sudah merupakan
  Linux terkecil yang memenuhi (tailscale + tshark + iptables + iproute2).
- **nginx `limit_req`**: 10 request/detik per IP (burst 20, `nodelay`) -
  lapis rate-limit di level aplikasi/proxy (lihat `nginx/nginx.conf`).

*Lapis 2 - firewall HOST (opsional, hanya bila host OS Linux/Ubuntu):*
`infrastructure/firewall/firewall.sh` tetap tersedia untuk membatasi akses
manajemen host (SSH) dan port host yang di-publish Docker:

- **UFW**: default deny incoming; buka SSH dan port 80/443 hanya dari
  subnet Tailscale `100.64.0.0/10`.
- **iptables DOCKER-USER** (karena traffic container lewat FORWARD, bukan
  INPUT): ESTABLISHED diizinkan → subnet Tailscale diizinkan → lainnya
  ditolak → rate limit koneksi NEW **10/detik** (burst 20) per source IP
  via modul `hashlimit`.

Pada host Windows (Docker Desktop) skrip host ini dilewati; perlindungan
tetap utuh lewat Lapis 1 (iptables di dalam container + `limit_req` nginx).

---

## 5. Metodologi Red Team - Fase 2

Alat: **Burp Suite** (Repeater & Intruder), mengikuti metodologi pengujian
keamanan aplikasi web (Stuttard & Pinto, 2011) dan kerangka OWASP Top 10
untuk *broken access control* (OWASP Foundation, 2021). Tidak ada automated
scanner; semua manipulasi manual, dan server **tidak diputus** koneksinya.

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

| Vektor       | Sebelum (user) | Setelah (bypass) |
| ------------ | -------------- | ---------------- |
| `alg=none` | 403            | **200**    |
| forge HS256  | 403            | **200**    |

Server tetap hidup; tidak ada flooding. Semua request terekam PCAP oleh
Blue Team. Walkthrough penuh: `docs/RED_TEAM.md`.

---

## 6. Analisis Blue Team - Fase 3

Analisis lalu lintas dilakukan dengan Wireshark/tshark dan filter BPF
(Sanders, 2017).

### 6.1 Capture

Karena web server adalah node tailnet, capture dijalankan **di dalam
container nginx** pada interface `tailscale0` (tempat traffic attacker
masuk):

```bash
# Terminal 1 - mulai capture di dalam container web server
docker exec -it nginx sh -c \
  'tshark -i tailscale0 -f "tcp port 80" -w /tmp/red_team.pcap'

# Setelah Fase 2 selesai, Ctrl+C lalu salin PCAP keluar untuk Wireshark:
docker cp nginx:/tmp/red_team.pcap ./red_team.pcap
```

### 6.2 BPF & isolasi paket mencurigakan

| Kebutuhan                | Filter                                                                           |
| ------------------------ | -------------------------------------------------------------------------------- |
| Hanya IP attacker        | `-f "tcp port 80 and host 100.101.102.103"`                                    |
| Hanya POST               | `-Y "http.request.method == POST"`                                             |
| Cari JWT (prefix`eyJ`) | `-Y "frame contains \"eyJ\""`                                                  |
| Akses ke target          | `-Y "http.request.uri contains \"customers\""`                                 |
| Timeline                 | `-T fields -e frame.time -e ip.src -e http.request.method -e http.request.uri` |

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

1. **Patch `auth.py`** - verifikasi dengan whitelist algoritma + signature
   wajib (lihat `docs/BLUE_TEAM.md` §5.1).
2. **Patch `routes.py`** - role dicek ke **database**, bukan klaim token.
3. **Blokir IP attacker** di dalam container nginx (interface `tailscale0`,
   tempat traffic attacker masuk):
   ```bash
   docker exec nginx sh -c \
     'iptables -I INPUT 1 -i tailscale0 -s 100.101.102.103 -j DROP'
   ```

   (Untuk vektor port host yang di-publish Docker, blokir di host lewat
   chain **DOCKER-USER**: `sudo iptables -I DOCKER-USER 1 -s <ip> -j DROP`.
   Alternatif lain: Tailscale ACL - lihat `docs/BLUE_TEAM.md` §4.)
4. **Hardening** - lihat `docs/HARDENING.md`: base image, non-root user,
   secret dari environment, WebSocket ber-autentikasi, rate limit.

### 6.6 Verifikasi perbaikan

- Token `alg=none` & forge HS256 → kini **401/403**.
- User biasa tetap 403 di `/api/customers`; admin (`admin/admin123`) → 200.
- IP yang diblokir → timeout (bukan respons HTTP).

---

## 7. Jawaban Pertanyaan Base Image

*(Soal meminta saran image container Linux paling kecil yang tetap memenuhi
semua kebutuhan.)*

**Kesimpulan: bukan selalu yang terkecil, melainkan yang terkecil yang tetap
deterministik.** Rincian:

- **nginx (web server)** → `nginx:1.27-alpine` **sudah merupakan image Linux
  terkecil yang memenuhi semua kebutuhan**: nginx + tailscale + tshark +
  iptables + iproute2 di dalam satu image (lihat `nginx/Dockerfile`). Dengan
  begini firewall (iptables) dan forensik (tshark) bisa berjalan **di dalam
  container yang sama**, tanpa container tambahan dan tanpa mengganti image.
  Ukuran tetap kecil karena Alpine (~5-10 MB base). Tidak perlu image terpisah.
- **Backend** → `python:3.12-slim`, bukan alpine: wheel binary
  `cryptography` (dibutuhkan PyMySQL) dan gunicorn lebih andal di glibc
  (Debian/slim); alpine (musl) berisiko gagal/membutuhkan kompiler.
- **Database** → `mysql:8.4` (sesuai syarat "MySQL"; tidak ada varian alpine
  resmi). `mariadb:11` lebih ringan tetapi bukan MySQL.

Trade-off: hemat ±75 MB di backend dengan alpine tidak sebanding dengan
risiko build tidak deterministik pada project yang harus direproduksi.
Kesimpulan praktis: `nginx:1.27-alpine` (dengan paket forensik/firewall)
memenuhi kebutuhan firewall di dalam container Linux terkecil yang
fungsional; backend memakai `python:3.12-slim` karena deterministik.

---

## 8. Kesimpulan & Saran

**Kesimpulan.**

1. Layanan API/WebSocket (Flask) berhasil dibangun dengan autentikasi JWT
   serta transfer data sinkron dan asinkron di atas Docker microservices
   bertopologi DMZ + IP statis.
2. Firewall diterapkan di dalam container web server (iptables pada
   interface `tailscale0` + nginx `limit_req`) untuk membatasi port dan rate
   koneksi per detik; skrip host (UFW + DOCKER-USER) opsional untuk host
   Linux/Ubuntu.
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

## Daftar Pustaka

1. Donenfeld, J. A. (2017). WireGuard: Next generation kernel network
   tunnel. Dalam *Proceedings of the 24th Annual Network and Distributed
   System Security Symposium (NDSS 2017)*. The Internet Society.
   https://www.ndss-symposium.org/ndss2017/ndss-2017-programme/wireguard-next-generation-kernel-network-tunnel/
2. Fette, I., & Melnikov, A. (2011). *The WebSocket protocol* (RFC 6455).
   Internet Engineering Task Force. https://www.rfc-editor.org/rfc/rfc6455
3. Grinberg, M. (2018). *Flask web development: Developing web applications
   with Python* (2nd ed.). O'Reilly Media.
4. Jones, M., Bradley, J., & Sakimura, N. (2015). *JSON Web Signature (JWS)*
   (RFC 7515). Internet Engineering Task Force.
   https://www.rfc-editor.org/rfc/rfc7515
5. Jones, M., Bradley, J., & Sakimura, N. (2015). *JSON Web Token (JWT)*
   (RFC 7519). Internet Engineering Task Force.
   https://www.rfc-editor.org/rfc/rfc7519
6. Kane, S. P., & Matthias, K. (2018). *Docker: Up & running: Shipping
   reliable containers in production* (2nd ed.). O'Reilly Media.
7. Kurose, J. F., & Ross, K. W. (2021). *Computer networking: A top-down
   approach* (8th ed.). Pearson.
8. McLean, T. (2015). *Critical vulnerabilities in JSON Web Token libraries*.
   Auth0.
   https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/
9. Newman, S. (2021). *Building microservices: Designing fine-grained
   systems* (2nd ed.). O'Reilly Media.
10. Opirskyy, I. R., & Kunakh, I. A. (2026). Analysis and mitigation of JWT
    and OAuth 2.0 vulnerabilities in REST APIs. *Radio Electronics, Computer
    Science, Control*. https://doi.org/10.30837/rt.2026.2.225.05
11. OWASP Foundation. (2021). *OWASP Top 10:2021 - A01:2021 Broken access
    control*. https://owasp.org/Top10/A01_2021-Broken_Access_Control/
12. OWASP Foundation. (n.d.). *JSON Web Token (JWT) cheat sheet*. OWASP Cheat
    Sheet Series.
    https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html
13. Rash, M. (2007). *Linux firewalls: Attack detection and response with
    iptables, psad, and fwsnort*. No Starch Press.
14. Rhodes, B., & Goerzen, J. (2017). *Foundations of Python network
    programming* (3rd ed.). Apress.
15. Sanders, C. (2017). *Practical packet analysis: Using Wireshark to solve
    real-world network problems* (3rd ed.). No Starch Press.
16. Sheffer, Y., Hardt, D., & Jones, M. B. (2020). *JSON Web Token best
    current practices* (RFC 8725). Internet Engineering Task Force.
    https://www.rfc-editor.org/rfc/rfc8725
17. Stuttard, D., & Pinto, M. (2011). *The web application hacker's handbook:
    Finding and exploiting security flaws* (2nd ed.). Wiley.

---

## Lampiran

- `docs/RECON.md` - langkah recon (list endpoint).
- `docs/RED_TEAM.md` - walkthrough serangan Burp Suite.
- `docs/BLUE_TEAM.md` - analisis tshark/BPF & patch.
- `docs/HARDENING.md` - base image & checklist hardening.
- `scripts/bypass_jwt.py` - PoC bypass (reproduksibel).
- `scripts/smoke_test.sh` - tes end-to-end.
- `infrastructure/firewall/firewall.sh` - aturan firewall host (opsional,
  hanya untuk host OS Linux/Ubuntu).
- `infrastructure/tailscale/setup.md` - setup Tailscale.

**Bukti uji firewall di dalam container (terverifikasi 2026-08-15):**

```bash
# 1) Terapkan aturan DROP untuk IP attacker di interface tailscale0
docker exec nginx sh -c 'iptables -I INPUT 1 -i tailscale0 -s 100.113.249.79 -j DROP'

# 2) Akses dari IP tersebut -> TIMEOUT (blokir aktif)
curl -m 6 http://100.112.109.101/api/health   # -> connection timeout

# 3) Hapus aturan -> akses pulih (200 OK)
docker exec nginx sh -c 'iptables -D INPUT -i tailscale0 -s 100.113.249.79 -j DROP'
curl http://100.112.109.101/api/health         # -> {"status":"ok"}
```

Hasil: aturan `iptables` di dalam container nginx berhasil memblokir akses
dari host/tailnet dan dapat dihapus tanpa sisa - membuktikan bahwa penerapan
firewall untuk skenario ujian **tidak memerlukan penggantian image nginx**.
