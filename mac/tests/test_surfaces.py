import unittest
import base64

import numpy as np

from trident.surfaces import SurfaceMap, depth_triangles, plane_snapshot


class SurfaceTests(unittest.TestCase):
    K = (200.0, 200.0, 40.0, 30.0)
    T = np.eye(4)

    def test_wall_is_a_connected_surface_at_the_measured_distance(self):
        mesh = depth_triangles(np.full((60, 80), 2.0, np.float32), self.K, self.T)
        self.assertGreater(len(mesh), 60)
        np.testing.assert_allclose(mesh[:, :, 2], -2)
        moved = self.T.copy()
        moved[:3, 3] = [1, 1.5, 0]
        np.testing.assert_allclose(depth_triangles(np.full((60, 80), 2.0, np.float32), self.K, moved),
                                   mesh + [1, 1.5, 0], atol=1e-6)

    def test_foreground_edges_and_missing_depth_are_not_bridged(self):
        depth = np.full((60, 80), 2.0, np.float32)
        depth[:, 40:] = 4
        depth[20:40, 20:30] = np.nan
        mesh = depth_triangles(depth, self.K, self.T)
        self.assertTrue(np.isfinite(mesh).all())
        self.assertTrue((np.ptp(mesh[:, :, 2], axis=1) < 0.1).all())
        self.assertFalse(((mesh[:, :, 0].min(axis=1) < 0) & (mesh[:, :, 0].max(axis=1) > 0)).any())

    def scan_wall(self, scan, distance=2.0, transform=None, start=0, image=None, frames=2):
        transform = self.T if transform is None else transform
        for frame in range(frames):
            scan.integrate(np.full((60, 80), distance, np.float32), self.K, transform,
                           start + frame * 0.3, image)

    @staticmethod
    def displayed(scan):
        return np.frombuffer(base64.b64decode(scan.payload["points"]), "<f4").reshape(-1, 3)

    def test_a_single_bad_frame_cannot_erase_or_add_persistent_geometry(self):
        scan = SurfaceMap()
        self.scan_wall(scan)
        original = self.displayed(scan).copy()
        self.scan_wall(scan, 2.7, start=1, frames=1)
        np.testing.assert_array_equal(self.displayed(scan), original)
        self.scan_wall(scan, start=2)
        self.scan_wall(scan, start=20)
        np.testing.assert_allclose(scan.points[:, 2], -2)

    def test_three_consistent_free_space_observations_repair_wrong_points(self):
        scan = SurfaceMap()
        self.scan_wall(scan)
        self.scan_wall(scan, 2.5, start=1, frames=2)
        self.assertTrue((self.displayed(scan)[:, 2] > -2.1).any())
        self.scan_wall(scan, 2.5, start=1.6, frames=1)
        np.testing.assert_allclose(self.displayed(scan)[:, 2], -2.5)
        before = len(scan.points)
        self.scan_wall(scan, 2.5, start=3, frames=20)
        self.assertEqual(len(scan.points), before)

    def test_closer_views_repair_initial_depth_overestimates(self):
        scan = SurfaceMap()
        self.scan_wall(scan, 2.5)
        approach = self.T.copy()
        approach[2, 3] = -0.5
        # The true wall is at world Z=-2, now 1.5 m from the phone.
        self.scan_wall(scan, 1.5, approach, start=1, frames=3)
        points = self.displayed(scan)
        centre = (np.abs(points[:, 0]) < 0.25) & (np.abs(points[:, 1]) < 0.2)
        self.assertTrue(centre.any())
        np.testing.assert_allclose(points[centre, 2], -2)
        # Unseen edges outside the closer view remain until revisited.
        self.assertTrue((points[:, 2] < -2.4).any())

    def test_unseen_points_survive_a_turn_and_do_not_age_out(self):
        scan = SurfaceMap()
        self.scan_wall(scan)
        original = self.displayed(scan).copy()
        turn = self.T.copy()
        turn[0, 0] = turn[2, 2] = -1
        self.scan_wall(scan, transform=turn, start=3600)
        points = self.displayed(scan)
        np.testing.assert_array_equal(points[points[:, 2] < 0], original)
        self.assertTrue((points[:, 2] > 0).any())

    def test_foreground_occlusion_does_not_erase_the_wall_behind_it(self):
        scan = SurfaceMap()
        self.scan_wall(scan, 4)
        original = self.displayed(scan).copy()
        self.scan_wall(scan, 2, start=1, frames=12)
        points = self.displayed(scan)
        np.testing.assert_array_equal(points[points[:, 2] < -3], original)
        self.assertTrue((points[:, 2] > -3).any())

    def test_missing_depth_cannot_clear_confirmed_points(self):
        scan = SurfaceMap()
        self.scan_wall(scan)
        original = self.displayed(scan).copy()
        scan.integrate(np.full((60, 80), np.nan, np.float32), self.K, self.T, 100)
        np.testing.assert_array_equal(self.displayed(scan), original)

    def test_repeated_measurements_reduce_depth_jitter(self):
        scan = SurfaceMap()
        self.scan_wall(scan)
        for frame in range(20):
            self.scan_wall(scan, 2 + (0.02 if frame % 2 else -0.02), start=1 + frame * 0.3, frames=1)
        points = self.displayed(scan)
        self.assertLess(np.sqrt(np.mean((points[:, 2] + 2) ** 2)), 0.014)
        self.assertLess(len(points), 300)

    def test_growing_room_respects_the_memory_budget(self):
        scan = SurfaceMap(limit=200)
        for frame in range(12):
            moved = self.T.copy()
            moved[0, 3] = frame * 0.1
            self.scan_wall(scan, transform=moved, start=frame)
            self.assertLessEqual(len(scan.points), 200)
            self.assertLessEqual(scan.payload["count"], 200)
        self.assertGreater(self.displayed(scan)[:, 0].max(), 1)

    def test_plane_validation_rejects_invalid_indices_and_nonfinite_vertices(self):
        plane = {"id": "wall", "kind": "wall", "vertices": [[0, 0, -2], [1, 0, -2], [0, 1, -2]], "indices": [0, 1, 2]}
        self.assertEqual(len(plane_snapshot([plane])), 1)
        self.assertEqual(plane_snapshot([{**plane, "indices": [0, 1, 4]}]), [])
        self.assertEqual(plane_snapshot([{**plane, "vertices": [[0, 0, np.nan]] * 3}]), [])

    def test_point_colours_match_the_camera_pixels_after_world_transformation(self):
        image = np.zeros((60, 80, 3), np.uint8)
        image[:, :, 0] = np.arange(80)[None, :]
        image[:, :, 1] = np.arange(60)[:, None]
        image[:, :, 2] = 220
        transform = self.T.copy()
        transform[:3, 3] = [0.5, 1.2, -0.4]
        scan = SurfaceMap()
        self.scan_wall(scan, transform=transform, image=image)
        points = np.frombuffer(base64.b64decode(scan.payload['points']), '<f4').reshape(-1, 3)
        colors = np.frombuffer(base64.b64decode(scan.payload['colors']), np.uint8).reshape(-1, 3)
        camera = points - transform[:3, 3]
        fx, fy, cx, cy = self.K
        u = np.rint(fx * camera[:, 0] / -camera[:, 2] + cx - 0.5).astype(int)
        v = np.rint(-fy * camera[:, 1] / -camera[:, 2] + cy - 0.5).astype(int)
        np.testing.assert_array_equal(colors, image[v, u, ::-1])
        self.assertGreater(len(points), 0)
        self.assertLessEqual(len(points), 60_000)

    def test_reobserving_refines_colour_without_changing_the_geometry(self):
        scan = SurfaceMap()
        red = np.full((60, 80, 3), [0, 0, 255], np.uint8)
        blue = np.full((60, 80, 3), [255, 0, 0], np.uint8)
        self.scan_wall(scan, image=red)
        original = self.displayed(scan).copy()
        self.scan_wall(scan, start=1, image=blue, frames=20)
        colors = np.frombuffer(base64.b64decode(scan.payload['colors']), np.uint8).reshape(-1, 3)
        self.assertTrue((colors[:, 2] > 220).all())
        self.assertTrue((colors[:, 0] < 35).all())
        np.testing.assert_allclose(self.displayed(scan), original, atol=1e-6)


if __name__ == "__main__":
    unittest.main()
