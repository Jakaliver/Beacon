#!/usr/bin/env bash
# One-time setup. Needs internet. After this, everything runs offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DA2_COMMIT=a561b849ebae10a6f5ef49e26c83cbbcd36c71bf
DA2_DIR="$ROOT/mac/third_party/Depth-Anything-V2"
if [ ! -d "$DA2_DIR/.git" ]; then
  git clone --quiet https://github.com/DepthAnything/Depth-Anything-V2 "$DA2_DIR"
fi
git -C "$DA2_DIR" checkout --quiet "$DA2_COMMIT"

cd "$ROOT/mac"
uv sync
uv run python -m beacon.setup_models

cd "$ROOT/web"
npm ci

echo "Setup complete. Start with: scripts/dev.sh"
