#!/usr/bin/env bash
# ============================================================
# firewall.sh - Aturan firewall HOST (OPSIONAL, hanya host OS Linux/Ubuntu)
#
# KONTEKS SKENARIO UJIAN:
# Host Docker = mesin Blue Team (bisa Windows/Linux). Jalur serangan utama
# (Fase 2) masuk lewat tailnet LANGSUNG ke dalam container nginx
# (interface `tailscale0`), sehingga firewall utama yang relevan diterapkan
# DI DALAM container:
#   docker exec nginx sh -c 'iptables -I INPUT 1 -i tailscale0 -s <ip> -j DROP'
#   + nginx `limit_req` (10 r/s) di nginx/nginx.conf
# Skrip ini hanya LAPIS TAMBAHAN untuk host yang OS-nya Linux/Ubuntu:
# melindungi layanan host (SSH) dan membatasi port host yang di-publish
# Docker. Pada host Windows (Docker Desktop) skrip ini dilewati.
#
# DUA LAPIS (defense in depth, khusus host Linux):
#   Layer A - UFW         : melindungi layanan HOST (SSH, dsb.)
#   Layer B - iptables    : membatasi lalu lintas ke CONTAINER Docker
#
# PENTING (dijelaskan juga di docs/BLUE_TEAM.md):
# Port 80/443 yang di-publish Docker TIDAK lewat chain INPUT UFW - paketnya
# di-DNAT di PREROUTING lalu di-FORWARD ke container. Karena itu semua
# filtering traffic container ditaruh di chain khusus **DOCKER-USER**
# (disediakan Docker, tidak ditimpa saat Docker restart).
#
# Jalankan:  sudo bash firewall.sh
# ============================================================
set -euo pipefail

TAILSCALE_SUBNET="100.64.0.0/10"   # subnet CGNAT Tailscale
HTTP_PORT="80"
HTTPS_PORT="443"
SSH_PORT="22"

if [ "$(id -u)" -ne 0 ]; then
    echo "Jalankan dengan root: sudo bash firewall.sh" >&2
    exit 1
fi

# ---------------- Layer A: UFW (layanan host) ----------------
echo "[firewall] Konfigurasi UFW..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow from "${TAILSCALE_SUBNET}" to any port "${SSH_PORT}/tcp"
ufw allow from "${TAILSCALE_SUBNET}" to any port "${HTTP_PORT}/tcp"
ufw allow from "${TAILSCALE_SUBNET}" to any port "${HTTPS_PORT}/tcp"
ufw --force enable >/dev/null

# ---------------- Layer B: iptables chain DOCKER-USER ----------------
# Flush rule admin di DOCKER-USER (chain ini memang milik admin, aman di-flush).
iptables -F DOCKER-USER

# Susun dari BAWAH KE ATAS (setiap insert memakai -I DOCKER-USER 1), sehingga
# urutan evaluasi top->bottom menjadi:
#   1) ESTABLISHED,RELATED        -> RETURN (koneksi aktif tidak dipotong)
#   2) hashlimit port 80 NEW      -> DROP   (rate limit 10/detik, burst 20)
#   3) subnet Tailscale port 80   -> RETURN (diizinkan)
#   4) port 80 lainnya            -> DROP   (ditolak dari luar tailnet)
#   5-7) aturan yang sama untuk port 443
# (untuk 443 tanpa TLS cukup skip; aturan ESTABLISHED tetap dipakai.)

# --- port 443 ---
iptables -I DOCKER-USER 1 -p tcp --dport "${HTTPS_PORT}" -j DROP
iptables -I DOCKER-USER 1 -p tcp --dport "${HTTPS_PORT}" -s "${TAILSCALE_SUBNET}" -j RETURN
iptables -I DOCKER-USER 1 -p tcp --dport "${HTTPS_PORT}" -m conntrack --ctstate NEW \
    -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 20 \
    --hashlimit-mode srcip --hashlimit-name https --jump DROP

# --- port 80 ---
iptables -I DOCKER-USER 1 -p tcp --dport "${HTTP_PORT}" -j DROP
iptables -I DOCKER-USER 1 -p tcp --dport "${HTTP_PORT}" -s "${TAILSCALE_SUBNET}" -j RETURN
iptables -I DOCKER-USER 1 -p tcp --dport "${HTTP_PORT}" -m conntrack --ctstate NEW \
    -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 20 \
    --hashlimit-mode srcip --hashlimit-name http --jump DROP

# --- established/related selalu diizinkan (harus paling atas) ---
iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

echo "[firewall] Selesai. Isi chain DOCKER-USER:"
iptables -L DOCKER-USER -n -v --line-numbers

echo
echo "[firewall] Verifikasi (di server):"
echo "  sudo iptables -L DOCKER-USER -n -v -Z    # reset counter lalu lihat counter setelah tes"
echo "  sudo tshark -i any -f \"tcp port ${HTTP_PORT}\" -w red_team.pcap   # hanya untuk traffic port host"
echo
echo "[firewall] Jalur tailnet (Fase 3) - capture & blokir DI DALAM container:"
echo "  docker exec -it nginx sh -c 'tshark -i tailscale0 -f \"tcp port 80\" -w /captures/red_team.pcap'"
echo "  # PCAP hasil capture langsung di host: ./captures/red_team.pcap (bind mount)"
echo "  docker exec nginx sh -c 'iptables -I INPUT 1 -i tailscale0 -s <ip-attacker> -j DROP'"
echo
echo "[firewall] Persistensi antar reboot (opsional):"
echo "  sudo apt install iptables-persistent"
echo "  sudo netfilter-persistent save"
