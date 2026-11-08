"""Geometry/lifecycle regressions; no learned models, server, or phone required."""
import math
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import cv2
import numpy as np

from beacon.config import CONFIG
from beacon.engine import Engine, Pose
from beacon.geometry import to_world, unproject
from beacon.mapping import FREE, INFLATED, OCCUPIED, UNKNOWN, UNCERTAIN, GridMap
from beacon.planner import line_clear, plan, walkable_grid
from beacon.speech import parse_command


def camera(position, towards):
    T = np.eye(4)
    f = np.asarray(towards, float) - position
    f /= np.linalg.norm(f)
    right = np.cross(f, [0, 1, 0]); right /= np.linalg.norm(right)
    T[:3, :3] = np.stack([right, np.cross(right, f), -f], axis=1)
    T[:3, 3] = position
    return T


def room_depth(T, boxes=(), floor=0.0):
    """Analytic calibrated camera: floor, ceiling, four walls and optional boxes."""
    h, w = 240, 320
    K = [130.0, 130.0, w / 2, h / 2]
    v, u = np.mgrid[:h, :w]
    rays = np.stack([(u + .5 - K[2]) / K[0], -(v + .5 - K[3]) / K[1], -np.ones_like(u)], -1)
    rays = rays @ T[:3, :3].T
    cam = T[:3, 3]
    distance = np.full((h, w), 20.0)
    with np.errstate(divide='ignore', invalid='ignore'):
        for axis, value in [(0, -3.8), (0, 3.8), (2, -3.8), (2, 3.8), (1, floor), (1, 2.8)]:
            d = (value - cam[axis]) / rays[..., axis]
            distance = np.minimum(distance, np.where(d > .05, d, np.inf))
        for lo, hi in boxes:
            t1, t2 = (np.asarray(lo) - cam) / rays, (np.asarray(hi) - cam) / rays
            near, far = np.min(np.stack([t1, t2]), axis=0).max(axis=-1), np.max(np.stack([t1, t2]), axis=0).min(axis=-1)
            distance = np.minimum(distance, np.where((far >= near) & (near > .05), near, np.inf))
    return distance.astype(np.float32), K


def observe(grid, T, t, boxes=(), floor=0.0):
    depth, K = room_depth(T, boxes, floor)
    pts, _ = unproject(depth, K, step=2)
    grid.integrate(to_world(T, pts), T[:3, 3], t, depth, K, T)


def populated_room(now=100.0, boxes=(), engine=None):
    grid = GridMap(); grid.arkit_floor = 0.0
    if engine is not None:
        engine.map = grid
        engine.frame_meta = {'seq': None, 't': None}
    # A sequence of actual calibrated views, each repeated independently. This
    # exercises projection and fusion, never assigns a FREE cell by hand.
    views = [camera(np.array([x, 1.25, z]), [0, .8, 0])
             for x, z in [(-1.8, 1.8), (1.8, 1.8), (-1.8, -1.8), (1.8, -1.8),
                          (0, 1.8), (0, -1.8), (-1.8, 0), (1.8, 0)]]
    for i, T in enumerate(views):
        for j in range(2):
            capture = now - 2 + i * .2 + j * .05
            if engine is None:
                observe(grid, T, capture, boxes)
            else:
                depth, K = room_depth(T, boxes)
                _, jpeg = cv2.imencode('.jpg', np.zeros((*depth.shape, 3), np.uint8))
                header = {'tracking': 'normal', 'height': depth.shape[0], 'width': depth.shape[1],
                          'intrinsics': K, 'pose': T.T.ravel().tolist(), 'seq': i * 2 + j,
                          't': capture, 'epoch': engine.epoch, 'session': engine.session,
                          'perception': 'injected', 'injected': {'detections': []}}
                engine.process_frame(header, jpeg.tobytes(), depth)
    return grid


