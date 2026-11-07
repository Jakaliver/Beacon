#!/usr/bin/env bash
set -euo pipefail
TRIDENT_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIDENT_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/trident-action-button.XXXXXX")"
trap 'rm -rf "$TRIDENT_TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$TRIDENT_TEST_BUILD/module-cache" \
  "$TRIDENT_TEST_ROOT/ios/Trident/Trident/VoiceRequestEndpoint.swift" \
  "$TRIDENT_TEST_ROOT/ios/Trident/VoiceTests/VoiceRequestEndpointTests.swift" \
  -o "$TRIDENT_TEST_BUILD/action-button-tests"
"$TRIDENT_TEST_BUILD/action-button-tests"
