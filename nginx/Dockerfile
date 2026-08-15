# ============================================================
# Web server nginx + Tailscale (skenario ujian Fase 2/3)
#
# Web server ini adalah NODE TAILNET: tailscaled berjalan di DALAM
# container, sehingga Red Team (attacker) dan Blue Team mengakses langsung
# alamat tailnet web server (100.x.y.z:80), bukan lewat port host.
#
# Isi image:
#   - tailscale      : web server bergabung ke tailnet (bila TS_AUTHKEY diisi)
#   - wireshark-cli  : tshark untuk capture PCAP pada interface tailscale0
#                      (analisis Blue Team, Fase 3)
#   - iptables       : pemblokiran IP attacker di dalam container (Fase 3)
#                      dan dipakai tailscaled untuk mengatur rule-nya
#   - iproute2       : perintah `ip` yang dibutuhkan tailscaled
# ============================================================
FROM nginx:1.27-alpine

# Paket tambahan untuk tailscale + forensik + firewall di dalam container.
RUN apk add --no-cache \
        tailscale \
        wireshark-cli \
        iptables \
        iproute2 \
    && mkdir -p /var/lib/tailscale /var/run/tailscale

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Entrypoint memulai tailscaled (bila TS_AUTHKEY diisi), lalu nginx.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
