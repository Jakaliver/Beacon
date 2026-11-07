"""Room view feed: high update rates stay cheap because unchanged point clouds are not resent."""
import unittest
from unittest.mock import patch

from trident import server


def snapshot(version):
    return {"type": "recon", "points_version": version, "points": "AAAA", "point_colors": "BBBB", "phone": {}}


class LightSnapshotTests(unittest.TestCase):
    def setUp(self):
        p = patch.object(server, "viewer_points", {"version": None, "new_viewer": False})
        p.start()
        self.addCleanup(p.stop)

    def test_unchanged_point_cloud_is_omitted(self):
        self.assertIn("points", server.lighten(snapshot(1)))
        light = server.lighten(snapshot(1))
        self.assertNotIn("points", light)
        self.assertNotIn("point_colors", light)
        self.assertEqual(light["points_version"], 1)  # the viewer still sees which cloud is current

    def test_changed_point_cloud_is_sent(self):
        server.lighten(snapshot(1))
        self.assertIn("points", server.lighten(snapshot(2)))

    def test_a_new_viewer_gets_the_full_cloud(self):
        server.lighten(snapshot(1))
        server.viewer_points["new_viewer"] = True
        self.assertIn("points", server.lighten(snapshot(1)))
        self.assertNotIn("points", server.lighten(snapshot(1)))


if __name__ == "__main__":
    unittest.main()
