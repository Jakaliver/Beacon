import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ScanCloud } from '../reconstruction-viewer/scan-cloud.ts';

const points = (...values) => new Float32Array(values);
const read = scan => {
  const out = new Float32Array(scan.size * 3);
  assert.equal(scan.writeTo(out), scan.size);
  return [...out];
};

test('keeps previously seen surfaces when the camera turns away, deduplicating repeat frames', () => {
  const scan = new ScanCloud();
  scan.add(points(1, 1, 1), 0);
  scan.add(points(2, 1, 1), 1000);
  scan.add(points(2, 1, 1), 2000);
  assert.deepEqual(read(scan), [1, 1, 1, 2, 1, 1]);
});

test('uses a bounded point budget and preserves recently revisited surfaces', () => {
  const scan = new ScanCloud(2);
  scan.add(points(1, 1, 1, 2, 1, 1), 0);
  scan.add(points(1, 1, 1, 3, 1, 1), 1000);
  assert.deepEqual(read(scan), [1, 1, 1, 3, 1, 1]);
});

test('ages out old observations and clears geometry between camera sessions', () => {
  const scan = new ScanCloud();
  scan.add(points(1, 1, 1), 0);
  scan.add(points(2, 1, 1), 91_000);
  assert.deepEqual(read(scan), [2, 1, 1]);
  scan.clear();
  assert.equal(scan.size, 0);
});

test('rejects non-finite samples and never writes beyond the GPU buffer', () => {
  const scan = new ScanCloud();
  scan.add(points(NaN, 0, 0, 0, Infinity, 0, 1, 1, 1, 2, 2, 2), 0);
  assert.equal(scan.size, 2);
  const small = new Float32Array(3);
  assert.equal(scan.writeTo(small), 1);
  assert.deepEqual([...small], [1, 1, 1]);
});
