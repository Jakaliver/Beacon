"""Rolling 2.5D occupancy grid built only from depth observations."""
from collections import deque

import cv2
import numpy as np

from .config import CONFIG

UNKNOWN, FREE, OCCUPIED, INFLATED, UNCERTAIN = 0, 1, 2, 3, 4


class GridMap:
    def __init__(self) -> None:
        c = CONFIG
        self.res = c.cell_m
        self.n = int(round(c.map_size_m / c.cell_m))
        self.origin = np.array([-c.map_size_m / 2, -c.map_size_m / 2])  # (x0, z0)
        shape = (self.n, self.n)  # [row = z, col = x]
        self.hits = np.zeros(shape, np.float32)
        self.floor = np.zeros(shape, np.float32)
        self.cleared = np.zeros(shape, np.float32)
        self.top = np.full(shape, np.nan, np.float32)  # highest obstacle point above floor
        self.last_seen = np.zeros(shape, np.float64)
        self.floor_samples: deque[float] = deque(maxlen=60)
        self.arkit_floor: float | None = None
        self.expect_arkit_floor = False
        self.scale = 1.0  # running depth-scale correction
        self.n_scale = 0
        self.version = 0

    @property
    def floor_y(self) -> float | None:
        if self.arkit_floor is not None:
            return self.arkit_floor
        if self.expect_arkit_floor:
            return None
        return float(np.median(self.floor_samples)) if len(self.floor_samples) >= 3 else None

    def cell(self, xz: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        ij = np.floor((xz - self.origin) / self.res).astype(int)
        ok = (ij >= 0).all(axis=-1) & (ij < self.n).all(axis=-1)
        return ij[..., 1], ij[..., 0], ok  # row (z), col (x)

    def centre_of(self, row: int, col: int) -> np.ndarray:
        return self.origin + (np.array([col, row]) + 0.5) * self.res

    @staticmethod
    def frame_floor(pts: np.ndarray) -> float | None:
        """Lowest dense horizontal band of points, if the floor is visible in this frame."""
        y = pts[:, 1]
        bins = np.arange(y.min(), y.min() + 3.0, 0.03)
        if len(bins) < 3:
            return None
        hist, edges = np.histogram(y, bins)
        need = 0.08 * len(y)
        for i, count in enumerate(hist):
            if count >= need:
                f = float(np.median(y[(y >= edges[i]) & (y < edges[i] + 0.06)]))
                return f if np.mean(np.abs(y - f) < 0.05) > 0.12 else None
        return None

    @staticmethod
    def frame_scale(pts: np.ndarray, cam: np.ndarray, floor: float) -> float | None:
        """Depth scale that puts this frame's floor at the known floor height.

        For a point below the camera, s = (cam height above floor) / (its drop below the camera)
        is the scale that would place it on the floor. Objects stand on the floor, so real floor
        points form the low, dense edge of that distribution.
        """
        drop = cam[1] - pts[:, 1]
        below = drop > 0.3
        if below.sum() < 200 or cam[1] - floor < 0.25:
            return None
        s = (cam[1] - floor) / drop[below]
        candidate = float(np.percentile(s, 15))
        on_floor = np.abs(s / candidate - 1) < 0.06
        if on_floor.sum() < 0.2 * len(pts):
            return None
        # A sofa seat or table top is also flat and dense; a floor view covers more area.
        scaled_xz = (cam[[0, 2]] + (pts[below][on_floor][:, [0, 2]] - cam[[0, 2]]) * candidate)
        area = len(np.unique(np.floor(scaled_xz / 0.1).astype(int), axis=0)) * 0.01
        return candidate if area >= 1.0 else None

    def check_scale(self, pts_world: np.ndarray, cam: np.ndarray) -> tuple[np.ndarray, float]:
        """Monocular depth scale check against the floor height. Returns (corrected points, scale).

        Frames that show the floor measure their own scale. Other frames use a running
        estimate, so a frame without visible floor is not left at the raw model scale.
        """
        ref = self.floor_y
        if ref is None:
            f = self.frame_floor(pts_world)
            if f is not None:
                self.floor_samples.append(f)
            return pts_world, 1.0
        scale = self.scale
        s = self.frame_scale(pts_world, cam, ref)
        if s is not None:
            # No agreement check with the running scale: monocular scale really changes per view.
            if 0.4 < s < 2.5:
                scale = s
                self.scale = s if self.n_scale == 0 else 0.8 * self.scale + 0.2 * s
                self.n_scale += 1
                if self.arkit_floor is None:
                    f = self.frame_floor(cam + (pts_world - cam) * s)
                    if f is not None:
                        self.floor_samples.append(f)
        if abs(scale - 1) > 0.01:
            pts_world = cam + (pts_world - cam) * scale
        return pts_world, scale

    def recentre(self, xz: np.ndarray) -> None:
        margin = 2.0
        centre = self.origin + self.n * self.res / 2
        if np.all(np.abs(xz - centre) < self.n * self.res / 2 - margin):
            return
        shift = np.round((xz - centre) / self.res).astype(int)  # (dx, dz) in cells
        for name in ("hits", "floor", "cleared", "top", "last_seen"):
            a = getattr(self, name)
            fill = np.nan if name == "top" else 0
            out = np.full_like(a, fill)
            dz, dx = shift[1], shift[0]
            src = a[max(dz, 0):self.n + min(dz, 0), max(dx, 0):self.n + min(dx, 0)]
            out[max(-dz, 0):max(-dz, 0) + src.shape[0], max(-dx, 0):max(-dx, 0) + src.shape[1]] = src
            setattr(self, name, out)
        self.origin = self.origin + shift * self.res

    def integrate(self, pts: np.ndarray, cam: np.ndarray, t: float) -> None:
        floor = self.floor_y
        if floor is None or len(pts) == 0:
            return
        self.recentre(cam[[0, 2]])
        # Monocular depth noise grows with range; far points made false obstacles in testing.
        pts = pts[np.linalg.norm(pts - cam, axis=1) < CONFIG.map_max_range_m]
        rel = pts[:, 1] - floor
        pts = pts[rel > -0.2]
        rel = rel[rel > -0.2]
        rows, cols, ok = self.cell(pts[:, [0, 2]])

        is_floor = ok & (np.abs(rel) < CONFIG.floor_band)
        is_obst = ok & (rel > CONFIG.obstacle_min_h) & (rel < CONFIG.obstacle_max_h)
        np.add.at(self.floor, (rows[is_floor], cols[is_floor]), 1.0)
        frame_hits = np.zeros_like(self.hits)
        np.add.at(frame_hits, (rows[is_obst], cols[is_obst]), 1.0)
        # Counters move at most a few steps per frame, so one frame cannot create or erase an obstacle.
        self.hits = np.minimum(20.0, self.hits + np.minimum(frame_hits, 3.0))
        np.fmax.at(self.top, (rows[is_obst], cols[is_obst]), rel[is_obst])
        self.last_seen[rows[ok], cols[ok]] = t

        # Free-space carving: obstacle-band samples along each camera ray before the hit.
        sub = pts[:: max(1, len(pts) // 1500)]
        vec = sub - cam
        dist = np.linalg.norm(vec, axis=1)
        # Samples beyond the farthest retained hit always fail `valid` below.
        # Avoid allocating/projecting those rays (most are outside our 4 m map range).
        steps = np.arange(0.2, max(0.2, float(dist.max()) - 0.2) if len(dist) else 0.2, self.res)
        frac = steps[None, :] / np.maximum(dist[:, None], 1e-6)
        valid = steps[None, :] < dist[:, None] - 0.2
        samples = cam + frac[..., None] * vec[:, None, :]
        srel = samples[..., 1] - floor
        keep = valid & (srel > CONFIG.obstacle_min_h) & (srel < CONFIG.obstacle_max_h)
        r, c, ok2 = self.cell(samples[keep][:, [0, 2]])
        np.add.at(self.cleared, (r[ok2], c[ok2]), 1.0)
        crossed = np.zeros_like(self.hits)
        np.add.at(crossed, (r[ok2], c[ok2]), 1.0)
        self.hits = np.maximum(0, self.hits - np.minimum(crossed, 1.0) * (frame_hits == 0))

        self.version += 1

    def mark_walked(self, xz: np.ndarray, t: float) -> None:
        """The user stood here, so the floor under the body proxy is traversable."""
        rows, cols, ok = self.cell(xz[None, :] + np.array([[0, 0], [0.1, 0], [-0.1, 0], [0, 0.1], [0, -0.1]]))
        self.floor[rows[ok], cols[ok]] = np.maximum(self.floor[rows[ok], cols[ok]], 2)
        self.last_seen[rows[ok], cols[ok]] = t

    def states(self) -> np.ndarray:
        s = np.full(self.hits.shape, UNKNOWN, np.uint8)
        s[self.cleared >= 2] = UNCERTAIN
        s[self.floor >= 2] = FREE
        occupied = self.hits >= 3
        k = int(np.ceil(CONFIG.inflation_m / self.res))
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * k + 1, 2 * k + 1))
        inflated = cv2.dilate(occupied.astype(np.uint8), kernel) > 0
        s[inflated & (s != UNKNOWN)] = INFLATED
        s[occupied] = OCCUPIED
        return s


if __name__ == "__main__":
    # Synthetic scene: camera 1.4 m above a floor at y=0, a 0.5 m box at x=0, z=-2.
    m = GridMap()
    cam = np.array([0.0, 1.4, 0.0])
    rng = np.random.default_rng(0)
    floor_pts = np.c_[rng.uniform(-1.5, 1.5, 3000), np.zeros(3000), rng.uniform(-3, -0.5, 3000)]
    box = np.c_[rng.uniform(-0.25, 0.25, 800), rng.uniform(0, 0.5, 800), np.full(800, -1.75)]
    pts = np.r_[floor_pts, box]
    for i in range(4):
        out = m.check_scale(pts, cam)
        m.integrate(out[0], cam, float(i))
    assert abs(m.floor_y) < 0.03, m.floor_y
    # Same scene at 0.8x scale is corrected back.
    scaled = cam + (pts - cam) * 0.8
    fixed, scale = m.check_scale(scaled, cam)
    assert abs(scale - 1.25) < 0.05, scale
    s = m.states()
    r, c, _ = m.cell(np.array([0.0, -1.75]))
    assert s[r, c] == OCCUPIED
    r, c, _ = m.cell(np.array([1.2, -1.0]))
    assert s[r, c] == FREE, s[r, c]
    r, c, _ = m.cell(np.array([0.0, 2.0]))
    assert s[r, c] == UNKNOWN
    print("mapping ok")
