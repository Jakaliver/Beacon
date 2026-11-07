"""Trident engine: reconstruction, target state, guidance modes and stop rules.

One engine serves whichever sensor source is connected (simulator or iPhone).
Server-side times use time.monotonic(); source times are only compared with
other times from the same source.
"""
import math
import os
import threading
import time
from dataclasses import dataclass

import cv2
import numpy as np

from .config import CONFIG
from .geometry import forward, head_local, pose_matrix, to_world, unproject, wrap, yaw_of
from .mapping import UNCERTAIN, GridMap
from .planner import line_clear, plan, ring_cells, walkable_grid
from .speech import parse_command
from .targets import IGNORED, Tracker, canonical, observe

# OpenCV's own thread pool, used from several threads next to PyTorch, deadlocked the vision thread.
cv2.setNumThreads(0)

ACTIVE = {"hotcold", "walking", "probe"}
DEBUG_DIR = os.environ.get("TRIDENT_DEBUG_DIR")  # writes the latest upright frame with detections


@dataclass
class Pose:
    T: np.ndarray
    t: float
    seq: int
    tracking: str
    head_q: list[float] | None
    received: float


def quat_yaw(q: list[float]) -> float:
    x, y, z, w = q
    # Rotate the -Z axis by q and take its heading.
    fx = -(2 * (x * z + w * y))
    fz = -(1 - 2 * (x * x + y * y))
    return yaw_of(np.array([fx, 0.0, fz]))


def upright_turns(T: np.ndarray) -> int:
    """Quarter turns (np.rot90 k) that make the image gravity-upright for the models.

    The iPhone sends its native landscape sensor image whatever the hand orientation,
    and YOLO is not rotation invariant.
    """
    gx, gy, _ = T[:3, :3].T @ np.array([0.0, 1.0, 0.0])  # world up in camera axes
    if abs(gy) >= abs(gx):
        return 0 if gy >= 0 else 2
    return 1 if gx > 0 else 3


def pulse_interval(d: float) -> float:
    c = CONFIG
    s = min(1.0, max(0.0, (d - c.near_m) / (c.far_m - c.near_m)))
    return 0.08 * (1.2 / 0.08) ** s


def describe_direction(az: float) -> str:
    deg = math.degrees(az)
    if abs(deg) < 15:
        return "ahead"
    if abs(deg) > 135:
        return "behind you"
    side = "right" if deg > 0 else "left"
    return f"slightly {side}" if abs(deg) < 45 else f"to your {side}"


