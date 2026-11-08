"""Object tracks in world coordinates, estimated from instance masks and metric depth."""
from dataclasses import dataclass, field

import cv2
import numpy as np

from .config import CONFIG
from .geometry import project, to_world, unproject

IGNORED = {"person"}
# COCO splits drink containers inconsistently: a real flask flipped between "cup" and "bottle".
# Track them as one family so a request for either keeps one stable target.
FAMILY = {"cup": "bottle", "vase": "bottle", "wine glass": "bottle"}
# Flat things on a wall: their box keeps the depth that was seen instead of an assumed one.
FLAT = {"door", "window", "light switch", "power outlet", "tv"}


def canonical(label: str) -> str:
    return FAMILY.get(label, label)


@dataclass
class Observation:
    label: str
    position: np.ndarray
    extent: np.ndarray
    surface: np.ndarray
    sigma: float
    depth: float
    yaw: float = 0.0  # box rotation about +Y; extent is [across, up, along] in that frame


@dataclass
class Track:
    id: str
    label: str
    position: np.ndarray
    extent: np.ndarray
    surface: np.ndarray
    sigma: float
    last_seen: float
    n_obs: int = 1
    misses: int = 0
    last_miss: float = 0.0
    # Retain the selected identity offscreen; fresh camera observations still refine its geometry.
    locked: bool = False
    best_depth: float = 99.0  # closest camera distance of any sighting used so far
    relocate: list = field(default_factory=list)  # recent sightings away from a locked target
    observed_now: bool = True
    injected: bool = False
    yaw: float = 0.0
    refinements: list = field(default_factory=list)

    def sigma_at(self, now: float) -> float:
        if self.locked:
            return float(self.sigma)
        return float(self.sigma) + CONFIG.sigma_growth_per_s * max(0.0, now - self.last_seen) + 0.02 * self.misses

    def valid_at(self, now: float) -> bool:
        if self.locked:
            return True
        return bool(self.misses < CONFIG.misses_to_lose and now - self.last_seen < CONFIG.offscreen_max_age_s
                    and self.sigma_at(now) < CONFIG.max_sigma_m)


