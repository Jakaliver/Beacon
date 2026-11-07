import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { ScanCloud } from "./scan-cloud";
import type { Recon } from "./types";

const MAX_POINTS = 20_000;
const RED = 0xff4b50;
const decode = (base64: string) => Uint8Array.from(atob(base64), c => c.charCodeAt(0));
const PALETTE = [[0, 0, 0, 0], [40, 48, 54, 110], [108, 119, 127, 125], [47, 55, 62, 75], [32, 39, 45, 60]];

/** Only consumes reconstruction snapshots. No simulator geometry or inferred furniture. */
export class RoomView {
  readonly renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.OrthographicCamera(-6, 6, 6, -6, 0.05, 100);
  private controls: OrbitControls;
  private cloudGeometry = new THREE.BufferGeometry();
  private positions = new Float32Array(MAX_POINTS * 3);
  private colors = new Float32Array(MAX_POINTS * 3);
  private cloud: THREE.Points;
  private scan = new ScanCloud(MAX_POINTS);
  private scanId: string | undefined;
  private mapVersion: number | boolean | null | undefined;
  private autoFit = true;
  private lastFit = 0;
  private showDetections = false;
  private showFloor = true;
  private floor = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, side: THREE.DoubleSide }));
  private texture: THREE.DataTexture | null = null;
  private grid = new THREE.GridHelper(40, 40, 0x303b45, 0x1c252d);
  private targets = new THREE.Group();
  private targetGeometry = new THREE.BoxGeometry(1, 1, 1);
  private targetEdges = new THREE.EdgesGeometry(this.targetGeometry);
  private ringGeometry = new THREE.BufferGeometry().setFromPoints(Array.from({ length: 65 }, (_, i) => new THREE.Vector3(Math.cos(i / 64 * Math.PI * 2), 0, Math.sin(i / 64 * Math.PI * 2))));
  private targetVisuals = new Map<string, {
    group: THREE.Group;
    box: THREE.Mesh<THREE.BoxGeometry, THREE.MeshBasicMaterial>;
    edges: THREE.LineSegments<THREE.EdgesGeometry, THREE.LineBasicMaterial>;
    ring: THREE.Line<THREE.BufferGeometry, THREE.LineBasicMaterial>;
    stem: THREE.Line<THREE.BufferGeometry, THREE.LineBasicMaterial>;
  }>();
  private route = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: 0xa5cbd1, transparent: true, opacity: 0.85 }));
  private waypoint = new THREE.Mesh(new THREE.OctahedronGeometry(0.085), new THREE.MeshBasicMaterial({ color: 0xc1e2e6 }));
  private phone = new THREE.Group();
  private phoneMaterial = new THREE.MeshBasicMaterial({ color: 0xe8eff2, depthTest: false });
  private body = new THREE.Line(this.ringGeometry, new THREE.LineBasicMaterial({ color: 0x8b9ba5, transparent: true, opacity: 0.6 }));
  private recon: Recon | null = null;
  private epoch: number | null = null;
  private needsFit = true;
  private dirty = true;
  private lastFrame = 0;
  private following = false;
  private disposed = false;
  private width = 1;
  private height = 1;
  private resizeObserver: ResizeObserver;
  private anchor = new THREE.Vector3();
  private project = new THREE.Vector3();
  private delta = new THREE.Vector3();
  private label: HTMLElement;
  private scaleBar: HTMLElement;
  private phoneLabel: HTMLElement;
  onInteract = () => {};

  constructor(canvas: HTMLCanvasElement, label: HTMLElement, scaleBar: HTMLElement, phoneLabel: HTMLElement) {
    this.label = label;
    this.scaleBar = scaleBar;
    this.phoneLabel = phoneLabel;
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "low-power" });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
    this.renderer.setClearColor(0x0c1117, 0);
    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.enableDamping = !matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.controls.dampingFactor = 0.12;
    this.controls.minZoom = 0.35;
    this.controls.maxZoom = 8;
    this.controls.maxPolarAngle = Math.PI * 0.47;
    this.controls.minPolarAngle = 0;
    this.controls.screenSpacePanning = false;
    this.controls.addEventListener("change", () => this.invalidate());
    this.controls.addEventListener("start", () => { this.following = false; this.autoFit = false; this.onInteract(); });
    this.setView("3d");

    this.cloudGeometry.setAttribute("position", new THREE.BufferAttribute(this.positions, 3).setUsage(THREE.DynamicDrawUsage));
    this.cloudGeometry.setAttribute("color", new THREE.BufferAttribute(this.colors, 3).setUsage(THREE.DynamicDrawUsage));
    this.cloudGeometry.setDrawRange(0, 0);
    // Soft circular splats in one draw call; no textures, lights, shadows or postprocessing.
    const material = new THREE.ShaderMaterial({
      vertexColors: true, transparent: true, depthWrite: true,
      uniforms: { pointSize: { value: 3 * this.renderer.getPixelRatio() } },
      vertexShader: `uniform float pointSize; varying vec3 vColor;
        void main() { vColor = color; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); gl_PointSize = pointSize; }`,
      fragmentShader: `varying vec3 vColor;
        void main() { float r = length(gl_PointCoord - 0.5); if (r > 0.5) discard;
          gl_FragColor = vec4(vColor, (1.0 - smoothstep(0.3, 0.5, r)) * 0.9);
          #include <tonemapping_fragment>
          #include <colorspace_fragment>
        }`,
    });
    this.cloud = new THREE.Points(this.cloudGeometry, material);
    this.cloud.frustumCulled = false;
    this.floor.rotation.x = -Math.PI / 2;
    this.floor.visible = false;
    const dot = new THREE.Mesh(new THREE.SphereGeometry(0.085, 12, 8), this.phoneMaterial);
    const heading = new THREE.Mesh(new THREE.ConeGeometry(0.11, 0.32, 3), this.phoneMaterial);
    heading.rotation.x = -Math.PI / 2;
    heading.position.z = -0.23;
    const fov = new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(-0.65, 0, -1.05), new THREE.Vector3(0, 0, 0), new THREE.Vector3(0.65, 0, -1.05),
    ]);
    const halo = new THREE.Line(this.ringGeometry, new THREE.LineBasicMaterial({ color: 0xd4e3ec, transparent: true, opacity: 0.8, depthTest: false }));
    halo.scale.setScalar(0.22);
    this.phone.add(dot, heading, halo, new THREE.Line(fov, new THREE.LineBasicMaterial({ color: 0x91a8b6, transparent: true, opacity: 0.55, depthTest: false })));
    this.phone.renderOrder = 4;
    this.phone.children.forEach(child => { child.renderOrder = 4; });
    this.body.scale.setScalar(0.22);
    this.phone.visible = this.body.visible = this.waypoint.visible = false;
    this.scene.add(this.grid, this.floor, this.cloud, this.targets, this.route, this.waypoint, this.phone, this.body);
    this.resizeObserver = new ResizeObserver(() => this.resize(canvas));
    this.resizeObserver.observe(canvas);
    canvas.addEventListener("webglcontextlost", this.contextLost);
    canvas.addEventListener("webglcontextrestored", this.contextRestored);
    document.addEventListener("visibilitychange", this.visibilityChanged);
    this.renderer.setAnimationLoop(this.animate);
  }

  private invalidate() { this.dirty = true; }
  private visibilityChanged = () => this.invalidate();
  private contextLost = (event: Event) => { event.preventDefault(); this.renderer.setAnimationLoop(null); };
  private contextRestored = () => { this.invalidate(); this.renderer.setAnimationLoop(this.animate); };

  private resize(canvas: HTMLCanvasElement) {
    this.width = Math.max(1, canvas.clientWidth);
    this.height = Math.max(1, canvas.clientHeight);
    const aspect = this.width / this.height;
    this.camera.left = -5.5 * aspect;
    this.camera.right = 5.5 * aspect;
    this.camera.top = 5.5;
    this.camera.bottom = -5.5;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(this.width, this.height, false);
    if (this.autoFit) this.fit();
    this.invalidate();
  }

  setView(view: "3d" | "plan") {
    const offset = view === "plan" ? new THREE.Vector3(0, 14, 0.001) : new THREE.Vector3(4, 12, 6);
    this.camera.position.copy(this.controls.target).add(offset);
    this.controls.enableRotate = view !== "plan";
    this.controls.mouseButtons.LEFT = view === "plan" ? THREE.MOUSE.PAN : THREE.MOUSE.ROTATE;
    this.controls.touches.ONE = view === "plan" ? THREE.TOUCH.PAN : THREE.TOUCH.ROTATE;
    this.camera.lookAt(this.controls.target);
    this.controls.update();
    if (this.autoFit) this.fit();
    this.invalidate();
  }

  setFollow(value: boolean) { this.following = value; if (value) { this.autoFit = false; this.follow(); } }
  setAutoFit(value: boolean) { this.autoFit = value; if (value) { this.following = false; this.fit(); } }
  resetScan() { this.scan.clear(); this.scanId = undefined; this.mapVersion = undefined; this.needsFit = true; }
  focusTarget() {
    const target = this.recon?.targets.find(t => t.selected);
    if (!target) return;
    this.following = false;
    this.autoFit = false;
    this.onInteract();
    this.delta.fromArray(target.position).sub(this.controls.target);
    this.camera.position.add(this.delta);
    this.controls.target.add(this.delta);
    this.controls.update();
    this.invalidate();
  }
  setLayer(layer: "points" | "floor" | "route" | "detections", visible: boolean) {
    if (layer === "points") this.cloud.visible = visible;
    if (layer === "floor") { this.showFloor = visible; this.floor.visible = visible && !!this.texture; }
    if (layer === "route") { this.route.visible = visible; this.waypoint.visible = visible && !!this.recon?.waypoint; }
    if (layer === "detections") { this.showDetections = visible; if (this.recon) this.updateTargets(this.recon, this.recon.floor_y ?? 0); }
    this.invalidate();
  }

  private follow() {
    const p = this.recon?.phone.position;
    if (!p) return;
    this.delta.set(p[0], this.recon?.floor_y ?? 0, p[2]).sub(this.controls.target);
    this.camera.position.add(this.delta);
    this.controls.target.add(this.delta);
    this.controls.update();
    this.invalidate();
  }

  fit() {
    if (!this.recon) return;
    const box = new THREE.Box3();
    const count = this.cloudGeometry.drawRange.count;
    for (let i = 0; i < count; i++) box.expandByPoint(this.project.fromArray(this.positions, i * 3));
    for (const t of this.recon.targets) if (t.selected) box.expandByPoint(this.project.fromArray(t.position));
    if (this.recon.phone.position) box.expandByPoint(this.project.fromArray(this.recon.phone.position));
    if (box.isEmpty()) return;
    box.getCenter(this.anchor);
    // Centre the full height of the scan, not just its floor, to keep walls on screen.
    this.delta.copy(this.anchor).sub(this.controls.target);
    this.camera.position.add(this.delta);
    this.controls.target.copy(this.anchor);
    this.camera.zoom = 1;
    this.camera.updateProjectionMatrix();
    this.camera.lookAt(this.anchor);
    this.camera.updateMatrixWorld();
    // Fit projected bounds, including height, for both plan and oblique views.
    let extentX = 0.25, extentY = 0.25;
    for (const x of [box.min.x, box.max.x]) for (const y of [box.min.y, box.max.y]) for (const z of [box.min.z, box.max.z]) {
      this.project.set(x, y, z).project(this.camera);
      extentX = Math.max(extentX, Math.abs(this.project.x));
      extentY = Math.max(extentY, Math.abs(this.project.y));
    }
    this.camera.zoom = THREE.MathUtils.clamp(0.76 / Math.max(extentX, extentY), 0.35, 2.5);
    this.camera.updateProjectionMatrix();
    this.controls.update();
    this.invalidate();
  }

  update(recon: Recon): { points: number; area: number } {
    if (recon.epoch !== this.epoch || recon.scan_id !== this.scanId) {
      this.resetScan(); this.epoch = recon.epoch; this.scanId = recon.scan_id;
    }
    this.recon = recon;
    const floorY = recon.floor_y ?? 0;
    this.grid.position.set(Math.round(recon.grid.origin[0] + recon.grid.w * recon.grid.res / 2), floorY - 0.04, Math.round(recon.grid.origin[1] + recon.grid.h * recon.grid.res / 2));
    const version = recon.stats.map_version;
    if (version === undefined || version !== this.mapVersion) {
      const bytes = decode(recon.points);
      const points = new Float32Array(bytes.buffer, 0, Math.floor(bytes.byteLength / 12) * 3);
      this.scan.add(points, performance.now());
      this.mapVersion = version;
    }
    const selected = recon.targets.find(t => t.selected && t.valid);
    const count = this.scan.writeTo(this.positions);
    for (let j = 0; j < count * 3; j += 3) {
      const x = this.positions[j], y = this.positions[j + 1], z = this.positions[j + 2];
      const inTarget = selected
        && Math.abs(x - selected.position[0]) < selected.extent[0] / 2 + 0.025
        && Math.abs(y - selected.position[1]) < selected.extent[1] / 2 + 0.025
        && Math.abs(z - selected.position[2]) < selected.extent[2] / 2 + 0.025;
      // Quiet floor returns; bright furniture and walls make height legible.
      const shade = THREE.MathUtils.clamp(0.20 + (y - floorY) * 0.40, 0.16, 0.9);
      this.colors[j] = inTarget ? 1 : shade;
      this.colors[j + 1] = inTarget ? 0.065 : shade * 1.03;
      this.colors[j + 2] = inTarget ? 0.08 : shade * 1.07;
    }
    this.cloudGeometry.setDrawRange(0, count);
    this.cloudGeometry.attributes.position.needsUpdate = this.cloudGeometry.attributes.color.needsUpdate = true;

    const { w, h, res, origin } = recon.grid;
    if (!this.texture || this.texture.image.width !== w || this.texture.image.height !== h) {
      this.texture?.dispose();
      this.texture = new THREE.DataTexture(new Uint8Array(w * h * 4), w, h);
      this.texture.colorSpace = THREE.SRGBColorSpace;
      this.texture.magFilter = this.texture.minFilter = THREE.NearestFilter;
      this.floor.material.map = this.texture;
      this.floor.material.needsUpdate = true;
    }
    const cells = decode(recon.grid.cells);
    const pixels = this.texture.image.data as Uint8Array;
    let observed = 0;
    for (let row = 0; row < h; row++) for (let col = 0; col < w; col++) {
      const cell = cells[row * w + col] ?? 0;
      if (cell) observed++;
      // Plane UV +Y maps to world -Z; reverse rows so the occupancy map matches the cloud.
      pixels.set(PALETTE[cell] ?? PALETTE[0], ((h - 1 - row) * w + col) * 4);
    }
    this.texture.needsUpdate = true;
    this.floor.visible = this.showFloor && observed > 0;
    this.floor.scale.set(w * res, h * res, 1);
    this.floor.position.set(origin[0] + w * res / 2, floorY - 0.025, origin[1] + h * res / 2);
    this.updateTargets(recon, floorY);

    this.route.geometry.dispose();
    this.route.geometry = new THREE.BufferGeometry().setFromPoints(recon.path.map(([x, z]) => new THREE.Vector3(x, floorY + 0.06, z)));
    this.waypoint.visible = this.route.visible && !!recon.waypoint;
    if (recon.waypoint) this.waypoint.position.set(recon.waypoint[0], floorY + 0.09, recon.waypoint[1]);
    this.phone.visible = !!recon.phone.position;
    if (recon.phone.position) {
      this.phone.position.set(recon.phone.position[0], floorY + 0.1, recon.phone.position[2]);
      const f = recon.phone.forward;
      if (f) this.phone.rotation.y = Math.atan2(-f[0], -f[2]);
      this.phoneMaterial.color.setHex(recon.phone.tracking === "normal" ? 0xe8eff2 : 0xdba866);
    }
    this.body.visible = !!recon.listener;
    if (recon.listener) this.body.position.set(recon.listener[0], floorY + 0.05, recon.listener[2]);
    const now = performance.now();
    if (count && (this.needsFit || this.autoFit && now - this.lastFit > 2000)) {
      this.fit(); this.needsFit = false; this.lastFit = now;
    }
    if (this.following) this.follow();
    this.invalidate();
    return { points: count, area: observed * res * res };
  }

  private updateTargets(recon: Recon, floorY: number) {
    const ids = new Set(recon.targets.map(t => t.id));
    for (const [id, visual] of this.targetVisuals) if (!ids.has(id)) {
      this.targets.remove(visual.group);
      visual.box.material.dispose(); visual.edges.material.dispose(); visual.ring.material.dispose();
      visual.stem.geometry.dispose(); visual.stem.material.dispose();
      this.targetVisuals.delete(id);
    }
    for (const t of recon.targets) {
      let visual = this.targetVisuals.get(t.id);
      if (!visual) {
        const group = new THREE.Group();
        const box = new THREE.Mesh(this.targetGeometry, new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.07, depthWrite: false }));
        const edges = new THREE.LineSegments(this.targetEdges, new THREE.LineBasicMaterial({ transparent: true, depthTest: false }));
        const ring = new THREE.Line(this.ringGeometry, new THREE.LineBasicMaterial({ transparent: true, depthTest: false }));
        const stem = new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3(0, 1, 0)]), new THREE.LineBasicMaterial({ color: RED, transparent: true, opacity: 0.65, depthTest: false }));
        group.add(box, edges, ring, stem);
        edges.renderOrder = ring.renderOrder = stem.renderOrder = 3;
        this.targets.add(group);
        visual = { group, box, edges, ring, stem };
        this.targetVisuals.set(t.id, visual);
      }
      const color = t.selected ? RED : 0x8d9aa4;
      visual.group.visible = t.selected || this.showDetections;
      visual.group.position.fromArray(t.position);
      const size = t.extent.map(v => Math.max(0.06, v));
      visual.box.scale.fromArray(size); visual.edges.scale.fromArray(size);
      visual.box.material.color.setHex(color); visual.edges.material.color.setHex(color); visual.ring.material.color.setHex(color);
      visual.box.material.opacity = t.valid ? (t.selected ? 0.24 : 0.025) : 0.08;
      visual.edges.material.opacity = t.valid ? (t.selected ? 1 : 0.45) : 0.25;
      visual.ring.material.opacity = t.valid ? (t.selected ? 0.95 : 0.2) : 0.35;
      visual.ring.position.y = floorY + 0.065 - t.position[1];
      visual.ring.scale.setScalar(Math.max(t.sigma, size[0] / 2, size[2] / 2, 0.18));
      visual.stem.visible = t.selected;
      visual.stem.position.y = visual.ring.position.y;
      visual.stem.scale.y = Math.max(0, -visual.ring.position.y);
    }
  }

  private animate = (time: number) => {
    if (this.disposed || document.hidden || time - this.lastFrame < 1000 / 30) return;
    this.lastFrame = time;
    this.controls.update();
    if (!this.dirty) return;
    this.dirty = false;
    const pixelsPerMeter = this.height / (this.camera.top - this.camera.bottom) * this.camera.zoom;
    (this.cloud.material as THREE.ShaderMaterial).uniforms.pointSize.value = THREE.MathUtils.clamp(pixelsPerMeter * 0.04, 2.4, 5) * this.renderer.getPixelRatio();
    this.renderer.render(this.scene, this.camera);
    const t = this.recon?.targets.find(target => target.selected);
    this.label.hidden = !t;
    if (t) {
      this.project.set(t.position[0], t.position[1] + t.extent[1] / 2 + 0.15, t.position[2]).project(this.camera);
      this.label.hidden = Math.abs(this.project.x) > 0.92 || Math.abs(this.project.y) > 0.9 || Math.abs(this.project.z) > 1;
      this.label.style.left = `${(this.project.x + 1) * this.width / 2}px`;
      this.label.style.top = `${(1 - this.project.y) * this.height / 2}px`;
    }
    this.phoneLabel.hidden = !this.recon?.phone.position;
    if (this.recon?.phone.position) {
      this.project.copy(this.phone.position).project(this.camera);
      this.phoneLabel.hidden = Math.abs(this.project.x) > 0.90 || Math.abs(this.project.y) > 0.85;
      this.phoneLabel.style.left = `${(this.project.x + 1) * this.width / 2}px`;
      this.phoneLabel.style.top = `${(1 - this.project.y) * this.height / 2 + 28}px`;
    }
    this.scaleBar.style.width = `${pixelsPerMeter}px`;
  };

  dispose() {
    this.disposed = true;
    this.renderer.setAnimationLoop(null);
    this.resizeObserver.disconnect(); this.controls.dispose();
    document.removeEventListener("visibilitychange", this.visibilityChanged);
    this.renderer.domElement.removeEventListener("webglcontextlost", this.contextLost);
    this.renderer.domElement.removeEventListener("webglcontextrestored", this.contextRestored);
    const geometries = new Set<THREE.BufferGeometry>();
    const materials = new Set<THREE.Material>();
    this.scene.traverse(object => {
      if (object instanceof THREE.Mesh || object instanceof THREE.Line || object instanceof THREE.Points) {
        geometries.add(object.geometry);
        for (const material of Array.isArray(object.material) ? object.material : [object.material]) materials.add(material);
      }
    });
    geometries.add(this.targetGeometry); geometries.add(this.targetEdges);
    geometries.forEach(g => g.dispose()); materials.forEach(m => m.dispose());
    this.texture?.dispose(); this.renderer.dispose();
  }
}
