#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/trident-torch.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/Trident/Trident/Torch.swift" "$ROOT/ios/Trident/VoiceTests/TorchMain.swift" -o "$BUILD/torch-tests"
"$BUILD/torch-tests"
