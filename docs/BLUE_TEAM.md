# BLUE TEAM - Analisis & Forensik Paket (Fase 3)

Posisi Blue Team: mempertahankan server, menangkap semua lalu lintas selama
Red Team menyerang, menemukan jejak eksploitasi, lalu meremediasi.

Tools: **tshark** (CLI) / **Wireshark** (GUI), **BPF** (Berkeley Packet
Filter) untuk mengisolasi lalu lintas mencurigakan. Karena web server
(nginx) adalah **node tailnet**, capture dijalankan **di dalam container
nginx** pada interface `tailscale0` (tempat traffic attacker masuk).

> Dapatkan IP tailnet web server: `docker exec nginx tailscale ip -4`
> (mis. `100.98.42.7`). Contoh IP attacker di bawah memakai `100.101.102.103`.

---

## 1. Menangkap lalu lintas (PCAP)

Mulai capture SEBELUM Red Team mulai menyerang, **di dalam container nginx**
pada interface `tailscale0`. tshark sudah terpasang di image nginx
(`wireshark-cli`).

```bash
# Terminal 1 - mulai capture di dalam container web server.
# `./captures` di host di-bind-mount ke `/captures` di container, jadi file
# PCAP langsung tersedia di host TANPA docker cp.
docker exec -it nginx sh -c 'tshark -i tailscale0 -f "tcp port 80" -w /captures/red_team.pcap'

# (Red Team menyerang di terminal lain; capture terus berjalan)
# Setelah Fase 2 selesai, hentikan (Ctrl+C). File sudah ada di host:
#   ./captures/red_team.pcap   -> buka langsung dengan Wireshark.
```

- `-f` = **capture filter** (BPF), diterapkan saat menangkap, hemat ruang.
- `-w` = simpan ke file PCAP. Karena `/captures` adalah bind mount ke
  `./captures` di host, hasil langsung terlihat di folder project (tidak
  perlu `docker cp`). Fallback tanpa bind mount: `/tmp/red_team.pcap` lalu
  `docker cp nginx:/tmp/red_team.pcap ./red_team.pcap`.

### 1.1 Realtime streaming ke Wireshark HOST (tanpa file)

Tampilkan paket **langsung** di Wireshark host dengan dua cara (keduanya
teruji). Keduanya memakai `tshark -w -` (stream pcap ke stdout) DI DALAM
container nginx.

#### Cara A (paling simpel) - pipe stdin ke Wireshark

Wireshark Windows mendukung live-capture dari **stdin** (`-i -`). Jalankan
**dari cmd.exe** (bukan PowerShell!) karena PowerShell 5.1 mengubah aliran
byte biner saat pipe native->native (stream pcap rusak / ber-BOM).

```cmd
:: HOST - jalankan dari Command Prompt (cmd). Wireshark terbuka otomatis.
docker exec uas-kelompok5dan9-nginx-1 sh -c "tshark -i tailscale0 -w - 'tcp port 80'" | "C:\Program Files\Wireshark\Wireshark.exe" -k -i -
```

Catatan:
- **Gunakan `tshark`, bukan `tcpdump`** (tcpdump TIDAK terpasang di image).
- Filter capture ditulis sebagai argumen terakhir (mis. `'tcp port 80'`).
- Uji cepat dari localhost (mode dev): ganti `tailscale0` -> `lo` dan arahkan
  request ke `127.0.0.1` di dalam container.
- Ctrl+C pada cmd menghentikan seluruh alur.

#### Cara B - named pipe (opsional)

Skrip `infrastructure/blue_team/live_capture.ps1` (dijalankan di HOST)
membuat named pipe `\\.\pipe\uas_capture`, **membuka Wireshark otomatis**
pada pipe tersebut, lalu menyalurkan output tshark dari container ke pipe.
Berguna bila ingin Wireshark tetap terbuka secara independen dari proses
streaming.

