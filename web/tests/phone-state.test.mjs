import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PhoneState } from '../reconstruction-viewer/phone-state.ts';

const frame = ({ phone, stats, ...rest } = {}) => ({
  type: 'phone_pose',
  scan_id: 'scan-a',
  epoch: 7,
  floor_y: -0.5,
  phone: {
    position: [1, 1.25, -2],
    forward: [0, 0, -1],
    up: [0, 1, 0],
    tracking: 'normal',
    seq: 1,
    t: 10,
    ...phone,
  },
  stats: { sensor_connected: true, pose_age_ms: 0, ...stats },
  ...rest,
});

test('reports height above the measured floor rather than height above the AR origin', () => {
  const state = new PhoneState();
  state.update(frame({ floor_y: 2.5, phone: { position: [3, 4.25, -8] } }), 1000);
  const location = state.location(1000, true);
  assert.deepEqual(location.position, [3, 4.25, -8]);
  assert.equal(location.floorY, 2.5);
  assert.equal(location.height, 1.75);
  assert.equal(location.state, 'live');
});

test('allows a negative AR-world floor coordinate and a zero height above the floor', () => {
  const state = new PhoneState();
  state.update(frame({ floor_y: -2, phone: { position: [0, -0.25, 0] } }), 1000);
  assert.equal(state.location(1000, true).height, 1.75);
  assert.equal(state.location(1000, true).floorY, -2);
  state.update(frame({ floor_y: -2, phone: { seq: 2, t: 11, position: [0, -2, 0] } }), 1100);
  assert.equal(state.location(1100, true).height, 0);
});

test('unknown, non-finite, or physically negative floor-relative heights remain unknown', async t => {
  for (const [name, floor] of [
    ['unknown', null], ['missing', undefined], ['NaN', NaN], ['infinite', Infinity],
    ['string', '0'], ['floor above the phone', 3],
  ]) {
    await t.test(name, () => {
      const state = new PhoneState();
      state.update(frame({ floor_y: floor }), 1000);
      const location = state.location(1000, true);
      assert.equal(location.height, null);
      assert.equal(location.floorY, null);
      assert.equal(location.state, 'live');
      assert.deepEqual(location.position, [1, 1.25, -2]);
    });
  }
});

test('a fresh phone pose stays live even while vision and reconstruction statistics are old', () => {
  const state = new PhoneState();
  state.update(frame({ stats: { pose_age_ms: 20, frame_age_ms: 30_000, vision_fps: 0 } }), 1000);
  assert.equal(state.location(1000, true).state, 'live');
  state.update(frame({
    phone: { seq: 2, t: 11, position: [2, 1.5, -3] },
    stats: { pose_age_ms: 12, frame_age_ms: 40_000, vision_fps: 0 },
  }), 1200);
  const location = state.location(1220, true);
  assert.deepEqual(location.position, [2, 1.5, -3]);
  assert.equal(location.ageMs, 32);
  assert.equal(location.state, 'live');
});

test('limited tracking retains the last trustworthy pose and its original age', () => {
  const state = new PhoneState();
  state.update(frame({ stats: { pose_age_ms: 10 } }), 1000);
  state.update(frame({
    phone: { seq: 2, t: 11, tracking: 'limited', position: [99, 99, 99], forward: [1, 0, 0], up: [0, 0, 1] },
  }), 1400);
  const location = state.location(1500, true);
  assert.equal(location.state, 'tracking');
  assert.deepEqual(location.position, [1, 1.25, -2]);
  assert.deepEqual(location.forward, [0, 0, -1]);
  assert.deepEqual(location.up, [0, 1, 0]);
  assert.equal(location.ageMs, 510);

  state.update(frame({ phone: { seq: 3, t: 12, position: [2, 2, -3] }, stats: { pose_age_ms: 15 } }), 1600);
  assert.equal(state.location(1600, true).state, 'live');
  assert.deepEqual(state.location(1600, true).position, [2, 2, -3]);
  assert.equal(state.location(1600, true).ageMs, 15);
});

test('tracking loss before the first trustworthy pose stays waiting', () => {
  const state = new PhoneState();
  state.update(frame({ phone: { tracking: 'limited' } }), 1000);
  const location = state.location(1500, true);
  assert.equal(location.state, 'waiting');
  assert.equal(location.position, null);
  assert.equal(location.height, null);
  assert.equal(location.ageMs, null);
});

