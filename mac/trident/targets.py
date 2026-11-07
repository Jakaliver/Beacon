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
    # Locked: the 3D position is fixed; guidance relies on phone tracking only, not on seeing it again.
    locked: bool = False
    observed_now: bool = True
    injected: bool = False
    history: list = field(default_factory=list)

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
    lo, hi = np.percentile(world, 10, axis=0), np.percentile(world, 90, axis=0)
    return Observation(label, np.median(world, axis=0), np.maximum(hi - lo, 0.03), surface,
                       0.05 + 0.1 * med, med)


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
                matched.add(best.id)  # a sighting of the locked target: absorb it, never move it
                continue
            if best is None:
                self._new(obs, now, injected)
                continue
            matched.add(best.id)
            self._fuse(best, obs, now)

        # Negative evidence: a track that should be visible and unoccluded but was not detected.
        h, w = depth.shape
        for t in self.tracks.values():
            if t.id in matched or t.locked:
                continue
            p = project(T, K, t.position)
            if p is None:
                continue
            u, v, d = p
            apparent_px = K[1] * float(max(t.extent)) / d
            # Only count a miss where the detector would reliably see an object of this size.
            # Very close objects are often cropped or blurred and missed by the detector.
            detectable = 25 < apparent_px < 0.6 * min(w, h) and 0.7 < d < 5.0
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
                                 now, injected=injected)

    @staticmethod
    def _fuse(t: Track, obs: Observation, now: float) -> None:
        s_t = t.sigma_at(now)
        wt, wo = 1 / s_t**2, 1 / obs.sigma**2
        pos = (t.position * wt + obs.position * wo) / (wt + wo)
        t.surface = obs.surface + (pos - obs.position)
        t.position = pos
        t.extent = 0.7 * t.extent + 0.3 * obs.extent
        # Repeated views of a biased monocular estimate are not independent: keep a floor.
        t.sigma = max(0.08, 1 / np.sqrt(wt + wo))
        t.last_seen = now
        t.n_obs += 1
        t.misses = 0
        t.observed_now = True

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
    assert obs and abs(obs.position[2] + 1.5) < 0.02, obs
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
    moved = observe("bottle", mask, depth * 1.2, K, T)
    for i in range(20):
        locked.update([moved] if i % 2 else [], empty, K, T, 1.0 + i, False)
    assert track.valid_at(500.0) and np.allclose(track.position, before) and len(locked.tracks) == 1
    print("targets ok")
