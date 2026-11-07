import type { Recon } from "./types";

// Explicit opt-in visual preview. These points are illustrative, never camera observations.
const points: number[] = [];
let seed = 42;
const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) | 0; return (seed >>> 0) / 4294967296; };
const add = (x: number, y: number, z: number) => points.push(x + (random() - .5) * .018, y + (random() - .5) * .012, z + (random() - .5) * .018);
function box(x: number, y: number, z: number, w: number, h: number, d: number, density = 520) {
  const area = 2 * (w * h + h * d + w * d);
  for (let i = 0; i < area * density; i++) {
    const face = random() * (w * d + w * h + h * d);
    let px = (random() - .5) * w, py = random() * h, pz = (random() - .5) * d;
    if (face < w * d) py = h;
    else if (face < w * d + w * h) pz = (random() < .5 ? -.5 : .5) * d;
    else px = (random() < .5 ? -.5 : .5) * w;
    add(x + px, y + py, z + pz);
  }
}
// A partial-height room boundary keeps the overhead scan readable.
for (let i = 0; i < 3200; i++) {
  const y = random() * 1.45;
  if (i % 2) add(-3 + random() * 6, y, -2.5);
  else add(-3, y, -2.5 + random() * 5);
}
for (let i = 0; i < 1400; i++) add(-3 + random() * 6, .005, -2.5 + random() * 5);
// Sofa, table, desk, chair and low cabinet, sampled as surfaces rather than loaded models.
box(-1.95, .14, -.55, 1.05, .4, 2.3, 180);
box(-2.4, .52, -.55, .2, .53, 2.3, 220);
box(-1.95, .5, -1.66, 1.05, .18, .15, 200);
box(-1.95, .5, .56, 1.05, .18, .15, 200);
box(-.15, .5, -.35, 1.15, .08, 1.45, 400);
for (const x of [-.6, .3]) for (const z of [-.9, .2]) box(x, 0, z, .06, .5, .06, 200);
box(1.9, .73, -1.88, 1.75, .08, .8, 330);
for (const x of [1.15, 2.65]) for (const z of [-2.18, -1.58]) box(x, 0, z, .06, .73, .06, 200);
box(1.9, .4, -.8, .5, .07, .5, 300);
box(1.9, .45, -.56, .5, .5, .06, 250);
box(.05, 0, -2.23, 1.5, .6, .45, 260);
// Selected bottle on the table.
for (let i = 0; i < 320; i++) {
  const angle = random() * Math.PI * 2, y = random() * .28;
  const radius = y > .22 ? .027 : .055;
  add(.15 + Math.cos(angle) * radius, .58 + y, -.48 + Math.sin(angle) * radius);
}
const encode = (data: Uint8Array) => {
  let binary = "";
  for (let i = 0; i < data.length; i += 4096) binary += String.fromCharCode(...data.subarray(i, i + 4096));
  return btoa(binary);
};
const cloud = encode(new Uint8Array(new Float32Array(points).buffer));
const cells = new Uint8Array(80 * 80);
for (let r = 15; r < 65; r++) for (let c = 10; c < 70; c++) cells[r * 80 + c] = 1;
for (let i = 0; i < points.length; i += 3) if (points[i + 1] > .15) {
  const c = Math.floor((points[i] + 4) / .1), r = Math.floor((points[i + 2] + 4) / .1);
  if (c >= 0 && c < 80 && r >= 0 && r < 80) cells[r * 80 + c] = 2;
}
const grid = { origin: [-4, -4] as [number, number], res: .1, w: 80, h: 80, cells: encode(cells) };
export function sampleRoom(time: number): Recon {
  const x = .9 + Math.sin(time * .12) * .25, z = 1.65;
  return {
    epoch: 1, perception: "preview", mode: "preview", stop_reason: null, navigation: false,
    grid, floor_y: 0, points: cloud,
    phone: { position: [x, 1.25, z], forward: [-.3, -.2, -.95], tracking: "normal" },
    listener: [x + .09, 0, z + .28],
    targets: [{ id: "bottle-01", label: "Bottle", position: [.15, .72, -.48], extent: [.14, .3, .14], sigma: .14, age: 0, valid: true, selected: true, injected: false }],
    path: [], waypoint: null, stats: {},
  };
}