class MapSafetyTests(unittest.TestCase):
    def test_positive_evidence_requires_independent_captures(self):
        grid = GridMap(); grid.arkit_floor = 0
        T = camera(np.array([0., 1.25, 1.8]), [0, .8, 0])
        observe(grid, T, 1)
        self.assertFalse(grid.raw_supported(1).any())
        observe(grid, T, 1)
        self.assertEqual(float(grid.floor.max()), 1)
        observe(grid, T, 2)
        self.assertTrue(grid.raw_supported(2).any())

    def test_unknown_floor_and_missing_depth_are_not_walkable(self):
        grid = GridMap()
        T = camera(np.array([0, 1.2, 2.0]), [0, .8, 0])
        observe(grid, T, 1)
        self.assertFalse((grid.states(1) == FREE).any())
        self.assertEqual(grid.corridor(np.zeros(2), np.ones(2), 1, .3)[:2], ('unknown', 'floor_unknown'))

    def test_high_ray_does_not_erase_low_obstacle(self):
        grid = GridMap(); grid.arkit_floor = 0
        cam = np.array([0., 1.4, 0.])
        obstacle = np.array([[0., .1, -1.]])
        grid.integrate(obstacle, cam, 1)
        r, c, _ = grid.cell(np.array([0, -1.]))
        self.assertTrue(grid.voxel_hits[:, r, c].any())
        for t in [2, 3, 4]:
            grid.integrate(np.array([[0, 1.4, -3.]]), cam, t)
        self.assertTrue(grid.voxel_hits[:, r, c].any())

    def test_ray_above_hit_in_same_height_bin_cannot_erase_it(self):
        grid = GridMap(); grid.arkit_floor = 0
        cam = np.array([0., .14, 0.])
        grid.integrate(np.array([[0., .07, -1.]]), cam, 1)
        for t in [2, 3]:
            grid.integrate(np.array([[0., .14, -3.]]), cam, t)
        r, c, _ = grid.cell(np.array([0., -1.]))
        self.assertTrue(grid.voxel_hits[:, r, c].any())

    def test_obstacle_is_immediate_and_same_height_clearing_needs_two_captures(self):
        grid = GridMap(); grid.arkit_floor = 0
        cam = np.array([0., .11, 0.])
        grid.integrate(np.array([[0, .11, -1.]]), cam, 1)
        r, c, _ = grid.cell(np.array([0, -1.]))
        self.assertEqual(grid.states(1)[r, c], OCCUPIED)
        grid.integrate(np.array([[0, .11, -3.]]), cam, 2)
        self.assertTrue(grid.voxel_hits[:, r, c].any())
        grid.integrate(np.array([[0, .11, -3.]]), cam, 2)  # duplicate cannot vote twice
        self.assertTrue(grid.voxel_hits[:, r, c].any())
        grid.integrate(np.array([[0, .11, -3.]]), cam, 3)
        self.assertFalse(grid.voxel_hits[:, r, c].any())

    def test_full_footprint_must_remain_inside_map(self):
        grid = GridMap(); grid.arkit_floor = 0
        self.assertEqual(grid.corridor(np.array([3.5, 0]), np.array([3.5, 0]), 1, .7)[:2],
                         ('unknown', 'outside_map'))

    def test_no_start_escape_or_uncertain_ground(self):
        states = np.full((10, 10), FREE, np.uint8)
        for state in [UNKNOWN, UNCERTAIN, INFLATED, OCCUPIED]:
            states[5, 5] = state
            walk = walkable_grid(states, (5, 5))
            self.assertFalse(walk[5, 5])
            self.assertIsNone(plan(walk, (5, 5), (1., 1.), (1, 2)))

    def test_weighted_route_does_not_smooth_away_cost(self):
        walk = np.ones((15, 15), bool)
        penalty = np.ones_like(walk, float); penalty[5:10, 5:10] = 100
        path = plan(walk, (7, 1), (7.5, 13.5), (0, .2), penalty)
        self.assertTrue(path)
        self.assertTrue(all(penalty[p] == 1 for p in path))

    def test_calibrated_depth_establishes_clear_space_then_it_expires(self):
        grid = populated_room()
        states = grid.states(100)
        self.assertGreater(np.count_nonzero(states == FREE), 100)
        self.assertFalse((grid.states(111) == FREE).any())
        self.assertEqual(grid.corridor(np.array([0., 0]), np.array([0., -.5]), 104, CONFIG.inflation_m)[0], 'unknown')

    def test_appearing_obstacle_blocks_previously_clear_corridor(self):
        grid = populated_room()
        start, end = np.array([0., .5]), np.array([0., -.5])
        self.assertEqual(grid.corridor(start, end, 100, CONFIG.inflation_m)[0], 'clear')
        grid.integrate(np.array([[0., .12, 0.]]), np.array([0., 1.2, 1.5]), 100.1)
        self.assertEqual(grid.corridor(start, end, 100.1, CONFIG.inflation_m)[:2], ('blocked', 'obstacle'))

    def test_floor_reference_change_invalidates_prior_free_evidence(self):
        grid = populated_room()
        self.assertTrue(grid.raw_supported(100).any())
        grid.arkit_floor = .2
        observe(grid, camera(np.array([0., 1.25, 1.8]), [0, .8, 0]), 100.1, floor=.2)
        self.assertFalse(grid.raw_supported(100.1).any())

    def test_visible_drop_removes_ground_support_immediately(self):
        grid = populated_room()
        T = camera(np.array([0., 1.25, 1.8]), [0, .2, 0])
        observe(grid, T, 100.1, floor=-.5)
        r, c, _ = grid.cell(np.array([0., 0.]))
        self.assertFalse(np.isfinite(grid.ground_seen[r, c]))


class EngineSafetyTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.clock = patch('beacon.engine.time.monotonic', return_value=self.now); self.clock.start(); self.addCleanup(self.clock.stop)
        self.engine = Engine(); self.engine.sensor_connected = True
        self.engine.session = 'phone-session'; self.engine.clock_offset = 0
        T = np.eye(4); T[:3, 3] = [0, 1.2, 1.5]
        self.engine.pose = Pose(T, self.now, 20, 'normal', None, self.now)
        self.engine.frame_meta = {'seq': 19, 't': self.now - .1}
        self.engine.audio_yaw_offset = 0

    def target(self, position=(0., .8, -1.5)):
        p = np.array(position)
        t = SimpleNamespace(id='target', position=p, extent=np.array([.1, .1, .1]), label='bottle',
                            surface=p[None], last_seen=self.now, locked=True, misses=0, observed_now=True,
                            injected=True, sigma_at=lambda _: .01, valid_at=lambda _: True)
        self.engine.tracker.tracks[t.id] = t; self.engine.selected = t.id
        return t

    def test_only_exact_new_command_pair(self):
        for text, expected in [('pathfinding on', True), ('Pathfinding off.', False)]:
            self.assertEqual(parse_command(text, set()), {'cmd': 'pathfinding', 'on': expected})
        for text in ['pathfinding', 'enable pathfinding', 'do not turn pathfinding on', 'pathfinding on please', 'find pathfinding on']:
            self.assertNotEqual(parse_command(text, set())['cmd'], 'pathfinding')
        self.assertEqual(parse_command('navigation on', set())['cmd'], 'navigation')
        self.assertEqual(parse_command('find bottle', {'bottle'})['cmd'], 'find')

    def test_toggles_reset_path_without_releasing_pause_and_echo_request(self):
        self.target(); self.engine.mode = 'hotcold'
        self.engine.path = [np.zeros(2)]; self.engine.waypoint = np.zeros(2)
        self.engine.set_navigation(True, 'first')
        self.assertEqual(self.engine.mode, 'walking'); self.assertFalse(self.engine.path)
        self.engine.stop('user', 'Stopped.')
        self.engine.set_navigation(False, 'second'); self.engine.set_navigation(True, 'third')
        self.assertEqual(self.engine.mode, 'stopped'); self.assertEqual(self.engine.stop_reason, 'user')
        self.engine.set_navigation(True, 'fourth')
        g = self.engine.step()
        self.assertEqual(g['navigation_request_id'], 'fourth')
        self.assertEqual(g['source']['session'], 'phone-session')
        self.assertEqual(g['source']['epoch'], self.engine.epoch)

    def test_hand_rotation_does_not_move_body_or_fabricate_floor(self):
        self.engine.set_navigation(True)
        before = self.engine.walking_body()
        self.engine.pose.T[:3, :3] = [[0, 0, 1], [0, 1, 0], [-1, 0, 0]]
        np.testing.assert_allclose(before, self.engine.walking_body())
        self.assertFalse((self.engine.map.floor > 0).any())

    def test_capture_age_not_completion_controls_safety(self):
        self.target(); self.engine.map = populated_room()
        self.engine.set_navigation(True); self.engine.mode = 'walking'
        self.engine.frame_meta['t'] = 95.0; self.engine.last_frame_processed = 100.0
        g = self.engine.step()
        self.assertEqual((g['mode'], g['safety']['state'], g['safety']['reason']), ('stopped', 'unknown', 'stale_capture'))
        self.assertEqual(g['safety']['age_ms'], 5000)
        self.assertFalse(any(m['type'] == 'say' for m in self.engine.drain()))
        self.engine.resume(); self.assertEqual(self.engine.mode, 'stopped')

    def test_fresh_frame_elsewhere_cannot_refresh_old_corridor(self):
        self.target(); self.engine.map = populated_room(now=96)
        self.engine.set_navigation(True); self.engine.mode = 'walking'
        self.engine.frame_meta = {'seq': 21, 't': 99.9}
        g = self.engine.step()
        self.assertEqual(g['safety']['state'], 'unknown')
        self.assertEqual(g['safety']['reason'], 'corridor_unobserved')
        self.assertIsNone(g['waypoint'])

    def test_default_off_preserves_direct_guidance_without_depth(self):
        self.target(); self.engine.mode = 'hotcold'
        g = self.engine.step()
        self.assertFalse(g['navigation']); self.assertEqual(g['mode'], 'hotcold')
        self.assertIsNotNone(g['proximity'])

    def test_clearance_recovery_does_not_resume_until_explicit_resume(self):
        self.target(); self.engine.map = populated_room(now=96)
        self.engine.set_navigation(True); self.engine.mode = 'walking'
        self.engine.pose.T[2, 3] = 1.3
        self.assertEqual(self.engine.step()['mode'], 'stopped')
        self.engine.map = populated_room(); self.engine._last_plan = (0, -1)
        g = self.engine.step()
        self.assertIn(g['safety']['state'], {'clear', 'caution'})
        self.assertEqual(g['mode'], 'stopped'); self.assertIsNone(g['waypoint'])
        self.engine.drain(); self.engine.resume()
        self.assertEqual(self.engine.step()['mode'], 'walking')
        self.assertFalse(any(m['type'] == 'say' for m in self.engine.drain()))

    def test_actual_sideways_motion_is_checked_even_when_waypoint_is_clear(self):
        target = self.target(); self.engine.map = populated_room()
        self.engine.set_navigation(True); self.engine.mode = 'walking'
        self.engine.pose.T[:3, 3] = [0, 1.2, 0]
        # Clear route points north, actual translation heads right into a box.
        self.engine.map.integrate(np.array([[1., .4, 0.]]), np.array([0., 1.2, 0.]), 100.01)
        self.engine._phone_velocity = np.array([.3, 0.]); self.engine._phone_speed = .3
        def route(*_):
            self.engine.waypoint = np.array([0., -1.])
            return {}, None
        with patch.object(self.engine, '_route', side_effect=route):
            self.engine._navigation_assessment(target, 100.1)
        self.assertEqual((self.engine.safety['state'], self.engine.safety['reason']), ('blocked', 'obstacle'))

    def test_obstacle_just_outside_core_corridor_is_caution(self):
        target = self.target(); self.engine.map = populated_room()
        self.engine.set_navigation(True); self.engine.mode = 'probe'
        self.engine.pose.T[:3, 3] = [0, 1.2, 0]
        self.engine.map.integrate(np.array([[.85, .4, 0.]]), np.array([0., 1.2, 0.]), 100.01)
        self.engine._navigation_assessment(target, 100.1, probe=True)
        self.assertEqual((self.engine.safety['state'], self.engine.safety['reason']), ('caution', 'close_obstacle'))

    def test_failed_plan_remains_blocked_during_replan_cache_interval(self):
        target = self.target(); self.engine.map = populated_room()
        self.engine.set_navigation(True)
        self.engine.pose.T[2, 3] = 1.3
        with patch('beacon.engine.plan', return_value=None):
            for moment in [100.0, 100.1, 100.2]:
                self.engine._navigation_assessment(target, moment)
                self.assertEqual(self.engine.safety['state'], 'blocked')
                self.assertEqual(self.engine.safety['reason'], 'route_blocked')
                self.assertFalse(self.engine.path)

    def test_floor_level_object_has_a_geometry_checked_approach(self):
        target = self.target((0., .03, -1.5)); self.engine.map = populated_room()
        self.engine.set_navigation(True); self.engine.pose.T[2, 3] = 1.3
        waypoint, reason = self.engine._route(target, 100)
        self.assertIsNone(reason)
        self.assertIsNotNone(waypoint)
        self.assertTrue(self.engine.path)

    def test_horizon_budgets_corridor_age_even_with_a_just_captured_global_frame(self):
        target = self.target(); self.engine.map = populated_room()
        self.engine.set_navigation(True)
        self.engine.pose.T[:3, 3] = [0, 1.2, 0]
        self.engine.frame_meta['t'] = 100.0
        self.engine._phone_velocity = np.array([.2, 0])
        seen = []
        def corridor(start, end, now, radius):
            seen.append(float(np.linalg.norm(end - start)))
            return 'clear', None, seen[-1]
        def route(*_):
            self.engine.waypoint = np.array([0., -3.])
            return {}, None
        with patch.object(self.engine.map, 'corridor', side_effect=corridor), \
                patch.object(self.engine, '_route', side_effect=route):
            self.engine._navigation_assessment(target, 100.0)
        expected = (CONFIG.corridor_min_m + .5 * (CONFIG.corridor_fresh_s + CONFIG.reaction_time_s)
                    + .5 ** 2 / (2 * CONFIG.stopping_deceleration_mps2))
        self.assertGreaterEqual(min(seen), expected - 1e-6)

    def test_arkit_floor_shift_resets_map_but_keeps_display_cloud(self):
        self.engine.map = populated_room()
        old_map, surfaces = self.engine.map, self.engine.surfaces
        self.engine.path = [np.zeros(2), np.ones(2)]
        self.engine.on_pose({'epoch': self.engine.epoch, 'session': self.engine.session,
                             'pose': self.engine.pose.T.T.ravel().tolist(), 't': 100.01, 'seq': 21,
                             'tracking': 'normal', 'floor_y': .2, 'floor_source': 'arkit'})
        self.assertIsNot(self.engine.map, old_map); self.assertIs(self.engine.surfaces, surfaces)
        self.assertFalse(self.engine.path); self.assertFalse(self.engine.map.raw_supported(100).any())

    def test_depth_published_before_detector_and_stale_detector_cannot_reset_metadata(self):
        e = self.engine
        e.map.arkit_floor = 0.0
        T = camera(np.array([0., 1.2, 2.]), [0, .7, 0])
        depth, K = room_depth(T)
        _, jpeg = cv2.imencode('.jpg', np.zeros((*depth.shape, 3), np.uint8))
        header = {'tracking': 'normal', 'height': depth.shape[0], 'width': depth.shape[1],
                  'intrinsics': K, 'pose': T.T.ravel().tolist(), 'seq': 22, 't': 99.95,
                  'epoch': e.epoch, 'session': e.session}
        seen = []
        def detect(_):
            seen.append((e.frame_meta.copy(), e.map.version))
            return []
        e.perception = SimpleNamespace(depth=lambda _: depth, detect=detect)
        e.process_frame(header, jpeg.tobytes(), None)
        self.assertEqual(seen[0][0], {'seq': 22, 't': 99.95}); self.assertGreater(seen[0][1], 0)

    def test_calibrated_route_around_barrier_progresses_to_reachable_approach(self):
        box = ([-.35, 0., -.25], [.35, 1.2, .25])
        target_box = ([-.05, .75, -2.05], [.05, .85, -1.95])
        self.engine.map = populated_room(boxes=[box, target_box], engine=self.engine)
        target = self.target((0., .8, -2.0))
        self.engine.pose.T[2, 3] = 1.3
        self.engine.set_navigation(True); self.engine.mode = 'walking'
        g = self.engine.step()
        self.assertIn(g['safety']['state'], {'clear', 'caution'}, g['safety'])
        self.assertIsNotNone(g['waypoint'])
        route = [p.copy() for p in self.engine.path]
        self.assertTrue(any(abs(p[0]) > 1.0 for p in route), route)
        walk = walkable_grid(self.engine.map.states(self.now), (0, 0))
        for a, b in zip(route, route[1:]):
            ra, ca, _ = self.engine.map.cell(a); rb, cb, _ = self.engine.map.cell(b)
            self.assertTrue(line_clear(walk, (int(ra), int(ca)), (int(rb), int(cb))))
        self.assertFalse(any(m['type'] == 'say' for m in self.engine.drain()))
        # Progress along the route while depth remains fresh. The endpoint was
        # checked for body clearance and an observed hand-height reach line.
        for endpoint in route[1:]:
            self.engine.pose.T[[0, 2], 3] = endpoint
            self.engine._last_plan = (0.0, -1)
            g = self.engine.step()
            self.assertIn(g['safety']['state'], {'clear', 'caution'}, g['safety'])
        self.assertEqual(g['mode'], 'probe')
        self.assertIsNotNone(g['proximity'])


if __name__ == '__main__':
    unittest.main()
