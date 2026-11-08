"""Target boxes are measured in the camera's view frame and filled in behind the visible face."""
import unittest

import numpy as np

from beacon.targets import blend_yaw, view_box


def face(centre, width, height, yaw):
    """Visible front face of an object, a grid of points, facing a camera at the origin."""
    along = np.array([np.sin(yaw), 0, np.cos(yaw)])
    across = np.array([along[2], 0, -along[0]])
    u, v = np.meshgrid(np.linspace(-width / 2, width / 2, 30), np.linspace(-height / 2, height / 2, 30))
    return np.asarray(centre) + u.reshape(-1, 1) * across + v.reshape(-1, 1) * [0, 1, 0]


TRIM = 27 / 29  # the 5-95 % range of a 30-point grid spans 27 of its 29 steps


class ViewBoxTests(unittest.TestCase):
    def test_a_bottle_box_extends_behind_its_visible_face(self):
        front = face([0, 0, -1], 0.08, 0.25, np.pi)  # camera at origin looks along -Z
        centre, size, _ = view_box("bottle", front, np.zeros(3))
        np.testing.assert_allclose(size, np.array([0.08, 0.25, 0.08]) * TRIM, atol=0.002)
        self.assertAlmostEqual(centre[2], -1 - size[2] / 2, places=3)

    def test_a_door_stays_flat(self):
        front = face([0, 1, -2], 0.9, 2.0, np.pi)
        _, size, _ = view_box("door", front, np.zeros(3))
        self.assertLess(size[2], 0.05)

    def test_the_box_turns_with_an_object_seen_at_an_angle(self):
        yaw = np.pi + 0.6
        front = face(2 * np.array([np.sin(yaw), 0, np.cos(yaw)]), 0.5, 0.5, yaw)
        _, size, box_yaw = view_box("chair", front, np.zeros(3))
        self.assertAlmostEqual((box_yaw - yaw + np.pi) % (2 * np.pi) - np.pi, 0, places=3)
        self.assertAlmostEqual(size[0], 0.5 * TRIM, delta=0.002)  # not inflated by the turn

    def test_yaw_blends_the_short_way_round(self):
        self.assertAlmostEqual(blend_yaw(3.1, -3.1, 0.5), 3.1 + 0.5 * (2 * np.pi - 6.2), places=6)
        self.assertAlmostEqual(blend_yaw(0.0, np.pi, 0.5), 0.0, places=6)  # half a turn is the same box


if __name__ == "__main__":
    unittest.main()
