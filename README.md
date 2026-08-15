# UAS - Network Programming & Administration (Kelompok 5)

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
  Red/Blue Team --> host:80
                     nginx 10.10.0.10 (dmz)   <- satu-satunya yang di-publish
                       | proxy_pass
                     flask 10.10.0.11 (dmz) / 10.10.2.11 (internal)
                       | SQL
                     mysql 10.10.2.12 (internal, TIDAK di-publish)
```

## Quickstart (Docker Desktop Windows / server Ubuntu)

```bash
cp .env.example .env          # sudah tersedia .env untuk dev
docker compose up -d --build
docker compose ps             # pastikan semua "healthy"
```

**Endpoint utama** (`http://localhost` di dev, atau IP tailnet server):

| Method | Path | Keterangan |
|--------|------|------------|
| GET | `/api` | Daftar endpoint |
| GET | `/api/health` | Health check |
| POST | `/api/register` | Daftar (role=user) |
| POST | `/api/login` | Login → JWT (admin: `admin`/`admin123`) |
| GET | `/api/profile` | Profil (perlu JWT) |
| GET | `/api/customers` | Khusus admin (target bypass) |
| POST | `/api/jobs` | Job asinkron |
| GET | `/api/jobs/<id>` | Status job |
| WS | `/ws/notifications` | WebSocket notifikasi |

## Troubleshooting

- **Port 80 sudah dipakai project lain / Windows** (`Bind for 0.0.0.0:80 failed`):
  tambahkan `HTTP_PORT=8080` di `.env` lalu `docker compose up -d`. Di server
  Ubuntu port 80 default dipakai (tailscale mengarah ke port 80).
- **Ubah subnet 10.10.0.0/24 / 10.10.2.0/24** bila bentrok dengan network
  Docker lain di mesin (terjadi jika ada project lain memakai range yang sama).
- **Reset database**: `docker compose down -v && docker compose up -d` (volume
  `db_data` dihapus, `init.sql` dijalankan ulang).

## Tes cepat

```bash
bash scripts/smoke_test.sh http://localhost          # register→login→bypass→rate limit
python scripts/bypass_jwt.py --none --target http://localhost
python scripts/bypass_jwt.py --hs256 --target http://localhost
```

Catatan: di Windows gunakan `python` (atau `py`); pastikan Git Bash / bash
tersedia untuk `smoke_test.sh`.

## Urutan kerja untuk ujian

1. **Fase 1**: `docker compose up -d --build` + terapkan firewall
   (`infrastructure/firewall/firewall.sh` di server Ubuntu).
2. **Fase 2 (Red Team)**: ikuti `docs/RECON.md` → `docs/RED_TEAM.md`
   (Burp Suite Repeater/Intruder; tanpa automated scanner).
3. **Fase 3 (Blue Team)**: mulai `tshark -w red_team.pcap` sebelum serangan,
   analisis BPF (`docs/BLUE_TEAM.md`), blokir IP, lalu patch kode.

## Membuat laporan PDF

1. Ekspor `docs/LAPORAN.md` ke PDF - mis. dengan VS Code + ekstensi
   *Markdown PDF*, atau *Pandoc*:
   ```bash
   pandoc docs/LAPORAN.md -o KODEMK_NAMA_NIM.pdf --pdf-engine=weasyprint
   ```
2. Sesuaikan identitas (KODEMK, Nama, NIM) di bagian cover per anggota.
3. Setiap anggota **wajib mengunggah PDF-nya sendiri** ke LMS.

> **Catatan akademik:** pahami & parafrasekan seluruh kode/laporan sesuai
> kemampuannya sendiri; jangan copy-paste buta. Project ini adalah alat
> edukasi keamanan untuk lab ujian, jangan dipakai menyerang sistem selain
> target ujian.
