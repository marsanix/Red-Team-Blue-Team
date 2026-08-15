#!/bin/sh
# ============================================================
# Entrypoint web server nginx:
#   1) Bila TS_AUTHKEY diisi -> jalankan tailscaled & join tailnet.
#      Web server menjadi node tailnet (interface tailscale0) sehingga
#      Red/Blue Team menyerang/menganalisis lewat alamat tailnet-nya.
#      Bila TS_AUTHKEY kosong (mode dev di Windows/Docker Desktop) -> skip.
#   2) Jalankan nginx di foreground (exec).
#
# Catatan penting:
#   - `--accept-dns=false` agar tailscale TIDAK menimpa resolv.conf
#     container, sehingga nama service `flask` tetap ter-resolve oleh
#     Docker DNS (127.0.0.11).
#   - nginx `listen 80` terikat ke semua interface, termasuk tailscale0.
# ============================================================
set -u

start_tailscale() {
    echo "[tailscale] memulai tailscaled..."
    tailscaled \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock &
    # Tunggu socket daemon siap (maks 30 dtk).
    i=0
    while [ "$i" -lt 30 ]; do
        [ -S /var/run/tailscale/tailscaled.sock ] && break
        i=$((i + 1))
        sleep 1
    done

    if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
        echo "[tailscale] PERINGATAN: daemon tidak siap dalam 30 dtk."
        return 1
    fi

    echo "[tailscale] bergabung ke tailnet sebagai ${TS_HOSTNAME:-uas-nginx} ..."
    # timeout 90 dtk agar tidak menggantung bila auth key tidak valid.
    timeout 90 tailscale up \
        --authkey="${TS_AUTHKEY}" \
        --hostname="${TS_HOSTNAME:-uas-nginx}" \
        --accept-dns=false

    echo "[tailscale] alamat tailnet (interface tailscale0):"
    tailscale ip -4 || true
    tailscale status || true
}

# ---- 1) Tailscale: hanya bila auth key diisi ----
if [ -n "${TS_AUTHKEY:-}" ]; then
    if start_tailscale; then
        echo "[tailscale] OK - web server sudah menjadi node tailnet."
    else
        echo "[tailscale] GAGAL join tailnet (periksa /dev/net/tun & auth key)."
        echo "[tailscale] nginx tetap berjalan untuk akses via port host."
    fi
else
    echo "[tailscale] TS_AUTHKEY kosong -> mode dev, tailscale dilewati."
fi

# ---- 2) Nginx (foreground) ----
echo "[nginx] memulai nginx..."
exec "$@"
