#!/usr/bin/env bash
# Compile production state transitions with fake audio; no simulator or audio device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOICE_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/beacon-voice-lab.XXXXXX")"
trap 'rm -rf "$VOICE_TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$VOICE_TEST_BUILD/module-cache" \
  "$ROOT/ios/Beacon/Beacon/VoiceCommand.swift" \
  "$ROOT/ios/Beacon/Beacon/Settings.swift" \
  "$ROOT/ios/Beacon/VoiceLab/VoiceLabModel.swift" \
  "$ROOT/ios/Beacon/VoiceTests/VoiceLabAudioTestDouble.swift" \
  "$ROOT/ios/Beacon/VoiceTests/VoiceLabDirectionalTests.swift" \
  -o "$VOICE_TEST_BUILD/voice-lab-tests"
"$VOICE_TEST_BUILD/voice-lab-tests"
