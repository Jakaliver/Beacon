#!/usr/bin/env bash
set -euo pipefail
VOICE_BUILD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOICE_DIRECTION_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/trident-voice-directions.XXXXXX")"
trap 'rm -rf "$VOICE_DIRECTION_TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$VOICE_DIRECTION_TEST_BUILD/module-cache" \
  "$VOICE_BUILD_ROOT/ios/Trident/Trident/VoiceCommand.swift" \
  "$VOICE_BUILD_ROOT/ios/Trident/VoiceTests/DirectionCommandsMain.swift" \
  -o "$VOICE_DIRECTION_TEST_BUILD/voice-direction-tests"
"$VOICE_DIRECTION_TEST_BUILD/voice-direction-tests"
