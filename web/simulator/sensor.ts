// Simulated phone sensors → Trident sensor protocol (shared/PROTOCOL.md).
// Only data that a real iPhone could provide leaves this module.
import * as THREE from "three";

export const IMG_W = 640;
export const IMG_H = 480;
const DEPTH_W = 160;
const DEPTH_H = 120;
const now = () => (performance.timeOrigin + performance.now()) / 1000;

export type Tracking = "normal" | "limited" | "not_available";

export class SensorLink {
  session = Math.random().toString(36).slice(2, 8);
  epoch = 0;
  frameSeq = 0;
  poseSeq = 0;
  delayMs = 0;
  disconnected = false;
  connected = false;
  sentFrames = 0;
  private ws: WebSocket | null = null;
  private encoding = false;

  constructor(private url: string) { this.connect(); }

  private connect() {
    if (this.disconnected) return;
    const ws = new WebSocket(this.url);
    ws.binaryType = "arraybuffer";
    ws.onopen = () => { this.connected = true; };
    ws.onclose = () => {
      this.connected = false;
      this.ws = null;
      setTimeout(() => this.connect(), 1000);
    };
    this.ws = ws;
  }

  setDisconnected(off: boolean) {
    this.disconnected = off;
    if (off) this.ws?.close();
    else if (!this.ws) this.connect();
  }

  private send(data: string | ArrayBuffer) {
    const go = () => { if (this.ws?.readyState === WebSocket.OPEN && !this.disconnected) this.ws.send(data); };
    if (this.delayMs > 0) setTimeout(go, this.delayMs);
    else go();
  }

  sendPose(pose: number[], tracking: Tracking, headQ: number[] | null, floorY: number | null) {
    this.send(JSON.stringify({
      v: 1, type: "pose", session: this.session, epoch: this.epoch, seq: this.poseSeq++, t: now(),
      pose, tracking, tracking_reason: tracking === "normal" ? null : "simulated",
      head: headQ ? { q: headQ, available: true } : null, floor_y: floorY,
    }));
  }

  /** True when the previous frame is still encoding; the caller then skips this frame. */
  get busy() { return this.encoding; }

  /** Metadata is fixed here, at render time; JPEG encoding happens afterwards. */
  sendFrame(canvas: HTMLCanvasElement, intrinsics: number[], pose: number[], tracking: Tracking,
            injected: { depth: Float32Array; detections: { label: string; bbox: number[] }[] } | null) {
    const header = {
      v: 1, type: "frame", source: "sim", session: this.session, epoch: this.epoch,
      seq: this.frameSeq++, t: now(), width: IMG_W, height: IMG_H, intrinsics,
      image_transform: { rotation_deg: 0, scale: 1, crop: [0, 0, IMG_W, IMG_H] },
      pose, tracking, perception: injected ? "injected" : "real",
      injected: injected ? { depth_w: DEPTH_W, depth_h: DEPTH_H, detections: injected.detections } : null,
    };
    this.encoding = true;
    canvas.toBlob(async (blob) => {
      this.encoding = false;
      if (!blob) return;
      const jpeg = new Uint8Array(await blob.arrayBuffer());
      const head = new TextEncoder().encode(JSON.stringify(header));
      const parts: Uint8Array[] = [u32(head.length), head];
      if (injected) parts.push(u32(jpeg.length), jpeg, new Uint8Array(injected.depth.buffer));
      else parts.push(jpeg);
      const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
      let o = 0;
      for (const p of parts) { out.set(p, o); o += p.length; }
      this.sentFrames++;
      this.send(out.buffer);
    }, "image/jpeg", 0.75);
  }
}

function u32(n: number) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n, true);
  return b;
}

/** Pinhole intrinsics matching a Three.js PerspectiveCamera rendered at IMG_W × IMG_H. */
export function intrinsicsFor(cam: THREE.PerspectiveCamera): number[] {
  const fy = (IMG_H / 2) / Math.tan(THREE.MathUtils.degToRad(cam.fov) / 2);
  return [fy, fy, IMG_W / 2, IMG_H / 2];
}

// Debug-only "injected perception": visible metric depth and projected boxes of visible COCO objects.
const depthMaterial = new THREE.ShaderMaterial({
  vertexShader: `varying float vDepth;
    void main() { vec4 mv = modelViewMatrix * vec4(position, 1.0); vDepth = -mv.z; gl_Position = projectionMatrix * mv; }`,
  fragmentShader: `varying float vDepth; void main() { gl_FragColor = vec4(vDepth, 0.0, 0.0, 1.0); }`,
});
const depthTarget = new THREE.WebGLRenderTarget(DEPTH_W, DEPTH_H, { type: THREE.FloatType });

export function renderInjected(renderer: THREE.WebGLRenderer, scene: THREE.Scene, cam: THREE.PerspectiveCamera,
                               objects: { object: THREE.Object3D; label: string }[]) {
  scene.overrideMaterial = depthMaterial;
  const bg = scene.background;
  scene.background = null;
  renderer.setRenderTarget(depthTarget);
  renderer.setClearColor(0x000000, 0);
  renderer.clear();
  renderer.render(scene, cam);
  const rgba = new Float32Array(DEPTH_W * DEPTH_H * 4);
  renderer.readRenderTargetPixels(depthTarget, 0, 0, DEPTH_W, DEPTH_H, rgba);
  renderer.setRenderTarget(null);
  scene.overrideMaterial = null;
  scene.background = bg;
  const depth = new Float32Array(DEPTH_W * DEPTH_H);
  for (let y = 0; y < DEPTH_H; y++)  // GL rows are bottom-up
    for (let x = 0; x < DEPTH_W; x++) depth[y * DEPTH_W + x] = rgba[((DEPTH_H - 1 - y) * DEPTH_W + x) * 4];

  const detections: { label: string; bbox: number[] }[] = [];
  for (const { object, label } of objects) {
    const box = new THREE.Box3().setFromObject(object);
    const pts = [0, 1].flatMap((i) => [0, 1].flatMap((j) => [0, 1].map((k) => new THREE.Vector3(
      i ? box.max.x : box.min.x, j ? box.max.y : box.min.y, k ? box.max.z : box.min.z))));
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, behind = false;
    for (const p of pts) {
      const v = p.clone().applyMatrix4(cam.matrixWorldInverse);
      if (v.z > -0.05) { behind = true; break; }
      const s = p.clone().project(cam);
      x0 = Math.min(x0, (s.x + 1) / 2 * IMG_W); x1 = Math.max(x1, (s.x + 1) / 2 * IMG_W);
      y0 = Math.min(y0, (1 - s.y) / 2 * IMG_H); y1 = Math.max(y1, (1 - s.y) / 2 * IMG_H);
    }
    if (behind) continue;
    [x0, x1] = [Math.max(0, x0), Math.min(IMG_W, x1)];
    [y0, y1] = [Math.max(0, y0), Math.min(IMG_H, y1)];
    if (x1 - x0 < 6 || y1 - y0 < 6) continue;
    // Visible only if the depth buffer at the box centre is not much closer than the object.
    const c = box.getCenter(new THREE.Vector3());
    const dist = -c.clone().applyMatrix4(cam.matrixWorldInverse).z;
    const u = Math.floor((x0 + x1) / 2 / IMG_W * DEPTH_W), v = Math.floor((y0 + y1) / 2 / IMG_H * DEPTH_H);
    if (depth[v * DEPTH_W + u] < dist - 0.5) continue;
    detections.push({ label, bbox: [x0, y0, x1, y1] });
  }
  return { depth, detections };
}