```powershell
# HOST - Wireshark terbuka sendiri & streaming langsung:
powershell -ExecutionPolicy Bypass -File .\infrastructure\blue_team\live_capture.ps1
#   -Interface tailscale0   -> jalur serangan Fase 2 (default)
#   -Interface lo / eth0    -> uji cepat dari localhost (mode dev)
#   -Filter "tcp port 80"   -> capture filter BPF (default)
#   -NoLaunch               -> jangan buka Wireshark otomatis (buka manual)
#   -WiresharkArgs "-a duration:10"  -> uji cepat, berhenti otomatis 10 dtk
```

Bila memilih `-NoLaunch`, buka Wireshark manual pada pipe:
`Capture -> Options -> Manage Interfaces -> "+" -> "Named pipe" -> \\.\pipe\uas_capture`  (atau CLI: `Wireshark.exe -i \\.\pipe\uas_capture -k`).

Saat Wireshark ditutup, streamer otomatis menghentikan tshark di container.
Tetap jalankan capture ke file (`/captures`) untuk bukti forensik yang
permanen; realtime streaming hanya untuk observasi langsung.

---

## 2. BPF untuk mengisolasi lalu lintas mencurigakan

### Capture filter (BPF asli, saat capture)

```bash
# Semua HTTP dari host attacker tertentu (di dalam container nginx)
docker exec -it nginx sh -c \
  'tshark -i tailscale0 -f "tcp port 80 and host 100.101.102.103" -w /captures/attacker.pcap'

# Hanya koneksi baru (SYN) - melihat upaya brute-force/scan
docker exec -it nginx sh -c \
  'tshark -i tailscale0 -f "tcp port 80 and tcp[tcpflags] & tcp-syn != 0"'

# Semua lalu lintas WebSocket (port 80 + header upgrade)
docker exec -it nginx sh -c 'tshark -i tailscale0 -f "tcp port 80"'
```

### Display filter (saat menganalisis PCAP)

```bash
# Semua HTTP dari IP attacker
tshark -r red_team.pcap -Y "ip.addr == 100.101.102.103" 

# Hanya request POST (login/register/job)
tshark -r red_team.pcap -Y "http.request.method == POST"

# Cari token JWT (prefix base64 header JWT "eyJ") di payload
tshark -r red_team.pcap -Y "frame contains \"eyJ\""

# Cari akses ke endpoint target
tshark -r red_team.pcap -Y "http.request.uri contains \"customers\""

# Request dengan status respons tertentu
tshark -r red_team.pcap -Y "http.response.code == 403 or http.response.code == 200"
```

---

## 3. Membaca hasil: menemukan anomali

### 3.1. Pola request normal vs serangan

Jalankan statistik sederhana untuk melihat distribusi request per IP:

```bash
tshark -r red_team.pcap -q -z io,phs              # protokol
tshark -r red_team.pcap -q -z endpoints,tcp       # top IP endpoints
tshark -r red_team.pcap -q -z http,req,tree       # request HTTP
```

**Anomali yang diharapkan saat serangan `alg=none`:**

1. Banyak request `POST /api/login` / `POST /api/register` dari satu IP
   (Red Team menyiapkan akun).
2. Request `GET /api/customers` dengan `Authorization: Bearer <token>` yang
   **berubah-ubah**, padahal normalnya hanya 1 token valid berulang.
3. Token JWT yang header/payload-nya **di-decode** menunjukkan `alg:none`.

### 3.2. Men-decode token dari PCAP

1. **Follow TCP stream** di Wireshark (klik kanan paket HTTP → *Follow →
   TCP Stream*) pada request `GET /api/customers`.
2. Salin nilai `Authorization: Bearer eyJ...`.
3. Decode segmen payload (base64url) → terlihat `"role":"admin"` padahal
   `"alg":"none"` (tanpa signature) → **itulah bukti bypass**.

> Ini menuntut pemahaman **struktur JWT** (header.payload.signature), bukan
> sekadar membaca baris log. Jelaskan di laporan: *signature kosong
>
> + role=admin = token palsu yang diterima server*.

### 3.3. Buat timeline serangan dari PCAP

