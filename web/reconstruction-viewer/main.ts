// Receives backend reconstruction only; never imports simulator state.
import { HotCold } from "./audio";
import { RoomView } from "./room-view";
import type { Recon } from "./types";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const params = new URLSearchParams(location.search);
const port = params.get("backend") ?? "8787";
const endpoint = new URL(location.href);
endpoint.port = port;
const API = endpoint.origin;
const socketURL = (path: string) => `${location.protocol === "https:" ? "wss:" : "ws:"}//${endpoint.host}${path}`;
let preview = params.get("preview") === "1";
let recon: Recon | null = null;
let room: RoomView | null = null;
let lastSnapshot = 0;
let viewerConnected = false;
let viewer: WebSocket | null = null;
let viewerRetry = 0;
let controlRetry = 0;
let previewTimer = 0;
let destroyed = false;
let pointCount = 0;
const liveParams = new URLSearchParams(params);
liveParams.delete("preview"); liveParams.delete("lab");
$("exitPreview").setAttribute("href", `./?${liveParams}`);
document.querySelector<HTMLAnchorElement>(".brand")!.href = `./?${liveParams}`;
const labParams = new URLSearchParams(liveParams);
labParams.set("lab", "1");
$("labLink").setAttribute("href", `/?${labParams}`);

try {
  room = new RoomView($("roomCanvas"), $("targetLabel"), $("scaleBar"), $("phoneLabel"));
  room.onInteract = () => {
    $<HTMLInputElement>("followCamera").checked = false;
    $<HTMLInputElement>("autoFit").checked = false;
  };
} catch (error) {
  $("renderError").hidden = false;
  $("emptyState").hidden = true;
  $("renderInfo").textContent = "WEBGL UNAVAILABLE";
  console.error("Room renderer unavailable", error);
}

function setView(view: "3d" | "plan") {
  room?.setView(view);
  $("view3d").setAttribute("aria-pressed", String(view === "3d"));
  $("viewPlan").setAttribute("aria-pressed", String(view === "plan"));
  document.querySelector<HTMLElement>(".interaction-hint")!.textContent = view === "plan"
    ? "DRAG TO PAN · SCROLL OR PINCH TO ZOOM"
    : "DRAG TO ORBIT · SCROLL TO ZOOM · RIGHT-DRAG TO PAN";
}
$("view3d").onclick = () => setView("3d");
$("viewPlan").onclick = () => setView("plan");
$("fitRoom").onclick = () => {
  room?.setAutoFit(true);
  $<HTMLInputElement>("followCamera").checked = false;
  $<HTMLInputElement>("autoFit").checked = true;
};
$("focusTarget").onclick = () => room?.focusTarget();
for (const [id, layer] of [["layerPoints", "points"], ["layerFloor", "floor"], ["layerRoute", "route"], ["layerDetections", "detections"]] as const) {
  $<HTMLInputElement>(id).onchange = e => room?.setLayer(layer, (e.target as HTMLInputElement).checked);
}
$<HTMLInputElement>("followCamera").onchange = e => {
  const enabled = (e.target as HTMLInputElement).checked;
  room?.setFollow(enabled);
  if (enabled) $<HTMLInputElement>("autoFit").checked = false;
};
$<HTMLInputElement>("autoFit").onchange = e => {
  const enabled = (e.target as HTMLInputElement).checked;
  room?.setAutoFit(enabled);
  if (enabled) $<HTMLInputElement>("followCamera").checked = false;
};

function displaySnapshot(snapshot: Recon) {
  recon = snapshot;
  lastSnapshot = performance.now();
  const metric = room?.update(snapshot);
  pointCount = metric?.points ?? 0;
  $("pointCount").textContent = pointCount.toLocaleString();
  $("mappedArea").textContent = metric ? metric.area.toFixed(1) : "—";
  $("epoch").textContent = String(snapshot.epoch).padStart(2, "0");
  $("emptyState").hidden = !room || pointCount > 0;
  $("injected").hidden = snapshot.perception !== "injected";
  $("sourceLabel").textContent = preview ? "SAMPLE DATA" : snapshot.perception === "injected" ? "INJECTED DATA" : "CAMERA FEED";
  $("renderInfo").textContent = room ? `${pointCount.toLocaleString()} POINTS / ACCUMULATED SCAN` : "WEBGL UNAVAILABLE";
  const s = snapshot.stats;
  $("stats").textContent = preview ? "Illustrative reconstruction. No sensor connected; guidance controls are disabled." :
    `vision ${Number(s.vision_fps).toFixed(1)} fps · depth ${Number(s.depth_ms).toFixed(0)} ms · detect ${Number(s.detect_ms).toFixed(0)} ms`
    + ` · dropped ${s.dropped_frames}`
    + ` · RSS ${s.rss_mb ?? "—"} / ${s.budget_mb ?? "—"} MB · MPS ${s.mps_mb ?? "—"} MB${s.over_budget ? " · OVER BUDGET" : ""}`;
  const t = snapshot.targets.find(t => t.selected);
  $("targetName").textContent = t?.label ?? "Find an object";
  $("targetMeta").textContent = t ? `${t.id} · ${t.injected ? "injected estimate" : preview ? "sample object" : "camera estimate"}` : "Type an object below. It appears in red when located.";
  $("targetUncertainty").textContent = t ? `±${Math.round(t.sigma * 100)} cm` : "—";
  const p = snapshot.phone.position;
  $("targetDistance").textContent = t && p ? Math.hypot(...t.position.map((v, i) => v - p[i])).toFixed(2) : "—";
  $<HTMLButtonElement>("focusTarget").disabled = !t;
  updateFreshness();
}

