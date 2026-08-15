# captures/ — hasil capture PCAP (Fase 3 Blue Team)

Folder ini di-bind-mount ke container `nginx` di `/captures`. File `.pcap`
yang ditulis tshark **di dalam container** langsung muncul di sini (di host),
tanpa perlu `docker cp`.

```bash
# Mulai capture di dalam container nginx (interface tailscale0 / tcp 80)
docker exec -it nginx sh -c \
  'tshark -i tailscale0 -f "tcp port 80" -w /captures/red_team.pcap'

# Hentikan (Ctrl+C) -> file langsung tersedia di ./captures/red_team.pcap
# Buka dengan Wireshark di host.
```

Catatan:
- File `.pcap`/`.pcapng` di-ignore oleh git (`.gitignore`), jadi hasil
  capture tidak ikut ter-commit. Simpan salinan ke tempat aman bila perlu
  dilampirkan ke laporan.
- Perintah capture (multi-buffer, `-b` rotasi) bila traffic besar:
  ```bash
  docker exec -it nginx sh -c \
    'tshark -i tailscale0 -f "tcp port 80" -w /captures/red_team.pcap -b filesize:10240 -b files:5'
  ```
