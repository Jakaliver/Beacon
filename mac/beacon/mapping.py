"""Rolling ground and height-binned clearance evidence built only from depth.

Missing returns are unknown, not free. An occupied height bin can only be cleared
by two later captures that see through that same height, never by a ray above it.
"""
from collections import deque
import math

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
        self.ground_seen = np.full(shape, -np.inf, np.float64)
        self.heights = c.obstacle_min_h + (np.arange(math.ceil(
            (c.obstacle_max_h - c.obstacle_min_h) / c.height_bin_m)) + 0.5) * c.height_bin_m
        volume = (len(self.heights), *shape)
        self.voxel_hits = np.zeros(volume, bool)
        self.voxel_clear = np.full(volume, -np.inf, np.float64)
        self.voxel_misses = np.zeros(volume, np.uint8)
        self.voxel_observations = np.zeros(volume, np.uint8)
        self.hit_low = np.full(volume, np.inf, np.float32)
        self.hit_high = np.full(volume, -np.inf, np.float32)
        self.observed_t: float | None = None
        self.evidence_floor: float | None = None
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
        for name in ("hits", "floor", "cleared", "top", "last_seen", "ground_seen",
                     "voxel_hits", "voxel_clear", "voxel_misses", "voxel_observations", "hit_low", "hit_high"):
            a = getattr(self, name)
            fill = (np.nan if name == "top" else np.inf if name == "hit_low" else
                    -np.inf if name in {"ground_seen", "voxel_clear", "hit_high"} else 0)
            out = np.full_like(a, fill)
            dz, dx = shift[1], shift[0]
            if abs(dz) < self.n and abs(dx) < self.n:
                src = a[..., max(dz, 0):self.n + min(dz, 0), max(dx, 0):self.n + min(dx, 0)]
                out[..., max(-dz, 0):max(-dz, 0) + src.shape[-2],
                    max(-dx, 0):max(-dx, 0) + src.shape[-1]] = src
            setattr(self, name, out)
        self.origin = self.origin + shift * self.res

    def integrate(self, pts: np.ndarray, cam: np.ndarray, t: float,
                  depth: np.ndarray | None = None, intrinsics=None, T: np.ndarray | None = None) -> None:
        """Publish one capture's geometry. t is capture time in the server clock.

        Optional calibrated depth provides dense visibility tests at volume-cell
        centres. Points alone still support the simulator and geometry regressions.
        """
        floor = self.floor_y
        if floor is None or not np.isfinite(floor) or len(pts) == 0 or not np.isfinite(t):
            return
        if self.evidence_floor is not None and abs(floor - self.evidence_floor) > CONFIG.floor_band:
            # A new height reference cannot reinterpret old bins as clear volume.
            for name in ("hits", "floor", "cleared", "last_seen", "voxel_hits", "voxel_misses", "voxel_observations"):
                getattr(self, name).fill(0)
            self.top.fill(np.nan)
            self.ground_seen.fill(-np.inf)
            self.voxel_clear.fill(-np.inf)
            self.hit_low.fill(np.inf)
            self.hit_high.fill(-np.inf)
            self.observed_t = None
        if self.evidence_floor is None or abs(floor - self.evidence_floor) > CONFIG.floor_band:
            self.evidence_floor = floor
        if self.observed_t is not None and t <= self.observed_t:
            return  # duplicated/out-of-order captures cannot accumulate clearing votes
        self.observed_t = t
        self.recentre(cam[[0, 2]])
        # Monocular depth noise grows with range; far points made false obstacles in testing.
        pts = pts[np.isfinite(pts).all(axis=1) &
                  (np.linalg.norm(pts - cam, axis=1) < CONFIG.map_max_range_m)]
        rel = pts[:, 1] - floor
        pts = pts[rel > -0.2]
        rel = rel[rel > -0.2]
        rows, cols, ok = self.cell(pts[:, [0, 2]])

        is_floor = ok & (np.abs(rel) < CONFIG.floor_band)
        is_obst = ok & (rel > CONFIG.obstacle_min_h) & (rel < CONFIG.obstacle_max_h)
        ground = np.zeros_like(self.floor, bool)
        ground[rows[is_floor], cols[is_floor]] = True
        frame_hits = np.zeros_like(self.voxel_hits)
        bins = np.clip(((rel[is_obst] - CONFIG.obstacle_min_h) / CONFIG.height_bin_m).astype(int),
                       0, len(self.heights) - 1)
        frame_hits[bins, rows[is_obst], cols[is_obst]] = True
        np.minimum.at(self.hit_low, (bins, rows[is_obst], cols[is_obst]), rel[is_obst])
        np.maximum.at(self.hit_high, (bins, rows[is_obst], cols[is_obst]), rel[is_obst])
        np.fmax.at(self.top, (rows[is_obst], cols[is_obst]), rel[is_obst])
        self.last_seen[rows[ok], cols[ok]] = t
        if depth is not None and T is not None:
            crossed, seen_ground, missing_ground = self._visible_volume(depth, intrinsics, T, floor)
            self.floor[missing_ground] = 0
            self.ground_seen[missing_ground] = -np.inf
            ground |= seen_ground
            crossed &= self._occupied_visible(depth, intrinsics, T, floor)
        else:
            crossed, low, high = self._ray_clearance(pts, cam, floor)
            crossed &= (~self.voxel_hits | ((low <= self.hit_low + 1e-5) & (high >= self.hit_high - 1e-5)))
        # A hit always wins over any clear ray from this same capture.
        clear = crossed & ~frame_hits
        self.voxel_misses[~clear] = 0
        self.voxel_misses[clear] = np.minimum(2, self.voxel_misses[clear] + 1)
        self.voxel_hits[self.voxel_misses >= 2] = False
        self.voxel_hits |= frame_hits
        self.hit_low[~self.voxel_hits] = np.inf
        self.hit_high[~self.voxel_hits] = -np.inf
        self.voxel_observations[t - self.voxel_clear > CONFIG.clearance_memory_s] = 0
        self.voxel_observations[clear] = np.minimum(2, self.voxel_observations[clear] + 1)
        self.voxel_observations[frame_hits] = 0
        self.voxel_clear[clear] = t
        self.voxel_clear[frame_hits] = -np.inf
        self.floor[t - self.ground_seen > CONFIG.ground_memory_s] = 0
        self.ground_seen[ground] = t
        self.floor[ground] = np.minimum(20, self.floor[ground] + 1)
        self.cleared = np.sum(np.isfinite(self.voxel_clear), axis=0).astype(np.float32)
        self.hits = self.voxel_hits.any(axis=0).astype(np.float32) * 3
        self.version += 1

    def _ray_clearance(self, pts: np.ndarray, cam: np.ndarray, floor: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        clear = np.zeros_like(self.voxel_hits)
        low = np.full_like(self.hit_low, np.inf)
        high = np.full_like(self.hit_high, -np.inf)
        sub = pts[::max(1, len(pts) // 2500)]
        vec = sub - cam
        dist = np.linalg.norm(vec, axis=1)
        steps = np.arange(0.1, CONFIG.map_max_range_m, self.res / 2)
        samples = cam + (steps[None, :] / np.maximum(dist[:, None], 1e-6))[..., None] * vec[:, None, :]
        height = samples[..., 1] - floor
        keep = (steps[None, :] < dist[:, None] - 0.15) & (height > CONFIG.obstacle_min_h) & (height < CONFIG.obstacle_max_h)
        sample = samples[keep]
        r, c, ok = self.cell(sample[:, [0, 2]])
        b = np.clip(((sample[:, 1] - floor - CONFIG.obstacle_min_h) / CONFIG.height_bin_m).astype(int), 0, len(self.heights) - 1)
        clear[b[ok], r[ok], c[ok]] = True
        np.minimum.at(low, (b[ok], r[ok], c[ok]), sample[ok, 1] - floor)
        np.maximum.at(high, (b[ok], r[ok], c[ok]), sample[ok, 1] - floor)
        return clear, low, high

    def _occupied_visible(self, depth, intrinsics, T, floor) -> np.ndarray:
        """Clearing must see through retained hit heights, not merely a bin centre."""
        allowed = np.ones_like(self.voxel_hits)
        b, r, c = np.nonzero(self.voxel_hits)
        if len(b) == 0:
            return allowed
        xz = self.origin + np.c_[c + .5, r + .5] * self.res
        world = np.stack([np.column_stack([xz[:, 0], floor + self.hit_low[b, r, c], xz[:, 1]]),
                          np.column_stack([xz[:, 0], floor + self.hit_high[b, r, c], xz[:, 1]])])
        pc = (world - T[:3, 3]) @ T[:3, :3]
        d = -pc[..., 2]
        fx, fy, cx, cy = intrinsics
        u = np.rint(fx * pc[..., 0] / np.maximum(d, 1e-6) + cx - .5).astype(int)
        v = np.rint(-fy * pc[..., 1] / np.maximum(d, 1e-6) + cy - .5).astype(int)
        h, w = depth.shape
        valid = (d > .1) & (u >= 1) & (u < w - 1) & (v >= 1) & (v < h - 1)
        nearest = cv2.erode(np.where(np.isfinite(depth) & (depth > .1), depth, 0).astype(np.float32),
                            np.ones((3, 3), np.uint8))
        measured = nearest[np.clip(v, 0, h - 1), np.clip(u, 0, w - 1)]
        allowed[b, r, c] = (valid & (measured > d + CONFIG.depth_uncertainty + self.res)).all(axis=0)
        return allowed

    def _visible_volume(self, depth, intrinsics, T, floor) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Visibility of every height bin, with conservative depth-edge sampling."""
        r, c = np.indices(self.hits.shape)
        x = self.origin[0] + (c + 0.5) * self.res
        z = self.origin[1] + (r + 0.5) * self.res
        levels = np.r_[0.0, self.heights]
        world = np.stack(np.broadcast_arrays(x[None], floor + levels[:, None, None], z[None]), axis=-1)
        pc = (world - T[:3, 3]) @ T[:3, :3]
        d = -pc[..., 2]
        fx, fy, cx, cy = intrinsics
        u = np.rint(fx * pc[..., 0] / np.maximum(d, 1e-6) + cx - 0.5).astype(int)
        v = np.rint(-fy * pc[..., 1] / np.maximum(d, 1e-6) + cy - 0.5).astype(int)
        h, w = depth.shape
        valid = (d > 0.1) & (np.linalg.norm(pc, axis=-1) < CONFIG.map_max_range_m)
        valid &= (u >= 1) & (u < w - 1) & (v >= 1) & (v < h - 1)
        # The nearest return in a 3x3 patch prevents an edge pixel erasing thin geometry.
        safe_depth = np.where(np.isfinite(depth) & (depth > 0.1), depth, 0).astype(np.float32)
        nearest = cv2.erode(safe_depth, np.ones((3, 3), np.uint8))
        measured = nearest[np.clip(v, 0, h - 1), np.clip(u, 0, w - 1)]
        valid &= measured > 0.1
        clear = valid[1:] & (measured[1:] > d[1:] + CONFIG.depth_uncertainty + self.res)
        # A floor return must actually land near this cell and the known floor.
        ratio = measured[0] / np.maximum(d[0], 1e-6)
        actual_y = T[1, 3] + (world[0, ..., 1] - T[1, 3]) * ratio
        lateral_error = np.linalg.norm((world[0][..., [0, 2]] - T[[0, 2], 3]) * (ratio - 1)[..., None], axis=-1)
        ground = valid[0] & (np.abs(actual_y - floor) < CONFIG.floor_band) & (lateral_error < self.res)
        missing_ground = valid[0] & (actual_y < floor - CONFIG.floor_band)
        return clear, ground, missing_ground

    def kernel(self, radius: float | None = None) -> np.ndarray:
        k = int(np.ceil((CONFIG.inflation_m if radius is None else radius) / self.res))
        return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * k + 1, 2 * k + 1))

    def raw_supported(self, now: float, freshness: float | None = None) -> np.ndarray:
        ground_ttl = CONFIG.ground_memory_s if freshness is None else freshness
        clear_ttl = CONFIG.clearance_memory_s if freshness is None else freshness
        return ((self.floor >= 2) & (now - self.ground_seen <= ground_ttl) &
                ((self.voxel_observations >= 2) & (now - self.voxel_clear <= clear_ttl)).all(axis=0)
                & ~self.voxel_hits.any(axis=0))

    def states(self, now: float | None = None, radius: float | None = None) -> np.ndarray:
        now = (self.observed_t or 0.0) if now is None else now
        s = np.full(self.hits.shape, UNKNOWN, np.uint8)
        s[np.isfinite(self.voxel_clear).any(axis=0)] = UNCERTAIN
        supported = self.raw_supported(now)
        kernel = self.kernel(radius)
        # Unknown ground/height coverage also consumes the body footprint; never
        # squeeze a centre line past an unobserved edge or unobserved overhead space.
        full_body = cv2.erode(supported.astype(np.uint8), kernel, borderType=cv2.BORDER_CONSTANT, borderValue=0) > 0
        s[full_body] = FREE
        occupied = self.voxel_hits.any(axis=0)
        inflated = cv2.dilate(occupied.astype(np.uint8), kernel) > 0
        s[inflated & (s != UNKNOWN)] = INFLATED
        s[occupied] = OCCUPIED
        return s

    def corridor(self, start: np.ndarray, end: np.ndarray, now: float, radius: float) -> tuple[str, str | None, float | None]:
        """Check the entire swept footprint, not just the newest frame anywhere."""
        if self.floor_y is None:
            return "unknown", "floor_unknown", None
        edge = int(np.ceil(radius / self.res)) * self.res
        lo, hi = self.origin + edge, self.origin + self.n * self.res - edge
        if np.any(np.minimum(start, end) < lo) or np.any(np.maximum(start, end) >= hi):
            return "unknown", "outside_map", None
        length = float(np.linalg.norm(end - start))
        samples = start + np.linspace(0, 1, max(2, int(length / (self.res / 2)) + 1))[:, None] * (end - start)
        r, c, ok = self.cell(samples)
        if not ok.all():
            return "unknown", "outside_map", None
        centreline = np.zeros_like(self.hits, np.uint8)
        centreline[r, c] = 1
        footprint = cv2.dilate(centreline, self.kernel(radius)) > 0
        occupied = self.voxel_hits.any(axis=0)
        if (footprint & occupied).any():
            rr, cc = np.nonzero(footprint & occupied)
            positions = self.origin + np.c_[cc + 0.5, rr + 0.5] * self.res
            return "blocked", "obstacle", max(0.0, float(np.linalg.norm(positions - start, axis=1).min()) - radius)
        if not self.raw_supported(now, CONFIG.corridor_fresh_s)[footprint].all():
            return "unknown", "corridor_unobserved", None
        return "clear", None, length

    def reachable_approach(self, cell: tuple[int, int], target: np.ndarray, extent: np.ndarray, now: float) -> bool:
        """An approach must also have an observed arm-height line to the object."""
        floor = self.floor_y
        if floor is None or not -CONFIG.floor_band <= target[1] - floor < CONFIG.obstacle_max_h:
            return False
        start = self.centre_of(*cell)
        vector = target[[0, 2]] - start
        length = float(np.linalg.norm(vector))
        stop_short = max(0.15, float(max(extent[0], extent[2])) / 2 + 0.1)
        if length <= stop_short:
            return True
        fractions = np.linspace(0, (length - stop_short) / length,
                                max(2, int(length / (self.res / 2))))
        samples = start + fractions[:, None] * vector
        r, c, ok = self.cell(samples)
        # Floor-level keys/books still have an approach. Check a descending reach
        # segment from hand height, rather than rejecting their low target height.
        # This verifies geometry to the approach, not unmeasured bending/posture.
        hand_y = float(np.clip(target[1], floor + .9, floor + 1.5))
        heights = hand_y + fractions * (target[1] - hand_y)
        b = np.clip(((heights - floor - CONFIG.obstacle_min_h) / CONFIG.height_bin_m).astype(int), 0, len(self.heights) - 1)
        return bool(ok.all() and not self.voxel_hits[b, r, c].any() and
                    (self.voxel_observations[b, r, c] >= 2).all() and
                    (now - self.voxel_clear[b, r, c] <= CONFIG.clearance_memory_s).all())


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
    # Seeing floor points alone does not establish full-height body clearance.
    assert s[r, c] in {UNKNOWN, UNCERTAIN}, s[r, c]
    r, c, _ = m.cell(np.array([0.0, 2.0]))
    assert s[r, c] == UNKNOWN
    print("mapping ok")