function updateFreshness() {
  const elapsed = lastSnapshot ? performance.now() - lastSnapshot : Infinity;
  const age = recon?.stats.observation_age_ms;
  const frameAge = typeof age === "number" ? age + Number(recon?.stats.frame_age_ms ?? 0) + elapsed : Infinity;
  const poseAge = recon?.stats.pose_age_ms;
  const live = viewerConnected && elapsed < 1500 && frameAge < 2500
    && typeof poseAge === "number" && poseAge + elapsed < 1000
    && recon?.stats.sensor_connected === true && recon.phone.tracking === "normal";
  const state = preview ? "preview" : live ? "live" : recon ? "stale" : "waiting";
  $("connection").dataset.state = state;
  $("connectionText").textContent = preview ? "Sample preview" : live ? "Live reconstruction" : !viewerConnected ? "Reconnecting" : !recon?.phone.position ? "Awaiting camera" : "Scan paused";
  $("scanStatus").textContent = preview ? "Illustrative scan" : live ? "Camera connected" : !viewerConnected ? "Backend disconnected" : recon?.phone.tracking && recon.phone.tracking !== "normal" ? "Tracking limited" : "Waiting for camera";
  $("sceneCaption").textContent = preview ? "Sample geometry · not your camera" : live ? "Move slowly. The scan builds as you look around." : pointCount ? "Scan paused. Open Trident to continue mapping." : "Open Trident and point the camera around your room.";
  $("scanHint").textContent = preview ? "SAMPLE ROOM" : live ? "LIVE CAMERA · ACCUMULATED SCAN" : pointCount ? "LAST SCAN · WAITING FOR CAMERA" : "WAITING FOR CAMERA";
  $("frameAge").textContent = preview ? "PREVIEW" : Number.isFinite(frameAge) ? `${(frameAge / 1000).toFixed(1)}s ago` : "—";
  const t = recon?.targets.find(t => t.selected);
  const stale = !preview && (!live || !!t && t.age + elapsed / 1000 > 1.5);
  const targetState = !t ? "NO TARGET" : preview ? "SAMPLE" : !t.valid ? "UNVERIFIED" : !live ? "PAUSED" : t.locked ? "LOCKED" : stale ? "LAST SEEN" : "TRACKED";
  $("targetState").textContent = targetState;
  $("targetLabelText").textContent = t ? `${t.label.toUpperCase()} · ${$("targetDistance").textContent} m` : "";
  if (t) $("targetMeta").textContent = preview ? "Sample object on the table." : `${t.locked ? "Position locked" : "Estimated position"} · seen ${(t.age + elapsed / 1000).toFixed(1)}s ago`;
}

function connectViewer() {
  if (preview || destroyed) return;
  const ws = new WebSocket(socketURL("/ws/viewer"));
  viewer = ws;
  ws.onopen = () => { room?.resetScan(); viewerConnected = true; updateFreshness(); };
  ws.onmessage = e => {
    try {
      const snapshot = JSON.parse(e.data) as Recon;
      if (snapshot.grid && snapshot.phone && Array.isArray(snapshot.targets) && typeof snapshot.points === "string") displaySnapshot(snapshot);
    } catch (error) { console.warn("Skipped invalid reconstruction snapshot", error); }
  };
  ws.onclose = () => {
    viewerConnected = false; updateFreshness();
    if (!preview && !destroyed) viewerRetry = window.setTimeout(connectViewer, 1000);
  };
}

