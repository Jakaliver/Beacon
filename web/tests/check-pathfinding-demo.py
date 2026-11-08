"""Offline fixture check using the production planner; never a browser dependency.

From repo root: PYTHONPATH=mac python web/tests/check-pathfinding-demo.py
Requires the backend's numpy/OpenCV environment and Node with type stripping.
"""
import base64
import json
from pathlib import Path
import subprocess

import cv2
import numpy as np

from beacon.config import CONFIG
from beacon.mapping import FREE, INFLATED, OCCUPIED, UNKNOWN
from beacon.planner import line_clear, plan, ring_cells


def check():
    web = Path(__file__).resolve().parents[1]
    result = subprocess.run([
        "node", "--experimental-strip-types", "--input-type=module", "-e",
        "import {PathfindingDemo} from './reconstruction-viewer/pathfinding-demo.ts'; "
        "console.log(JSON.stringify(new PathfindingDemo().snapshot(0)));",
    ], cwd=web, text=True, capture_output=True, check=True)
    snapshot = json.loads(result.stdout)
    assert CONFIG.cell_m == .1 and abs(CONFIG.inflation_m - .68) < 1e-9, "Regenerate the demo after clearance configuration changes"
    n, res = 80, CONFIG.cell_m
    origin = np.array([-4., -4.])
    row, col = np.indices((n, n))
    x, z = origin[0] + (col + .5) * res, origin[1] + (row + .5) * res
    floor = (abs(x) < 3.6) & (abs(z) < 3.6)
    occupied = ((abs(x) >= 3.5) | (abs(z) >= 3.5)) & floor
    occupied |= (x >= -.9) & (x <= .9) & (z >= -.55) & (z <= .55)
    occupied |= (x >= .55) & (x <= .75) & (z >= -2.75) & (z <= -2.55)
    states = np.full((n, n), UNKNOWN, np.uint8)
    states[floor] = FREE
    radius = int(np.ceil(CONFIG.inflation_m / res))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1))
    inflated = cv2.dilate(occupied.astype(np.uint8), kernel) > 0
    states[inflated & floor] = INFLATED
    states[occupied] = OCCUPIED
    np.testing.assert_array_equal(np.frombuffer(base64.b64decode(snapshot['grid']['cells']), np.uint8).reshape(n, n), states)
    target = snapshot['targets'][0]
    target_xz = np.array(target['position'])[[0, 2]]
    target_grid = (target_xz - origin) / res
    start = (64, 40)
    extent = max(target['extent'][0], target['extent'][2])
    route = plan(states == FREE, start, (target_grid[1], target_grid[0]), ring_cells(extent))
    assert route, 'Expected a feasible conservative route around the table'
    world_route = [origin + (np.array([c, r]) + .5) * res for r, c in route]
    np.testing.assert_allclose(snapshot['path'], world_route, atol=1e-8)
    assert not line_clear(states == FREE, start, tuple(np.floor(target_grid[::-1]).astype(int)))
    assert all(line_clear(states == FREE, a, b) for a, b in zip(route, route[1:]))
    print(f'Production planner matches demo: {len(route)} vertices, {radius * res:.1f} m grid clearance, actual bottle extent {extent:.2f} m')


if __name__ == '__main__':
    check()
