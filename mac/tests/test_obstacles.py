"""Obstacle warnings: only while walking towards something, caution then stop, never about the target."""
import unittest
from types import SimpleNamespace

import numpy as np

from beacon.config import CONFIG
from beacon.engine import Engine, Pose


def pose_at(x, z, yaw=0.0):
    """Camera at (x, 1.2, z) looking along -Z turned by yaw (radians, positive to the right)."""
    T = np.eye(4)
    c, s = np.cos(yaw), np.sin(yaw)
    T[:3, :3] = [[c, 0, -s], [0, 1, 0], [s, 0, c]]
    T[:3, 3] = [x, 1.2, z]
    return T


def phone_z(gap):
    """Phone Z for a body-to-box gap: box cell centre -2.95, near edge -2.90, body 0.3 m behind the phone."""
    return -2.90 + gap - 0.3


class ObstacleTests(unittest.TestCase):
    def setUp(self):
        self.engine = Engine()
        self.engine.mode = "hotcold"
        self.engine.map.arkit_floor = 0.0
        self.box_at(0.0, -3.0)

    def box_at(self, x, z):
        r, c, _ = self.engine.map.cell(np.array([x, z]))
        self.engine.map.hits[r, c] = 5
        self.engine.map.top[r, c] = 0.5

    def walk(self, start_z, end_z, x=0.0, seconds=0.6, steps=10):
        """Feed poses walking in a straight line, then return the obstacle warning."""
        for i, t in enumerate(np.linspace(0, seconds, steps)):
            z = start_z + (end_z - start_z) * i / (steps - 1)
            self.engine._recent_xz.append((100 + t, np.array([x, z])))
        self.engine.pose = Pose(pose_at(x, end_z), 0.0, 1, "normal", None, 100 + seconds)
        return self.engine._obstacle_ahead(None)

    def test_walking_towards_an_obstacle_warns_caution_then_stop(self):
        caution = self.walk(phone_z(1.4), phone_z(1.0))
        self.assertEqual(caution["level"], "caution")
        self.assertAlmostEqual(caution["distance"], 1.0, delta=0.01)
        self.engine._recent_xz.clear()
        stop = self.walk(phone_z(0.8), phone_z(0.4))
        self.assertEqual(stop["level"], "stop")
        np.testing.assert_allclose(stop["position"], [0.05, 0.25, -2.95], atol=0.06)

    def test_standing_still_or_walking_past_does_not_warn(self):
        self.assertIsNone(self.walk(phone_z(0.4), phone_z(0.4)))
        self.engine._recent_xz.clear()
        for i, t in enumerate(np.linspace(0, 0.6, 10)):  # sideways along X, the box is off to the side
            self.engine._recent_xz.append((200 + t, np.array([-0.5 + 0.06 * i, -2.0])))
        self.engine.pose = Pose(pose_at(0.04, -2.0, yaw=np.pi / 2), 0.0, 1, "normal", None, 200.6)
        self.assertIsNone(self.engine._obstacle_ahead(None))

    def test_the_target_and_what_it_rests_on_never_warn(self):
        target = SimpleNamespace(position=np.array([0.0, 0.8, -3.0]), extent=np.array([0.2, 0.3, 0.2]))
        self.walk(phone_z(0.8), phone_z(0.4))
        self.assertIsNone(self.engine._obstacle_ahead(target))

    def test_stop_holds_until_the_gap_opens_past_the_hysteresis(self):
        self.engine.obstacle_level = "stop"
        gap = CONFIG.obstacle_stop_m + CONFIG.obstacle_hysteresis_m / 2
        self.assertEqual(self.walk(phone_z(gap + 0.4), phone_z(gap))["level"], "stop")
        self.engine.obstacle_level = None
        self.assertEqual(self.walk(phone_z(gap + 0.4), phone_z(gap))["level"], "caution")

    def test_probe_mode_never_warns(self):
        self.engine.mode = "probe"
        self.assertIsNone(self.walk(phone_z(0.8), phone_z(0.4)))


if __name__ == "__main__":
    unittest.main()