def observe(label: str, mask: np.ndarray, depth: np.ndarray, K, T: np.ndarray,
            floor_y: float | None = None) -> Observation | None:
    """Robust target estimate from the depth inside an eroded instance mask."""
    m = cv2.erode(mask.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    if m.sum() < 40:
        m = mask
    pts, _ = unproject(depth, K, step=2, mask=m)
    if len(pts) < 15:
        return None
    d = -pts[:, 2]
    med = float(np.median(d))
    keep = np.abs(d - med) < max(0.08, 0.12 * med)  # drop background and edge bleed
    if keep.mean() < 0.35:
        return None
    world = to_world(T, pts[keep])
    cam = T[:3, 3]
    low = float(np.percentile(world[:, 1], 5))
    if floor_y is not None and low < floor_y - 0.03 < cam[1]:
        # Nothing rests below the floor: shrink the depth scale until the object's base is on it.
        s = (cam[1] - floor_y) / (cam[1] - low)
        if s < 0.6:
            return None
        world = cam + (world - cam) * s
        med *= s
    surface = world[np.random.default_rng(0).choice(len(world), min(48, len(world)), replace=False)]
    centre, extent, yaw = view_box(label, world, cam)
    return Observation(label, centre, extent, surface, 0.05 + 0.1 * med, med, yaw)


def view_box(label: str, world: np.ndarray, cam: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    """Box (centre, [across, up, along] size, yaw) from the visible surface, in the camera's view frame.

    The camera sees only an object's front, so the box extends behind it: as deep as it is wide
    (at most 0.6 m), except for flat wall objects. Its centre is then the same from every viewpoint.
    """
    ray = np.median(world, axis=0) - cam
    yaw = float(np.arctan2(ray[0], ray[2]))  # three.js rotation.y that turns local +Z along the view
    along = np.array([np.sin(yaw), 0.0, np.cos(yaw)])
    across = np.array([along[2], 0.0, -along[0]])
    local = np.stack([world @ across, world[:, 1], world @ along], axis=1)
    lo, hi = np.percentile(local, 5, axis=0), np.percentile(local, 95, axis=0)
    size = np.maximum(hi - lo, 0.03)
    if label not in FLAT:
        size[2] = max(size[2], min(size[0], 0.6))
    mid = np.array([(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2] + size[2] / 2])
    centre = mid[0] * across + mid[2] * along
    centre[1] = mid[1]
    return centre, size, yaw


def blend_yaw(a: float, b: float, gain: float) -> float:
    # A box looks the same turned half a turn, so blend across the shorter way modulo pi.
    d = (b - a + np.pi / 2) % np.pi - np.pi / 2
    return float(a + gain * d)


class Tracker:
    def __init__(self) -> None:
        self.tracks: dict[str, Track] = {}
        self.counter: dict[str, int] = {}

    def reset(self) -> None:
        self.tracks.clear()
        self.counter.clear()

    def update(self, observations: list[Observation], depth: np.ndarray, K, T: np.ndarray,
               now: float, injected: bool) -> None:
        matched: set[str] = set()
        for t in self.tracks.values():
            t.observed_now = False
        for obs in observations:
            best, best_d = None, 1e9
            for t in self.tracks.values():
                if t.label != obs.label or t.id in matched:
                    continue
                d = float(np.linalg.norm(t.position - obs.position))
                gate = max(0.35, 2.5 * np.hypot(t.sigma_at(now), obs.sigma))
                if d < gate and d < best_d:
                    best, best_d = t, d
            if best is not None and best.locked:
                matched.add(best.id)
                # Large innovations need repeat evidence, even if they pass association.
                if best_d > max(0.16, 2.5 * best.sigma):
                    self._consider_refinement(best, obs, now)
                else:
                    self._fuse(best, obs, now)
                    best.refinements = []
                best.relocate = []
                continue
            locked = [t for t in self.tracks.values() if t.locked and t.label == obs.label and t.id not in matched]
            if best is None and locked:
                # A closer view can correct a depth bias outside the old 3D gate. Require
                # the same viewing direction and repeated agreement; don't switch to a
                # different bottle merely because it has the same label.
                candidates = [t for t in locked if self._closer_on_same_ray(t, obs, T)]
                if len(candidates) == 1:
                    matched.add(candidates[0].id)
                    self._consider_refinement(candidates[0], obs, now)
                elif len(locked) == 1:
                    self._consider_relocation(locked[0], obs, now)
                continue
            if best is None:
                self._new(obs, now, injected)
                continue
            matched.add(best.id)
            self._fuse(best, obs, now)

        # Negative evidence: a track that should be visible and unoccluded but was not detected.
        h, w = depth.shape
        for t in self.tracks.values():
            if t.id in matched:
                continue
            p = project(T, K, t.position)
            if p is None:
                continue
            u, v, d = p
            apparent_px = K[1] * float(max(t.extent)) / d
            # Only count a miss where the detector would reliably see an object of this size.
            # Very close objects are often cropped or blurred and missed by the detector.
            # The size limit already rejects cropped close-ups, so arm's-length views count too.
            detectable = 25 < apparent_px < 0.6 * min(w, h) and 0.35 < d < 5.0
            if detectable and 0.1 * w < u < 0.9 * w and 0.1 * h < v < 0.9 * h:
                seen = depth[int(v), int(u)]
                if seen > d - 0.3:  # the line of sight reaches the cached position
                    if now - t.last_miss > 0.5:  # a weak detector misses some frames anyway
                        t.misses += 1
                        t.last_miss = now
        self._merge_duplicates()

    def _new(self, obs: Observation, now: float, injected: bool) -> None:
        n = self.counter.get(obs.label, 0) + 1
        self.counter[obs.label] = n
        tid = f"{obs.label.replace(' ', '-')}-{n}"
        self.tracks[tid] = Track(tid, obs.label, obs.position, obs.extent, obs.surface, obs.sigma,
                                 now, injected=injected, best_depth=obs.depth, yaw=obs.yaw)

    @staticmethod
    def _closer_on_same_ray(t: Track, obs: Observation, transform: np.ndarray) -> bool:
        a, b = t.position - transform[:3, 3], obs.position - transform[:3, 3]
        lengths = np.linalg.norm(a) * np.linalg.norm(b)
        return bool(lengths > 0.01 and obs.depth < t.best_depth * 0.85
                    and np.linalg.norm(t.position - obs.position) < 1.2
                    and np.dot(a, b) / lengths > 0.985)

    @staticmethod
    def _consider_refinement(t: Track, obs: Observation, now: float) -> None:
        t.refinements = [(at, o) for at, o in t.refinements
                         if now - at < 1.5 and np.linalg.norm(o.position - obs.position) < max(0.12, obs.sigma)]
        t.refinements.append((now, obs))
        t.refinements = t.refinements[-3:]
        if len(t.refinements) == 3 and now - t.refinements[0][0] >= 0.12:
            # Average the agreeing observations so a single last-frame spike cannot win.
            centre = np.mean([o.position for _, o in t.refinements], axis=0)
            agreed = Observation(obs.label, centre, obs.extent,
                                 obs.surface + centre - obs.position, obs.sigma, obs.depth, obs.yaw)
            Tracker._fuse(t, agreed, now, prefer_new=True)
            t.refinements = []

    @staticmethod
    def _consider_relocation(t: Track, obs: Observation, now: float) -> None:
        """Move a locked target when sightings agree elsewhere and its old place looked empty,
        or, with the old place out of view, when they keep agreeing for 1.5 s."""
        t.relocate = [o for o in t.relocate if now - o[0] < 3.0 and np.linalg.norm(o[1] - obs.position) < 0.2]
        t.relocate.append((now, obs.position))
        steady = len(t.relocate) >= 6 and now - t.relocate[0][0] >= 1.5
        if len(t.relocate) >= 3 and (t.misses >= 2 or steady):
            t.position = np.mean([p for _, p in t.relocate], axis=0)
            t.surface = obs.surface + (t.position - obs.position)
            t.extent = obs.extent.copy()
            t.yaw = obs.yaw
            t.sigma = obs.sigma
            t.best_depth = obs.depth
            t.last_seen = now
            t.misses = 0
            t.relocate = []
            t.observed_now = True
            t.refinements = []

    @staticmethod
    def _fuse(t: Track, obs: Observation, now: float, prefer_new: bool = False) -> None:
        # Monocular observations share bias: old repeated frames must never become
        # so confident that better close-up evidence has almost no effect.
        s_t = np.hypot(t.sigma_at(now), 0.04)
        wt, wo = 1 / s_t**2, 1 / obs.sigma**2
        gain = float(np.clip(wo / (wt + wo), 0.15, 0.6))
        if obs.depth < t.best_depth * 0.85:
            gain = max(gain, 0.65)
        if prefer_new:
            gain = max(gain, 0.8)
        pos = t.position + gain * (obs.position - t.position)
        t.surface = obs.surface + (pos - obs.position)
        t.position = pos
        t.extent = (1 - gain) * t.extent + gain * obs.extent
        t.yaw = blend_yaw(t.yaw, obs.yaw, gain)
        # Repeated views of a biased monocular estimate are not independent: keep a floor.
        t.sigma = max(0.06, 0.6 * obs.sigma, 1 / np.sqrt(wt + wo))
        t.last_seen = now
        t.n_obs += 1
        t.misses = 0
        t.observed_now = True
        t.best_depth = min(t.best_depth, obs.depth)

    def _merge_duplicates(self) -> None:
        ids = sorted(self.tracks, key=lambda i: (not self.tracks[i].locked, -self.tracks[i].n_obs))
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                ta, tb = self.tracks.get(a), self.tracks.get(b)
                if ta and tb and ta.label == tb.label and np.linalg.norm(ta.position - tb.position) < 0.2:
                    del self.tracks[b]

    def confirmed(self, label: str, now: float) -> list[Track]:
        return [t for t in self.tracks.values()
                if t.label == label and t.n_obs >= 3 and t.valid_at(now)]


if __name__ == "__main__":
    # A bottle mask in front of a far wall: background pixels must not pull the estimate.
    K = (500.0, 500.0, 320.0, 240.0)
    T = np.eye(4)
    depth = np.full((480, 640), 5.0, np.float32)
    depth[200:280, 300:340] = 1.5
    mask = np.zeros((480, 640), bool)
    mask[195:285, 295:345] = True  # mask a bit larger than the object
    obs = observe("bottle", mask, depth, K, T)
    # The box centre sits behind the visible face, half the bottle's width deeper.
    assert obs and abs(obs.position[2] + 1.5 + obs.extent[2] / 2) < 0.02, obs
    # 40 x 80 px at 1.5 m is 0.12 x 0.24 m; as deep as it is wide.
    assert abs(obs.extent[0] - 0.12) < 0.025 and abs(obs.extent[1] - 0.24) < 0.04, obs.extent
    assert abs(obs.extent[2] - obs.extent[0]) < 1e-6, obs.extent
    tr = Tracker()
    tr.update([obs], depth, K, T, 0.0, False)
    tr.update([obs], depth, K, T, 0.1, False)
    tr.update([obs], depth, K, T, 0.15, False)
    assert len(tr.confirmed("bottle", 0.2)) == 1
    # The bottle disappears while in view: misses accumulate and the cache becomes invalid.
    empty = np.full((480, 640), 5.0, np.float32)
    for i in range(CONFIG.misses_to_lose):
        tr.update([], empty, K, T, 1.0 + i, False)
    assert not tr.confirmed("bottle", 5.0)
    # A locked target keeps its place and validity without being seen again.
    locked = Tracker()
    for t_ in (0.0, 0.1, 0.2):
        locked.update([obs], depth, K, T, t_, False)
    track = next(iter(locked.tracks.values()))
    track.locked = True
    before = track.position.copy()
    for i in range(20):  # long unseen, many misses: still valid and in place
        locked.update([], empty, K, T, 1.0 + i, False)
    assert track.valid_at(500.0) and np.allclose(track.position, before) and len(locked.tracks) == 1
    track.misses = 0
    # A re-sighting near the lock refines it.
    near = observe("bottle", mask, depth, K, T)
    near.position = track.position + np.array([0.0, 0.0, 0.1])
    locked.update([near], depth, K, T, 600.0, False)
    assert 0.0 < float(np.linalg.norm(track.position - before)) < 0.1, track.position
    # Moved: the old place looks empty and three sightings agree 1 m away -> the lock moves there.
    track.misses = 2
    moved_obs = observe("bottle", mask, depth, K, T)
    moved_obs.position = track.position + np.array([1.0, 0.0, 0.0])
    for i in range(3):
        locked.update([moved_obs], depth, K, T, 601.0 + 0.5 * i, False)
    assert abs(track.position[0] - moved_obs.position[0]) < 1e-6, track.position
    print("targets ok")
