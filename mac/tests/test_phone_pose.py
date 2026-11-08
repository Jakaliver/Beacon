"""Live phone telemetry uses AR poses, independently of reconstruction/model work."""
import threading
import json
import unittest
from unittest.mock import patch

import numpy as np

from beacon.engine import Engine


def pose_message(seq=7, t=12.5, epoch=0, session="phone-a", floor_y=None):
    transform = np.array([[0, -1, 0, 1.23456],
                          [1, 0, 0, 1.5],
                          [0, 0, 1, -2.0],
                          [0, 0, 0, 1.0]])
    return {"type": "pose", "seq": seq, "t": t, "epoch": epoch, "session": session,
            "tracking": "normal", "pose": transform.T.reshape(-1).tolist(),
            "floor_source": "arkit", "floor_y": floor_y}


class PhonePoseTests(unittest.TestCase):
    def setUp(self):
        self.engine = Engine()
        self.engine.sensor_connected = True

    def test_initial_pose_and_unknown_floor_are_null(self):
        snap = self.engine.phone_snapshot()
        self.assertEqual(snap["type"], "phone_pose")
        self.assertIsNone(snap["floor_y"])
        self.assertEqual(snap["phone"], dict.fromkeys(["position", "forward", "up", "tracking", "seq", "t"]))
        self.assertEqual(snap["stats"], {"sensor_connected": True, "pose_age_ms": None})

    def test_phone_orientation_and_ordering_match_full_reconstruction(self):
        self.engine.on_pose(pose_message())
        light = self.engine.phone_snapshot()
        full = self.engine.snapshot(with_points=False)
        self.assertEqual(light["phone"], full["phone"])
        self.assertEqual(light["phone"], {"position": [1.235, 1.5, -2.0], "forward": [0.0, 0.0, -1.0],
                                          "up": [-1.0, 0.0, 0.0], "tracking": "normal", "seq": 7, "t": 12.5})
        self.assertEqual(light["scan_id"], full["scan_id"])
        self.assertIsNone(light["floor_y"])

    def test_lightweight_feed_does_not_access_reconstruction_or_wait_for_its_lock(self):
        self.engine.on_pose(pose_message())
        finished = threading.Event()
        result = []

        def read():
            result.append(self.engine.phone_snapshot())
            finished.set()

        with patch.object(self.engine, "snapshot", side_effect=AssertionError("heavy snapshot called")), \
                patch.object(self.engine.map, "states", side_effect=AssertionError("grid rebuilt")):
            with self.engine.lock:
                worker = threading.Thread(target=read)
                worker.start()
                independent = finished.wait(1)
            worker.join(timeout=1)
        self.assertTrue(independent, "point-cloud/world lock must not block live phone reads")
        self.assertEqual(set(result[0]), {"type", "scan_id", "epoch", "floor_y", "phone", "stats"})

    def test_pose_age_and_connection_status_keep_updating_without_new_sensor_data(self):
        with patch("beacon.engine.time.monotonic", return_value=100.0):
            self.engine.on_pose(pose_message())
        self.engine.sensor_connected = False
        with patch("beacon.engine.time.monotonic", return_value=102.25):
            snap = self.engine.phone_snapshot()
        self.assertEqual(snap["stats"], {"sensor_connected": False, "pose_age_ms": 2250})
        self.assertEqual(snap["phone"]["seq"], 7)

    def test_new_floor_resets_scan_but_preserves_the_current_pose(self):
        self.engine.on_pose(pose_message())
        old = self.engine.phone_snapshot()
        self.engine.on_pose(pose_message(seq=8, t=12.6, floor_y=-0.4))
        new = self.engine.phone_snapshot()
        self.assertNotEqual(new["scan_id"], old["scan_id"])
        self.assertEqual(new["epoch"], old["epoch"])
        self.assertEqual(new["floor_y"], -0.4)
        self.assertEqual(new["phone"]["seq"], 8)
        self.assertEqual(new["phone"]["position"], old["phone"]["position"])

    def test_new_sensor_session_can_restart_sequence_and_clears_the_old_floor(self):
        self.engine.on_pose(pose_message(seq=90, floor_y=-1.0))
        old = self.engine.phone_snapshot()
        self.engine.on_pose(pose_message(seq=1, t=1.0, session="phone-b"))
        new = self.engine.phone_snapshot()
        self.assertNotEqual(new["scan_id"], old["scan_id"])
        self.assertEqual(new["phone"]["seq"], 1)
        self.assertEqual(new["phone"]["t"], 1.0)
        self.assertIsNone(new["floor_y"])

    def test_reset_never_labels_an_old_pose_with_a_new_world(self):
        self.engine.on_pose(pose_message())
        old = self.engine.phone_snapshot()
        self.engine.check_epoch(2, "phone-a")
        new = self.engine.phone_snapshot()
        self.assertNotEqual(new["scan_id"], old["scan_id"])
        self.assertEqual(new["epoch"], 2)
        self.assertIsNone(new["phone"]["position"])
        self.assertIsNone(new["phone"]["seq"])

    def test_vectors_are_finite_or_null_and_returned_lists_do_not_mutate_the_cache(self):
        message = pose_message()
        message["pose"][4] = float("nan")  # camera up vector
        self.engine.on_pose(message)
        snap = self.engine.phone_snapshot()
        self.assertIsNone(snap["phone"]["up"])
        snap["phone"]["position"][0] = 999
        self.assertEqual(self.engine.phone_snapshot()["phone"]["position"][0], 1.235)

    def test_nonfinite_floor_is_unknown_in_both_message_types(self):
        self.engine.on_pose(pose_message(floor_y=float("nan")))
        for snap in [self.engine.phone_snapshot(), self.engine.snapshot(with_points=False)]:
            self.assertIsNone(snap["floor_y"])
            json.dumps(snap, allow_nan=False)


if __name__ == "__main__":
    unittest.main()
