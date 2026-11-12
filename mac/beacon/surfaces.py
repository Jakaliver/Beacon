"""Persistent display points fused from depth, separate from navigation geometry."""
import base64

import cv2
import numpy as np


def depth_triangles(depth: np.ndarray, intrinsics, transform: np.ndarray, step: int = 8,
                    smooth: np.ndarray | None = None) -> np.ndarray:
    """Connect neighbouring pixels only across short, continuous depth intervals.

    Invalid pixels and foreground/background edges stay open. Never triangulate an
    unordered cloud: that would fill unseen gaps between furniture and walls.
    """
    depth = np.asarray(depth, dtype=np.float32)
    valid = np.isfinite(depth) & (depth > 0.2) & (depth < 6.0)
    if smooth is None:
        smooth = cv2.bilateralFilter(np.where(valid, depth, 0), 5, 0.04, 3)
    h, w = depth.shape
    v, u = np.mgrid[step // 2:h:step, step // 2:w:step]
    if min(u.shape) < 2:
        return np.empty((0, 3, 3), np.float32)
    d = smooth[v, u]
    fx, fy, cx, cy = intrinsics
    camera = np.stack(((u + 0.5 - cx) / fx * d, -(v + 0.5 - cy) / fy * d, -d), axis=-1)
    rows, cols = d.shape
    indices = np.arange(rows * cols).reshape(rows, cols)
    a, b, c, e = (x.ravel() for x in (indices[:-1, :-1], indices[:-1, 1:], indices[1:, :-1], indices[1:, 1:]))
    faces = np.concatenate((np.stack((a, c, b), axis=1), np.stack((b, c, e), axis=1)))
    local = camera.reshape(-1, 3)[faces]
    depths = d.ravel()[faces]
    keep = valid[v, u].ravel()[faces].all(axis=1)
    keep &= np.ptp(depths, axis=1) < 0.06 + depths.min(axis=1) * 0.035
    edges = np.linalg.norm(local - np.roll(local, 1, axis=1), axis=2)
    keep &= edges.max(axis=1) < np.minimum(0.25, 0.04 + depths.mean(axis=1) * 0.07)
    keep &= np.linalg.norm(np.cross(local[:, 1] - local[:, 0], local[:, 2] - local[:, 0]), axis=1) > 1e-6
    world = local[keep] @ transform[:3, :3].T + transform[:3, 3]
    return world.astype(np.float32)


class SurfaceMap:
    """Fuse revisits; retain confirmed points until contradicted, reset or over budget.

    A new sample needs a second sighting before display. Depth disagreements need
    three consistent observations before carving old points. Occluded points and
    points outside the camera view do not age out.
    """
    _fields = ("points", "colors", "weights", "best_range", "hits", "seen",
               "conflicts", "candidate", "candidate_since", "candidate_last")

    def __init__(self, limit: int = 240_000, voxel: float = 0.025):
        self.limit = max(1, limit)
        self.voxel = voxel
        self.points = np.empty((0, 3), np.float32)
        self.colors = np.empty((0, 3), np.float32)
        self.weights = np.empty(0, np.float32)
        self.best_range = np.empty(0, np.float32)
        self.hits = np.empty(0, np.uint8)
        self.seen = np.empty(0, np.float64)
        self.conflicts = np.empty(0, np.uint8)
        self.candidate = np.empty((0, 3), np.float32)
        self.candidate_since = np.empty(0, np.float64)
        self.candidate_last = np.empty(0, np.float64)
        self.version = 0
        self._payload = {"version": 0, "points": "", "colors": "", "count": 0}

    def _unique(self, points):
        """One sample per voxel, using scalar keys instead of sorting XYZ records."""
        if not len(points):
            return np.empty(0, np.int64)
        cells = np.floor(points / self.voxel).astype(np.int64)
        cells -= cells.min(axis=0)
        span = cells.max(axis=0) + 1
        keys = (cells[:, 0] * span[1] + cells[:, 1]) * span[2] + cells[:, 2]
        return np.sort(np.unique(keys, return_index=True)[1])

    def _select(self, indices):
        for name in self._fields:
            setattr(self, name, getattr(self, name)[indices])

    @staticmethod
    def _project(points, intrinsics, transform):
        local = (points - transform[:3, 3]) @ transform[:3, :3]
        z = -local[:, 2]
        fx, fy, cx, cy = intrinsics
        safe_z = np.maximum(z, 0.01)
        u = np.rint(fx * local[:, 0] / safe_z + cx - 0.5).astype(np.int32)
        v = np.rint(-fy * local[:, 1] / safe_z + cy - 0.5).astype(np.int32)
        return local, z, u, v

    def _refine(self, depth, intrinsics, transform, now, bgr):
        if not len(self.points):
            return
        local, z, u, v = self._project(self.points, intrinsics, transform)
        h, w = depth.shape
        inside = (z > 0.2) & (u >= 2) & (u < w - 2) & (v >= 2) & (v < h - 2)
        ids = np.flatnonzero(inside)
        # Neither missing depth nor a foreground silhouette is evidence that the
        # stored wall has moved. Require a continuous patch around the sample.
        valid = np.isfinite(depth) & (depth > 0.2) & (depth < 6.0)
        safe_depth = np.where(valid, depth, 0).astype(np.float32)
        patch = np.ones((5, 5), np.uint8)
        low = cv2.erode(safe_depth, patch)
        high = cv2.dilate(safe_depth, patch)
        observed = safe_depth[v[ids], u[ids]]
        reliable = (low[v[ids], u[ids]] > 0.2) & (
            high[v[ids], u[ids]] - low[v[ids], u[ids]] < 0.04 + observed * 0.025)
        ids, observed = ids[reliable], observed[reliable]
        delta = observed - z[ids]
        tolerance = 0.025 + observed * 0.02
        agrees = np.abs(delta) <= tolerance
        matched = ids[agrees]
        self.conflicts[matched] = 0
        self.seen[matched] = now
        self.hits[matched] = np.minimum(self.hits[matched] + 1, 8)

        # Preserve detail against later blurry, distant views. Bounded confidence
        # still lets good close views continually reduce jitter and refine colour.
        refine = agrees & (z[ids] <= self.best_range[ids] * 1.4 + 0.1)
        good, measured = ids[refine], observed[refine]
        weight = np.clip(4 / np.maximum(measured, 0.2) ** 2, 0.25, 4)
        gain = np.clip(weight / (self.weights[good] + weight), 0.06, 0.45)
        corrected = local[good] * (measured / z[good])[:, None]
        world = corrected @ transform[:3, :3].T + transform[:3, 3]
        self.points[good] += gain[:, None] * (world - self.points[good])
        if bgr is not None:
            self.colors[good] += gain[:, None] * (bgr[v[good], u[good], ::-1] - self.colors[good])
        self.weights[good] = np.minimum(self.weights[good] + weight, 12)
        self.best_range[good] = np.minimum(self.best_range[good], measured)

        # A point in front of a repeatedly observed surface occupies known free
        # space. A point behind a new foreground object may simply be occluded:
        # only repair small behind-surface errors from a materially closer view.
        closer_view = z[ids] < self.best_range[ids] * 0.85
        behind_error = (delta < -tolerance) & closer_view & (-delta < np.minimum(0.6, 0.12 + z[ids] * 0.22))
        contradicts = (delta > tolerance) | behind_error
        bad = ids[contradicts]
        measured = observed[contradicts]
        candidates = local[bad] * (measured / z[bad])[:, None]
        candidates = candidates @ transform[:3, :3].T + transform[:3, 3]
        consistent = ((self.conflicts[bad] > 0) & (now - self.candidate_last[bad] < 2.0)
                      & (np.linalg.norm(candidates - self.candidate[bad], axis=1) < 0.04 + measured * 0.025))
        self.conflicts[bad] = np.where(consistent, np.minimum(self.conflicts[bad] + 1, 3), 1)
        self.candidate_since[bad[~consistent]] = now
        self.candidate[bad] = candidates
        self.candidate_last[bad] = now
        # Occlusion / an intervening good frame breaks a run of contradictions.
        self.conflicts[ids[~contradicts & ~agrees]] = 0
        repair = (self.conflicts[bad] >= 3) & (now - self.candidate_since[bad] >= 0.2)
        keep = np.ones(len(self.points), bool)
        keep[bad[repair]] = False
        # Only never-confirmed samples expire. Established room geometry persists.
        keep &= (self.hits >= 2) | (now - self.seen < 8)
        self._select(keep)

    def integrate(self, depth, intrinsics, transform, now, bgr=None):
        depth = np.asarray(depth, np.float32)
        valid = np.isfinite(depth) & (depth > 0.2) & (depth < 6.0)
        smooth = cv2.bilateralFilter(np.where(valid, depth, 0), 5, 0.04, 3)
        smooth[~valid] = 0
        self._refine(smooth, intrinsics, transform, now, bgr)

        # Denser edge-aware samples fill in detail as the camera moves; they do
        # not bridge missing pixels or create surfaces across depth boundaries.
        fresh = depth_triangles(depth, intrinsics, transform, step=6, smooth=smooth).reshape(-1, 3)
        fresh = fresh[self._unique(fresh)]
        _, ranges, u, v = self._project(fresh, intrinsics, transform)
        rgb = np.full(fresh.shape, 180, np.float32)
        if bgr is not None and len(fresh):
            rgb = bgr[np.clip(v, 0, bgr.shape[0] - 1), np.clip(u, 0, bgr.shape[1] - 1), ::-1].astype(np.float32)
        n = len(fresh)
        values = (fresh, rgb, np.clip(4 / np.maximum(ranges, 0.2) ** 2, 0.25, 4),
                  ranges, np.ones(n, np.uint8), np.full(n, now), np.zeros(n, np.uint8),
                  np.zeros((n, 3), np.float32), np.zeros(n), np.zeros(n))
        for name, value in zip(self._fields, values):
            setattr(self, name, np.concatenate((getattr(self, name), value)))
        # Existing refined samples win over new duplicates. Re-voxelising also
        # merges points that converged after small depth corrections.
        self._select(self._unique(self.points))
        # Stage tentative samples separately: a noisy frame must not evict a
        # confirmed wall. Only newly confirmed geometry competes for its budget.
        confirmed = np.flatnonzero(self.hits >= 2)
        tentative = np.flatnonzero(self.hits < 2)
        tentative_limit = max(1, self.limit // 10)
        if len(confirmed) > self.limit or len(tentative) > tentative_limit:
            def newest(ids, limit):
                if len(ids) <= limit:
                    return ids
                return ids[np.argpartition(self.seen[ids], -limit)[-limit:]]
            self._select(np.sort(np.concatenate((newest(confirmed, self.limit),
                                                 newest(tentative, tentative_limit)))))
        self.version += 1

    @property
    def payload(self) -> dict:
        """Confirmed points as base64, encoded only when a viewer asks for a new version."""
        if self._payload["version"] != self.version:
            confirmed = self.hits >= 2
            points = self.points[confirmed].astype("<f4", copy=False)
            colors = np.clip(np.rint(self.colors[confirmed]), 0, 255).astype(np.uint8)
            self._payload = {"version": self.version, "count": len(points),
                             "points": base64.b64encode(points.tobytes()).decode(),
                             "colors": base64.b64encode(colors.tobytes()).decode()}
        return self._payload


def plane_snapshot(value) -> list[dict]:
    """Validate the bounded, complete ARKit plane snapshot from the phone."""
    result = []
    if not isinstance(value, list):
        return result
    for plane in value[:32]:
        try:
            vertices = np.asarray(plane["vertices"], dtype=np.float32)
            indices = np.asarray(plane["indices"], dtype=np.int32)
            if (vertices.ndim != 2 or vertices.shape[1] != 3 or not 3 <= len(vertices) <= 1024
                    or not np.isfinite(vertices).all() or indices.ndim != 1 or len(indices) % 3
                    or not 3 <= len(indices) <= 6144 or indices.min() < 0 or indices.max() >= len(vertices)):
                continue
            result.append({"id": str(plane["id"]), "kind": str(plane.get("kind", "unknown")),
                           "vertices": vertices.round(4).tolist(), "indices": indices.tolist()})
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
    return result
