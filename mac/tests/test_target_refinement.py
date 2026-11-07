import unittest

import numpy as np

from trident.targets import Observation, Tracker


def observation(position, depth):
    centre = np.array(position, dtype=float)
    return Observation("bottle", centre, np.array([0.1, 0.25, 0.1]),
                       centre[None, :] + [[-0.03, 0, 0], [0.03, 0, 0]], 0.05 + 0.1 * depth, depth)


class RefinementTests(unittest.TestCase):
    def setUp(self):
        self.tracker = Tracker()
        self.depth = np.full((480, 640), 5, np.float32)
        self.K = (500, 500, 320, 240)
        self.T = np.eye(4)
        initial = observation([0, 0, -2.5], 2.5)
        for i in range(40):
            self.tracker.update([initial], self.depth, self.K, self.T, i * 0.2, False)
        self.track = next(iter(self.tracker.tracks.values()))
        self.track.locked = True
        self.T[2, 3] = -1

    def test_closer_consistent_views_correct_initial_depth_bias_without_losing_identity(self):
        better = observation([0, 0, -2], 1)
        old_id = self.track.id
        for i in range(8):
            self.tracker.update([better], self.depth, self.K, self.T, 10 + i * 0.2, False)
        self.assertEqual(list(self.tracker.tracks), [old_id])
        self.assertLess(np.linalg.norm(self.track.position - better.position), 0.05)
        np.testing.assert_allclose(self.track.surface.mean(axis=0), self.track.position)
        self.assertTrue(self.track.observed_now)

    def test_a_single_bad_depth_frame_does_not_move_the_target(self):
        before = self.track.position.copy()
        self.tracker.update([observation([0, 0, -1.8], 0.8)], self.depth, self.K, self.T, 10, False)
        np.testing.assert_allclose(self.track.position, before)

    def test_another_bottle_in_a_different_direction_does_not_steal_the_target(self):
        before = self.track.position.copy()
        other = observation([0.9, 0, -2], 1.3)
        for i in range(3):
            self.track.misses = 0  # the old location has not been shown to be empty
            self.tracker.update([other], self.depth, self.K, self.T, 10 + i * 0.2, False)
        np.testing.assert_allclose(self.track.position, before)

    def test_small_refinements_continue_after_the_closest_view(self):
        obs = observation([0, 0, -2.42], 2.5)
        for i in range(12):
            self.tracker.update([obs], self.depth, self.K, self.T, 10 + i * 0.2, False)
        self.assertLess(np.linalg.norm(self.track.position - obs.position), 0.02)

    def test_a_moved_target_follows_when_the_old_place_is_out_of_view(self):
        self.T[0, 3] = 3.0  # the camera now faces away from the old place
        moved = observation([3.5, 0, -2], 1.3)
        for i in range(8):
            self.tracker.update([moved], self.depth, self.K, self.T, 10 + i * 0.25, False)
        self.assertLess(np.linalg.norm(self.track.position - moved.position), 1e-6)
        self.assertTrue(self.track.relocated)

    def test_an_empty_old_place_at_arms_length_counts_as_a_miss(self):
        self.T[2, 3] = -2.0  # 0.5 m from the target, which is no longer there
        self.tracker.update([], self.depth, self.K, self.T, 10, False)
        self.assertEqual(self.track.misses, 1)


if __name__ == "__main__":
    unittest.main()
