import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { IMG_H, IMG_W, SensorLink, type Tracking, intrinsicsFor, renderInjected } from "./sensor";
import { SCENES, World } from "./world";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const backend = `ws://${location.hostname}:8787/ws/sensor`;

// Renderers: one for the third-person view, one that is the phone camera sensor.
const view = new THREE.WebGLRenderer({ canvas: $("view"), antialias: true });
view.shadowMap.enabled = true;
const phoneRenderer = new THREE.WebGLRenderer({ canvas: $("phonecam"), antialias: true, preserveDrawingBuffer: true });
phoneRenderer.setSize(IMG_W, IMG_H, false);
phoneRenderer.shadowMap.enabled = true;
phoneRenderer.toneMapping = view.toneMapping = THREE.ACESFilmicToneMapping;

const world = new World();
const scene = world.scene;
const viewCam = new THREE.PerspectiveCamera(55, 1, 0.05, 50);
const orbit = new OrbitControls(viewCam, view.domElement);

// Avatar. Body, head and phone are independent: the head and phone are children of the
// body so walking carries them, but neither the head nor the phone moves the other.
const body = new THREE.Group();
const torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.2, 1.1, 4, 12),
  new THREE.MeshStandardMaterial({ color: 0x3b6ea8, transparent: true, opacity: 0.55 }));
torso.position.y = 0.75;
body.add(torso);
const head = new THREE.Group();
head.position.y = 1.6;
const skull = new THREE.Mesh(new THREE.SphereGeometry(0.11, 16, 12), new THREE.MeshStandardMaterial({ color: 0xe0b48f }));
const cups = new THREE.Mesh(new THREE.BoxGeometry(0.27, 0.08, 0.08), new THREE.MeshStandardMaterial({ color: 0x222222 }));
const nose = new THREE.Mesh(new THREE.ConeGeometry(0.03, 0.08, 8), new THREE.MeshStandardMaterial({ color: 0xe0b48f }));
nose.rotation.x = -Math.PI / 2;
nose.position.z = -0.12;
head.add(skull, cups, nose);
body.add(head);
const phone = new THREE.Group();
const phoneMesh = new THREE.Mesh(new THREE.BoxGeometry(0.075, 0.15, 0.008), new THREE.MeshStandardMaterial({ color: 0x111111 }));
phone.add(phoneMesh);
// The camera sensor is mounted along the phone's long axis: holding the phone upright
// gives a landscape image rolled by 90°, as on a real iPhone's capturedImage.
const phoneCam = new THREE.PerspectiveCamera(50, IMG_W / IMG_H, 0.05, 30);
phoneCam.rotation.z = -Math.PI / 2;
phone.add(phoneCam);
const frustum = new THREE.CameraHelper(phoneCam);
body.add(phone);
// Avatar parts are invisible to the phone camera (layer 1), so the user's own body is not in the image.
for (const o of [torso, skull, cups, nose, phoneMesh]) o.layers.set(1);
viewCam.layers.enable(1);
scene.add(body, frustum);
frustum.layers.set(1);

const PHONE_HOME = { pos: new THREE.Vector3(0.12, 1.25, -0.35), rot: new THREE.Euler(-0.35, 0, 0, "YXZ") };
const state = {
  headYaw: 0, headPitch: 0,
  tracking: "normal" as Tracking,
  injected: false,
  // Fixed rotation between the headphones' own reference frame and the world. Trident must calibrate it out.
  headRef: new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), 0.7),
  // AR world origin in simulator coordinates (like ARKit: set at session start / reset).
  arOrigin: new THREE.Matrix4(),
  // Like ARKit horizontal plane detection: the floor height becomes known only after the camera has seen it.
  floorSeen: false,
};
function resetPhone() {
  phone.position.copy(PHONE_HOME.pos);
  phone.rotation.copy(PHONE_HOME.rot);
}

const link = new SensorLink(backend);

function resetArWorld() {
  // ARKit-style origin: current phone position, gravity aligned, yaw from the phone heading.
  phone.updateWorldMatrix(true, false);
  const p = new THREE.Vector3().setFromMatrixPosition(phone.matrixWorld);
  const fwd = new THREE.Vector3(0, 0, -1).applyQuaternion(phone.getWorldQuaternion(new THREE.Quaternion()));
  const yaw = Math.atan2(-fwd.x, -fwd.z);
  state.arOrigin.makeRotationY(yaw).setPosition(p);
}

