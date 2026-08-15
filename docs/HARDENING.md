# HARDENING - Base Image & Langkah Pengamanan (Fase 3)

Bagian ini menjawab pertanyaan dari soal: *"beri saran apakah sebaiknya
menggunakan image container Linux yang paling kecil namun bisa memenuhi
semuanya?"* dan menyediakan checklist pengamanan menyeluruh.

---

## 1. Rekomendasi base image container

| Service    | Image yang dipakai    | Ukuran ± | Alternatif                      | Alasan                                                                                                      |
| ---------- | --------------------- | --------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Web server | `nginx:1.27-alpine` | ~ 45 MB   | `nginx:1.27` (~100 MB)        | Alpine = image resmi, kecil, sudah mencukupi fitur proxy/rate-limit yang dipakai.                           |
| Backend    | `python:3.12-slim`  | ~ 125 MB  | `python:3.12-alpine` (~50 MB) | **slim dipilih, bukan alpine** (penjelasan di bawah).                                                 |
| Database   | `mysql:8.4`         | ~ 600 MB  | `mariadb:11` (~400 MB)        | MySQL sesuai syarat soal; tidak ada varian alpine resmi untuk MySQL. MariaDB lebih ringan tapi bukan MySQL. |

### Mengapa backend memakai `slim`, bukan `alpine`?

Pertanyaan "paling kecil tapi bisa memenuhi semuanya" jawabannya **bukan
selalu yang terkecil** - ada trade-off antara ukuran dan *determinisme*:

1. **Wheel binary**: `cryptography` (ditarik `PyMySQL[rsa]`) dan gunicorn
   punya banyak wheel. Untuk Alpine (musl libc) tersedia wheel `musllinux`,
   tapi historis lebih sering menimbulkan masalah kompatibilitas ABI.
   `python:3.12-slim` (Debian, glibc) punya wheel lengkap dan stabil.
2. **Alat build**: kalau wheel tidak tersedia untuk platform tertentu, alpine
   butuh `gcc`/`musl-dev` (menambah ukuran build sementara + risiko gagal).
   Dengan slim, `pip install` hampir selalu tanpa kompilasi.
3. **Perilaku deterministik**: build yang sama di mesin yang sama → hasil
   yang sama. Untuk project ujian (harus bisa dijelaskan & direproduksi),
   determinisme lebih berharga daripada hemat ±75 MB.

**Kesimpulan yang dilaporkan:** gunakan image **sekecil mungkin yang tetap
menjamin instalasi deterministik**. Kombinasi pilihan: `nginx:1.27-alpine`
(web, aman alpine) + `python:3.12-slim` (backend, wajib glibc untuk wheel
`cryptography`) + `mysql:8.4` (wajib MySQL; tidak ada varian alpine). Bila
benar-benar ingin mengecilkan backend, pakai `python:3.12-alpine` hanya
setelah menguji `pip install` lolos.

---

## 2. Checklist hardening

### 2.1. Container & image

- [ ] **Non-root user** di dalam container (`USER appuser` di Dockerfile
  backend) - mengurangi dampak bila container di-breach.
- [ ] Image di-pin ke versi (bukan `latest`) agar build reproducible.
- [ ] `:ro` (read-only) untuk file konfigurasi yang di-mount.
- [ ] Tidak menjalankan `FLASK_DEBUG=1` / debug server di produksi
  (pakai gunicorn).

### 2.2. Jaringan & segmentasi (DMZ)

- [ ] Hanya **nginx** yang di-publish (port 80). Flask & MySQL tidak.
- [ ] MySQL hanya di network **internal** (tidak terjangkau dari dmz/host).
- [ ] IP statis per service agar aturan firewall & diagram topologi jelas.
- [ ] Docker `restart: unless-stopped` + healthcheck tiap service.

### 2.3. Firewall (host Ubuntu)

- [ ] UFW: `default deny incoming`; buka SSH & port 80/443 **hanya** dari
  subnet Tailscale `100.64.0.0/10`.
- [ ] iptables **DOCKER-USER**: ESTABLISHED diizinkan, subnet Tailscale
  diizinkan, selain itu drop, plus rate-limit `hashlimit` 10/detik
  (lihat `infrastructure/firewall/firewall.sh`).
- [ ] Persistensi: `iptables-persistent` / systemd unit.
- [ ] Verifikasi berkala: `iptables -L DOCKER-USER -n -v`.

### 2.4. Aplikasi / kode

- [ ] JWT: whitelist algoritma, wajib signature, role dicek ke **database**
  (bukan dari klaim token) - lihat `docs/BLUE_TEAM.md` §5.
- [ ] Secret tidak di-hardcode (dari environment / secret manager).
- [ ] WebSocket wajib autentikasi + validasi payload.
- [ ] Rate limit aplikasi (login) & transport (nginx `limit_req`).

### 2.5. nginx

- [ ] `server_tokens off` (sembunyikan versi).
- [ ] Security headers (`X-Content-Type-Options`, `X-Frame-Options`; untuk
  produksi tambah `Content-Security-Policy`, HSTS bila HTTPS).
- [ ] `limit_req_zone` untuk mitigasi flooding/brute-force.

### 2.6. Monitoring & forensik

- [ ] Akses log nginx + aplikasi dipertahankan untuk audit.
- [ ] Capture PCAP (`tshark -w`) saat uji serangan - bukti untuk laporan.
- [ ] Backup database (`docker compose exec mysql mysqldump ...`).
