#!/usr/bin/env bash
set -euo pipefail
BEACON_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BEACON_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/beacon-pathfinding.XXXXXX")"
trap 'rm -rf "$BEACON_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BEACON_BUILD/module-cache" \
  "$BEACON_ROOT/ios/Beacon/Beacon/PathfindingFeedback.swift" \
  "$BEACON_ROOT/ios/Beacon/Beacon/GuidanceSounds.swift" \
  "$BEACON_ROOT/ios/Beacon/VoiceTests/PathfindingFeedbackTests.swift" \
  -o "$BEACON_BUILD/pathfinding-tests"
"$BEACON_BUILD/pathfinding-tests"
