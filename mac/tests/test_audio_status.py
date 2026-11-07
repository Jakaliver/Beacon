"""Regression checks: a silent Mac viewer must not block real iPhone guidance."""
import asyncio
import json
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import WebSocketDisconnect
from beacon import server


class AudioStatusTests(unittest.TestCase):
    def setUp(self):
        self.engine = SimpleNamespace(audio_ok=True, interrupted=False, lock=threading.RLock())
        for name, value in (("engine", self.engine), ("audio_status", {}),
                            ("control_roles", {}), ("control_clients", set())):
            p = patch.object(server, name, value)
            p.start()
            self.addCleanup(p.stop)

    def check(self, expected):
        server.apply_audio_status()
        self.assertEqual((self.engine.audio_ok, self.engine.interrupted), expected)

    def test_muted_viewer_does_not_block_audio(self):
        server.control_roles["browser"] = "viewer"
        server.audio_status["browser"] = (False, True)
        self.check((True, False))

    def test_existing_iphone_ignores_legacy_browser_status(self):
        server.control_roles.update(phone="iphone", browser="sim-app")
        server.audio_status["browser"] = (False, True)
        self.check((True, False))

    def test_browser_audio_cannot_mask_phone_failure(self):
        server.control_roles.update(phone="iphone", browser="sim-app")
        server.audio_status.update(phone=(False, True), browser=(True, False))
        self.check((False, True))

    def test_simulator_status_still_applies_without_phone(self):
        server.control_roles["browser"] = "sim-app"
        server.audio_status["browser"] = (False, False)
        self.check((False, False))

    def test_disconnect_returns_to_remaining_client_status(self):
        server.control_roles.update(phone="iphone", browser="sim-app")
        server.audio_status["browser"] = (False, False)
        self.check((True, False))
        server.control_roles.pop("phone")
        self.check((False, False))

    def test_viewer_handshake_ignores_status_and_cleans_up_on_disconnect(self):
        messages = iter([{"type": "hello", "role": "viewer"},
                         {"type": "client_status", "audio_ok": False, "interrupted": True}])
        class Socket:
            async def accept(self):
                pass
            async def receive_text(self):
                try:
                    return json.dumps(next(messages))
                except StopIteration:
                    raise WebSocketDisconnect()
        seen = []
        async def publish():
            seen.append((self.engine.audio_ok, self.engine.interrupted))
        with patch.object(server, "publish_guidance", publish):
            asyncio.run(server.control(Socket()))
        self.assertEqual(seen, [(True, False), (True, False)])
        self.assertFalse(server.control_roles)
        self.assertFalse(server.audio_status)
        self.assertFalse(server.control_clients)


if __name__ == "__main__":
    unittest.main()
