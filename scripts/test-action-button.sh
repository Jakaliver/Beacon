#!/usr/bin/env bash
set -euo pipefail
BEACON_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BEACON_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/beacon-action-button.XXXXXX")"
trap 'rm -rf "$BEACON_TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BEACON_TEST_BUILD/module-cache" \
  "$BEACON_TEST_ROOT/ios/Beacon/Beacon/VoiceRequestEndpoint.swift" \
  "$BEACON_TEST_ROOT/ios/Beacon/VoiceTests/VoiceRequestEndpointTests.swift" \
  -o "$BEACON_TEST_BUILD/action-button-tests"
"$BEACON_TEST_BUILD/action-button-tests"
