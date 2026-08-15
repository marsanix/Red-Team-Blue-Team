# Setup Tailscale (Web Server, Red Team, Blue Team)

Tailscale membuat *tailnet* privat (WireGuard-based, lihat `docs/LAPORAN.md`
Daftar Pustaka: Donenfeld, 2017) sehingga web server, mesin penyerang (Red
Team), dan mesin analisis (Blue Team) saling terhubung lewat subnet CGNAT
`100.64.0.0/10` - tanpa perlu port forwarding publik.

**Poin penting arsitektur:** pada project ini **web server (container nginx)
sendiri yang menjadi node tailnet**. `tailscaled` berjalan di dalam container
nginx (lihat `nginx/Dockerfile` + `nginx/entrypoint.sh`). Jadi attacker
menyerang langsung alamat tailnet web server (`100.x.y.z:80`), bukan port
host. **Host Docker adalah mesin Blue Team** (mis. laptop salah satu anggota)
- host cukup menjalankan Docker, tidak perlu Ubuntu.

---

## 1. Siapkan auth key di `.env`

Isi dua variabel ini di `.env` pada **host Docker (mesin Blue Team)**:

```bash
# .env (server) - nilai auth key DIISI di .env, JANGAN di file ter-track git
TS_AUTHKEY=tskey-auth-XXXX-YYYY        # ganti: isi key asli hanya di .env
TS_HOSTNAME=uas-nginx
```

- Auth key terbaru (2026-08-15) sudah dipakai dan berhasil join saat tes dev.
  Jika key sudah terpakai/dicabut, generate ulang di
  https://login.tailscale.com/admin/settings/keys lalu isi `TS_AUTHKEY` di
  `.env`.
- **Jangan pernah commit auth key ke repo publik** (setup.md ter-track git).
  Isi key asli hanya di `.env` (ter-gitignore).

## 2. Jalankan stack (web server masuk tailnet)

```bash
docker compose up -d --build
docker compose ps          # nginx, backend, mysql sehat
```

Saat container nginx mulai dengan `TS_AUTHKEY` terisi, entrypoint akan:
1. Menjalankan `tailscaled` (membutuhkan `/dev/net/tun` + cap `NET_ADMIN`).
2. `tailscale up --authkey=... --hostname=uas-nginx --accept-dns=false`.
3. Baru menjalankan nginx.

Cek alamat tailnet web server:

```bash
docker exec nginx tailscale ip -4        # mis. 100.98.42.7  -> target serangan
docker exec nginx tailscale status
```

> `--accept-dns=false` penting: tailscale tidak menimpa `resolv.conf`
> container, sehingga nama service `flask` tetap ter-resolve oleh Docker DNS.

## 3. Join mesin RED TEAM (attacker)

Mesin attacker (di luar host Blue Team) install & join ke **tailnet yang
sama** (auth key sama):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key="${TS_AUTHKEY}"   # nilai diambil dari .env (jangan commit)
```

Target serangan = **IP tailnet web server** (dari langkah 2), misal
`http://100.98.42.7`. Verifikasi:

```bash
curl -I http://<ip-tailnet-nginx>/api/health
```

## 4. Join mesin BLUE TEAM lainnya (analisis / pembela)

Anggota Blue Team **selain host** (host = yang menjalankan Docker) install &
join ke tailnet yang sama:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key="${TS_AUTHKEY}"   # nilai diambil dari .env (jangan commit)
```

Mereka memakai IP tailnet web server ini untuk koneksi tes dan analisis.
(Host itu sendiri tidak wajib join - akses/manajemen via `docker exec`.)

## 5. Capture & pemblokiran untuk Blue Team

Karena traffic attacker masuk lewat interface `tailscale0` **di dalam
container** (bukan host), capture dan pemblokiran dilakukan di dalam
container nginx:

```bash
# Capture PCAP pada interface tailscale0 (di dalam container web server)
docker exec -it nginx sh -c \
  'tshark -i tailscale0 -f "tcp port 80" -w /tmp/red_team.pcap'
# (di terminal lain) biarkan menangkap selama Fase 2, lalu Ctrl+C.

# Salin PCAP keluar untuk analisis Wireshark
docker cp nginx:/tmp/red_team.pcap ./red_team.pcap
```

Pemblokiran IP attacker (di dalam container, interface tailscale0):

```bash
docker exec -it nginx sh -c \
  'iptables -I INPUT 1 -i tailscale0 -s <ip-attacker> -j DROP'
```

Detail lengkap: `docs/BLUE_TEAM.md`.

## 6. Firewall (di dalam container + host opsional)

**Utama (skenario ini):** lalu lintas penyerangan via tailnet masuk
**langsung ke container** (interface `tailscale0`), sehingga pembatasan
dilakukan di dalam container nginx:
- **iptables di dalam container** (langkah 5) untuk blokir IP attacker.
- **nginx `limit_req`** (`nginx/nginx.conf`) untuk rate limit 10 r/s.

**Opsional (hanya bila host OS Linux/Ubuntu):** `infrastructure/firewall/
firewall.sh` untuk membatasi akses manajemen host (SSH) dan port host yang
di-publish Docker. Pada host Windows (Docker Desktop) skrip ini dilewati;
perlindungan tetap utuh lewat lapis di dalam container.

## 7. Verifikasi lintas mesin

Dari mesin mana pun (Red/Blue Team):

```bash
tailscale status          # semua node terlihat (termasuk uas-nginx)
ping -c 1 <ip-tailnet-nginx>
curl -I http://<ip-tailnet-nginx>/api/health
```
