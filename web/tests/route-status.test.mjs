import assert from "node:assert/strict";
import test from "node:test";
import { routeStatus } from "../reconstruction-viewer/route-status.ts";
import { readRoute } from "../reconstruction-viewer/route-geometry.ts";

const fresh = { connected: true, phoneLive: true, elapsedMs: 100 };
const snapshot = (changes = {}) => ({
  navigation: true,
  mode: "walking",
  stop_reason: null,
  floor_y: -1.3,
  path: [[0, 0], [0, -3], [4, -3]],
  waypoint: [0, -3],
  phone: { tracking: "normal" },
  stats: { sensor_connected: true, observation_age_ms: 100, frame_age_ms: 200 },
  ...changes,
});

test("a fresh planned route reports its polyline distance in x/z", () => {
  assert.deepEqual(routeStatus(snapshot(), fresh), { visible: true, text: "Planned route · 7.0 m", distance: 7 });
});

test("no snapshot, disabled pathfinding and explicit stops have distinct hidden statuses", () => {
  assert.deepEqual(routeStatus(null, fresh), { visible: false, text: "Waiting for route", distance: null });
  assert.equal(routeStatus(snapshot({ navigation: false }), fresh).text, "Pathfinding off");
  for (const changes of [{ mode: "stopped" }, { stop_reason: "user" }, { stop_reason: "pathfinding_unknown" }]) {
    assert.deepEqual(routeStatus(snapshot(changes), fresh), { visible: false, text: "Route paused", distance: null });
  }
});

test("disconnects or unavailable tracking immediately hide the route", () => {
  for (const state of [{ ...fresh, connected: false }, { ...fresh, phoneLive: false }]) {
    assert.equal(routeStatus(snapshot(), state).text, "Route paused");
    assert.equal(routeStatus(snapshot(), state).visible, false);
  }
  for (const tracking of [null, undefined, "limited", "not_available"]) {
    assert.equal(routeStatus(snapshot({ phone: { tracking } }), fresh).visible, false);
  }
  for (const sensor_connected of [false, undefined]) {
    assert.equal(routeStatus(snapshot({ stats: { ...snapshot().stats, sensor_connected } }), fresh).visible, false);
  }
});

test("capture age includes all intervals and expires without another snapshot", () => {
  const recon = snapshot({ stats: { ...snapshot().stats, observation_age_ms: 300, frame_age_ms: 400 } });
  assert.equal(routeStatus(recon, { ...fresh, elapsedMs: 800 }).visible, true);
  assert.equal(routeStatus(recon, { ...fresh, elapsedMs: 800.01 }).visible, false);
  assert.equal(routeStatus(recon, { ...fresh, elapsedMs: 1000 }).text, "Route paused");
  const lowLatency = snapshot({ stats: { ...snapshot().stats, observation_age_ms: 0, frame_age_ms: 0 } });
  assert.equal(routeStatus(lowLatency, { ...fresh, elapsedMs: 1000 }).visible, true);
  assert.equal(routeStatus(lowLatency, { ...fresh, elapsedMs: 1000.01 }).visible, false);
  assert.equal(routeStatus(snapshot({ stats: { ...snapshot().stats, frame_age_ms: 1600 } }), { ...fresh, elapsedMs: 0 }).visible, false);
});

test("missing, negative and non-finite ages fail closed", () => {
  for (const invalid of [undefined, null, -1, NaN, Infinity, -Infinity, "0"]) {
    assert.equal(routeStatus(snapshot(), { ...fresh, elapsedMs: invalid }).visible, false);
    for (const key of ["observation_age_ms", "frame_age_ms"]) {
      assert.equal(routeStatus(snapshot({ stats: { ...snapshot().stats, [key]: invalid } }), fresh).visible, false);
    }
  }
});

test("fresh probe mode is approaching; stale probe mode remains paused", () => {
  const recon = snapshot({ mode: "probe", path: [], waypoint: null });
  assert.deepEqual(routeStatus(recon, fresh), { visible: false, text: "Approaching object", distance: null });
  assert.equal(routeStatus(recon, { ...fresh, phoneLive: false }).text, "Route paused");
  assert.equal(routeStatus(recon, { ...fresh, elapsedMs: 1600 }).text, "Route paused");
  for (const mode of ["idle", "searching", "choosing", "hotcold"]) {
    assert.deepEqual(routeStatus(snapshot({ mode }), fresh), { visible: false, text: "Waiting for route", distance: null });
  }
});

test("walking requires a known floor, complete finite path and a finite waypoint", () => {
  for (const floor_y of [null, undefined, NaN, Infinity, "0"]) {
    assert.equal(routeStatus(snapshot({ floor_y }), fresh).visible, false);
  }
  for (const path of [undefined, null, [], [[0, 0]], [[0, 0], [0, 0]], [[0, 0], [1]], [[0, 0], [1, 2, 3]], [[0, 0], [NaN, 1]], [[0, 0], ["1", 2]], [[0, 0], [Infinity, 2]]]) {
    assert.deepEqual(routeStatus(snapshot({ path }), fresh), { visible: false, text: "Waiting for route", distance: null });
  }
  for (const waypoint of [undefined, null, [], [1], [1, 2, 3], [NaN, 1], [Infinity, 1], ["0", 1]]) {
    assert.equal(routeStatus(snapshot({ waypoint }), fresh).visible, false);
  }
  assert.equal(routeStatus(snapshot({ path: [[-Number.MAX_VALUE, 0], [Number.MAX_VALUE, 0]] }), fresh).visible, false);
});

test("status evaluation never mutates a snapshot or carries a route across calls", () => {
  const recon = snapshot();
  const before = structuredClone(recon);
  routeStatus(recon, fresh);
  assert.deepEqual(recon, before);
  assert.equal(routeStatus(snapshot({ navigation: false }), fresh).visible, false);
  assert.equal(routeStatus(null, fresh).distance, null);
});

test("visible status agrees with renderer geometry limits and duplicate removal", () => {
  const cases = [
    {},
    { path: [[0, 0], [0, 0.0005]] },
    { path: [[0, 0], [0, 0.0005], [0, 0.0015]] },
    { path: [[0, 0], [0, 0], [0, 2]] },
    { path: [[0, 0], [100_001, 0]] },
    { path: Array.from({ length: 8193 }, (_, i) => [i, 0]) },
    { floor_y: 100_001 },
  ];
  for (const changes of cases) {
    const recon = snapshot(changes);
    assert.equal(routeStatus(recon, fresh).visible, readRoute(recon) !== null);
  }
});

test("a synthetic demo follows the same sensor and tracking freshness contract", () => {
  const demo = snapshot({ perception: "demo", stats: { ...snapshot().stats, sensor_connected: true, demo: true } });
  assert.equal(routeStatus(demo, fresh).visible, true);
  assert.equal(routeStatus(demo, { ...fresh, phoneLive: false }).visible, false);
  assert.equal(routeStatus({ ...demo, stats: { ...demo.stats, sensor_connected: false } }, fresh).visible, false);
});
