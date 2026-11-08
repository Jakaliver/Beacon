import type { Recon } from "./types";

/** An authored browser demonstration. No camera, inference, or backend is involved. */
export const PATHFINDING_DEMO_TITLE = "Around the table";
export const PATHFINDING_DEMO_NOTE = "Simulated room · Precomputed route · No live camera or inference";

type XZ = [number, number];
type XYZ = [number, number, number];
type RGB = [number, number, number];

const ORIGIN: XZ = [-4, -4];
const RESOLUTION = 0.1;
const GRID_SIZE = 80;
const FLOOR_Y = 0;
const SPEED = 0.35;
const START_HOLD = 1.2;
const END_HOLD = 2;
const TARGET: XYZ = [0.65, 0.885, -2.65];

// Generated with mac/beacon/planner.py plan(), at the production .68 m body
// envelope (ceil to 7 cells), on the exact grid below. The goal ring uses the
// selected bottle's actual .18 m extent, exactly as Engine._route does. A narrow
// .2 m pedestal leaves a reachable approach without excluding its occupancy.
// These are [row, column] cells: (64,40), (50,55), (47,56), (29,56), (21,48).
// Generation/clearance is checked by web/tests/check-pathfinding-demo.py.
const ROUTE: XZ[] = [[0.05, 2.45], [1.55, 1.05], [1.65, 0.75], [1.65, -1.05], [0.85, -1.85]];

// OpenCV MORPH_ELLIPSE radius7, matching GridMap.kernel() exactly.
const INFLATION_HALF_WIDTHS = [0, 4, 5, 6, 6, 7, 7, 7, 7, 7, 6, 6, 5, 4, 0];

function encodeBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}

function encodePoints(values: number[]): string {
  const bytes = new Uint8Array(values.length * 4);
  const view = new DataView(bytes.buffer);
  values.forEach((value, index) => view.setFloat32(index * 4, value, true));
  return encodeBytes(bytes);
}

function makeGrid(): Recon["grid"] {
  const cells = new Uint8Array(GRID_SIZE * GRID_SIZE);
  const occupied: XZ[] = [];
  for (let row = 0; row < GRID_SIZE; row++) {
    for (let col = 0; col < GRID_SIZE; col++) {
      const x = ORIGIN[0] + (col + 0.5) * RESOLUTION;
      const z = ORIGIN[1] + (row + 0.5) * RESOLUTION;
      const floor = Math.abs(x) < 3.6 && Math.abs(z) < 3.6;
      if (!floor) continue;
      const wall = Math.abs(x) >= 3.5 || Math.abs(z) >= 3.5;
      const table = x >= -0.9 && x <= 0.9 && z >= -0.55 && z <= 0.55;
      const pedestal = x >= 0.55 && x <= 0.75 && z >= -2.75 && z <= -2.55;
      cells[row * GRID_SIZE + col] = wall || table || pedestal ? 2 : 1;
      if (wall || table || pedestal) occupied.push([row, col]);
    }
  }
  for (const [row, col] of occupied) {
    INFLATION_HALF_WIDTHS.forEach((halfWidth, index) => {
      const r = row + index - 7;
      if (r < 0 || r >= GRID_SIZE) return;
      for (let c = col - halfWidth; c <= col + halfWidth; c++) {
        if (c >= 0 && c < GRID_SIZE && cells[r * GRID_SIZE + c] === 1) cells[r * GRID_SIZE + c] = 3;
      }
    });
  }
  return { origin: [...ORIGIN], res: RESOLUTION, w: GRID_SIZE, h: GRID_SIZE, cells: encodeBytes(cells) };
}

