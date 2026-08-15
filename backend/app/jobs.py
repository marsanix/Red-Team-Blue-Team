"""Transfer data ASINKRON (Fase 1): job queue memakai ThreadPoolExecutor.

Kontras dengan REST sinkron di routes.py:
  POST /api/jobs        -> langsung mengembalikan 202 + job_id (tanpa menunggu selesai)
  GET  /api/jobs/<id>   -> polling status: queued / running / completed / failed

Saat job selesai, notifikasi di-broadcast ke klien WebSocket (/ws/notifications).
"""
import json
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from flask import Blueprint, abort, jsonify, request

from app.ws import broadcast

bp = Blueprint("jobs", __name__, url_prefix="/api/jobs")

# State in-memory (cukup untuk demonstrasi; tidak persisten antar restart).
executor = ThreadPoolExecutor(max_workers=4)
_jobs: dict[str, dict] = {}


def _worker(job_id: str, payload: dict) -> None:
    _jobs[job_id]["status"] = "running"
    try:
        time.sleep(4)  # simulasi pekerjaan panjang (mis. ekspor laporan)
        _jobs[job_id]["status"] = "completed"
        _jobs[job_id]["result"] = {
            "echo": payload,
            "message": "pekerjaan selesai (proses asinkron berjalan di latar belakang)",
        }
        broadcast(json.dumps({
            "type": "job_done",
            "job_id": job_id,
            "status": "completed",
        }))
    except Exception as exc:  # noqa: BLE001
        _jobs[job_id]["status"] = "failed"
        _jobs[job_id]["error"] = str(exc)


@bp.post("")
def create_job():
    """Submit job asinkron. Tidak menunggu hasil (HTTP 202 Accepted)."""
    data = request.get_json(silent=True) or {}
    job_id = uuid.uuid4().hex[:12]
    _jobs[job_id] = {"job_id": job_id, "status": "queued", "payload": data}
    executor.submit(_worker, job_id, data)
    return jsonify({
        "job_id": job_id,
        "status": "queued",
        "note": "Proses berjalan asinkron. Polling hasil: GET /api/jobs/<job_id>",
    }), 202


@bp.get("/<job_id>")
def job_status(job_id: str):
    """Cek status & hasil job asinkron (polling)."""
    job = _jobs.get(job_id)
    if not job:
        abort(404, "Job tidak ditemukan")
    return jsonify(job)
