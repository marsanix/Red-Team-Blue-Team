# Base image: python:3.12-slim (bukan alpine) - lihat docs/HARDENING.md
# untuk analisis keputusan "image terkecil vs determinisme".
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Jalankan sebagai user non-root (hardening dasar container).
RUN useradd --create-home --uid 1000 appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

USER appuser

EXPOSE 5000
ENTRYPOINT ["sh", "entrypoint.sh"]