test('socket and sensor disconnection mark retained positions stale', () => {
  const state = new PhoneState();
  state.update(frame(), 1000);
  assert.equal(state.location(1050, false).state, 'stale');
  assert.deepEqual(state.location(1050, false).position, [1, 1.25, -2]);
  assert.equal(state.location(1050, false).ageMs, 50);
  assert.equal(state.location(1050, true).state, 'live');

  state.update(frame({ phone: { seq: 2, t: 11 }, stats: { sensor_connected: false } }), 1100);
  assert.equal(state.location(1100, true).state, 'stale');
  state.update(frame({ phone: { seq: 3, t: 12 } }), 1200);
  assert.equal(state.location(1200, true).state, 'live');
});

test('pose age advances without updates and becomes stale at one second', () => {
  const state = new PhoneState();
  state.update(frame({ stats: { pose_age_ms: 200 } }), 1000);
  assert.equal(state.location(1799, true).state, 'live');
  assert.equal(state.location(1799, true).ageMs, 999);
  assert.equal(state.location(1800, true).state, 'stale');
  assert.equal(state.location(1800, true).ageMs, 1000);
  assert.deepEqual(state.location(9000, true).position, [1, 1.25, -2]);
  assert.equal(state.location(9000, true).ageMs, 8200);
});

test('malformed coordinates never replace a trustworthy phone position', async t => {
  const badVectors = [null, undefined, [0, 1], [0, 1, 2, 3], [NaN, 1, 2], [0, Infinity, 2], ['0', 1, 2]];
  for (const key of ['position', 'forward']) {
    for (const [index, value] of badVectors.entries()) {
      await t.test(`${key} malformed vector ${index + 1}`, () => {
        const state = new PhoneState();
        state.update(frame(), 1000);
        state.update(frame({ phone: { seq: 2, t: 11, [key]: value } }), 1100);
        const location = state.location(1200, true);
        assert.equal(location.state, 'tracking');
        assert.deepEqual(location.position, [1, 1.25, -2]);
        assert.deepEqual(location.forward, [0, 0, -1]);
        assert.equal(location.ageMs, 200);
      });
    }
  }
});

test('zero direction and invalid pose ages cannot make a pose live', async t => {
  const cases = [
    ['zero direction', { phone: { forward: [0, 0, 0] } }],
    ['missing age', { stats: { pose_age_ms: undefined } }],
    ['unknown age', { stats: { pose_age_ms: null } }],
    ['negative age', { stats: { pose_age_ms: -1 } }],
    ['NaN age', { stats: { pose_age_ms: NaN } }],
    ['infinite age', { stats: { pose_age_ms: Infinity } }],
  ];
  for (const [name, overrides] of cases) {
    await t.test(name, () => {
      const state = new PhoneState();
      state.update(frame(overrides), 1000);
      assert.equal(state.location(1000, true).state, 'waiting');
      assert.equal(state.location(1000, true).position, null);
      assert.equal(state.location(1000, true).ageMs, null);
    });
  }
});

test('optional up preserves orientation without making older phone senders invalid', () => {
  const state = new PhoneState();
  state.update(frame({ phone: { up: [1, 0, 0] } }), 1000);
  assert.deepEqual(state.location(1000, true).up, [1, 0, 0]);
  state.update(frame({ phone: { seq: 2, t: 11, up: undefined } }), 1100);
  assert.equal(state.location(1100, true).state, 'live');
  assert.equal(state.location(1100, true).up, null);
});

test('malformed optional up falls back without discarding the valid position', async t => {
  for (const [index, up] of [[0, 0, 0], [0, NaN, 0], [0, Infinity, 0], [0, 1], 'up'].entries()) {
    await t.test(`up fallback ${index + 1}`, () => {
      const state = new PhoneState();
      state.update(frame({ phone: { up } }), 1000);
      const location = state.location(1000, true);
      assert.equal(location.state, 'live');
      assert.deepEqual(location.position, [1, 1.25, -2]);
      assert.equal(location.up, null);
    });
  }
});

test('copies incoming arrays so later frame mutation cannot move the stored pose', () => {
  const state = new PhoneState();
  const input = frame();
  state.update(input, 1000);
  input.phone.position[0] = 99;
  input.phone.forward[0] = 99;
  input.phone.up[0] = 99;
  const location = state.location(1000, true);
  assert.deepEqual(location.position, [1, 1.25, -2]);
  assert.deepEqual(location.forward, [0, 0, -1]);
  assert.deepEqual(location.up, [0, 1, 0]);
});

