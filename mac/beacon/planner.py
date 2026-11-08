"""Grid route planning over observed walkable cells. Unknown space is blocked."""
import heapq
import math

import numpy as np

from .config import CONFIG
from .mapping import FREE

MOVES = [(-1, 0, 1.0), (1, 0, 1.0), (0, -1, 1.0), (0, 1, 1.0),
         (-1, -1, math.sqrt(2)), (-1, 1, math.sqrt(2)), (1, -1, math.sqrt(2)), (1, 1, math.sqrt(2))]


def walkable_grid(states: np.ndarray, start: tuple[int, int], escape_cells: int = 4) -> np.ndarray:
    # The phone's location is not evidence of safe ground or torso clearance.
    # Keep the legacy parameter for callers, but never carve an escape through danger.
    return states == FREE


def line_clear(walk: np.ndarray, a: tuple[int, int], b: tuple[int, int]) -> bool:
    n = int(max(abs(b[0] - a[0]), abs(b[1] - a[1])) * 2) + 1
    for s in np.linspace(0, 1, n + 1):
        r = a[0] + (b[0] - a[0]) * s
        c = a[1] + (b[1] - a[1]) * s
        # Check every cell the segment's footprint can touch, not just the nearest.
        for rr in {math.floor(r + 0.5 - 0.3), math.floor(r + 0.5 + 0.3)}:
            for cc in {math.floor(c + 0.5 - 0.3), math.floor(c + 0.5 + 0.3)}:
                if not (0 <= rr < walk.shape[0] and 0 <= cc < walk.shape[1]) or not walk[rr, cc]:
                    return False
    return True


def plan(walk: np.ndarray, start: tuple[int, int], target: tuple[float, float],
         ring: tuple[float, float], penalty: np.ndarray | None = None,
         goal_allowed=None) -> list[tuple[int, int]] | None:
    """Dijkstra to the cheapest reachable cell whose distance (in cells) to target lies in ring."""
    h, w = walk.shape
    if not (0 <= start[0] < h and 0 <= start[1] < w) or not walk[start]:
        return None
    dist = np.full(walk.shape, np.inf)
    prev: dict[tuple[int, int], tuple[int, int]] = {}
    dist[start] = 0
    pq = [(0.0, start)]
    tr, tc = target
    best = None
    while pq:
        d, (r, c) = heapq.heappop(pq)
        if d > dist[r, c]:
            continue
        if (ring[0] <= math.hypot(r + 0.5 - tr, c + 0.5 - tc) <= ring[1]
                and (goal_allowed is None or goal_allowed((r, c)))):
            best = (r, c)
            break
        for dr, dc, cost in MOVES:
            nr, nc = r + dr, c + dc
            if not (0 <= nr < h and 0 <= nc < w) or not walk[nr, nc]:
                continue
            if dr and dc and not (walk[r + dr, c] and walk[r, c + dc]):
                continue  # no diagonal corner cutting
            nd = d + cost * (penalty[nr, nc] if penalty is not None else 1.0)
            if nd < dist[nr, nc]:
                dist[nr, nc] = nd
                prev[(nr, nc)] = (r, c)
                heapq.heappush(pq, (nd, (nr, nc)))
    if best is None:
        return None
    path = [best]
    while path[-1] != start:
        path.append(prev[path[-1]])
    # Weighted paths must retain the cells whose cost Dijkstra evaluated.
    return path[::-1] if penalty is not None else smooth(walk, path[::-1])


def smooth(walk: np.ndarray, path: list[tuple[int, int]]) -> list[tuple[int, int]]:
    out = [path[0]]
    i = 0
    while i < len(path) - 1:
        j = len(path) - 1
        while j > i + 1 and not line_clear(walk, path[i], path[j]):
            j -= 1
        out.append(path[j])
        i = j
    return out


def ring_cells(target_extent_xz: float, slack: float = 0.0) -> tuple[float, float]:
    r = target_extent_xz / 2
    return ((r + CONFIG.approach_min) / CONFIG.cell_m, (r + CONFIG.approach_max + slack) / CONFIG.cell_m)


if __name__ == "__main__":
    from .mapping import OCCUPIED, INFLATED
    s = np.full((40, 40), FREE, np.uint8)
    s[20, 5:35] = OCCUPIED  # a wall between start and target, open at both ends
    s[19, 5:35] = INFLATED
    s[21, 5:35] = INFLATED
    start, target = (30, 20), (10.0, 20.0)
    walk = walkable_grid(s, start)
    path = plan(walk, start, target, (3, 8))
    assert path, "expected a route around the wall"
    for a, b in zip(path, path[1:]):
        assert line_clear(walk, a, b)
    assert any(p[1] < 5 or p[1] > 34 for p in path), path
    s[:, 0:5] = OCCUPIED
    s[:, 35:] = OCCUPIED
    assert plan(walkable_grid(s, start), start, target, (3, 8)) is None
    print("planner ok")
