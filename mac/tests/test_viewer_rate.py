"""Room view feed: high update rates stay cheap because the point cloud is not resent every tick."""
import unittest
from unittest.mock import patch

from trident import server


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


if __name__ == "__main__":
    unittest.main()
