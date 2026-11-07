#!/usr/bin/env bash
# Test the real coordinator with deterministic listener/speaker doubles; no audio permissions needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOICE_SESSION_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/beacon-voice-session-tests.XXXXXX")"
trap 'rm -rf "$VOICE_SESSION_TEST_BUILD"' EXIT

swiftc -swift-version 5 -parse-as-library -module-cache-path "$VOICE_SESSION_TEST_BUILD/module-cache" \
  "$ROOT/ios/Beacon/Beacon/VoiceCommand.swift" \
  "$ROOT/ios/Beacon/Beacon/VoiceSession.swift" \
  "$ROOT/ios/Beacon/VoiceTests/VoiceSessionTests.swift" \
  -o "$VOICE_SESSION_TEST_BUILD/voice-session-tests"
"$VOICE_SESSION_TEST_BUILD/voice-session-tests"
