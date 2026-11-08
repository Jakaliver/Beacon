export type FloorPoint = [number, number];
export type RouteData = { points: FloorPoint[]; floorY: number; waypoint: FloorPoint | null };
const MAX_POINTS = 8192;
const finiteCoordinate = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && Math.abs(v) <= 100_000;
const point = (v: unknown): v is FloorPoint => Array.isArray(v) && v.length === 2 && v.every(finiteCoordinate);

/** Reject a malformed path as a whole: filtering a bad point could invent a shortcut across a gap. */
export function readRoute(value: { navigation?: unknown; mode?: unknown; path?: unknown; floor_y?: unknown; waypoint?: unknown; stop_reason?: unknown }): RouteData | null {
  if (value.navigation !== true || value.mode !== "walking" || value.stop_reason != null || !point(value.waypoint) || !finiteCoordinate(value.floor_y)
    || !Array.isArray(value.path) || value.path.length > MAX_POINTS || !value.path.every(point)) return null;
  const points: FloorPoint[] = [];
  for (const p of value.path) {
    const previous = points.at(-1);
    if (!previous || Math.hypot(p[0] - previous[0], p[1] - previous[1]) > 0.001) points.push([p[0], p[1]]);
  }
  return points.length >= 2 ? { points, floorY: value.floor_y, waypoint: point(value.waypoint) ? [...value.waypoint] : null } : null;
}

/** Flat triangles avoid WebGL's platform-dependent one-pixel line width. No per-frame tessellation. */
export function routeRibbon(points: FloorPoint[], y: number, width: number): Float32Array {
  const vertices: number[] = [];
  const half = width / 2;
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], b = points[i];
    const length = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (length < 0.001) continue;
    const nx = -(b[1] - a[1]) / length * half, nz = (b[0] - a[0]) / length * half;
    vertices.push(a[0] + nx, y, a[1] + nz, a[0] - nx, y, a[1] - nz, b[0] + nx, y, b[1] + nz,
      b[0] + nx, y, b[1] + nz, a[0] - nx, y, a[1] - nz, b[0] - nx, y, b[1] - nz);
  }
  // Rounded joins and caps remain bounded at sharp/reversing corners; no long miter spikes.
  for (const [x, z] of points) {
    for (let i = 0; i < 12; i++) {
      const a = i * Math.PI / 6, b = (i + 1) * Math.PI / 6;
      vertices.push(x, y, z, x + Math.cos(a) * half, y, z + Math.sin(a) * half,
        x + Math.cos(b) * half, y, z + Math.sin(b) * half);
    }
  }
  return new Float32Array(vertices);
}

/** Chevrons are evenly spaced along arc length, rather than repeated at every grid cell. */
export function routeChevrons(points: FloorPoint[], y: number): Float32Array {
  const vertices: number[] = [];
  const spacing = 0.65;
  let distance = 0, next = 0.32, count = 0;
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], b = points[i];
    const length = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (length < 0.001) continue;
    const fx = (b[0] - a[0]) / length, fz = (b[1] - a[1]) / length;
    while (next <= distance + length && count < 512) {
      const x = a[0] + fx * (next - distance), z = a[1] + fz * (next - distance);
      // Two slim arms form a V pointing towards the next waypoint/approach point.
      const local = [[-0.062, -0.045], [0, 0.045], [0, 0.085],
        [-0.062, -0.045], [0, 0.085], [-0.062, -0.005],
        [0, 0.045], [0.062, -0.045], [0.062, -0.005],
        [0, 0.045], [0.062, -0.005], [0, 0.085]];
      for (const [side, forward] of local) vertices.push(x - fz * side + fx * forward, y, z + fx * side + fz * forward);
      next += spacing;
      count++;
    }
    distance += length;
  }
  return new Float32Array(vertices);
}
