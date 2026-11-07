// The authored fake physical world. Ground truth lives here and never leaves the simulator.
import * as THREE from "three";
import { GLTFLoader } from "three/examples/jsm/loaders/GLTFLoader.js";

const A = "/assets";
type ModelSpec = { url: string; height?: number; coco?: string };
const MODELS: Record<string, ModelSpec> = {
  bottle: { url: `${A}/WaterBottle/WaterBottle.glb`, height: 0.26, coco: "bottle" },
  sofa: { url: `${A}/Sofa_01/Sofa_01.gltf`, coco: "couch" },
  chair: { url: `${A}/dining_chair_02/dining_chair_02.gltf`, coco: "chair" },
  coffeeTable: { url: `${A}/coffee_table_round_01/coffee_table_round_01.gltf`, coco: "dining table" },
  table: { url: `${A}/wooden_table_02/wooden_table_02.gltf`, coco: "dining table" },
  sideTable: { url: `${A}/WoodenTable_02/WoodenTable_02.gltf` },
  teaSet: { url: `${A}/tea_set_01/tea_set_01.gltf`, coco: "cup" },
  plant: { url: `${A}/potted_plant_01/potted_plant_01.gltf`, coco: "potted plant" },
};

const loader = new GLTFLoader();
const cache = new Map<string, Promise<THREE.Object3D>>();

function load(kind: string): Promise<THREE.Object3D> {
  if (!cache.has(kind)) {
    const spec = MODELS[kind];
    cache.set(kind, loader.loadAsync(spec.url).then((g) => {
      const root = g.scene;
      root.traverse((o) => {
        const m = o as THREE.Mesh;
        if (m.isMesh) { m.castShadow = true; m.receiveShadow = true; }
      });
      if (spec.height) {
        const box = new THREE.Box3().setFromObject(root);
        root.scale.setScalar(spec.height / (box.max.y - box.min.y));
      }
      // Put the model's base at y = 0 and its footprint centre at the origin.
      const box = new THREE.Box3().setFromObject(root);
      const c = box.getCenter(new THREE.Vector3());
      const wrap = new THREE.Group();
      root.position.sub(new THREE.Vector3(c.x, box.min.y, c.z));
      wrap.add(root);
      return wrap;
    }));
  }
  return cache.get(kind)!.then((o) => o.clone(true));
}

export type Placement = { kind: string; x: number; z: number; rot?: number; on?: string; id?: string };
export type SceneSpec = {
  name: string; title: string; room: [number, number];
  walls?: { x: number; z: number; w: number; d: number }[];
  objects: Placement[];
  start: { x: number; z: number; yaw: number };
  notes: string;
};

export const SCENES: SceneSpec[] = [
  {
    name: "clear-room", title: "M1: clear room", room: [6, 6],
    objects: [
      { kind: "bottle", x: 0.3, z: -1.6, id: "target" },
      { kind: "sofa", x: 0, z: -2.5, rot: 0 },
      { kind: "chair", x: 2.2, z: -1.0, rot: -Math.PI / 2 },
      { kind: "plant", x: -2.5, z: -2.5 },
      { kind: "sideTable", x: -2.4, z: 0.5 },
      { kind: "teaSet", x: -2.4, z: 0.5, on: "sideTable" },
    ],
    start: { x: 0, z: 1.0, yaw: 0 },
    notes: "Unobstructed room. Say or type: find the bottle.",
  },
  {
    name: "behind-table", title: "M2: target behind a table", room: [6, 6],
    objects: [
      { kind: "table", x: 0, z: -0.4 },
      { kind: "bottle", x: 1.1, z: -1.5, id: "target" },
      { kind: "chair", x: -2.2, z: -2.0, rot: Math.PI / 4 },
      { kind: "sofa", x: 0, z: -2.6 },
    ],
    start: { x: 0, z: 2.0, yaw: 0 },
    notes: "Turn route guidance on. The route must go around the table.",
  },
  {
    name: "blocked-route", title: "M2: blocked route", room: [7, 6],
    walls: [{ x: -1.6, z: -0.5, w: 3.8, d: 0.15 }, { x: 2.6, z: -0.5, w: 1.8, d: 0.15 }],
    objects: [
      { kind: "bottle", x: 0.5, z: -2.0, id: "target" },
      { kind: "plant", x: -2.8, z: -2.5 },
    ],
    start: { x: 0.5, z: 2.0, yaw: 0 },
    notes: "A partition with one gap. Use 'Drop obstacle in gap' to block it.",
  },
  {
    name: "new-obstacle", title: "M2: newly introduced obstacle", room: [6, 7],
    objects: [
      { kind: "bottle", x: 0, z: -1.2, id: "target" },
      { kind: "sofa", x: 0, z: -3.1 },
    ],
    start: { x: 0, z: 1.8, yaw: 0 },
    notes: "Start guidance, then 'Drop obstacle ahead' to place an unrecognised box.",
  },
  {
    name: "two-bottles", title: "Two similar targets", room: [6, 6],
    objects: [
      { kind: "bottle", x: -1.0, z: -1.5, id: "target" },
      { kind: "bottle", x: 1.2, z: -1.2, id: "target2" },
      { kind: "sofa", x: 0, z: -2.5 },
    ],
    start: { x: 0, z: 1.8, yaw: 0 },
    notes: "Trident must ask which bottle and must not switch silently.",
  },
  {
    name: "on-table", title: "Object on a table (close probing)", room: [6, 6],
    objects: [
      { kind: "coffeeTable", x: 0, z: -0.8 },
      { kind: "bottle", x: 0.25, z: -0.8, on: "coffeeTable", id: "target" },
      { kind: "teaSet", x: -0.3, z: -0.8, on: "coffeeTable" },
      { kind: "sofa", x: 0, z: -2.5 },
    ],
    start: { x: 0, z: 1.5, yaw: 0 },
    notes: "Walk close, then probe with the phone around the table top.",
  },
];

