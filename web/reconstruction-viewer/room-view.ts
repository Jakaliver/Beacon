import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { ScanCloud } from "./scan-cloud";
import type { Recon } from "./types";

const MAX_POINTS = 20_000;
const RED = 0xee5252;
const decode = (base64: string) => Uint8Array.from(atob(base64), c => c.charCodeAt(0));
const PALETTE = [[0, 0, 0, 0], [48, 48, 48, 85], [108, 108, 108, 95], [52, 52, 52, 65], [38, 38, 38, 50]];

/** Displays measured reconstruction snapshots without inventing unseen surfaces. */
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
  private floor = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.4, depthWrite: false, side: THREE.DoubleSide }));
  private texture: THREE.DataTexture | null = null;
  private grid = new THREE.GridHelper(40, 40, 0x333333, 0x272727);
  private targets = new THREE.Group();
  private targetGeometry = new THREE.BoxGeometry(1, 1, 1);
  private targetEdges = new THREE.EdgesGeometry(this.targetGeometry);
  private targetVisuals = new Map<string, {
    group: THREE.Group;
    box: THREE.Mesh<THREE.BoxGeometry, THREE.MeshBasicMaterial>;
    edges: THREE.LineSegments<THREE.EdgesGeometry, THREE.LineBasicMaterial>;
  }>();
  private route = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: 0xb0b0b0, transparent: true, opacity: 0.65 }));
  private waypoint = new THREE.Mesh(new THREE.OctahedronGeometry(0.085), new THREE.MeshBasicMaterial({ color: 0xd4d4d4 }));
  private phone = new THREE.Group();
  private phoneMaterial = new THREE.MeshBasicMaterial({ color: 0xe5e5e5, depthTest: false, side: THREE.DoubleSide });
  private recon: Recon | null = null;
  private epoch: number | null = null;
  private needsFit = true;
  private dirty = true;
  private lastFrame = 0;
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

  constructor(canvas: HTMLCanvasElement, label: HTMLElement, scaleBar: HTMLElement, phoneLabel: HTMLElement) {
    this.label = label;
    this.scaleBar = scaleBar;
    this.phoneLabel = phoneLabel;
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "low-power" });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
    this.renderer.setClearColor(0x181818, 0);
    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.enableDamping = !matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.controls.dampingFactor = 0.12;
    this.controls.minZoom = 0.35;
    this.controls.maxZoom = 8;
    this.controls.maxPolarAngle = Math.PI * 0.47;
    this.controls.minPolarAngle = 0;
    this.controls.screenSpacePanning = false;
    this.controls.addEventListener("change", () => this.invalidate());
    this.controls.addEventListener("start", () => { this.autoFit = false; });
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
    const arrow = new THREE.BufferGeometry();
    arrow.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, -0.15, -0.075, 0, 0.08, 0, 0, 0.04, 0.075, 0, 0.08], 3));
    arrow.setIndex([0, 1, 2, 0, 2, 3]);
    const heading = new THREE.Mesh(arrow, this.phoneMaterial);
    this.phone.add(heading);
    this.phone.renderOrder = 4;
    this.phone.children.forEach(child => { child.renderOrder = 4; });
    this.phone.visible = this.waypoint.visible = false;
    this.scene.add(this.grid, this.floor, this.cloud, this.targets, this.route, this.waypoint, this.phone);
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

  setAutoFit(value: boolean) { this.autoFit = value; if (value) this.fit(); }
  resetScan() { this.scan.clear(); this.scanId = undefined; this.mapVersion = undefined; this.needsFit = true; }
  focusTarget() {
    const target = this.recon?.targets.find(t => t.selected);
    if (!target) return;
    this.autoFit = false;
    this.delta.fromArray(target.position).sub(this.controls.target);
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
    this.camera.zoom = THREE.MathUtils.clamp(0.82 / Math.max(extentX, extentY), 0.35, 4);
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
      this.colors[j + 1] = inTarget ? 0.065 : shade;
      this.colors[j + 2] = inTarget ? 0.08 : shade;
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
    this.floor.visible = observed > 0;
    this.floor.scale.set(w * res, h * res, 1);
    this.floor.position.set(origin[0] + w * res / 2, floorY - 0.025, origin[1] + h * res / 2);
    this.updateTargets(recon);

    this.route.geometry.dispose();
    this.route.geometry = new THREE.BufferGeometry().setFromPoints(recon.path.map(([x, z]) => new THREE.Vector3(x, floorY + 0.06, z)));
    this.waypoint.visible = this.route.visible && !!recon.waypoint;
    if (recon.waypoint) this.waypoint.position.set(recon.waypoint[0], floorY + 0.09, recon.waypoint[1]);
    this.phone.visible = !!recon.phone.position;
    if (recon.phone.position) {
      this.phone.position.set(recon.phone.position[0], floorY + 0.1, recon.phone.position[2]);
      const f = recon.phone.forward;
      if (f) this.phone.rotation.y = Math.atan2(-f[0], -f[2]);
      this.phoneMaterial.color.setHex(recon.phone.tracking === "normal" ? 0xe5e5e5 : 0x999999);
    }
    const now = performance.now();
    if (count && (this.needsFit || this.autoFit && now - this.lastFit > 2000)) {
      this.fit(); this.needsFit = false; this.lastFit = now;
    }
    this.invalidate();
    return { points: count, area: observed * res * res };
  }

  private updateTargets(recon: Recon) {
    const selected = recon.targets.filter(t => t.selected);
    const ids = new Set(selected.map(t => t.id));
    for (const [id, visual] of this.targetVisuals) if (!ids.has(id)) {
      this.targets.remove(visual.group);
      visual.box.material.dispose(); visual.edges.material.dispose();
      this.targetVisuals.delete(id);
    }
    for (const t of selected) {
      let visual = this.targetVisuals.get(t.id);
      if (!visual) {
        const group = new THREE.Group();
        const box = new THREE.Mesh(this.targetGeometry, new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.07, depthWrite: false }));
        const edges = new THREE.LineSegments(this.targetEdges, new THREE.LineBasicMaterial({ transparent: true, depthTest: false }));
        group.add(box, edges);
        edges.renderOrder = 3;
        this.targets.add(group);
        visual = { group, box, edges };
        this.targetVisuals.set(t.id, visual);
      }
      const color = RED;
      visual.group.position.fromArray(t.position);
      const size = t.extent.map(v => Math.max(0.06, v));
      visual.box.scale.fromArray(size); visual.edges.scale.fromArray(size);
      visual.box.material.color.setHex(color); visual.edges.material.color.setHex(color);
      visual.box.material.opacity = t.valid ? 0.16 : 0.05;
      visual.edges.material.opacity = t.valid ? 1 : 0.25;
    }
  }

  private animate = (time: number) => {
    if (this.disposed || document.hidden || time - this.lastFrame < 1000 / 30) return;
    this.lastFrame = time;
    this.controls.update();
    if (!this.dirty) return;
    this.dirty = false;
    const pixelsPerMeter = this.height / (this.camera.top - this.camera.bottom) * this.camera.zoom;
    (this.cloud.material as THREE.ShaderMaterial).uniforms.pointSize.value = THREE.MathUtils.clamp(pixelsPerMeter * 0.03, 1.8, 3.8) * this.renderer.getPixelRatio();
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
