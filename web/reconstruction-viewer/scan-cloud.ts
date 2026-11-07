// A bounded display history of measured points. It never feeds navigation or invents surfaces.
export class ScanCloud {
  private cells = new Map<string, { point: [number, number, number]; seen: number }>();
  readonly limit: number;
  private voxel: number;
  private lifetime: number;
  constructor(limit = 20_000, voxel = 0.045, lifetime = 90_000) {
    this.limit = limit; this.voxel = voxel; this.lifetime = lifetime;
  }

  clear() { this.cells.clear(); }
  get size() { return this.cells.size; }

  add(points: Float32Array, now: number) {
    for (let i = 0; i + 2 < points.length; i += 3) {
      const x = points[i], y = points[i + 1], z = points[i + 2];
      if (![x, y, z].every(Number.isFinite)) continue;
      const key = `${Math.floor(x / this.voxel)},${Math.floor(y / this.voxel)},${Math.floor(z / this.voxel)}`;
      // Refresh insertion order: the oldest observations leave first when the budget is full.
      this.cells.delete(key);
      this.cells.set(key, { point: [x, y, z], seen: now });
    }
    for (const [key, cell] of this.cells) {
      if (this.cells.size <= this.limit && now - cell.seen <= this.lifetime) break;
      this.cells.delete(key);
    }
  }

  writeTo(destination: Float32Array): number {
    let count = 0;
    for (const { point } of this.cells.values()) {
      if ((count + 1) * 3 > destination.length) break;
      destination.set(point, count++ * 3);
    }
    return count;
  }
}
