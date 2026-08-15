# Setup Tailscale (Web Server, Red Team, Blue Team)

Tailscale membuat *tailnet* privat (WireGuard-based, lihat `docs/LAPORAN.md`
Daftar Pustaka: Donenfeld, 2017) sehingga web server, mesin penyerang (Red
Team), dan mesin analisis (Blue Team) saling terhubung lewat subnet CGNAT
`100.64.0.0/10` - tanpa perlu port forwarding publik.

**Poin penting arsitektur:** pada project ini **web server (container nginx)
sendiri yang menjadi node tailnet**. `tailscaled` berjalan di dalam container
nginx (lihat `nginx/Dockerfile` + `nginx/entrypoint.sh`). Jadi attacker
menyerang langsung alamat tailnet web server (`100.x.y.z:80`), bukan port
host. Host cukup menjalankan Docker.

---

## 1. Siapkan auth key di `.env`

Isi dua variabel ini di `.env` pada **server Ubuntu**:

```bash
# .env (server)
TS_AUTHKEY=tskey-auth-kSGqNHhy2111CNTRL-45LKD4Yo97cqWzwwdUDk7cCY26bq1RtoG
TS_HOSTNAME=uas-nginx
```

- Auth key sesuai yang tercantum di `CLAUDE.md`. Jika key sudah terpakai/
  dicabut, generate ulang di https://login.tailscale.com/admin/settings/keys.
- Di mesin dev (Windows/Docker Desktop), biarkan `TS_AUTHKEY=` kosong agar
  auth key tidak terpakai oleh node percobaan (umumnya single-use).

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

Install & join ke **tailnet yang sama** (auth key sama):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key=tskey-auth-kSGqNHhy2111CNTRL-45LKD4Yo97cqWzwwdUDk7cCY26bq1RtoG
```

Target serangan = **IP tailnet web server** (dari langkah 2), misal
`http://100.98.42.7`. Verifikasi:

```bash
curl -I http://<ip-tailnet-nginx>/api/health
```

## 4. Join mesin BLUE TEAM (analisis / pembela)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key=tskey-auth-kSGqNHhy2111CNTRL-45LKD4Yo97cqWzwwdUDk7cCY26bq1RtoG
```

Blue Team memakai IP tailnet web server ini untuk koneksi tes dan analisis.

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

## 6. Firewall host (tetap ada untuk SSH & port host)

Firewall host (`infrastructure/firewall/firewall.sh`) tetap berguna untuk
akses manajemen (SSH) dan membatasi siapa yang boleh memakai port host.
Namun lalu lintas penyerangan via tailnet masuk **langsung ke container**,
sehingga untuk vektor itu pembatasan dilakukan di lapis nginx
(`limit_req` di `nginx.conf`) dan iptables di dalam container (langkah 5).

## 7. Verifikasi lintas mesin

Dari mesin mana pun (Red/Blue Team):

```bash
tailscale status          # semua node terlihat (termasuk uas-nginx)
ping -c 1 <ip-tailnet-nginx>
curl -I http://<ip-tailnet-nginx>/api/health
```