async function loadScene(name: string) {
  const spec = SCENES.find((s) => s.name === name)!;
  await world.load(spec);
  body.position.set(spec.start.x, 0, spec.start.z);
  body.rotation.y = spec.start.yaw;
  state.headYaw = state.headPitch = 0;
  resetPhone();
  $("notes").textContent = spec.notes;
  link.epoch++;
  resetArWorld();
  state.floorSeen = false;
}

// Pose in the AR world frame, column-major camera-to-world.
function cameraPose(): number[] {
  phoneCam.updateWorldMatrix(true, false);
  const inv = state.arOrigin.clone().invert();
  return inv.multiply(phoneCam.matrixWorld).elements.slice();
}

/** Floor height in the AR frame, once "plane detection" has seen the floor (camera pitched down ≥ 25°). */
function arkitFloorY(): number | null {
  const fwd = new THREE.Vector3(0, 0, -1).applyQuaternion(phoneCam.getWorldQuaternion(new THREE.Quaternion()));
  if (fwd.y < -0.42 && state.tracking === "normal") state.floorSeen = true;
  if (!state.floorSeen) return null;
  return -state.arOrigin.elements[13] + 0.01;  // ARKit planes are typically within ~1 cm
}

function headQuaternion(): number[] {
  const q = head.getWorldQuaternion(new THREE.Quaternion());
  const inRef = state.headRef.clone().multiply(q);
  return [inRef.x, inRef.y, inRef.z, inRef.w];
}

// Controls --------------------------------------------------------------------
const keys = new Set<string>();
addEventListener("keydown", (e) => { if ((e.target as HTMLElement).tagName !== "INPUT") keys.add(e.code); });
addEventListener("keyup", (e) => keys.delete(e.code));
addEventListener("blur", () => keys.clear());

function applyControls(dt: number) {
  const k = (c: string) => keys.has(c);
  const walk = 1.0 * dt, turn = 1.4 * dt, move = 0.4 * dt, rot = 1.2 * dt;
  // Body
  if (k("KeyA")) body.rotation.y += turn;
  if (k("KeyD")) body.rotation.y -= turn;
  const dir = new THREE.Vector3((k("KeyE") ? 1 : 0) - (k("KeyQ") ? 1 : 0), 0, (k("KeyS") ? 1 : 0) - (k("KeyW") ? 1 : 0));
  if (dir.lengthSq()) {
    const next = body.position.clone().add(dir.normalize().multiplyScalar(walk).applyAxisAngle(new THREE.Vector3(0, 1, 0), body.rotation.y));
    if (!world.collides(next, 0.22)) body.position.copy(next);
  }
  // Head only
  if (k("ArrowLeft")) state.headYaw += turn;
  if (k("ArrowRight")) state.headYaw -= turn;
  if (k("ArrowUp")) state.headPitch = Math.min(0.8, state.headPitch + turn);
  if (k("ArrowDown")) state.headPitch = Math.max(-0.8, state.headPitch - turn);
  state.headYaw = THREE.MathUtils.clamp(state.headYaw, -1.6, 1.6);
  head.rotation.set(state.headPitch, state.headYaw, 0, "YXZ");
  // Phone position relative to the body
  if (k("KeyI")) phone.position.z -= move;
  if (k("KeyK")) phone.position.z += move;
  if (k("KeyJ")) phone.position.x -= move;
  if (k("KeyL")) phone.position.x += move;
  if (k("KeyU")) phone.position.y += move;
  if (k("KeyO")) phone.position.y -= move;
  phone.position.clamp(new THREE.Vector3(-0.7, 0.2, -0.8), new THREE.Vector3(0.7, 1.9, 0.2));
  // Phone rotation
  if (k("KeyT")) phone.rotation.x += rot;
  if (k("KeyG")) phone.rotation.x -= rot;
  if (k("KeyF")) phone.rotation.y += rot;
  if (k("KeyH")) phone.rotation.y -= rot;
  if (k("KeyR")) phone.rotation.z += rot;
  if (k("KeyY")) phone.rotation.z -= rot;
}

function reachTowards(id: string) {
  // Simulator-only convenience: it uses ground truth to move the simulated hand. Nothing is sent.
  const obj = world.objects.get(id);
  if (!obj) return;
  const target = new THREE.Box3().setFromObject(obj).getCenter(new THREE.Vector3());
  const local = body.worldToLocal(target.clone());
  const shoulder = new THREE.Vector3(0.15, 1.35, 0);
  const d = local.clone().sub(shoulder);
  const reach = Math.min(d.length() - 0.12, 0.75);
  phone.position.copy(shoulder.add(d.normalize().multiplyScalar(Math.max(0.3, reach))));
  phone.lookAt(body.localToWorld(local.clone()));
  phone.rotateY(Math.PI); // lookAt points +z; the camera looks along -z
}

