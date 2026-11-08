"""Touching the target covers the camera; within reach that pauses guidance instead of stopping it."""
import time
import unittest
from unittest.mock import patch

from beacon.config import CONFIG
from beacon.engine import Engine
from test_phone_pose import pose_message


class ProbeTrackingTests(unittest.TestCase):
    def setUp(self):
        self.engine = Engine()
        self.engine.sensor_connected = True
        self.now = time.monotonic()

    def pose(self, tracking, mode):
        msg = pose_message(t=self.now)
        msg["tracking"] = tracking
        with patch("beacon.engine.time.monotonic", return_value=self.now):
            self.engine.on_pose(msg)
            self.engine.mode = mode
            self.engine._check_stops(self.now)

    def test_limited_tracking_within_reach_pauses_then_stops_if_it_lasts(self):
        self.pose("limited", "probe")
        self.assertEqual(self.engine.mode, "probe")
        self.now += CONFIG.probe_limited_tracking_s + 0.1
        self.pose("limited", "probe")
        self.assertEqual((self.engine.mode, self.engine.stop_reason), ("stopped", "tracking_lost"))

    def test_tracking_back_to_normal_restarts_the_allowance(self):
        self.pose("limited", "probe")
        self.now += CONFIG.probe_limited_tracking_s - 1
        self.pose("normal", "probe")
        self.now += 2
        self.pose("limited", "probe")
        self.assertEqual(self.engine.mode, "probe")

    def test_walking_still_stops_at_once(self):
        self.pose("limited", "walking")
        self.assertEqual(self.engine.stop_reason, "tracking_lost")

    def test_tracking_not_available_stops_even_within_reach(self):
        self.pose("not_available", "probe")
        self.assertEqual(self.engine.stop_reason, "tracking_lost")


if __name__ == "__main__":
    unittest.main()
