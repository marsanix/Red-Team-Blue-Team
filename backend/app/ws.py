"""WebSocket notifikasi (Fase 1): transfer data ASINKRON via WebSocket.

Menggunakan flask-sock (adapter WSGI -> WebSocket) dengan worker gunicorn
gthread. Setiap koneksi ditangani satu thread; pesan welcome dikirim saat
terhubung, dan job yang selesai di-broadcast (dari jobs.py).
"""
import json
import threading

from app import sock

_connected: set = set()
_lock = threading.Lock()


def broadcast(message: str) -> None:
    """Kirim pesan ke semua klien WebSocket yang sedang terhubung."""
    with _lock:
        for ws in list(_connected):
            try:
                ws.send(message)
            except Exception:  # noqa: BLE001 - koneksi mati, buang
                _connected.discard(ws)


@sock.route("/ws/notifications")
def ws_notifications(ws):
    with _lock:
        _connected.add(ws)
    try:
        ws.send(json.dumps({
            "type": "welcome",
            "message": "Terhubung ke WebSocket notifikasi (uas-kelompok5)",
            "connected_clients": len(_connected),
        }))
        while True:
            data = ws.receive()
            if data is None:
                break
            # Echo sederhana sebagai demonstrasi duplex asinkron.
            ws.send(json.dumps({"type": "echo", "received": data}))
    finally:
        with _lock:
            _connected.discard(ws)
