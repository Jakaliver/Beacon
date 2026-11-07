#!/usr/bin/env bash
# Starts the Mac backend (port 8787) and the read-only room view (port 5173).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HF_HUB_OFFLINE=1 YOLO_OFFLINE=1 PYTORCH_ENABLE_MPS_FALLBACK=1
(cd "$ROOT/mac" && uv run uvicorn trident.server:app --host 0.0.0.0 --port 8787 --log-level warning) &
BACKEND=$!
trap 'kill $BACKEND 2>/dev/null' EXIT
cd "$ROOT/web" && npx vite --host 0.0.0.0 --port 5173