test('rejects older sequence or source time without refreshing the last known pose', () => {
  const state = new PhoneState();
  state.update(frame({ phone: { seq: 10, t: 20 } }), 1000);
  for (const phone of [{ seq: 9, t: 21 }, { seq: 11, t: 19 }]) {
    assert.deepEqual(state.update(frame({ floor_y: 9, phone: { ...phone, position: [9, 9, 9] } }), 1100),
      { accepted: false, reset: false });
    assert.deepEqual(state.location(1200, true).position, [1, 1.25, -2]);
    assert.equal(state.location(1200, true).floorY, -0.5);
    assert.equal(state.location(1200, true).ageMs, 200);
  }
  assert.deepEqual(state.update(frame({ phone: { seq: 11, t: 21, position: [2, 2, 2] } }), 1300),
    { accepted: true, reset: false });
  assert.deepEqual(state.location(1300, true).position, [2, 2, 2]);
});

test('a new AR epoch clears the old pose and rejects late frames from the retired world', () => {
  const state = new PhoneState();
  const oldWorld = frame();
  assert.deepEqual(state.update(oldWorld, 1000), { accepted: true, reset: true });
  const newWorld = frame({ epoch: 8, floor_y: null, phone: { seq: 0, t: 0, tracking: 'limited' } });
  assert.deepEqual(state.update(newWorld, 1100), { accepted: true, reset: true });
  assert.equal(state.location(1100, true).state, 'waiting');
  assert.equal(state.location(1100, true).position, null);
  assert.equal(state.location(1100, true).forward, null);
  assert.equal(state.location(1100, true).up, null);
  assert.equal(state.location(1100, true).height, null);
  assert.deepEqual(state.update(oldWorld, 1200), { accepted: false, reset: false });
  assert.equal(state.location(1200, true).position, null);
});

test('a new scan with the same epoch resets ordering and rejects old scan messages', () => {
  const state = new PhoneState();
  const oldScan = frame({ phone: { seq: 100, t: 100 } });
  const newScan = frame({ scan_id: 'scan-b', phone: { seq: 0, t: 0, position: [4, 2, -1] } });
  state.update(oldScan, 1000);
  assert.deepEqual(state.update(newScan, 1100), { accepted: true, reset: true });
  assert.deepEqual(state.location(1100, true).position, [4, 2, -1]);
  assert.equal(state.location(1100, true).state, 'live');
  assert.deepEqual(state.update(oldScan, 1200), { accepted: false, reset: false });
  assert.deepEqual(state.location(1200, true).position, [4, 2, -1]);
  assert.equal(state.location(1200, true).ageMs, 100);
});

test('world checks match both scan and epoch without mutating pose freshness', () => {
  const state = new PhoneState();
  const current = frame();
  assert.equal(state.isCurrentWorld(current), false);
  state.update(current, 1000);
  assert.equal(state.isCurrentWorld(current), true);
  assert.equal(state.isCurrentWorld(frame({ epoch: 8 })), false);
  assert.equal(state.isCurrentWorld(frame({ scan_id: 'scan-b' })), false);
  assert.equal(state.location(1200, true).ageMs, 200);
  state.update(frame({ scan_id: 'scan-b' }), 1300);
  assert.equal(state.isCurrentWorld(current), false);
  assert.equal(state.isCurrentWorld(frame({ scan_id: 'scan-b' })), true);
});

test('explicit reset forgets the previous pose, ordering, and retired-world history', () => {
  const state = new PhoneState();
  state.update(frame(), 1000);
  state.update(frame({ scan_id: 'scan-b' }), 1100);
  state.reset();
  const location = state.location(1200, true);
  assert.equal(location.state, 'waiting');
  assert.equal(location.position, null);
  assert.equal(location.forward, null);
  assert.equal(location.up, null);
  assert.equal(location.ageMs, null);
  assert.equal(location.height, null);
  assert.equal(state.isCurrentWorld(frame({ scan_id: 'scan-b' })), false);
  assert.deepEqual(state.update(frame({ phone: { seq: 0, t: 0 } }), 1300), { accepted: true, reset: true });
  assert.equal(state.location(1300, true).state, 'live');
});