function bind(id: string, fn: () => void) { $(id).addEventListener("click", () => { fn(); (document.activeElement as HTMLElement)?.blur(); }); }
const sceneSelect = $<HTMLSelectElement>("scene");
for (const s of SCENES) sceneSelect.add(new Option(s.title, s.name));
sceneSelect.onchange = () => loadScene(sceneSelect.value);
bind("resetPhone", resetPhone);
bind("pointDown", () => { phone.position.set(0.1, 1.1, -0.3); phone.rotation.set(-1.45, 0, 0, "YXZ"); });
bind("reach", () => reachTowards("target"));
bind("resetScene", () => loadScene(sceneSelect.value));
bind("arReset", () => { link.epoch++; resetArWorld(); state.floorSeen = false; });
bind("moveTarget", () => {
  const t = world.objects.get("target");
  if (!t) return;
  // Move it somewhere roughly behind the user, where the phone cannot see it.
  const behind = new THREE.Vector3(0, 0, 1.2).applyAxisAngle(new THREE.Vector3(0, 1, 0), body.rotation.y);
  t.position.set(body.position.x + behind.x, 0, body.position.z + behind.z);
  t.position.x = THREE.MathUtils.clamp(t.position.x, -2.5, 2.5);
  t.position.z = THREE.MathUtils.clamp(t.position.z, -2.5, 2.5);
});
bind("dropAhead", () => {
  const ahead = new THREE.Vector3(0, 0, -1.3).applyAxisAngle(new THREE.Vector3(0, 1, 0), body.rotation.y).add(body.position);
  world.dropCardboardBox(ahead.x, ahead.z);
});
bind("dropGap", () => world.dropCardboardBox(1.25, -0.5));
$<HTMLInputElement>("tracking").onchange = (e) => {
  state.tracking = (e.target as HTMLInputElement).checked ? "not_available" : "normal";
};
$<HTMLInputElement>("disconnect").onchange = (e) => link.setDisconnected((e.target as HTMLInputElement).checked);
$<HTMLInputElement>("delay").oninput = (e) => {
  link.delayMs = +(e.target as HTMLInputElement).value;
  $("delayVal").textContent = `${link.delayMs} ms`;
};
$<HTMLSelectElement>("perception").onchange = (e) => {
  state.injected = (e.target as HTMLSelectElement).value === "injected";
  $("injectedBanner").hidden = !state.injected;
};

function trueTargetDistance(): string {
  const t = world.objects.get("target");
  if (!t) return "–";
  const p = new THREE.Vector3().setFromMatrixPosition(phoneCam.matrixWorld);
  return `${new THREE.Box3().setFromObject(t).distanceToPoint(p).toFixed(2)} m`;
}

// Loop -------------------------------------------------------------------------
let last = performance.now(), lastPose = 0, lastFrame = 0;
function resize() {
  const el = view.domElement;
  view.setSize(el.clientWidth, el.clientHeight, false);
  viewCam.aspect = el.clientWidth / el.clientHeight;
  viewCam.updateProjectionMatrix();
}
addEventListener("resize", resize);

function tick(t: number) {
  const dt = Math.min(0.1, (t - last) / 1000);
  last = t;
  applyControls(dt);
  scene.updateMatrixWorld();
  orbit.target.lerp(body.position.clone().setY(1.0), 0.1);
  orbit.update();
  frustum.update();

  // The phone camera renders every display frame (for the preview); it is transmitted at ~10 Hz.
  phoneRenderer.render(scene, phoneCam);
  if (t - lastFrame > 100 && !link.busy && link.connected) {
    lastFrame = t;
    const pose = cameraPose();
    const injected = state.injected ? renderInjected(phoneRenderer, scene, phoneCam, world.cocoObjects) : null;
    link.sendFrame(phoneRenderer.domElement, intrinsicsFor(phoneCam), pose, state.tracking, injected);
  }
  if (t - lastPose > 33) {
    lastPose = t;
    link.sendPose(cameraPose(), state.tracking, headQuaternion(), arkitFloorY());
  }
  view.render(scene, viewCam);
  $("status").textContent = `${link.connected ? "connected" : link.disconnected ? "DISCONNECTED (simulated)" : "connecting…"}`
    + ` · epoch ${link.epoch} · frames sent ${link.sentFrames} · tracking ${state.tracking}`
    + ` · ground truth (simulator only, never sent): phone→target surface ${trueTargetDistance()}`;
  requestAnimationFrame(tick);
}

await loadScene(SCENES[0].name);
viewCam.position.set(body.position.x + 0.5, 5.5, body.position.z + 1.2);
resize();
requestAnimationFrame(tick);