function makeCloud(): { points: string; colors: string; count: number } {
  const points: number[] = [], colors: number[] = [];
  const add = (x: number, y: number, z: number, color: RGB) => {
    points.push(x, y, z);
    colors.push(...color);
  };
  function panel(min: XYZ, max: XYZ, fixedAxis: 0 | 1 | 2, step: number, color: RGB) {
    const axes = [0, 1, 2].filter(axis => axis !== fixedAxis);
    const [a, b] = axes;
    const na = Math.max(1, Math.ceil((max[a] - min[a]) / step));
    const nb = Math.max(1, Math.ceil((max[b] - min[b]) / step));
    for (let ia = 0; ia <= na; ia++) {
      for (let ib = 0; ib <= nb; ib++) {
        const p: XYZ = [...min];
        p[a] = min[a] + (max[a] - min[a]) * ia / na;
        p[b] = min[b] + (max[b] - min[b]) * ib / nb;
        add(...p, color);
      }
    }
  }
  function box(min: XYZ, max: XYZ, color: RGB, step = 0.075) {
    for (const axis of [0, 1, 2] as const) {
      const high: XYZ = [...min]; high[axis] = max[axis];
      panel(min, max, axis, step, color);
      panel(high, max, axis, step, color);
    }
  }

  // Two cutaway walls keep the room readable without hiding its route in 3D.
  panel([-3.5, 0, -3.5], [3.5, 0, 3.5], 1, 0.13, [71, 80, 89]);
  panel([-3.55, 0, -3.55], [3.55, 2.15, -3.55], 2, 0.14, [129, 143, 152]);
  panel([-3.55, 0, -3.55], [-3.55, 2.15, 3.55], 0, 0.14, [111, 126, 138]);

  // A broad tabletop blocks full-height body passage even between its legs.
  box([-0.9, 0.72, -0.55], [0.9, 0.82, 0.55], [172, 143, 106]);
  for (const x of [-0.82, 0.74]) for (const z of [-0.47, 0.39]) {
    box([x, 0, z], [x + 0.08, 0.72, z + 0.08], [117, 100, 80], 0.08);
  }
  box([0.55, 0, -2.75], [0.75, 0.65, -2.55], [134, 152, 164], 0.04);

  // Distinct red bottle: body, sloped shoulder, narrower neck and cap.
  const ring = (y: number, radius: number, color: RGB) => {
    for (let angle = 0; angle < 32; angle++) {
      const theta = angle * Math.PI * 2 / 32;
      add(TARGET[0] + Math.cos(theta) * radius, y, TARGET[2] + Math.sin(theta) * radius, color);
    }
  };
  for (let i = 0; i <= 17; i++) ring(0.65 + i * 0.018, 0.078, [229, 75, 81]);
  for (let i = 1; i <= 5; i++) ring(0.956 + i * 0.012, 0.078 - i * 0.009, [235, 89, 94]);
  for (let i = 1; i <= 6; i++) ring(1.016 + i * 0.014, 0.033, [229, 75, 81]);
  ring(1.112, 0.036, [244, 203, 204]);
  return { points: encodePoints(points), colors: encodeBytes(new Uint8Array(colors)), count: points.length / 3 };
}

export class PathfindingDemo {
  readonly title = PATHFINDING_DEMO_TITLE;
  readonly note = PATHFINDING_DEMO_NOTE;
  readonly durationSeconds: number;
  readonly arrivalSeconds: number;
  private readonly lengths: number[];
  private readonly totalLength: number;
  private readonly grid: Recon["grid"];
  private readonly cloud: ReturnType<typeof makeCloud>;
  private readonly targets: Recon["targets"];

  constructor() {
    this.grid = makeGrid();
    this.cloud = makeCloud();
    this.lengths = ROUTE.slice(1).map((point, index) => Math.hypot(point[0] - ROUTE[index][0], point[1] - ROUTE[index][1]));
    this.totalLength = this.lengths.reduce((sum, length) => sum + length, 0);
    this.arrivalSeconds = START_HOLD + this.totalLength / SPEED;
    this.durationSeconds = this.arrivalSeconds + END_HOLD;
    this.targets = [{ id: "demo-red-bottle", label: "red bottle", position: [...TARGET],
      extent: [0.18, 0.47, 0.18], sigma: 0, age: 0, valid: true,
      selected: true, injected: true, locked: true }];
  }

  /** Random-access timeline: clamp at either end; callers reset pose ordering on rewind. */
  snapshot(elapsedSeconds: number): Recon {
    const elapsed = Number.isNaN(elapsedSeconds) ? 0 : Math.max(0, Math.min(this.durationSeconds, elapsedSeconds));
    const distance = Math.min(this.totalLength, Math.max(0, elapsed - START_HOLD) * SPEED);
    const arrived = distance >= this.totalLength - 1e-9;
    let segment = 0, before = 0;
    while (segment < this.lengths.length - 1 && before + this.lengths[segment] <= distance) {
      before += this.lengths[segment++];
    }
    const a = ROUTE[segment], b = ROUTE[segment + 1];
    const fraction = Math.min(1, (distance - before) / this.lengths[segment]);
    const xz: XZ = arrived ? [...ROUTE[ROUTE.length - 1]]
      : [a[0] + (b[0] - a[0]) * fraction, a[1] + (b[1] - a[1]) * fraction];
    const position: XYZ = [xz[0], 1.25, xz[1]];
    const direction: XZ = arrived ? [TARGET[0] - xz[0], TARGET[2] - xz[1]] : [b[0] - a[0], b[1] - a[1]];
    const norm = Math.hypot(...direction);
    const path = arrived ? [[...xz]] : [[...xz], ...ROUTE.slice(segment + 1).map(point => [...point])];
    return {
      scan_id: "pathfinding-browser-demo-v1", epoch: 1, perception: "demo",
      mode: arrived ? "probe" : "walking", stop_reason: null, navigation: true,
      grid: this.grid, floor_y: FLOOR_Y,
      points: this.cloud.points, point_colors: this.cloud.colors, points_version: 1, points_fused: true,
      phone: { position, forward: [direction[0] / norm, 0, direction[1] / norm], up: [0, 1, 0],
        tracking: "normal", seq: Math.floor(elapsed * 30), t: 1000 + elapsed },
      listener: [...position], targets: this.targets,
      path, waypoint: arrived ? null : [...b],
      stats: { sensor_connected: true, demo: true, map_version: 1, frame_age_ms: 0,
        observation_age_ms: 0, pose_age_ms: 0, point_count: this.cloud.count,
        demo_progress: distance / this.totalLength, demo_arrived: arrived },
    };
  }
}

export function createPathfindingDemo(): PathfindingDemo { return new PathfindingDemo(); }