async function startPreview() {
  if (previewTimer) return;
  preview = true;
  viewer?.close(); control?.close();
  clearTimeout(viewerRetry); clearTimeout(controlRetry);
  audio.silence();
  $("previewBanner").hidden = false;
  $("emptyState").hidden = true;
  $("mode").textContent = "Preview";
  $("prox").textContent = "Connect a camera to enable live guidance.";
  document.querySelectorAll<HTMLInputElement | HTMLButtonElement>(".guidance-panel button, .command-controls button, .command-controls input, .audio-controls button, .audio-controls input, #findBottle, #cmdForm input, #cmdForm button").forEach(el => { el.disabled = true; });
  const url = new URL(location.href); url.searchParams.set("preview", "1"); history.replaceState(null, "", url);
  const { sampleRoom } = await import("./sample-room");
  if (destroyed) return;
  const started = performance.now();
  displaySnapshot(sampleRoom(0));
  previewTimer = window.setInterval(() => { if (!document.hidden) displaySnapshot(sampleRoom((performance.now() - started) / 1000)); }, 200);
}
$("previewRoom").onclick = () => { void startPreview(); };

// Viewer controls and optional Mac audio preview. The iPhone owns guidance audio status.
type Guidance = {
  mode: string; stop_reason: string | null; perception: string;
  target: { id: string; sigma: number; age: number; valid: boolean; observed_now: boolean } | null;
  proximity: { distance: number; pulse_interval: number; confirm: boolean; threshold: number; source_head: [number, number, number] } | null;
  waypoint: { distance: number; instruction: string; pulse_interval: number; source_head: [number, number, number] } | null;
  navigation: boolean;
};
const audio = new HotCold();
let control: WebSocket | null = null;
let lastGuidance = 0;
let guidance: Guidance | null = null;

function send(m: object) { if (!preview && control?.readyState === WebSocket.OPEN) control.send(JSON.stringify(m)); }
function log(text: string) {
  const li = document.createElement("li");
  li.textContent = text;
  $("log").prepend(li);
  while ($("log").children.length > 30) $("log").lastChild!.remove();
}
function speak(text: string) {
  log(`🔊 ${text}`);
  if (!audio.ok) return;
  speechSynthesis.cancel();
  speechSynthesis.speak(new SpeechSynthesisUtterance(text));
}

function connectControl() {
  if (preview || destroyed) return;
  const ws = new WebSocket(socketURL("/ws/control"));
  ws.onopen = () => { send({ type: "hello", role: "viewer" }); };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "guidance") { guidance = m; lastGuidance = performance.now(); onGuidance(m); }
    else if (m.type === "say") speak(m.text);
    else if (m.type === "cue") audio.cue(m.name);
    else if (m.type === "choices") showChoices(m.options);
  };
  ws.onclose = () => { control = null; audio.silence(); if (!preview && !destroyed) controlRetry = window.setTimeout(connectControl, 1000); };
  control = ws;
}

function onGuidance(m: Guidance) {
  const modes: Record<string, string> = { idle: "Ready", stopped: "Paused", searching: "Searching", walking: "Guiding", probe: "Within reach", hotcold: "Locating", found: "Found" };
  $("mode").textContent = modes[m.mode] ?? m.mode;
  $("mode").dataset.mode = m.mode;
  $<HTMLInputElement>("nav").checked = m.navigation;
  const p = m.proximity, w = m.waypoint;
  const reasons: Record<string, string> = { audio: "Connect your AirPods to the iPhone, then tap Resume.", tracking: "Move the phone slowly until camera tracking returns.", sensor: "Keep Trident open on your iPhone.", user: "Tap Resume when you’re ready." };
  $("prox").textContent = m.mode === "stopped" ? reasons[m.stop_reason ?? ""] ?? `Guidance paused: ${(m.stop_reason ?? "waiting for camera").replaceAll("_", " ")}.`
    : p ? `${p.distance.toFixed(2)} m to the target surface${p.confirm ? " · Within reach" : ""}`
    : w ? `${w.instruction} · ${w.distance.toFixed(1)} m` : "Find an object above to start guidance.";
  $("target").textContent = "Listen on your iPhone · AirPods connected to iPhone";
  if ((m.mode === "probe" || m.mode === "hotcold") && p) audio.setProbe(p.distance, p.source_head);
  else if (m.mode === "walking" && w) audio.setWaypoint(w.pulse_interval, w.source_head);
  else audio.silence();
}

// Client-side freshness: stale guidance silences audio even if the backend is unreachable.
const freshnessTimer = window.setInterval(() => {
  updateFreshness();
  if (!preview && guidance && performance.now() - lastGuidance > 1000) {
    audio.silence();
    $("mode").textContent = "no fresh guidance — silent";
  }
}, 200);

