import unittest

from beacon.mapping import GridMap


class FloorSourceTests(unittest.TestCase):
    def test_phone_plane_detection_does_not_accept_a_monocular_tabletop_as_floor(self):
        grid = GridMap()
        grid.floor_samples.extend([-0.4] * 5)
        grid.expect_arkit_floor = True
        self.assertIsNone(grid.floor_y)
        grid.arkit_floor = -1.3
        self.assertEqual(grid.floor_y, -1.3)

    def test_sources_without_arkit_keep_the_existing_floor_estimator(self):
        grid = GridMap()
        grid.floor_samples.extend([-1.2] * 5)
        self.assertEqual(grid.floor_y, -1.2)
