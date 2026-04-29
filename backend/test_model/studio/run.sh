#!/usr/bin/env bash
# Run the local studio. Open http://localhost:8765/ after.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
exec uvicorn studio.server:app --reload --port "${STUDIO_PORT:-8765}"
