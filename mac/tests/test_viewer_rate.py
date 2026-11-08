"""Room view feed: high update rates stay cheap because the point cloud is not resent every tick."""
import asyncio
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from beacon import server


class PointCloudRateTests(unittest.TestCase):
    def setUp(self):
        p = patch.object(server, "viewer_points", {"version": None, "new_viewer": False, "sent": 0.0})
        p.start()
        self.addCleanup(p.stop)

    def test_unchanged_point_cloud_is_not_resent(self):
        self.assertTrue(server.wants_points(1, 10.0))
        self.assertFalse(server.wants_points(1, 11.0))

    def test_changed_point_cloud_is_sent_at_most_points_hz(self):
        server.wants_points(1, 10.0)
        self.assertFalse(server.wants_points(2, 10.0 + 0.5 / server.POINTS_HZ))
        self.assertTrue(server.wants_points(2, 10.0 + 1.01 / server.POINTS_HZ))

    def test_a_new_viewer_gets_the_full_cloud_at_once(self):
        server.wants_points(1, 10.0)
        server.viewer_points["new_viewer"] = True
        self.assertTrue(server.wants_points(1, 10.01))
        self.assertFalse(server.wants_points(1, 11.0))


class ViewerPublisherTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.sent = []
        self.built = []
        self.seq = 0
        self.scan_id = "scan-a"
        suite = self

        class Socket:
            async def send_text(self, text):
                suite.sent.append(json.loads(text))

        self.socket = Socket()
        self.engine = SimpleNamespace(surfaces=SimpleNamespace(version=1), phone_snapshot=self.phone_snapshot)
        for name, value in (("engine", self.engine), ("viewer_clients", {self.socket}),
                            ("viewer_points", {"version": None, "new_viewer": True, "sent": 0.0})):
            p = patch.object(server, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(server.CONFIG, "viewer_hz", 5.0)
        p.start()
        self.addCleanup(p.stop)
        self.publisher = server.ViewerPublisher()

    async def asyncTearDown(self):
        pending = self.publisher.pending_snapshot
        if pending is not None:
            pending.cancel()
            try:
                await pending
            except asyncio.CancelledError:
                pass

    def phone_snapshot(self):
        return {"type": "phone_pose", "scan_id": self.scan_id, "epoch": 0,
                "floor_y": None, "phone": {"seq": self.seq, "t": self.seq / 30},
                "stats": {"sensor_connected": True, "pose_age_ms": 0}}

    async def quick_snapshot(self, function, with_points):
        self.built.append(with_points)
        snap = {**self.phone_snapshot(), "type": "recon"}
        return snap, json.dumps(snap)

    async def test_phone_runs_at_30_hz_while_recon_honors_configured_5_hz(self):
        with patch.object(server.asyncio, "to_thread", self.quick_snapshot):
            for step in range(300):
                self.seq = step
                await self.publisher.tick(step / 300)
                await asyncio.sleep(0)
        self.assertEqual(len([m for m in self.sent if m["type"] == "phone_pose"]), 30)
        self.assertEqual(len([m for m in self.sent if m["type"] == "recon"]), 5)
        self.assertEqual(len(self.built), 5)
        self.assertEqual(self.built, [True, False, False, False, False])

    async def test_slow_reconstruction_neither_blocks_phone_updates_nor_queues_more_work(self):
        release = asyncio.Event()

        async def slow_snapshot(function, with_points):
            self.built.append(with_points)
            snap = {**self.phone_snapshot(), "type": "recon"}
            await release.wait()
            return snap, json.dumps(snap)

        with patch.object(server.asyncio, "to_thread", slow_snapshot):
            for step in range(30):
                self.seq = step
                await self.publisher.tick(step / 30)
                await asyncio.sleep(0)
            self.assertEqual(len(self.built), 1)
            self.assertEqual([m["phone"]["seq"] for m in self.sent], list(range(30)))
            release.set()
            await self.publisher.pending_snapshot
            self.seq = 30
            await self.publisher.tick(1.0)
        # An older full snapshot still carries its actual pose sequence, allowing the
        # browser to retain phone seq 30 while applying reconstruction from seq 0.
        self.assertEqual(self.sent[-2]["phone"]["seq"], 30)
        self.assertEqual(self.sent[-1]["type"], "recon")
        self.assertEqual(self.sent[-1]["phone"]["seq"], 0)

    async def test_missed_deadlines_send_only_the_newest_phone_pose(self):
        with patch.object(server.asyncio, "to_thread", self.quick_snapshot):
            await self.publisher.tick(0.0)
            await asyncio.sleep(0)
            self.seq = 99
            await self.publisher.tick(10.0)
        self.assertEqual([m["phone"]["seq"] for m in self.sent if m["type"] == "phone_pose"], [0, 99])

    async def test_completed_snapshot_from_a_reset_scan_is_discarded(self):
        with patch.object(server.asyncio, "to_thread", self.quick_snapshot):
            await self.publisher.tick(0.0)
            await self.publisher.pending_snapshot
            self.scan_id = "scan-b"
            self.seq = 1
            await self.publisher.tick(0.04)
        self.assertFalse(any(m["type"] == "recon" for m in self.sent))
        self.assertEqual(self.sent[-1]["scan_id"], "scan-b")
        self.assertTrue(server.viewer_points["new_viewer"])

    async def test_no_viewers_means_no_snapshot_work(self):
        server.viewer_clients.clear()
        with patch.object(server.asyncio, "to_thread", self.quick_snapshot):
            await self.publisher.tick(0.0)
            await asyncio.sleep(0)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.built, [])

    async def test_a_stalled_viewer_is_closed_without_blocking_other_viewers(self):
        class StalledSocket:
            closed = False

            async def send_text(self, text):
                await asyncio.Event().wait()

            async def close(self, code):
                self.closed = code == 1013

        stalled = StalledSocket()
        server.viewer_clients.add(stalled)
        with patch.object(server, "VIEWER_SEND_TIMEOUT", 0.01):
            await asyncio.wait_for(server.broadcast_viewer(json.dumps(self.phone_snapshot())), timeout=0.2)
        self.assertTrue(stalled.closed)
        self.assertNotIn(stalled, server.viewer_clients)
        self.assertIn(self.socket, server.viewer_clients)
        self.assertEqual(len(self.sent), 1)


if __name__ == "__main__":
    unittest.main()
