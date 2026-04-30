#!/usr/bin/env bash
# Run the FastAPI backend natively on the host with hot-reload — Flutter-equivalent dev loop.
# Postgres + MinIO stay in Docker (just data services); FastAPI runs in your shell so
# `--reload` triggers on file save and VSCode breakpoints land natively.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/backend"

# Load production .env from repo root, then override host-pointing values.
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

# Tunneled prod services (ssh -L 5433/9000/9001 → VM). Run scripts/dev-tunnel.sh first.
# DB writes go to PROD — every save can hit real data.
export DATABASE_URL="postgresql+asyncpg://${POSTGRES_USER:-inkspacex}:${POSTGRES_PASSWORD}@localhost:5433/${POSTGRES_DB:-inkspacex}"
export MINIO_ENDPOINT="localhost:9000"
export MINIO_ACCESS_KEY="$MINIO_ROOT_USER"
export MINIO_SECRET_KEY="$MINIO_ROOT_PASSWORD"
export MINIO_BUCKET="${MINIO_BUCKET:-inkspacex}"
export MINIO_USE_SSL="false"
# Public URL stays prod so generated asset links work in the browser (Flutter web pulls them direct).
export MINIO_PUBLIC_URL="https://inkspacex.com/storage"
# Allow Flutter web dev origins.
export CORS_ORIGINS="http://localhost:3000,http://localhost:5174,http://localhost:8080,http://localhost:8081,http://127.0.0.1:8080"

CONDA_PY="$HOME/miniconda3/envs/inkspacex/bin/python"
[[ -x "$CONDA_PY" ]] || { echo "✗ conda env 'inkspacex' missing — run: conda create -n inkspacex python=3.12 -y && conda activate inkspacex && pip install -r backend/requirements.txt"; exit 1; }

# Ensure SSH tunnel to VM is open before launching the app.
if ! nc -z localhost 5433 2>/dev/null; then
  echo "✗ No tunnel on :5433 — start it first: ./scripts/dev-tunnel.sh" >&2
  exit 1
fi
echo "→ Using tunneled prod DB on localhost:5433 (writes hit real data)."

echo "→ FastAPI on http://localhost:8000  (docs: /docs)"
echo "→ Save any file under backend/ to hot-reload."
exec "$CONDA_PY" -m uvicorn app.main:app \
  --host 0.0.0.0 --port 8000 \
  --reload --reload-dir app
