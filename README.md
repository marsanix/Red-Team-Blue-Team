# UAS - Network Programming & Administration (Kelompok 5 dan 9)

Layanan API/WebSocket (Python Flask) di-deploy sebagai microservices Docker
ber-topologi **DMZ** dengan IP statis, dilengkapi kerentanan **JWT bypass**
untuk simulasi Red Team (Burp Suite) dan analisis Blue Team (tshark/Wireshark + BPF).

Skenario aplikasi: `register` → `login` → `profile` → `customers`
(`customers` hanya untuk admin, tapi bisa di-bypass oleh user biasa).

---

## Struktur project

```
├── docker-compose.yml        # 3 service (nginx, flask, mysql) + 2 network DMZ
├── .env / .env.example       # konfigurasi (DB, secret)
├── backend/                  # aplikasi Flask + Dockerfile + entrypoint
├── nginx/nginx.conf          # reverse proxy + limit_req + WebSocket
├── db/init.sql               # schema & seed data customers
├── scripts/
│   ├── bypass_jwt.py         # PoC bypass JWT (alg=none & forge HS256)
│   └── smoke_test.sh         # tes end-to-end
├── infrastructure/
│   ├── firewall/firewall.sh  # UFW + iptables DOCKER-USER (rate limit)
│   └── tailscale/setup.md    # setup Tailscale (server/attacker/blue team)
└── docs/
    ├── LAPORAN.md            # laporan teknis lengkap (ekspor ke PDF)
    ├── RECON.md              # cara mendapatkan list endpoint
    ├── RED_TEAM.md           # walkthrough serangan Burp (bypass JWT)
    ├── BLUE_TEAM.md          # analisis tshark/BPF + patch
    └── HARDENING.md          # base image + checklist hardening
```

## Topologi (DMZ + IP statis)

```
TAILNET 100.64.0.0/10
  Red/Blue Team --> http://<IP-tailnet-nginx>/   <- web server = NODE TAILNET
                     nginx 10.10.0.10 (dmz) + tailscale0 (tailnet)
                       | proxy_pass
                     flask 10.10.0.11 (dmz) / 10.10.2.11 (internal)
                       | SQL
                     mysql 10.10.2.12 (internal, TIDAK di-publish)
```

`tailscaled` berjalan di dalam container nginx (lihat `nginx/Dockerfile`).
Attacker menyerang langsung alamat tailnet web server - dapatkan via
`docker exec nginx tailscale ip -4`. Port host hanya untuk dev & fallback.

## Quickstart (host Docker = mesin Blue Team)

```bash
cp .env.example .env          # sudah tersedia .env untuk dev
docker compose up -d --build
docker compose ps             # pastikan semua "healthy"
```

Host Docker adalah salah satu mesin Blue Team. Web server (container nginx)
otomatis join tailnet bila `TS_AUTHKEY` diisi di `.env`. Red Team & anggota
Blue Team lain join ke tailnet yang sama, lalu mengakses
`http://<IP-tailnet-nginx>` (dapatkan via `docker exec nginx tailscale ip -4`).

**Endpoint utama** (`http://localhost:8081` di dev, atau
`http://<IP-tailnet-nginx>` bila tailscale aktif):

| Method | Path                  | Keterangan                                  |
| ------ | --------------------- | ------------------------------------------- |
| GET    | `/api`              | Daftar endpoint                             |
| GET    | `/api/health`       | Health check                                |
| POST   | `/api/register`     | Daftar (role=user)                          |
| POST   | `/api/login`        | Login → JWT (admin:`admin`/`admin123`) |
| GET    | `/api/profile`      | Profil (perlu JWT)                          |
| GET    | `/api/customers`    | Khusus admin (target bypass)                |
| POST   | `/api/jobs`         | Job asinkron                                |
| GET    | `/api/jobs/<id>`    | Status job                                  |
| WS     | `/ws/notifications` | WebSocket notifikasi                        |

## Troubleshooting

- **Port 80/8080 sudah dipakai project lain di mesin dev** (`Bind for 0.0.0.0:80 failed`): `.env` sudah memakai `HTTP_PORT=8081` untuk dev
  (`docker compose up -d`). Port host hanya fallback - jalur utama serangan
  via tailnet (`100.x.y.z:80`) tidak bergantung pada port host.
- **Ubah subnet 10.10.0.0/24 / 10.10.2.0/24** bila bentrok dengan network
  Docker lain di mesin (terjadi jika ada project lain memakai range yang sama).
- **Reset database**: `docker compose down -v && docker compose up -d` (volume
  `db_data` dihapus, `init.sql` dijalankan ulang).

## Tes cepat

```bash
# dev lokal (tanpa tailscale): port host 8081
bash scripts/smoke_test.sh http://localhost:8081
python scripts/bypass_jwt.py --none --target http://localhost:8081
python scripts/bypass_jwt.py --hs256 --target http://localhost:8081

# dengan tailscale aktif (dari mana pun di tailnet): target = IP tailnet web server
# bash scripts/smoke_test.sh http://<IP-tailnet-nginx>
```

Catatan: di Windows gunakan `python` (atau `py`); pastikan Git Bash / bash
tersedia untuk `smoke_test.sh`.

## Urutan kerja untuk ujian

1. **Fase 1**: `docker compose up -d --build` di mesin Blue Team (host
   Docker). Firewall aktif **di dalam container nginx** (iptables pada
   `tailscale0` + `limit_req`); `infrastructure/firewall/firewall.sh` hanya
   opsional bila host OS Linux/Ubuntu.
2. **Fase 2 (Red Team)**: ikuti `docs/RECON.md` → `docs/RED_TEAM.md`
   (Burp Suite Repeater/Intruder; tanpa automated scanner).
3. **Fase 3 (Blue Team)**: mulai capture **di dalam container nginx**
   (`docker exec -it nginx sh -c 'tshark -i tailscale0 -f "tcp port 80" -w /captures/red_team.pcap'`)
   sebelum serangan - PCAP langsung jatuh ke `./captures/` di host via bind
   mount (tanpa `docker cp`); analisis BPF (`docs/BLUE_TEAM.md`), blokir IP,
   lalu patch kode.
