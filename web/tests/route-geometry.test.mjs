import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readRoute, routeRibbon, routeChevrons } from '../reconstruction-viewer/route-geometry.ts';
const route = (extra = {}) => ({ navigation: true, mode: 'walking', floor_y: -1.2, path: [[0, 0], [0, -1], [1, -1]], waypoint: [0, -0.7], ...extra });

test('only active walking navigation with a measured floor yields a route', () => {
  const result = readRoute(route());
  assert.deepEqual(result.points, [[0, 0], [0, -1], [1, -1]]);
  assert.equal(result.floorY, -1.2);
  assert.deepEqual(result.waypoint, [0, -0.7]);
  for (const invalid of [{navigation: false}, {navigation: 'true'}, {mode: 'stopped'}, {mode: 'probe'}, {mode: 'hotcold'}, {stop_reason: 'pathfinding_unknown'}, {waypoint: null}, {floor_y: null}, {floor_y: NaN}]) {
    assert.equal(readRoute(route(invalid)), null);
  }
});

test('malformed vertices reject the whole route instead of bridging an unseen gap', () => {
  for (const invalid of [[NaN, 0], [0, Infinity], [0], [0, 1, 2], ['0', 1], [1e100, 0], null]) {
    assert.equal(readRoute(route({path: [[0, 0], invalid, [2, 2]]})), null);
  }
  assert.equal(readRoute(route({path: null})), null);
  assert.equal(readRoute(route({path: Array.from({length: 8193}, () => [0, 0])})), null);
});

test('duplicate/degenerate paths and invalid waypoints are handled without false markers', () => {
  assert.equal(readRoute(route({path: []})), null);
  assert.equal(readRoute(route({path: [[1, 1], [1, 1]]})), null);
  assert.deepEqual(readRoute(route({path: [[0, 0], [0, 0], [0, -1]]})).points, [[0, 0], [0, -1]]);
  assert.equal(readRoute(route({waypoint: [0, Infinity]})), null);
});

test('ribbon lies on measured floor and stays bounded through reversing corners', () => {
  const points = [[0, 0], [0, -1], [0, 0], [1, 0]];
  const mesh = routeRibbon(points, -1.13, 0.16);
  assert.equal(mesh.length % 9, 0);
  assert.ok(mesh.every(Number.isFinite));
  for (let i = 0; i < mesh.length; i += 3) {
    assert.ok(Math.abs(mesh[i + 1] + 1.13) < 1e-6);
    assert.ok(mesh[i] >= -0.081 && mesh[i] <= 1.081);
    assert.ok(mesh[i + 2] >= -1.081 && mesh[i + 2] <= 0.081);
  }
});

test('chevrons follow the path direction and spacing independent of cell density', () => {
  const straight = routeChevrons([[0, 0], [0, -2]], 0.09);
  const dense = routeChevrons([[0, 0], [0, -0.1], [0, -0.2], [0, -0.9], [0, -2]], 0.09);
  assert.equal(straight.length, 3 * 12 * 3);
  assert.deepEqual(straight, dense);
  assert.ok(straight[8] < straight[2], 'V tip points toward negative Z');
  const turned = routeChevrons([[0, 0], [0, -1], [1, -1]], 0.09);
  assert.ok(turned.every(Number.isFinite));
  assert.equal(turned.length, straight.length);
});