function showChoices(options: { index: number; description: string }[]) {
  const box = $("choices");
  box.replaceChildren(...options.map((o) => {
    const b = document.createElement("button");
    b.textContent = `${o.index}: ${o.description}`;
    b.onclick = () => { send({ type: "choose", index: o.index }); box.replaceChildren(); };
    return b;
  }));
}

$("enableAudio").onclick = async () => {
  audio.start();
  await audio.ctx!.resume();
  $("enableAudio").textContent = "Audio on";
};
$<HTMLFormElement>("cmdForm").onsubmit = (e) => {
  e.preventDefault();
  const input = $<HTMLInputElement>("cmd");
  if (input.value.trim()) { send({ type: "command", text: input.value }); log(`⌨ ${input.value}`); }
  input.value = "";
};
for (const [id, msg] of [["stop", { type: "stop", reason: "user" }], ["resume", { type: "resume" }],
  ["calibrate", { type: "calibrate" }], ["repeat", { type: "command", text: "repeat" }],
  ["inspect", { type: "command", text: "inspect" }], ["cancel", { type: "command", text: "cancel" }]] as const) {
  $(id).onclick = () => send(msg);
}
$("stop").addEventListener("click", () => audio.silence());
$("findBottle").onclick = () => send({ type: "command", text: "find the bottle" });
$<HTMLInputElement>("nav").onchange = (e) => send({ type: "config", navigation: (e.target as HTMLInputElement).checked });
$("testEars").onclick = () => audio.testEars((side) => { $("earsVal").textContent = side ? `playing ${side}` : ""; });
$<HTMLInputElement>("spatial").onchange = (e) => { audio.settings.spatial = (e.target as HTMLInputElement).checked; };
for (const key of ["volume", "near", "far"] as const) {
  const input = $<HTMLInputElement>(key);
  input.oninput = () => { audio.settings[key] = +input.value; $(`${key}Val`).textContent = input.value; };
}

// Push-to-talk: record, resample to 16 kHz mono 16-bit WAV, transcribe locally on the Mac.
let recorder: MediaRecorder | null = null;
const ptt = $("ptt");
ptt.onpointerdown = async () => {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const chunks: Blob[] = [];
  recorder = new MediaRecorder(stream);
  recorder.ondataavailable = (e) => chunks.push(e.data);
  recorder.onstop = async () => {
    stream.getTracks().forEach((t) => t.stop());
    const buf = await new Blob(chunks).arrayBuffer();
    const decoded = await new AudioContext().decodeAudioData(buf);
    const off = new OfflineAudioContext(1, Math.ceil(decoded.duration * 16000), 16000);
    const src = off.createBufferSource();
    src.buffer = decoded; src.connect(off.destination); src.start();
    const pcm = (await off.startRendering()).getChannelData(0);
    const res = await fetch(`${API}/api/transcribe`, { method: "POST", body: wav16(pcm), headers: { "Content-Type": "audio/wav" } });
    const { text, error } = await res.json();
    log(`🎤 ${text || error || "(nothing heard)"}`);
    if (text) send({ type: "command", text });
  };
  recorder.start();
  ptt.textContent = "Listening… release to send";
};
const release = () => { if (recorder?.state === "recording") recorder.stop(); ptt.textContent = "Hold to talk"; };
ptt.onpointerup = release;
ptt.onpointerleave = release;

function wav16(pcm: Float32Array): Blob {
  const b = new DataView(new ArrayBuffer(44 + pcm.length * 2));
  const str = (o: number, s: string) => [...s].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF"); b.setUint32(4, 36 + pcm.length * 2, true); str(8, "WAVE"); str(12, "fmt ");
  b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 1, true);
  b.setUint32(24, 16000, true); b.setUint32(28, 32000, true); b.setUint16(32, 2, true); b.setUint16(34, 16, true);
  str(36, "data"); b.setUint32(40, pcm.length * 2, true);
  pcm.forEach((v, i) => b.setInt16(44 + i * 2, Math.max(-1, Math.min(1, v)) * 0x7fff, true));
  return new Blob([b.buffer], { type: "audio/wav" });
}

if (preview) void startPreview();
else { connectViewer(); connectControl(); }

function dispose() {
  destroyed = true;
  clearInterval(freshnessTimer); clearInterval(previewTimer);
  clearTimeout(viewerRetry); clearTimeout(controlRetry);
  viewer?.close(); control?.close(); audio.silence(); room?.dispose();
}
addEventListener("pagehide", event => { if (!event.persisted) dispose(); });
import.meta.hot?.dispose(dispose);
