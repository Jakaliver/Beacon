#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/beacon-torch.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/Beacon/Beacon/Torch.swift" "$ROOT/ios/Beacon/VoiceTests/TorchMain.swift" -o "$BUILD/torch-tests"
"$BUILD/torch-tests"
