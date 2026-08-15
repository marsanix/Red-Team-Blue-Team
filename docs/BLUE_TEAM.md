# BLUE TEAM — Analisis & Forensik Paket (Fase 3)

Posisi Blue Team: mempertahankan server, menangkap semua lalu lintas selama
Red Team menyerang, menemukan jejak eksploitasi, lalu meremediasi.

Tools: **tshark** (CLI) / **Wireshark** (GUI) di sisi server, **BPF**
(Berkeley Packet Filter) untuk mengisolasi lalu lintas mencurigakan.

---

## 1. Menangkap lalu lintas (PCAP)

Mulai capture SEBELUM Red Team mulai menyerang, di **interface apa pun**
yang dilalui traffic (tailscale0 / eth0 / Docker).

```bash
# Capture semua lalu lintas TCP port 80 ke file PCAP
sudo tshark -i any -f "tcp port 80" -w red_team.pcap

# atau dari mesin Blue Team (jika ingin memfilter host attacker):
sudo tshark -i any -f "tcp port 80" -w red_team.pcap
```

- `-f` = **capture filter** (BPF) — diterapkan saat menangkap, hemat ruang.
- `-w` = simpan ke file PCAP.
- Biarkan berjalan selama durasi Fase 2, lalu hentikan (`Ctrl+C`).

---

## 2. BPF untuk mengisolasi lalu lintas mencurigakan

### Capture filter (BPF asli, saat capture)

```bash
# Semua HTTP dari host attacker tertentu
sudo tshark -i any -f "tcp port 80 and host 100.101.102.103" -w attacker.pcap

# Hanya koneksi baru (SYN) — melihat upaya brute-force/scan
sudo tshark -i any -f "tcp port 80 and tcp[tcpflags] & tcp-syn != 0"

# Semua lalu lintas WebSocket (port 80 + header upgrade)
sudo tshark -i any -f "tcp port 80"
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
   **berubah-ubah** — normal hanya 1 token valid berulang.
3. Token JWT yang header/payload-nya **di-decode** menunjukkan `alg:none`.

### 3.2. Men-decode token dari PCAP

1. **Follow TCP stream** di Wireshark (klik kanan paket HTTP → *Follow →
   TCP Stream*) pada request `GET /api/customers`.
2. Salin nilai `Authorization: Bearer eyJ...`.
3. Decode segmen payload (base64url) → terlihat `"role":"admin"` padahal
   `"alg":"none"` (tanpa signature) → **itulah bukti bypass**.

> Ini menuntut pemahaman **struktur JWT** (header.payload.signature) —
> bukan sekadar membaca baris log. Jelaskan di laporan: *signature kosong
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

Begitu IP attacker teridentifikasi (dari PCAP), blokir di firewall server:

```bash
# Blokir seluruh traffic dari IP attacker
sudo iptables -I DOCKER-USER 1 -s 100.101.102.103 -j DROP

# atau lewat UFW (hanya berlaku untuk layanan host)
sudo ufw deny from 100.101.102.103

# verifikasi aturan
sudo iptables -L DOCKER-USER -n -v
```

> Kenapa **DOCKER-USER**? Port 80 yang dipublish Docker di-FORWARD, bukan
> lewat INPUT UFW. Menaruh rule di DOCKER-USER memastikan Docker tidak
> menimpa aturan saat restart. (Penjelasan penuh di `HARDENING.md` &
> `infrastructure/firewall/firewall.sh`.)

Setelah blokir, ulangi satu request dari IP attacker → harus **timeout/drop**
(bukan 403) — bukti blokir aktif.

---

## 5. Remediasi — menulis ulang kode (patch)

### 5.1. Patch `backend/app/auth.py` — verifikasi ketat

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

### 5.2. Patch `backend/app/routes.py` — role diambil dari DB, bukan token

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

- [ ] PCAP tersimpan lengkap selama durasi Fase 2 (`tshark -w red_team.pcap`).
- [ ] BPF dipakai untuk memfilter `host attacker`, `tcp port 80`, `POST`.
- [ ] Token JWT anomali di-decode → ditemukan `alg:none` + `role=admin`.
- [ ] Timeline serangan disusun dari `frame.time` & `http.request.uri`.
- [ ] IP attacker diblokir (`iptables DOCKER-USER`) → timeout setelah blokir.
- [ ] Kode di-patch (auth + routes) dan diverifikasi: bypass sekarang 401/403.
- [ ] Konfigurasi firewall & rate limit didokumentasikan.