```bash
tshark -r red_team.pcap -T fields -e frame.time -e ip.src -e http.request.method \
       -e http.request.uri | sort | head -50
```

Output memperlihatkan urutan: recon → register → login → customers (403) →
customers (200) → job/WS. **Timeline ini dipakai untuk memetakan vektor
serangan dari level paket** di laporan.

---

## 4. Memblokir penyerang (firewall)

IP attacker teridentifikasi dari PCAP. Karena traffic masuk lewat interface
`tailscale0` **di dalam container nginx**, blokir dilakukan di dalam
container pada chain `INPUT`:

```bash
# Blokir seluruh traffic dari IP attacker di interface tailscale0
docker exec -it nginx sh -c \
  'iptables -I INPUT 1 -i tailscale0 -s 100.101.102.103 -j DROP'

# verifikasi aturan di dalam container
docker exec nginx sh -c 'iptables -L INPUT -n -v | head -20'
```

**Alternatif - Tailscale ACL (tailnet policy):** buka
https://login.tailscale.com/admin/acls lalu tambahkan rule `drop` untuk node
attacker menuju web server (pendekatan firewall tingkat tailnet):

```jsonc
{ "action": "drop", "src": ["<node-attacker>"], "dst": ["<node-uas-nginx>:80"] }
```

> Catatan host: port 80 host yang dipublish Docker di-FORWARD, bukan lewat
> INPUT UFW, sehingga aturan host ditempatkan di chain **DOCKER-USER**
> (`infrastructure/firewall/firewall.sh`). Itu tetap berguna untuk akses via
> port host; untuk vektor tailnet, gunakan blokir di dalam container di atas.

Setelah blokir, ulangi satu request dari IP attacker → harus **timeout/drop**
(bukan 403) - bukti blokir aktif.

---

## 5. Remediasi - menulis ulang kode (patch)

### 5.1. Patch `backend/app/auth.py` - verifikasi ketat

Ganti `decode_token` yang mempercayai `alg` header dengan verifikasi PyJWT
yang **menolak** alg selain whitelist dan **wajib** signature:

```python
import jwt
from app.config import Config

def decode_token_secure(token: str) -> dict:
    """Versi PATCHED: algoritma di-whitelist, signature wajib, exp dicek."""
    return jwt.decode(
        token,
        Config.WEAK_SECRET,
        algorithms=["HS256"],   # 'none' & algoritma lain ditolak otomatis
        options={"require": ["exp", "sub"]},
    )
```

### 5.2. Patch `backend/app/routes.py` - role diambil dari DB, bukan token

```python
@bp.get("/customers")
def customers_secure():
    claims = _require_token()                 # pakai decoder yang aman
    user = db.session.get(User, claims.get("sub"))
    if not user or user.role != "admin":      # VULN DITUTUP: cek ke DB
        abort(403, "Akses khusus admin")
    return jsonify({"customers": [...]})
```

### 5.3. Perkuat secret & WebSocket

- Ganti `WEAK_SECRET` dengan secret acak dari environment (bukan hardcode):
  ```python
  WEAK_SECRET = os.environ["JWT_SECRET"]   # jangan ada default
  ```
- WebSocket `/ws/notifications` wajib autentikasi (token di query/header)
  dan validasi payload yang masuk.

---

## 6. Checklist analisis (untuk laporan)

- [ ] PCAP tersimpan lengkap selama durasi Fase 2 (`tshark -w /captures/red_team.pcap` di dalam container nginx) - langsung tersedia di `./captures/` host via bind mount.
- [ ] BPF dipakai untuk memfilter `host attacker`, `tcp port 80`, `POST`.
- [ ] Token JWT anomali di-decode → ditemukan `alg:none` + `role=admin`.
- [ ] Timeline serangan disusun dari `frame.time` & `http.request.uri`.
- [ ] IP attacker diblokir (`iptables` di dalam container / Tailscale ACL) → timeout setelah blokir.
- [ ] Kode di-patch (auth + routes) dan diverifikasi: bypass sekarang 401/403.
- [ ] Konfigurasi firewall & rate limit didokumentasikan.
