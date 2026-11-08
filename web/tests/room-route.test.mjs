import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import * as THREE from 'three';
import * as routeGeometry from '../reconstruction-viewer/route-geometry.ts';
import { ScanCloud } from '../reconstruction-viewer/scan-cloud.ts';

// Exercise actual RoomView lifecycle/Three geometry without creating a browser or GPU context.
class Renderer {
  constructor({canvas}) { this.domElement = canvas; }
  setPixelRatio(value) { this.ratio = value; }
  getPixelRatio() { return this.ratio; }
  setClearColor() {} setSize() {} setAnimationLoop() {} dispose() {}
}
class Controls {
  target = new THREE.Vector3(); mouseButtons = {}; touches = {};
  constructor(camera) { this.camera = camera; }
  addEventListener() {} dispose() {}
  update() { this.camera.lookAt(this.target); this.camera.updateMatrixWorld(true); }
}
globalThis.devicePixelRatio = 1;
globalThis.matchMedia = () => ({matches: true});
globalThis.document = {hidden: false, addEventListener() {}, removeEventListener() {}};
globalThis.ResizeObserver = class { observe() {} disconnect() {} };
const source = readFileSync(new URL('../reconstruction-viewer/room-view.ts', import.meta.url), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS} }).outputText;
const exportsObject = {};
new Function('require', 'exports', code)(name => {
  if (name === 'three') return {...THREE, WebGLRenderer: Renderer};
  if (name.includes('OrbitControls')) return {OrbitControls: Controls};
  if (name === './scan-cloud') return {ScanCloud};
  if (name === './route-geometry') return routeGeometry;
  throw new Error(`Unexpected RoomView runtime import: ${name}`);
}, exportsObject);
const canvas = {clientWidth: 800, clientHeight: 600, addEventListener() {}, removeEventListener() {}};
const element = () => ({hidden: true, style: {}});
const makeRoom = () => new exportsObject.RoomView(canvas, element(), element());
const recon = (changes = {}) => ({
  epoch: 1, scan_id: 'scan-a', navigation: true, mode: 'walking', stop_reason: null, floor_y: -1,
  path: [[0, 0], [0, -1], [1, -1]], waypoint: [0, -0.6],
  grid: {origin: [0, 0], res: 0.1, w: 1, h: 1, cells: 'AA=='}, points: '', points_fused: true,
  points_version: 1, targets: [], stats: {}, ...changes,
});

test('freshness gates the entire route in every view and colour refresh cannot revive it', () => {
  const room = makeRoom();
  room.update(recon());
  assert.equal(room.routeLayer.visible, false, 'Caller must explicitly declare feed live');
  room.setRouteLive(true);
  assert.equal(room.routeLayer.visible, true);
  assert.equal(room.waypoint.visible, true);
  assert.equal(room.approachEndpoint.visible, true);
  for (const view of ['plan', '3d', 'first']) {
    room.setView(view);
    assert.equal(room.routeLayer.visible, true, `Live route can appear in ${view}`);
  }
  room.setRouteLive(false);
  for (const view of ['plan', '3d', 'first']) {
    room.setView(view);
    assert.equal(room.routeLayer.visible, false, `Stale route stays hidden in ${view}`);
  }
  room.setColourMode(true);
  assert.equal(room.routeLayer.visible, false);
  room.dispose();
});

test('stopped/disabled/invalid routes cannot be revived by changing view or marking feed live', () => {
  for (const changes of [{mode: 'stopped'}, {navigation: false}, {stop_reason: 'pathfinding_unknown'}, {floor_y: null}, {waypoint: [0, Infinity]}, {path: [[0, 0], [NaN, 1], [2, 2]]}]) {
    const room = makeRoom();
    room.update(recon());
    room.setRouteLive(true);
    room.update(recon(changes));
    room.setView('plan');
    room.setRouteLive(true);
    assert.equal(room.routeLayer.visible, false);
    assert.equal(room.routeData, null);
    room.dispose();
  }
});

test('world/reset boundaries drop both route geometry and the previous freshness permission', () => {
  const room = makeRoom();
  room.update(recon());
  room.setRouteLive(true);
  room.update(recon({scan_id: 'scan-b', epoch: 2}));
  assert.equal(room.routeLayer.visible, false);
  room.setRouteLive(true);
  assert.equal(room.routeLayer.visible, true);
  room.resetScan();
  room.setView('3d');
  room.setRouteLive(true);
  assert.equal(room.routeLayer.visible, false);
  assert.equal(room.routeData, null);
  assert.equal(room.route.geometry.getAttribute('position'), undefined);
  room.dispose();
});

test('replacing/resetting route releases old geometry while marker geometry is reused', () => {
  const room = makeRoom();
  room.update(recon());
  const meshes = [room.routeBorder, room.route, room.routeMarks];
  const old = meshes.map(mesh => mesh.geometry);
  const diamond = room.waypoint.children[1].geometry;
  let disposed = 0;
  for (const geometry of old) geometry.addEventListener('dispose', () => disposed++);
  room.update(recon({path: [[0, 0], [0, -1.5], [1, -1.5]], waypoint: [0, -0.8]}));
  assert.equal(disposed, 3);
  assert.equal(room.waypoint.children[1].geometry, diamond);
  assert.deepEqual(room.approachEndpoint.position.toArray(), [1, -0.925, -1.5]);
  const current = meshes.map(mesh => mesh.geometry);
  for (const geometry of current) geometry.addEventListener('dispose', () => disposed++);
  room.resetScan();
  assert.equal(disposed, 6);
  let markerDisposals = 0;
  diamond.addEventListener('dispose', () => markerDisposals++);
  room.dispose();
  assert.equal(markerDisposals, 1);
});
