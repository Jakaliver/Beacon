import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PathfindingDemo, createPathfindingDemo } from '../reconstruction-viewer/pathfinding-demo.ts';

const demo = createPathfindingDemo();
const start = demo.snapshot(0);
const bytes = value => Uint8Array.from(atob(value), char => char.charCodeAt(0));
const grid = bytes(start.grid.cells);
const state = ([x, z]) => {
  const col = Math.floor((x - start.grid.origin[0]) / start.grid.res);
  const row = Math.floor((z - start.grid.origin[1]) / start.grid.res);
  return grid[row * start.grid.w + col];
};

test('provides a deterministic, explicitly synthetic room with cached geometry', () => {
  assert.ok(demo instanceof PathfindingDemo);
  assert.equal(start.perception, 'demo');
  assert.equal(start.stats.demo, true);
  assert.equal(start.targets[0].injected, true);
  assert.equal(start.targets[0].label, 'red bottle');
  assert.deepEqual(start, new PathfindingDemo().snapshot(0));
  const later = demo.snapshot(5);
  assert.equal(start.grid, later.grid);
  assert.equal(start.points, later.points);
  assert.equal(start.point_colors, later.point_colors);
  assert.equal(start.points_version, later.points_version);
  assert.equal(start.targets, later.targets);
});

test('point payload is finite and has one RGB color per point, with an identifiable red target', () => {
  const pointBytes = bytes(start.points);
  const points = new DataView(pointBytes.buffer);
  const colors = bytes(start.point_colors);
  assert.equal(pointBytes.length % 12, 0);
  assert.equal(colors.length, pointBytes.length / 4);
  assert.ok(pointBytes.length / 12 > 4000);
  assert.ok(pointBytes.length / 12 < 20000);
  let bottlePoints = 0;
  for (let i = 0; i < pointBytes.length; i += 12) {
    const x = points.getFloat32(i, true), y = points.getFloat32(i + 4, true), z = points.getFloat32(i + 8, true);
    assert.ok([x, y, z].every(Number.isFinite));
    const color = i / 4;
    if (colors[color] > 200 && colors[color + 1] < 110 && Math.abs(x - .65) < .1 && Math.abs(z + 2.65) < .1 && y > .64) bottlePoints++;
  }
  assert.ok(bottlePoints > 300);
});

test('direct bearing intersects furniture while every route segment remains in the conservative free grid', () => {
  const target = start.targets[0].position;
  const a = start.path[0], goal = [target[0], target[2]];
  const directStates = Array.from({ length: 101 }, (_, i) => state([a[0] + (goal[0] - a[0]) * i / 100, a[1] + (goal[1] - a[1]) * i / 100]));
  assert.ok(directStates.includes(2));
  assert.ok(start.path.some(([x]) => x > 1.5));
  for (let i = 1; i < start.path.length; i++) {
    const from = start.path[i - 1], to = start.path[i];
    for (let t = 0; t <= 1; t += .005) {
      assert.equal(state([from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t]), 1);
    }
  }
});

test('phone progresses slowly, stays on its remaining route, then stops at the verified approach', () => {
  let previous = demo.snapshot(0);
  for (let t = .1; t < demo.durationSeconds; t += .1) {
    const snapshot = demo.snapshot(t);
    const p = snapshot.phone.position, prior = previous.phone.position;
    assert.ok(Math.hypot(...p.map((value, i) => value - prior[i])) <= .035001);
    assert.deepEqual(snapshot.path[0], [p[0], p[2]]);
    assert.equal(state([p[0], p[2]]), 1);
    assert.ok(Math.abs(Math.hypot(...snapshot.phone.forward) - 1) < 1e-9);
    assert.deepEqual(snapshot.phone.up, [0, 1, 0]);
    assert.equal(p[1], 1.25);
    if (snapshot.mode === 'walking') assert.deepEqual(snapshot.waypoint, snapshot.path[1]);
    previous = snapshot;
  }
  const end = demo.snapshot(demo.durationSeconds);
  assert.equal(end.mode, 'probe');
  assert.equal(end.waypoint, null);
  assert.equal(end.stats.demo_arrived, true);
  assert.equal(end.stats.demo_progress, 1);
  assert.deepEqual(end.path[0], start.path.at(-1));
  const target = end.targets[0].position;
  const distance = Math.hypot(end.phone.position[0] - target[0], end.phone.position[2] - target[2]);
  assert.ok(distance >= .44 && distance <= .84, distance);
});

test('timeline random access clamps and replay never retains the preceding route', () => {
  assert.deepEqual(demo.snapshot(-10), start);
  assert.deepEqual(demo.snapshot(NaN), start);
  assert.deepEqual(demo.snapshot(Infinity), demo.snapshot(demo.durationSeconds));
  demo.snapshot(demo.durationSeconds);
  assert.deepEqual(demo.snapshot(0), start);
  assert.deepEqual(demo.snapshot(8), demo.snapshot(8));
});
