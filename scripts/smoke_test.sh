#!/usr/bin/env bash
# Smoke test end-to-end (berjalan di Git Bash Windows maupun shell Linux).
#
#   bash scripts/smoke_test.sh [BASE_URL]
#   contoh: bash scripts/smoke_test.sh http://localhost:8081
#           bash scripts/smoke_test.sh http://<IP-tailnet-nginx>
set -uo pipefail

BASE="${1:-http://localhost}"
RAND=$RANDOM
USERNAME="user_${RAND}"
PASSWORD="pass${RAND}"

echo "== 1. Health check =="
curl -s -o /dev/null -w "GET ${BASE}/api/health -> HTTP %{http_code}\n" "${BASE}/api/health"

echo "== 2. Daftar endpoint (recon: GET /api) =="
curl -s "${BASE}/api" | python -m json.tool | head -40

echo "== 3. Register user baru =="
curl -s -X POST "${BASE}/api/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"fullname\":\"Test User\"}" \
  | python -m json.tool

echo "== 4. Login (ambil JWT) =="
LOGIN=$(curl -s -X POST "${BASE}/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}")
TOKEN=$(echo "${LOGIN}" | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
echo "Token diterima: ${TOKEN:0:40}..."

echo "== 5. Profile dengan token valid -> HARUS 200 =="
curl -s "${BASE}/api/profile" -H "Authorization: Bearer ${TOKEN}" | python -m json.tool

echo "== 6. Customers sebagai user biasa -> HARUS 403 =="
curl -s -o /dev/null -w "GET ${BASE}/api/customers -> HTTP %{http_code}\n" \
  "${BASE}/api/customers" -H "Authorization: Bearer ${TOKEN}"

echo "== 7. Bypass JWT (alg=none + role=admin) -> HARUS 200 =="
python scripts/bypass_jwt.py --none --target "${BASE}"

echo "== 8. Transfer data asinkron (job queue) =="
JOB=$(curl -s -X POST "${BASE}/api/jobs" -H "Content-Type: application/json" -d '{"task":"export"}')
echo "${JOB}" | python -m json.tool
JOB_ID=$(echo "${JOB}" | python -c "import sys,json;print(json.load(sys.stdin)['job_id'])")
echo "Menunggu job selesai..."
sleep 6
curl -s "${BASE}/api/jobs/${JOB_ID}" | python -m json.tool

echo "== 9. Rate limit nginx (40 request konkuren) =="
python - "${BASE}" <<'PY'
import concurrent.futures
import sys
import urllib.error
import urllib.request
from collections import Counter

base = sys.argv[1]

def hit(_):
    try:
        with urllib.request.urlopen(f"{base}/api/health", timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception:
        return 0

with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
    codes = list(ex.map(hit, range(40)))

print("Distribusi kode HTTP:", dict(Counter(codes)))
if 503 in codes:
    print("-> limit_req nginx BEKERJA (muncul 503 untuk request di atas burst).")
else:
    print("-> Tidak ada 503 (request mungkin tersebar >1 detik).")
print("Selesai.")
PY
