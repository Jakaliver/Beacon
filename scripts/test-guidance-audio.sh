#!/usr/bin/env bash
set -euo pipefail
BEACON_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BEACON_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/beacon-guidance-audio.XXXXXX")"
trap 'rm -rf "$BEACON_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BEACON_BUILD/module-cache" \
  "$BEACON_ROOT/ios/Beacon/Beacon/TargetProximity.swift" \
  "$BEACON_ROOT/ios/Beacon/Beacon/GuidanceSounds.swift" \
  "$BEACON_ROOT/ios/Beacon/VoiceTests/GuidanceAudioTests.swift" \
  -o "$BEACON_BUILD/guidance-tests"
"$BEACON_BUILD/guidance-tests" "$@"