export class World {
  scene = new THREE.Scene();
  colliders: THREE.Box3[] = [];
  objects = new Map<string, THREE.Object3D>();
  cocoObjects: { object: THREE.Object3D; label: string }[] = [];
  spec!: SceneSpec;
  private content = new THREE.Group();

  constructor() {
    this.scene.background = new THREE.Color(0xdfe3e8);
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x8a7a66, 1.4));
    const sun = new THREE.DirectionalLight(0xfff3e0, 2.2);
    sun.position.set(2, 5, 3);
    sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048);
    Object.assign(sun.shadow.camera, { left: -5, right: 5, top: 5, bottom: -5 });
    this.scene.add(sun);
    this.scene.add(this.content);
  }

  async load(spec: SceneSpec): Promise<void> {
    this.spec = spec;
    this.scene.remove(this.content);
    this.content = new THREE.Group();
    this.scene.add(this.content);
    this.colliders = [];
    this.objects.clear();
    this.cocoObjects = [];
    this.buildRoom(spec);
    for (const p of spec.objects) {
      const o = await load(p.kind);
      let y = 0;
      if (p.on) {
        const base = [...this.objects.entries()].find(([k]) => k.startsWith(p.on!))?.[1];
        if (base) y = new THREE.Box3().setFromObject(base).max.y;
      }
      o.position.set(p.x, y, p.z);
      o.rotation.y = p.rot ?? 0;
      this.content.add(o);
      this.objects.set(p.id ?? `${p.kind}-${this.objects.size}`, o);
      const coco = MODELS[p.kind].coco;
      if (coco) this.cocoObjects.push({ object: o, label: coco });
      if (!p.on && p.kind !== "bottle" && p.kind !== "teaSet") this.colliders.push(new THREE.Box3().setFromObject(o));
    }
  }

  private buildRoom(spec: SceneSpec) {
    const [w, d] = spec.room;
    const tex = (name: string, rx: number, ry: number) => {
      const t = new THREE.TextureLoader().load(`${A}/textures/${name}.jpg`);
      t.colorSpace = THREE.SRGBColorSpace;
      t.wrapS = t.wrapT = THREE.RepeatWrapping;
      t.repeat.set(rx, ry);
      return t;
    };
    const floor = new THREE.Mesh(new THREE.PlaneGeometry(w, d),
      new THREE.MeshStandardMaterial({ map: tex("wood_floor", w / 2, d / 2), roughness: 0.8 }));
    floor.rotation.x = -Math.PI / 2;
    floor.receiveShadow = true;
    this.content.add(floor);
    const wallMat = new THREE.MeshStandardMaterial({ map: tex("beige_wall_001", 2, 1), roughness: 0.95 });
    const h = 2.6;
    // Faces down only, so the overhead view camera can see into the room.
    const ceiling = new THREE.Mesh(new THREE.PlaneGeometry(w, d), new THREE.MeshStandardMaterial({ color: 0xf2f0ea }));
    ceiling.rotation.x = Math.PI / 2;
    ceiling.position.y = h;
    this.content.add(ceiling);
    const walls = [
      { x: 0, z: -d / 2, w, d: 0.1 }, { x: 0, z: d / 2, w, d: 0.1 },
      { x: -w / 2, z: 0, w: 0.1, d }, { x: w / 2, z: 0, w: 0.1, d },
      ...(spec.walls ?? []),
    ];
    for (const b of walls) this.addBox(b.x, b.z, b.w, b.d, h, wallMat);
  }

  addBox(x: number, z: number, w: number, d: number, h: number, mat: THREE.Material): THREE.Mesh {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
    m.position.set(x, h / 2, z);
    m.castShadow = m.receiveShadow = true;
    this.content.add(m);
    this.colliders.push(new THREE.Box3().setFromObject(m));
    return m;
  }

  dropCardboardBox(x: number, z: number): void {
    const mat = new THREE.MeshStandardMaterial({ color: 0xa0784c, roughness: 0.9 });
    this.addBox(x, z, 0.7, 0.6, 0.6, mat);
  }

  collides(p: THREE.Vector3, radius: number): boolean {
    const sphere = new THREE.Sphere(new THREE.Vector3(p.x, 0.5, p.z), radius);
    return this.colliders.some((b) => b.intersectsSphere(sphere));
  }
}
