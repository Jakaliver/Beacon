import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { ScanCloud } from "./scan-cloud";
import type { PhoneLocation } from "./phone-state";
import type { Recon } from "./types";

const MAX_POINTS = 60_000;
const RED = 0xee5252;
const ORBIT_ELEVATION = Math.PI / 6;
const decode = (base64: string) => {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
};
const PALETTE = [[0, 0, 0, 0], [48, 48, 48, 85], [108, 108, 108, 95], [52, 52, 52, 65], [38, 38, 38, 50]];
const roundedRectangle = (width: number, height: number, radius: number) => {
  const x = -width / 2, y = -height / 2;
  const shape = new THREE.Shape();
  shape.moveTo(x + radius, y);
  shape.lineTo(x + width - radius, y);
  shape.quadraticCurveTo(x + width, y, x + width, y + radius);
  shape.lineTo(x + width, y + height - radius);
  shape.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
  shape.lineTo(x + radius, y + height);
  shape.quadraticCurveTo(x, y + height, x, y + height - radius);
  shape.lineTo(x, y + radius);
  shape.quadraticCurveTo(x, y, x + radius, y);
  return shape;
};
export type RoomViewMode = "3d" | "first";

/** Displays measured reconstruction snapshots without inventing unseen surfaces. */
export class RoomView {
  readonly renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.OrthographicCamera(-6, 6, 6, -6, 0.05, 100);
  private firstPersonCamera = new THREE.PerspectiveCamera(70, 1, 0.03, 80);
  private viewMode: RoomViewMode = "3d";
  private hasPhonePose = false;
  private phonePosition = new THREE.Vector3();
  private phoneRotation = new THREE.Quaternion();
  private firstPersonRotation = new THREE.Quaternion();
  private phoneForward = new THREE.Vector3(0, 0, -1);
  private phoneUp = new THREE.Vector3(0, 1, 0);
  private phoneState: PhoneLocation["state"] = "waiting";
  private phoneFloorY: number | null = null;
  private phoneHeight: number | null = null;
  private hasPhoneHeading = false;
  private phoneBasis = new THREE.Matrix4();
  private worldUp = new THREE.Vector3(0, 1, 0);
  private controls: OrbitControls;
  private cloudGeometry = new THREE.BufferGeometry();
  private positions = new Float32Array(MAX_POINTS * 3);
  private colors = new Float32Array(MAX_POINTS * 3);
  private imageColors: Uint8Array | null = null;
  private decodedCount = 0;
  private colourMode = false;
  private rgb = new THREE.Color();
  private cloud: THREE.Points;
  private scan = new ScanCloud(MAX_POINTS);
  private scanId: string | undefined;
  private mapVersion: number | boolean | null | undefined;
  // The point colours, floor texture and route are rebuilt only when their inputs change.
  private cloudKey = "";
  private gridCells = "";
  private routeKey = "";
  private pointCount = 0;
  private observedCells = 0;
  private autoFit = true;
  private orbit = false;
  private lastFit = 0;
  private floor = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.4, depthWrite: false, side: THREE.DoubleSide }));
  private texture: THREE.DataTexture | null = null;
  private hasFloor = false;
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
  private phoneModel = new THREE.Group();
  private phoneHeading = new THREE.Group();
  private phoneMaterial = new THREE.MeshBasicMaterial({ color: 0xb8e4eb, transparent: true, depthTest: false, depthWrite: false, side: THREE.DoubleSide });
  private phoneOutlineMaterial = new THREE.LineBasicMaterial({ color: 0xb8e4eb, transparent: true, opacity: 0.85, depthTest: false, depthWrite: false });
  private phoneSurfaces: THREE.MeshBasicMaterial[] = [];
  private phoneHeightPositions = new Float32Array(6);
  private phoneHeightLine = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: 0xb8e4eb, transparent: true, opacity: 0.6, depthTest: false, depthWrite: false }));
  private phoneFootprint = new THREE.Mesh(new THREE.RingGeometry(0.085, 0.105, 24), this.phoneMaterial);
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

  constructor(canvas: HTMLCanvasElement, label: HTMLElement, scaleBar: HTMLElement) {
    this.label = label;
    this.scaleBar = scaleBar;
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "low-power" });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
    this.renderer.setClearColor(0x181818, 0);
    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.enableDamping = !matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.controls.dampingFactor = 0.12;
    this.controls.autoRotateSpeed = 60 / 90; // One full turn in 90 seconds.
    this.controls.minZoom = 0.35;
    this.controls.maxZoom = 8;
    this.controls.maxPolarAngle = Math.PI * 0.47;
    this.controls.minPolarAngle = 0;
    this.controls.screenSpacePanning = false;
    this.controls.addEventListener("change", () => this.invalidate());
    this.controls.addEventListener("start", () => {
      this.autoFit = false;
      this.orbit = this.controls.autoRotate = false;
    });
    this.setView("3d");

    this.cloudGeometry.setAttribute("position", new THREE.BufferAttribute(this.positions, 3).setUsage(THREE.DynamicDrawUsage));
    this.cloudGeometry.setAttribute("color", new THREE.BufferAttribute(this.colors, 3).setUsage(THREE.DynamicDrawUsage));
    this.cloudGeometry.setDrawRange(0, 0);
    // Soft circular splats in one draw call; no textures, lights, shadows or postprocessing.
    const material = new THREE.ShaderMaterial({
      vertexColors: true, transparent: true, depthWrite: true,
      uniforms: { pointSize: { value: 3 * this.renderer.getPixelRatio() }, colourMode: { value: 0 },
        perspectiveScale: { value: 0 }, pixelRatio: { value: this.renderer.getPixelRatio() } },
      vertexShader: `uniform float pointSize; uniform float perspectiveScale; uniform float pixelRatio; varying vec3 vColor;
        void main() {
          vColor = color;
          vec4 viewPosition = modelViewMatrix * vec4(position, 1.0);
          gl_Position = projectionMatrix * viewPosition;
          gl_PointSize = perspectiveScale > 0.0
            ? clamp(perspectiveScale / max(-viewPosition.z, 0.03), 1.8 * pixelRatio, 12.0 * pixelRatio)
            : pointSize;
        }`,
      fragmentShader: `varying vec3 vColor; uniform float colourMode;
        void main() { float r = length(gl_PointCoord - 0.5); if (r > 0.5) discard;
          float edge = 1.0 - smoothstep(0.3, 0.5, r);
          float alpha = mix(edge * 0.9, exp(-r * r * 4.0) * edge, colourMode);
          gl_FragColor = vec4(vColor, alpha);
          #include <tonemapping_fragment>
          #include <colorspace_fragment>
        }`,
    });
    this.cloud = new THREE.Points(this.cloudGeometry, material);
    this.cloud.frustumCulled = false;
    this.floor.rotation.x = -Math.PI / 2;
    this.floor.visible = false;
    const surface = (color: number) => {
      const material = new THREE.MeshBasicMaterial({ color, transparent: true, depthTest: false, depthWrite: false });
      this.phoneSurfaces.push(material);
      return material;
    };
    // A solid phone, independent of the reconstruction: local −Z is the rear camera's
    // optical direction, +Z is the screen, and +Y runs towards the top of the handset.
    const bodyGeometry = new THREE.ExtrudeGeometry(roundedRectangle(0.09, 0.18, 0.012), { depth: 0.012, bevelEnabled: false, curveSegments: 4 });
    bodyGeometry.translate(0, 0, -0.006);
    const body = new THREE.Mesh(bodyGeometry, surface(0x30383d));
    const outline = new THREE.LineSegments(new THREE.EdgesGeometry(bodyGeometry, 35), this.phoneOutlineMaterial);
    const screen = new THREE.Mesh(new THREE.ShapeGeometry(roundedRectangle(0.076, 0.158, 0.008), 4), surface(0x416b78));
    screen.position.z = 0.0065;
    const earpiece = new THREE.Mesh(new THREE.BoxGeometry(0.022, 0.003, 0.001), surface(0x9ab6bd));
    earpiece.position.set(0, 0.071, 0.0075);
    const cameraHousing = new THREE.Mesh(new THREE.BoxGeometry(0.025, 0.043, 0.003), surface(0x536068));
    cameraHousing.position.set(-0.024, 0.055, -0.0075);
    const lensGeometry = new THREE.CylinderGeometry(0.006, 0.006, 0.002, 12);
    const lensMaterial = surface(0x081b25);
    for (const y of [0.045, 0.065]) {
      const lens = new THREE.Mesh(lensGeometry, lensMaterial);
      lens.rotation.x = Math.PI / 2;
      lens.position.set(-0.024, y, -0.01);
      this.phoneModel.add(lens);
    }
    this.phoneModel.add(body, outline, screen, earpiece, cameraHousing);
    this.phoneModel.traverse(child => { child.renderOrder = 5; });
    outline.renderOrder = 6;
    const arrow = new THREE.BufferGeometry();
    arrow.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, -0.16, -0.035, 0, -0.10, 0, 0, -0.12, 0.035, 0, -0.10], 3));
    arrow.setIndex([0, 1, 2, 0, 2, 3]);
    const heading = new THREE.Mesh(arrow, this.phoneMaterial);
    heading.renderOrder = 4;
    this.phoneHeading.add(heading);
    this.phoneHeightLine.geometry.setAttribute("position", new THREE.BufferAttribute(this.phoneHeightPositions, 3).setUsage(THREE.DynamicDrawUsage));
    this.phoneHeightLine.frustumCulled = false;
    this.phoneHeightLine.renderOrder = 3;
    this.phoneFootprint.rotation.x = -Math.PI / 2;
    this.phoneFootprint.renderOrder = 4;
    this.phone.add(this.phoneModel, this.phoneHeading, this.phoneHeightLine, this.phoneFootprint);
    this.phoneHeightLine.visible = this.phoneFootprint.visible = false;
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
    this.firstPersonCamera.aspect = aspect;
    this.firstPersonCamera.updateProjectionMatrix();
    this.renderer.setSize(this.width, this.height, false);
    if (this.autoFit) this.fit();
    this.invalidate();
  }

  setView(view: RoomViewMode) {
    this.viewMode = view;
    const firstPerson = view === "first";
    this.controls.enabled = !firstPerson;
    this.orbit = view === "3d";
    this.controls.autoRotate = false;
    this.autoFit = !firstPerson;
    this.grid.visible = !firstPerson;
    this.floor.visible = !firstPerson && this.hasFloor;
    this.phone.visible = !firstPerson && this.hasPhonePose;
    this.route.visible = !firstPerson;
    this.waypoint.visible = !firstPerson && !!this.recon?.waypoint;
    if (firstPerson) {
      if (this.hasPhonePose) {
        this.firstPersonCamera.position.copy(this.phonePosition);
        this.firstPersonCamera.quaternion.copy(this.firstPersonRotation);
      }
      this.invalidate();
      return;
    }
    const offset = new THREE.Vector3().setFromSphericalCoords(14, Math.PI / 2 - ORBIT_ELEVATION, Math.PI / 4);
    this.camera.position.copy(this.controls.target).add(offset);
    this.camera.lookAt(this.controls.target);
    this.controls.update(0);
    if (this.autoFit) this.fit();
    this.invalidate();
  }

  setAutoFit(value: boolean) { this.autoFit = value; if (value) this.fit(); }
  setColourMode(enabled: boolean) {
    this.colourMode = enabled;
    (this.cloud.material as THREE.ShaderMaterial).uniforms.colourMode.value = Number(enabled);
    if (this.recon) this.update(this.recon);
  }
  resetScan() {
    this.resetReconstruction();
    this.scanId = undefined;
    this.epoch = null;
    this.clearPhone();
    this.invalidate();
  }

  private resetReconstruction() {
    this.scan.clear();
    this.decodedCount = this.pointCount = this.observedCells = 0;
    this.imageColors = null;
    this.mapVersion = undefined;
    this.cloudKey = this.gridCells = this.routeKey = "";
    this.cloudGeometry.setDrawRange(0, 0);
    this.route.geometry.setDrawRange(0, 0);
    this.hasFloor = false;
    this.floor.visible = this.route.visible = this.waypoint.visible = false;
    this.recon = null;
    this.label.hidden = true;
    this.needsFit = true;
    for (const visual of this.targetVisuals.values()) {
      this.targets.remove(visual.group);
      visual.box.material.dispose();
      visual.edges.material.dispose();
    }
    this.targetVisuals.clear();
  }

  private clearPhone() {
    this.hasPhonePose = this.hasPhoneHeading = false;
    this.phoneFloorY = this.phoneHeight = null;
    this.phoneState = "waiting";
    this.phonePosition.set(0, 0, 0);
    this.phoneRotation.identity();
    this.firstPersonRotation.identity();
    this.phoneForward.set(0, 0, -1);
    this.phone.visible = this.phoneHeightLine.visible = this.phoneFootprint.visible = false;
  }

  focusPhone() {
    if (!this.hasPhonePose) return;
    if (this.viewMode === "first") {
      this.firstPersonCamera.position.copy(this.phonePosition);
      this.firstPersonCamera.quaternion.copy(this.firstPersonRotation);
    } else {
      this.autoFit = false;
      this.orbit = this.controls.autoRotate = false;
      this.delta.copy(this.phonePosition).sub(this.controls.target);
      this.camera.position.add(this.delta);
      this.controls.target.copy(this.phonePosition);
      const inspectZoom = 55 * (this.camera.top - this.camera.bottom) / (this.height * 0.18);
      this.camera.zoom = THREE.MathUtils.clamp(Math.max(this.camera.zoom, inspectZoom), this.controls.minZoom, this.controls.maxZoom);
      this.camera.updateProjectionMatrix();
      this.controls.update(0);
    }
    this.invalidate();
  }
  focusTarget() {
    if (this.viewMode === "first") return;
    const target = this.recon?.targets.find(t => t.selected);
    if (!target) return;
    this.autoFit = false;
    this.orbit = this.controls.autoRotate = false;
    this.delta.fromArray(target.position).sub(this.controls.target);
    this.camera.position.add(this.delta);
    this.controls.target.add(this.delta);
    this.controls.update(0);
    this.invalidate();
  }

  fit() {
    if (this.viewMode === "first") return;
    const box = new THREE.Box3();
    const count = this.pointCount;
    for (let i = 0; i < count; i++) box.expandByPoint(this.project.fromArray(this.positions, i * 3));
    for (const t of this.recon?.targets ?? []) if (t.selected) box.expandByPoint(this.project.fromArray(t.position));
    if (this.hasPhonePose) {
      box.expandByPoint(this.phonePosition);
      if (this.phoneHeight !== null && this.phoneFloorY !== null) {
        box.expandByPoint(this.project.set(this.phonePosition.x, this.phoneFloorY, this.phonePosition.z));
      }
    }
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
    // Fit projected bounds, including height.
    let extentX = 0.25, extentY = 0.25;
    if (this.orbit) {
      // Fit every heading of the orbit so rotation doesn't pump the zoom or crop walls.
      box.getSize(this.delta);
      const radius = Math.hypot(this.delta.x, this.delta.z) / 2;
      const vertical = this.delta.y / 2 * Math.cos(ORBIT_ELEVATION) + radius * Math.sin(ORBIT_ELEVATION);
      extentX = Math.max(extentX, radius / this.camera.right);
      extentY = Math.max(extentY, vertical / this.camera.top);
    } else {
      for (const x of [box.min.x, box.max.x]) for (const y of [box.min.y, box.max.y]) for (const z of [box.min.z, box.max.z]) {
        this.project.set(x, y, z).project(this.camera);
        extentX = Math.max(extentX, Math.abs(this.project.x));
        extentY = Math.max(extentY, Math.abs(this.project.y));
      }
    }
    this.camera.zoom = THREE.MathUtils.clamp(0.82 / Math.max(extentX, extentY), 0.35, 4);
    this.camera.updateProjectionMatrix();
    this.controls.update(0);
    this.invalidate();
  }

  updatePhone(location: PhoneLocation) {
    const { position, forward, up } = location;
    if (position?.length !== 3 || !position.every(Number.isFinite)) {
      this.clearPhone();
      this.invalidate();
      return;
    }
    const firstPose = !this.hasPhonePose;
    this.phoneState = location.state;
    // Stale/tracking locations describe the last valid pose; never animate towards an
    // untrusted update. A cached pose may still be the first one available after connecting.
    if (location.state === "live" || firstPose) {
      this.phonePosition.fromArray(position);
      if (forward?.length === 3 && forward.every(Number.isFinite)) {
        this.phoneForward.fromArray(forward);
        if (this.phoneForward.lengthSq() > 1e-6) {
          this.phoneForward.normalize();
          this.phoneUp.copy(this.worldUp);
          if (up?.length === 3 && up.every(Number.isFinite)) {
            // `up` is the camera's +Y. ARKit camera axes follow the sensor's landscape orientation:
            // +X runs from the handset's top to its bottom, so the model's top (+Y) is up × forward.
            this.phoneUp.fromArray(up).cross(this.phoneForward);
            if (this.phoneUp.lengthSq() < 1e-6) this.phoneUp.copy(this.worldUp);
            else this.phoneUp.normalize();
          }
          if (Math.abs(this.phoneForward.dot(this.phoneUp)) > 0.999) {
            this.phoneUp.set(0, Math.abs(this.phoneForward.y) > 0.99 ? 0 : 1, Math.abs(this.phoneForward.y) > 0.99 ? 1 : 0);
          }
          this.delta.copy(this.phonePosition).add(this.phoneForward);
          this.phoneBasis.lookAt(this.phonePosition, this.delta, this.phoneUp);
          this.phoneRotation.setFromRotationMatrix(this.phoneBasis);
          // Match pitch and position while keeping the follow view's horizon comfortable.
          this.phoneBasis.lookAt(this.phonePosition, this.delta, this.worldUp);
          this.firstPersonRotation.setFromRotationMatrix(this.phoneBasis);
          this.hasPhoneHeading = Math.hypot(this.phoneForward.x, this.phoneForward.z) > 1e-3;
          if (this.hasPhoneHeading) this.phoneHeading.rotation.y = Math.atan2(-this.phoneForward.x, -this.phoneForward.z);
        }
      }
    }
    this.hasPhonePose = true;
    this.phone.position.copy(this.phonePosition);
    this.phoneModel.quaternion.copy(this.phoneRotation);
    this.phoneFloorY = location.floorY !== null && Number.isFinite(location.floorY) ? location.floorY : null;
    this.phoneHeight = this.phoneFloorY !== null && location.height !== null && Number.isFinite(location.height) ? location.height : null;
    const hasHeight = this.phoneHeight !== null && this.phoneFloorY !== null;
    const floorOffset = hasHeight ? this.phoneFloorY! - this.phonePosition.y : 0;
    this.phoneHeightPositions[4] = floorOffset;
    this.phoneHeightLine.geometry.attributes.position.needsUpdate = true;
    this.phoneHeightLine.visible = this.phoneFootprint.visible = hasHeight;
    this.phoneFootprint.position.y = floorOffset + 0.015;
    this.phoneHeading.position.y = hasHeight ? floorOffset + 0.02 : 0;
    this.phoneHeading.visible = this.hasPhoneHeading;
    this.phone.visible = this.viewMode !== "first";
    const live = location.state === "live";
    const color = live ? 0xb8e4eb : location.state === "tracking" ? 0xd9a663 : 0x858e94;
    this.phoneMaterial.color.setHex(color);
    this.phoneMaterial.opacity = live ? 0.8 : 0.45;
    this.phoneOutlineMaterial.color.setHex(color);
    this.phoneOutlineMaterial.opacity = live ? 0.95 : 0.6;
    this.phoneHeightLine.material.color.setHex(color);
    this.phoneHeightLine.material.opacity = live ? 0.6 : 0.32;
    for (const material of this.phoneSurfaces) material.opacity = live ? 1 : 0.55;
    if (firstPose || !live) {
      this.firstPersonCamera.position.copy(this.phonePosition);
      this.firstPersonCamera.quaternion.copy(this.firstPersonRotation);
    }
    if (firstPose && this.pointCount === 0) this.fit();
    this.invalidate();
  }

  update(recon: Recon): { points: number; area: number } {
    if (recon.epoch !== this.epoch || recon.scan_id !== this.scanId) {
      this.resetReconstruction(); this.epoch = recon.epoch; this.scanId = recon.scan_id;
    }
    this.recon = recon;
    const floorY = recon.floor_y ?? 0;
    this.grid.position.set(Math.round(recon.grid.origin[0] + recon.grid.w * recon.grid.res / 2), floorY - 0.04, Math.round(recon.grid.origin[1] + recon.grid.h * recon.grid.res / 2));
    const version = recon.points_version ?? recon.stats.map_version;
    // Light snapshots omit an unchanged point cloud; keep the one already decoded.
    if (recon.points !== undefined && (version === undefined || version !== this.mapVersion)) {
      const bytes = decode(recon.points);
      const points = new Float32Array(bytes.buffer, 0, Math.floor(bytes.byteLength / 12) * 3);
      if (recon.points_fused) {
        this.decodedCount = Math.min(MAX_POINTS, points.length / 3);
        this.positions.set(points.subarray(0, this.decodedCount * 3));
        this.imageColors = recon.point_colors ? decode(recon.point_colors) : null;
      } else {
        this.scan.add(points, performance.now());
        this.imageColors = null;
      }
      this.mapVersion = version;
      this.cloudKey = "";
    }
    const selected = recon.targets.find(t => t.selected && t.valid);
    const cloudKey = [this.mapVersion, this.colourMode, floorY, selected?.id, selected?.position, selected?.extent, selected?.yaw].join("|");
    if (!recon.points_fused || cloudKey !== this.cloudKey) {
      this.cloudKey = cloudKey;
      const count = this.pointCount = recon.points_fused ? this.decodedCount : this.scan.writeTo(this.positions);
      const yawCos = Math.cos(selected?.yaw ?? 0), yawSin = Math.sin(selected?.yaw ?? 0);
      for (let j = 0; j < count * 3; j += 3) {
        const x = this.positions[j], y = this.positions[j + 1], z = this.positions[j + 2];
        // The box is turned by yaw about +Y: test the point in the box's own axes.
        const dx = x - (selected?.position[0] ?? 0), dz = z - (selected?.position[2] ?? 0);
        const inTarget = selected
          && Math.abs(dx * yawCos - dz * yawSin) < selected.extent[0] / 2 + 0.025
          && Math.abs(y - selected.position[1]) < selected.extent[1] / 2 + 0.025
          && Math.abs(dx * yawSin + dz * yawCos) < selected.extent[2] / 2 + 0.025;
        // Quiet floor returns; bright furniture and walls make height legible.
        const shade = THREE.MathUtils.clamp(0.20 + (y - floorY) * 0.40, 0.16, 0.9);
        if (this.colourMode && this.imageColors && this.imageColors.length >= count * 3) {
          this.rgb.setRGB(this.imageColors[j] / 255, this.imageColors[j + 1] / 255,
            this.imageColors[j + 2] / 255, THREE.SRGBColorSpace);
          this.colors[j] = inTarget ? 1 : this.rgb.r;
          this.colors[j + 1] = inTarget ? 0.065 : this.rgb.g;
          this.colors[j + 2] = inTarget ? 0.08 : this.rgb.b;
        } else {
          this.colors[j] = inTarget ? 1 : shade;
          this.colors[j + 1] = inTarget ? 0.065 : shade;
          this.colors[j + 2] = inTarget ? 0.08 : shade;
        }
      }
      this.cloudGeometry.setDrawRange(0, count);
      this.cloudGeometry.attributes.position.needsUpdate = this.cloudGeometry.attributes.color.needsUpdate = true;
    }

    const { w, h, res, origin } = recon.grid;
    if (recon.grid.cells !== this.gridCells) {
      this.gridCells = recon.grid.cells;
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
      this.observedCells = observed;
      this.hasFloor = observed > 0;
    }
    this.floor.visible = this.viewMode !== "first" && this.hasFloor;
    this.floor.scale.set(w * res, h * res, 1);
    this.floor.position.set(origin[0] + w * res / 2, floorY - 0.025, origin[1] + h * res / 2);
    this.updateTargets(recon);

    const routeKey = `${floorY}|${recon.path.join(";")}`;
    if (routeKey !== this.routeKey) {
      this.routeKey = routeKey;
      this.route.geometry.dispose();
      this.route.geometry = new THREE.BufferGeometry().setFromPoints(recon.path.map(([x, z]) => new THREE.Vector3(x, floorY + 0.06, z)));
    }
    this.route.visible = this.viewMode !== "first" && recon.path.length > 1;
    this.waypoint.visible = this.viewMode !== "first" && !!recon.waypoint;
    if (recon.waypoint) this.waypoint.position.set(recon.waypoint[0], floorY + 0.09, recon.waypoint[1]);
    const now = performance.now();
    if (this.viewMode !== "first" && this.pointCount && (this.needsFit || this.autoFit && now - this.lastFit > 2000)) {
      this.fit(); this.needsFit = false; this.lastFit = now;
    }
    this.invalidate();
    return { points: this.pointCount, area: this.observedCells * res * res };
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
      visual.group.rotation.y = t.yaw ?? 0;
      const size = t.extent.map(v => Math.max(0.06, v));
      visual.box.scale.fromArray(size); visual.edges.scale.fromArray(size);
      visual.box.material.color.setHex(color); visual.edges.material.color.setHex(color);
      visual.box.material.opacity = t.valid ? 0.16 : 0.05;
      visual.edges.material.opacity = t.valid ? 1 : 0.25;
    }
  }

  private animate = (time: number) => {
    if (this.disposed || document.hidden || time - this.lastFrame < 1000 / 30) return;
    const deltaSeconds = this.lastFrame ? Math.min((time - this.lastFrame) / 1000, 0.1) : 0;
    this.lastFrame = time;
    const firstPerson = this.viewMode === "first";
    this.controls.autoRotate = this.orbit && this.cloudGeometry.drawRange.count > 0;
    if (firstPerson) {
      if (this.hasPhonePose && this.phoneState === "live" && (this.firstPersonCamera.position.distanceToSquared(this.phonePosition) > 1e-8
        || this.firstPersonCamera.quaternion.angleTo(this.firstPersonRotation) > 1e-4)) {
        const blend = 1 - Math.exp(-16 * deltaSeconds);
        this.firstPersonCamera.position.lerp(this.phonePosition, blend);
        this.firstPersonCamera.quaternion.slerp(this.firstPersonRotation, blend);
        this.invalidate();
      }
    } else {
      this.controls.update(deltaSeconds);
    }
    if (!this.dirty) return;
    this.dirty = false;
    const camera = firstPerson ? this.firstPersonCamera : this.camera;
    const pixelsPerMeter = firstPerson
      ? this.height / (2 * Math.tan(THREE.MathUtils.degToRad(this.firstPersonCamera.fov / 2)))
      : this.height / (this.camera.top - this.camera.bottom) * this.camera.zoom;
    // Keep the handset recognisable at room-wide zoom. Only the symbol grows; its actual
    // position, floor footprint and measured height line remain in world coordinates.
    if (!firstPerson) this.phoneModel.scale.setScalar(THREE.MathUtils.clamp(34 / (pixelsPerMeter * 0.18), 1, 3));
    const uniforms = (this.cloud.material as THREE.ShaderMaterial).uniforms;
    uniforms.pointSize.value = THREE.MathUtils.clamp(pixelsPerMeter * 0.03, 1.8, 3.8) * this.renderer.getPixelRatio() * (this.colourMode ? 1.45 : 1);
    uniforms.perspectiveScale.value = firstPerson ? pixelsPerMeter * this.renderer.getPixelRatio() * (this.colourMode ? 0.027 : 0.021) : 0;
    this.renderer.render(this.scene, camera);
    const t = this.recon?.targets.find(target => target.selected);
    this.label.hidden = !t;
    if (t) {
      this.project.set(t.position[0], t.position[1] + t.extent[1] / 2 + 0.15, t.position[2]).project(camera);
      this.label.hidden = Math.abs(this.project.x) > 0.92 || Math.abs(this.project.y) > 0.9 || Math.abs(this.project.z) > 1;
      this.label.style.left = `${(this.project.x + 1) * this.width / 2}px`;
      this.label.style.top = `${(1 - this.project.y) * this.height / 2}px`;
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
