# Setup Tailscale (Server, Red Team, Blue Team)

Tailscale membuat *tailnet* privat (WireGuard-based) sehingga server web,
mesin penyerang (Red Team), dan mesin analisis (Blue Team) saling terhubung
lewat subnet CGNAT `100.64.0.0/10` — tanpa perlu port forwarding publik.

## 1. Install & join di SERVER (host yang menjalankan Docker)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key=tskey-auth-kSGqNHhy2111CNTRL-45LKD4Yo97cqWzwwdUDk7cCY26bq1RtoG
```

Catatan:
- Auth key di atas sesuai yang tercantum di `CLAUDE.md`. Jika key sudah
  digunakan/dicabut, generate ulang di https://login.tailscale.com/admin/settings/keys.
- Setelah up, lihat IP tailnet server:

```bash
tailscale status
tailscale ip -4
```

## 2. Join mesin RED TEAM (attacker)

Install & join ke **tailnet yang sama**:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key=tskey-auth-kSGqNHhy2111CNTRL-45LKD4Yo97cqWzwwdUDk7cCY26bq1RtoG
```

Target serangan = IP tailnet server (dari langkah 1), misal `http://100.x.y.z`.

## 3. Join mesin BLUE TEAM (analisis / pembela)

Sama seperti Red Team:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --auth-key=tskey-auth-kSGqNHhy2111CNTRL-45LKD4Yo97cqWzwwdUDk7cCY26bq1RtoG
```

Blue Team memakai IP tailnet server ini untuk:
- menangkap lalu lintas (`tshark` di sisi server, lihat `docs/BLUE_TEAM.md`), dan
- melakukan koneksi tes sebelum/menjelang fase Red Team.

## 4. Verifikasi akses lintas mesin

Dari mesin mana pun (Red/Blue Team):

```bash
tailscale status          # semua node terlihat
ping -c 1 <ip-tailnet-server>
curl -I http://<ip-tailnet-server>/api/health
```

## 5. Interaksi dengan firewall (infrastructure/firewall/firewall.sh)

Firewall hanya membuka port 80/443 dari subnet `100.64.0.0/10`. Artinya:
- Serangan/tes dari dalam tailnet (Red/Blue Team) → **diizinkan** (di-rate-limit).
- Akses dari internet umum → **ditolak**.

Cek dari server:

```bash
sudo iptables -L DOCKER-USER -n -v   # aturan yang melindungi container
```