class Engine:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.perception = None
        self.labels: set[str] = set()
        self.reset_world(epoch=0)
        self.pose: Pose | None = None
        self.session: str | None = None
        self.mode = "idle"
        self.stop_reason: str | None = None
        self.resume_mode: str | None = None
        self.want_label: str | None = None
        self.want_word: str | None = None  # what the user called it, for speech
        self.selected: str | None = None
        self.choice_ids: list[str] = []
        self.navigation = False
        self.probe_offset = np.zeros(3)
        self.audio_yaw_offset: float | None = None
        self.audio_ok = True
        self.interrupted = False
        self.sensor_connected = False
        self.clock_offset: float | None = None
        self.last_said = ""
        self.outbox: list[dict] = []
        self.smoothed_interval: float | None = None
        self.confirm = False
        self.last_instruction = ("", 0.0)
        self.perception_mode = "real"
        self.stats = {"vision_fps": 0.0, "frame_age_ms": None, "pose_hz": 0.0, "dropped_frames": 0,
                      "depth_ms": 0.0, "detect_ms": 0.0}
        self._last_pose_rx = 0.0
        self._last_frame_done = 0.0

    # World state ---------------------------------------------------------
    def reset_world(self, epoch: int) -> None:
        self.epoch = epoch
        self.map = GridMap()
        self.tracker = Tracker()
        self.path: list[np.ndarray] = []
        self.waypoint: np.ndarray | None = None
        self.listener_anchor: np.ndarray | None = None
        self.frame_meta = {"seq": None, "t": None}
        self.last_frame_processed = 0.0
        self._last_plan = (0.0, -1)

    def say(self, text: str) -> None:
        self.last_said = text
        self.outbox.append({"type": "say", "text": text})

    def cue(self, name: str) -> None:
        self.outbox.append({"type": "cue", "name": name})

    def drain(self) -> list[dict]:
        out, self.outbox = self.outbox, []
        return out

    def stop(self, reason: str, message: str) -> None:
        if self.mode == "stopped" and self.stop_reason == reason:
            return
        if self.mode in ACTIVE or self.mode in {"searching", "choosing"}:
            self.resume_mode = self.mode
        self.mode = "stopped"
        self.stop_reason = reason
        self.smoothed_interval = None
        self.cue("stop")
        self.say(message)

    def check_epoch(self, epoch: int, session: str | None = None) -> None:
        """A new world epoch or a new sensor session invalidates map, targets and route."""
        if session is not None and session != self.session:
            self.session = session
            self.epoch = None
            self.clock_offset = None  # each source has its own clock
        if epoch != self.epoch:
            was_active = self.mode not in {"idle", "stopped"}
            self.reset_world(epoch)
            # The headphone-to-world alignment is relative to the old world's heading.
            self.audio_yaw_offset = None
            self.selected = None
            if was_active:
                self.stop("world_reset", "Tracking was reset. The map is cleared. Scan again, then say resume.")

    # Sensor input ----------------------------------------------------------
    def on_pose(self, msg: dict) -> None:
        with self.lock:
            self.check_epoch(msg["epoch"], msg.get("session"))
            now = time.monotonic()
            offset = now - msg["t"]
            self.clock_offset = offset if self.clock_offset is None else min(self.clock_offset, offset)
            if self._last_pose_rx:
                dt = now - self._last_pose_rx
                self.stats["pose_hz"] = 0.9 * self.stats["pose_hz"] + 0.1 / max(dt, 1e-3)
            self._last_pose_rx = now
            head = msg.get("head")
            self.pose = Pose(pose_matrix(msg["pose"]), msg["t"], msg["seq"], msg["tracking"],
                             head["q"] if head and head.get("available") else None, now)
            # Not in Probe mode: there the hand may reach over furniture the body cannot cross.
            if msg["tracking"] == "normal" and self.map.floor_y is not None and self.mode != "probe":
                self.map.mark_walked(self.walking_body()[[0, 2]], now)
            if msg.get("floor_y") is not None:
                if self.map.arkit_floor is None and self.mode in {"idle", "searching"}:
                    # Geometry integrated before the metric floor was known used an unchecked depth scale.
                    self.reset_world(self.epoch)
                self.map.arkit_floor = float(msg["floor_y"])

    def process_frame(self, header: dict, jpeg: bytes, injected_depth: np.ndarray | None) -> None:
        """Runs in a worker thread. Heavy model calls happen outside the lock."""
        if header["tracking"] != "normal":
            return  # never combine an image with an unreliable pose
        bgr = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
        if bgr is None or bgr.shape[:2] != (header["height"], header["width"]):
            return
        K = header["intrinsics"]
        T = pose_matrix(header["pose"])
        injected = header.get("perception") == "injected"
        t0 = time.monotonic()
        if injected:
            depth = cv2.resize(injected_depth, (bgr.shape[1], bgr.shape[0]), interpolation=cv2.INTER_NEAREST)
            dets = []
            for d in header["injected"]["detections"]:
                m = np.zeros(depth.shape, bool)
                x0, y0, x1, y1 = (int(v) for v in d["bbox"])
                m[y0:y1, x0:x1] = True
                dets.append((d["label"], m))
            run_detect = True
        else:
            k = upright_turns(T)
            upright = np.ascontiguousarray(np.rot90(bgr, k))
            depth = np.ascontiguousarray(np.rot90(self.perception.depth(upright), -k))
            t1 = time.monotonic()
            self.stats["depth_ms"] = 1000 * (t1 - t0)
            run_detect = (header["seq"] % CONFIG.detect_every_n_frames == 0) or self.mode == "searching"
            dets = []
            if run_detect:
                raw = self.perception.detect(upright)
                dets = [(canonical(d.label), np.rot90(d.mask, -k)) for d in raw if d.label not in IGNORED]
                self.stats["detect_ms"] = 1000 * (time.monotonic() - t1)
                if DEBUG_DIR and header["seq"] % 20 == 0:
                    dbg = upright.copy()
                    for d in raw:
                        x0, y0, x1, y1 = (int(v) for v in d.box)
                        cv2.rectangle(dbg, (x0, y0), (x1, y1), (0, 255, 0), 1)
                        cv2.putText(dbg, f"{d.label} {d.conf:.2f}", (x0, y0 - 3), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 0), 1)
                    cv2.imwrite(f"{DEBUG_DIR}/frame.jpg", dbg)

        pts, _ = unproject(depth, K, step=8)
        world = to_world(T, pts)
        cam = T[:3, 3]
        with self.lock:
            if header["epoch"] != self.epoch or header.get("session") != self.session:
                return
            if DEBUG_DIR and header["seq"] % 20 == 0:
                np.savez(f"{DEBUG_DIR}/points_{header['seq'] // 20 % 5}.npz", world=world, cam=cam,
                         floor=np.nan if self.map.floor_y is None else self.map.floor_y)
            world, scale = self.map.check_scale(world, cam)
            self.map.integrate(world, cam, time.monotonic())
            if run_detect:
                depth_scaled = depth * scale
                obs = [o for label, m in dets if (o := observe(label, m, depth_scaled, K, T, self.map.floor_y))]
                if DEBUG_DIR:
                    with open(f"{DEBUG_DIR}/observations.log", "a") as f:
                        for o in obs:
                            f.write(f"{header['seq']} {o.label} d={o.depth:.2f} scale={scale:.2f} "
                                    f"pos={np.round(o.position, 2).tolist()} cam={np.round(cam, 2).tolist()}\n")
                self.tracker.update(obs, depth_scaled, K, T, time.monotonic(), injected)
            done = time.monotonic()
            if self._last_frame_done:
                self.stats["vision_fps"] = 0.8 * self.stats["vision_fps"] + 0.2 / max(done - self._last_frame_done, 1e-3)
            self._last_frame_done = done
            self.last_frame_processed = done
            self.frame_meta = {"seq": header["seq"], "t": header["t"]}
            if self.clock_offset is not None:
                self.stats["frame_age_ms"] = round(1000 * (done - (header["t"] + self.clock_offset)))
            self.perception_mode = "injected" if injected else "real"

    # Commands --------------------------------------------------------------
    def command(self, text: str) -> None:
        with self.lock:
            c = parse_command(text, self.labels)
            self._handle(c)

    def _handle(self, c: dict) -> None:
        cmd = c["cmd"]
        if cmd == "find":
            for t in self.tracker.tracks.values():
                t.locked = False
            self.want_label = canonical(c["label"])
            self.want_word = c["spoken"] or c["label"]
            self.selected = None
            self.choice_ids = []
            self.mode = "searching"
            self.stop_reason = None
            if self.audio_yaw_offset is None:
                self.calibrate(quiet=True)
            self.say(f"Looking for {self.spoken(self.want_label)}. Scan slowly around you.")
        elif cmd == "unsupported":
            self.say(f"Sorry, I can't recognise {c['spoken'] or 'that'}. "
                     "I can find bottles, cups, chairs, sofas, tables and other common objects.")
        elif cmd == "stop":
            self.stop("user", "Stopped.")
        elif cmd == "cancel":
            for t in self.tracker.tracks.values():
                t.locked = False
            self.mode, self.selected, self.want_label, self.stop_reason = "idle", None, None, None
            self.say("Cancelled.")
        elif cmd == "repeat":
            if self.last_said:
                self.outbox.append({"type": "say", "text": self.last_said})
        elif cmd == "inspect":
            self.say(self.inspect())
        elif cmd == "resume":
            self.resume()
        elif cmd == "calibrate":
            self.calibrate(quiet=False)
        elif cmd == "choose":
            self.choose(c["index"])
        elif cmd == "navigation":
            self.navigation = c["on"]
            self.say(f"Route guidance {'on' if c['on'] else 'off'}.")
        else:
            self.say("Say find, then an object. Or stop, cancel, repeat, inspect or resume.")

    def spoken(self, label: str) -> str:
        if label == self.want_label and self.want_word:
            return "the " + self.want_word
        names = {"couch": "sofa", "dining table": "table", "cell phone": "phone"}
        return "the " + names.get(label, label)

    def calibrate(self, quiet: bool) -> None:
        if self.pose is None:
            if not quiet:
                self.say("No phone pose yet.")
            return
        phone_yaw = yaw_of(forward(self.pose.T))
        if self.pose.head_q is not None:
            # Assumes the user faces where the phone points while calibrating.
            self.audio_yaw_offset = wrap(phone_yaw - quat_yaw(self.pose.head_q))
        else:
            self.audio_yaw_offset = 0.0
        if not quiet:
            self.say("Calibrated. Audio forward now matches where the phone points.")

    def choose(self, index: int) -> None:
        if not 1 <= index <= len(self.choice_ids):
            self.say("That number is not one of the choices.")
            return
        self.selected = self.choice_ids[index - 1]
        self.choice_ids = []
        self.start_guidance()

    def start_guidance(self) -> None:
        t = self.tracker.tracks[self.selected]
        t.locked = True
        self.mode = "walking" if self.navigation else "hotcold"
        self.stop_reason = None
        self.listener_anchor = None
        self.path, self.waypoint = [], None
        az, dist = self.relative(t.position)
        self.say(f"Found {self.spoken(t.label)}, about {dist:.1f} metres {describe_direction(az)}."
                 + " Its position is now fixed. Say find again to place it anew."
                + (" Follow the beacon." if self.navigation else " Faster pulses mean closer."))

    def resume(self) -> None:
        if self.audio_yaw_offset is None:
            self.calibrate(quiet=True)
        if self.mode != "stopped":
            self.say("Nothing to resume.")
            return
        problem = self.blocking_problem()
        if problem:
            self.say(f"Cannot resume: {problem}.")
            return
        self.stop_reason = None
        if self.selected and self.selected in self.tracker.tracks:
            self.start_guidance()
        elif self.want_label:
            self.mode = "searching"
            self.say(f"Resumed. Looking for {self.spoken(self.want_label)}.")
        else:
            self.mode = "idle"
            self.say("Resumed.")

    def blocking_problem(self) -> str | None:
        if not self.sensor_connected or self.pose is None:
            return "the phone is not connected"
        now = time.monotonic()
        if now - self.pose.received > CONFIG.pose_timeout_s or (
                self.clock_offset is not None and now - (self.pose.t + self.clock_offset) > CONFIG.max_pose_latency_s):
            return "phone updates are late"
        if self.pose.tracking != "normal":
            return "phone tracking is not ready"
        if not self.audio_ok:
            return "audio output is unavailable"
        if self.interrupted:
            return "the app is interrupted"
        return None

    # Geometry helpers -------------------------------------------------------
    def walking_body(self) -> np.ndarray:
        """While walking the phone is held ahead of the torso: the body is behind it."""
        f = forward(self.pose.T)
        f_xz = np.array([f[0], 0.0, f[2]])
        n = np.linalg.norm(f_xz)
        back = f_xz / n * CONFIG.hand_forward_offset if n > 0.3 else np.zeros(3)
        return self.pose.T[:3, 3] - back

    def body_position(self) -> np.ndarray:
        if self.mode == "probe" and self.listener_anchor is not None:
            return self.listener_anchor
        return self.walking_body()

    def probe_point(self) -> np.ndarray:
        return self.pose.T[:3, 3] + self.pose.T[:3, :3] @ self.probe_offset

    def relative(self, p: np.ndarray) -> tuple[float, float]:
        """Azimuth from phone heading and horizontal distance from the body to p."""
        b = self.body_position()
        v = p - b
        return wrap(yaw_of(v) - yaw_of(forward(self.pose.T))), float(math.hypot(v[0], v[2]))

    def head_azimuth(self, p: np.ndarray) -> float | None:
        if self.pose.head_q is None or self.audio_yaw_offset is None:
            return None
        head_world = quat_yaw(self.pose.head_q) + self.audio_yaw_offset
        return wrap(yaw_of(p - self.body_position()) - head_world)

    def source_in_head(self, p: np.ndarray) -> list[float]:
        """Where a sound at world point p sits relative to the listener's head, for HRTF preview."""
        head = self.body_position() + np.array([0.0, CONFIG.head_above_phone, 0.0])
        v = p - head
        if self.pose.head_q is not None and self.audio_yaw_offset is not None:
            local = head_local(v, self.pose.head_q, self.audio_yaw_offset)
        else:  # no headphone orientation: assume the head faces where the phone points
            local = head_local(v, [0.0, 0.0, 0.0, 1.0], yaw_of(forward(self.pose.T)))
        return local.round(3).tolist()

    def inspect(self) -> str:
        parts = [f"Mode {self.mode}" + (f", stopped because {self.stop_reason.replace('_', ' ')}" if self.stop_reason else "") + "."]
        t = self.tracker.tracks.get(self.selected) if self.selected else None
        if t and self.pose is not None:
            now = time.monotonic()
            az, dist = self.relative(t.position)
            age = now - t.last_seen
            parts.append(f"{self.spoken(t.label).capitalize()} about {dist:.1f} metres {describe_direction(az)}, "
                         + ("position fixed, not re-checked by the camera, " if t.locked else f"last seen {age:.0f} seconds ago, ")
                         + f"uncertainty about {100 * t.sigma_at(now):.0f} centimetres.")
            if self.perception_mode == "injected":
                parts.append("Warning: injected debug perception, not camera inference.")
        elif self.want_label:
            parts.append(f"Still looking for {self.spoken(self.want_label)}.")
        return " ".join(parts)

    # Guidance step (pose rate) -------------------------------------------------
    def step(self) -> dict | None:
        with self.lock:
            if self.pose is None:
                return None
            now = time.monotonic()
            self._check_stops(now)
            self._update_target_state(now)
            target = self.tracker.tracks.get(self.selected) if self.selected else None

            proximity = waypoint = None
            if self.mode in ACTIVE and target is not None:
                self._update_mode(target)
                if self.mode == "walking":
                    waypoint = self._route(target, now)
                else:
                    proximity = self._proximity(target, now)
            elif self.mode != "stopped":
                self.smoothed_interval = None

            listener = self.body_position()
            return {
                "type": "guidance", "mode": self.mode, "stop_reason": self.stop_reason,
                "epoch": self.epoch, "perception": self.perception_mode,
                "source": {"pose_seq": self.pose.seq, "pose_t": self.pose.t,
                           "frame_seq": self.frame_meta["seq"], "frame_t": self.frame_meta["t"]},
                "target": self._target_json(target, now) if target else None,
                "proximity": proximity, "waypoint": waypoint,
                "listener": listener.round(3).tolist(),
                "audio_yaw_offset": self.audio_yaw_offset or 0.0,
                "navigation": self.navigation,
            }

    def _check_stops(self, now: float) -> None:
        if self.mode not in ACTIVE and self.mode not in {"searching", "choosing"}:
            return
        if not self.sensor_connected or now - self.pose.received > CONFIG.pose_timeout_s:
            self.stop("connection", "Stopped. Connection to the phone was lost.")
        elif self.clock_offset is not None and now - (self.pose.t + self.clock_offset) > CONFIG.max_pose_latency_s:
            self.stop("stale", "Stopped. Phone updates are arriving late.")
        elif self.pose.tracking != "normal":
            self.stop("tracking_lost", "Stopped. Phone tracking was lost. Hold still and point at the floor.")
        elif not self.audio_ok:
            self.stop("audio", "Stopped. Audio output is unavailable.")
        elif self.interrupted:
            self.stop("interrupted", "Stopped. The app was interrupted.")
        elif self.mode == "walking" and now - self.last_frame_processed > CONFIG.walking_perception_timeout_s:
            self.stop("stale", "Stopped. Obstacle information is out of date.")

    def _update_target_state(self, now: float) -> None:
        if self.mode == "searching" and self.want_label:
            found = self.tracker.confirmed(self.want_label, now)
            if self.selected and any(t.id == self.selected for t in found):
                self.start_guidance()
            elif not self.selected and len(found) == 1:
                self.selected = found[0].id
                self.start_guidance()
            elif not self.selected and len(found) > 1:
                self.mode = "choosing"
                self.choice_ids = [t.id for t in sorted(found, key=lambda t: self.relative(t.position)[0])]
                options = []
                for i, tid in enumerate(self.choice_ids, 1):
                    az, dist = self.relative(self.tracker.tracks[tid].position)
                    options.append({"index": i, "id": tid,
                                    "description": f"{dist:.1f} metres {describe_direction(az)}"})
                self.outbox.append({"type": "choices", "options": options})
                self.say(f"I see {len(found)} {self.want_word or self.want_label}s. "
                         + ". ".join(f"Number {o['index']}: {o['description']}" for o in options)
                         + ". Say choose and a number.")
            return
        if self.mode in ACTIVE and self.selected:
            t = self.tracker.tracks.get(self.selected)
            if t is None or (not t.locked and t.misses >= CONFIG.misses_to_lose):
                self.mode = "searching"
                self.selected = None
                self.cue("rescan")
                self.say(f"{self.spoken(self.want_label).capitalize()} is not where I expected. Scan to find it again.")
            elif not t.valid_at(now):
                self.mode = "searching"
                self.cue("rescan")
                self.say(f"My estimate of {self.spoken(t.label)} is too old. Point the phone towards it again.")

    def _update_mode(self, target) -> None:
        phone = self.pose.T[:3, 3]
        dh = math.hypot(phone[0] - target.position[0], phone[2] - target.position[2])
        if self.mode == "walking":
            # With routing, probe only at the approach point: being close across a table is not reachable.
            arrived = len(self.path) >= 2 and float(np.linalg.norm(self.path[-1] - self.walking_body()[[0, 2]])) < 0.35
            near = arrived or (dh <= CONFIG.probe_enter and len(self.path) == 2)
        else:
            near = dh <= CONFIG.probe_enter
        if self.mode in {"walking", "hotcold"} and near:
            self.mode = "probe"
            self.listener_anchor = self.walking_body()
            self.path, self.waypoint = [], None
            self.say(f"Stop walking. {self.spoken(target.label).capitalize()} is within reach. "
                     "Move the phone slowly to find it.")
        elif self.mode == "probe":
            drift = math.hypot(phone[0] - self.listener_anchor[0], phone[2] - self.listener_anchor[2])
            if drift > CONFIG.probe_leave and dh > CONFIG.probe_enter:
                self.mode = "walking" if self.navigation else "hotcold"
                self.listener_anchor = None
                self.say("You moved away. Leaving probe mode.")

    def _proximity(self, target, now: float) -> dict:
        d = float(np.min(np.linalg.norm(target.surface - self.probe_point(), axis=1)))
        target_interval = pulse_interval(d)
        # Smooth, and ignore changes under 6% so the rhythm does not jitter.
        if self.smoothed_interval is None:
            self.smoothed_interval = target_interval
        elif abs(target_interval - self.smoothed_interval) / self.smoothed_interval > 0.06:
            self.smoothed_interval += 0.25 * (target_interval - self.smoothed_interval)
        threshold = min(0.4, max(CONFIG.confirm_min_m, 2.0 * target.sigma_at(now)))
        if not self.confirm and d < threshold:
            self.confirm = True
            self.cue("confirm")
        elif self.confirm and d > 1.3 * threshold:
            self.confirm = False
        return {"distance": round(d, 3), "pulse_interval": round(self.smoothed_interval, 3),
                "source_head": self.source_in_head(target.position),
                "confirm": self.confirm, "threshold": round(threshold, 3),
                "azimuth_head": self.head_azimuth(target.position)}

    def _route(self, target, now: float) -> dict | None:
        states = self.map.states()
        phone = self.walking_body()  # route from the body, not the hand-held phone
        r, c, ok = self.map.cell(phone[[0, 2]])
        if not ok:
            return None
        start = (int(r), int(c))
        walk = walkable_grid(states, start)
        stale = now - self._last_plan[0] > 0.5 or self._last_plan[1] != self.map.version
        if self.path:
            # Replan if the next leg is no longer clear (new obstacle, or the user drifted).
            nxt = self.map.cell(self.path[min(1, len(self.path) - 1)])
            if not line_clear(walk, start, (int(nxt[0]), int(nxt[1]))):
                stale = True
        if stale:
            tr, tc, _ = self.map.cell(target.position[[0, 2]])
            off = (target.position[[0, 2]] - self.map.origin) / self.map.res
            size = float(max(target.extent[0], target.extent[2]))
            penalty = np.where(states == UNCERTAIN, 3.0, 1.0)
            cells = plan(walk, start, (off[1], off[0]), ring_cells(size), penalty)
            if cells is None:  # e.g. the target sits deep on a table: accept a farther approach point
                cells = plan(walk, start, (off[1], off[0]), ring_cells(size, slack=0.5), penalty)
            self._last_plan = (now, self.map.version)
            if cells is None:
                self.path, self.waypoint = [], None
                self.stop("route_blocked", "Stopped. I have no safe route yet. "
                          "Scan the floor around you, then say resume.")
                return None
            self.path = [self.map.centre_of(rr, cc) for rr, cc in cells]
            self.path[0] = phone[[0, 2]].copy()
        if len(self.path) < 2:
            return None
        # Look-ahead: farthest path vertex within 2 m that has a clear line from here.
        wp = self.path[1]
        for p in self.path[1:]:
            pr, pc, _ = self.map.cell(p)
            if np.linalg.norm(p - phone[[0, 2]]) > 2.0 or not line_clear(walk, start, (int(pr), int(pc))):
                break
            wp = p
        self.waypoint = wp
        wp3 = np.array([wp[0], phone[1], wp[1]])
        az, dist = self.relative(wp3)
        if abs(az) < math.radians(25):
            instr = "continue"
        elif abs(az) > math.radians(135):
            instr = "turn around"
        else:
            instr = "turn right" if az > 0 else "turn left"
        last, when = self.last_instruction
        if instr != last and now - when > 2.0:
            self.last_instruction = (instr, now)
            self.outbox.append({"type": "say", "text": instr})
        return {"position": wp3.round(3).tolist(), "distance": round(dist, 2),
                "azimuth_phone": round(az, 3), "azimuth_head": self.head_azimuth(wp3),
                "instruction": instr, "source_head": self.source_in_head(wp3),
                "pulse_interval": round(0.25 + 0.95 * abs(az) / math.pi, 3)}

    @staticmethod
    def _target_json(t, now: float) -> dict:
        return {"id": t.id, "label": t.label, "position": t.position.round(3).tolist(),
                "extent": t.extent.round(3).tolist(), "surface": t.surface.round(3).tolist(),
                "sigma": round(t.sigma_at(now), 3), "age": round(now - t.last_seen, 2),
                "valid": t.valid_at(now), "observed_now": t.observed_now, "locked": t.locked, "injected": t.injected}

    # Viewer snapshot -------------------------------------------------------
    def snapshot(self) -> dict:
        import base64
        with self.lock:
            now = time.monotonic()
            states = self.map.states()
            pts = self.map.recent_points().astype(np.float32)
            phone = forward_vec = None
            if self.pose is not None:
                phone = self.pose.T[:3, 3].round(3).tolist()
                forward_vec = forward(self.pose.T).round(3).tolist()
            return {
                "type": "recon", "epoch": self.epoch, "perception": self.perception_mode,
                "mode": self.mode, "stop_reason": self.stop_reason, "navigation": self.navigation,
                "grid": {"origin": self.map.origin.tolist(), "res": self.map.res,
                         "w": self.map.n, "h": self.map.n,
                         "cells": base64.b64encode(states.tobytes()).decode()},
                "floor_y": self.map.floor_y,
                "points": base64.b64encode(pts.tobytes()).decode(),
                "phone": {"position": phone, "forward": forward_vec,
                          "tracking": self.pose.tracking if self.pose else None},
                "listener": self.body_position().round(3).tolist() if self.pose is not None else None,
                "targets": [{"id": t.id, "label": t.label, "position": t.position.round(3).tolist(),
                             "extent": t.extent.round(3).tolist(), "sigma": round(t.sigma_at(now), 3),
                             "age": round(now - t.last_seen, 1), "valid": t.valid_at(now),
                             "selected": t.id == self.selected, "injected": t.injected}
                            for t in self.tracker.tracks.values() if t.valid_at(now) or t.id == self.selected],
                "path": [p.round(3).tolist() for p in self.path] if self.mode == "walking" else [],
                "waypoint": self.waypoint.round(3).tolist() if self.waypoint is not None and self.mode == "walking" else None,
                "stats": {**self.stats,
                          "sensor_connected": self.sensor_connected,
                          "observation_age_ms": round(1000 * (now - self.last_frame_processed))
                          if self.last_frame_processed else None,
                          "pose_age_ms": round(1000 * (now - self.pose.received)) if self.pose else None},
            }
