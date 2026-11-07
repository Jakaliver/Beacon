import numpy as np


def pose_matrix(flat: list[float]) -> np.ndarray:
    """Protocol poses are column-major 4x4 camera-to-world."""
    return np.asarray(flat, dtype=np.float64).reshape(4, 4).T


def unproject(depth: np.ndarray, intrinsics, step: int = 4, mask: np.ndarray | None = None,
              dmin: float = 0.1, dmax: float = 15.0) -> tuple[np.ndarray, np.ndarray]:
    """Valid pixels → camera-frame points (ARKit axes: +x right, +y up, -z forward).

    Returns (points Nx3, pixel coords Nx2 as (u, v)).
    """
    fx, fy, cx, cy = intrinsics
    h, w = depth.shape
    v, u = np.mgrid[step // 2:h:step, step // 2:w:step]
    d = depth[v, u]
    ok = (d > dmin) & (d < dmax)
    if mask is not None:
        ok &= mask[v, u]
    u, v, d = u[ok], v[ok], d[ok]
    # CV axes (+y down, +z forward) → camera axes: negate y and z.
    pts = np.stack([(u + 0.5 - cx) / fx * d, -(v + 0.5 - cy) / fy * d, -d], axis=1)
    return pts, np.stack([u, v], axis=1)


def to_world(T: np.ndarray, pts: np.ndarray) -> np.ndarray:
    return pts @ T[:3, :3].T + T[:3, 3]


def project(T: np.ndarray, intrinsics, p_world: np.ndarray) -> tuple[float, float, float] | None:
    """World point → (u, v, depth) in the image, or None when behind the camera."""
    fx, fy, cx, cy = intrinsics
    pc = np.linalg.inv(T) @ np.append(p_world, 1.0)
    d = -pc[2]
    if d <= 0.05:
        return None
    return fx * pc[0] / d + cx - 0.5, -fy * pc[1] / d + cy - 0.5, d


def forward(T: np.ndarray) -> np.ndarray:
    return -T[:3, 2]


def yaw_of(v: np.ndarray) -> float:
    """Heading of a world vector in the X–Z plane; 0 = -Z, positive = turning right."""
    return float(np.arctan2(v[0], -v[2]))


def wrap(a: float) -> float:
    return float((a + np.pi) % (2 * np.pi) - np.pi)


def quat_matrix(q: list[float]) -> np.ndarray:
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def head_local(v_world: np.ndarray, head_q: list[float], yaw_offset: float) -> np.ndarray:
    """World vector → head frame (+x right, +y up, -z forward).

    head_q is in the headphones' own reference; yaw_offset (heading sense, from calibration)
    aligns that reference with the world.
    """
    c, s = np.cos(-yaw_offset), np.sin(-yaw_offset)
    align = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    return (align @ quat_matrix(head_q)).T @ v_world


if __name__ == "__main__":
    # Head turned 90° right (yaw about -Y by -90°): a source straight ahead in the world is on the left.
    q = [0.0, np.sin(-np.pi / 4), 0.0, np.cos(-np.pi / 4)]
    assert np.allclose(head_local(np.array([0, 0, -1.0]), q, 0.0), [-1, 0, 0], atol=1e-9)
    # With a +90° offset the headphone reference faces world +X, so a source at +X is straight ahead.
    assert np.allclose(head_local(np.array([1.0, 0, 0]), [0, 0, 0, 1.0], np.pi / 2), [0, 0, -1], atol=1e-9)

    # A camera 1.5 m up, looking straight down -Z: pixel at the centre with depth 2 maps to (0, 1.5, -2).
    T = np.eye(4)
    T[1, 3] = 1.5
    K = (100.0, 100.0, 50.0, 50.0)
    depth = np.full((100, 100), 2.0, np.float32)
    pts, uv = unproject(depth, K, step=1)
    centre = to_world(T, pts[(uv[:, 0] == 49) & (uv[:, 1] == 49)])[0]
    assert np.allclose(centre, [0, 1.5, -2], atol=0.02), centre
    u, v, d = project(T, K, np.array([0.5, 2.0, -2.0]))
    assert abs(u - 74.5) < 1e-6 and abs(v - 24.5) < 1e-6 and d == 2.0
    assert abs(yaw_of(np.array([1.0, 0, 0])) - np.pi / 2) < 1e-9
    print("geometry ok")
