// Reconstruction viewer + virtual Trident client. It receives ONLY backend output messages
// (/ws/viewer, /ws/control) and imports nothing from the simulator.
import { HotCold } from "./audio";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const host = location.hostname;
const API = `http://${host}:8787`;

type Recon = {
  epoch: number; perception: string; mode: string; stop_reason: string | null; navigation: boolean;
  grid: { origin: [number, number]; res: number; w: number; h: number; cells: string };
  floor_y: number | null; points: string;
  phone: { position: number[] | null; forward: number[] | null; tracking: string | null };
  listener: number[] | null;
  targets: { id: string; label: string; position: number[]; extent: number[]; sigma: number; age: number; valid: boolean; selected: boolean; injected: boolean }[];
  path: number[][]; waypoint: number[] | null;
  stats: Record<string, number | boolean | null>;
};
type Guidance = {
  mode: string; stop_reason: string | null; perception: string;
  target: { id: string; sigma: number; age: number; valid: boolean; observed_now: boolean } | null;
  proximity: { distance: number; pulse_interval: number; confirm: boolean; threshold: number } | null;
  waypoint: { distance: number; azimuth_head: number | null; azimuth_phone: number; instruction: string; pulse_interval: number } | null;
  navigation: boolean;
};

// Bird's-eye view ---------------------------------------------------------------
const canvas = $<HTMLCanvasElement>("bev");
const g = canvas.getContext("2d")!;
let recon: Recon | null = null;
let scale = 70; // pixels per metre
canvas.addEventListener("wheel", (e) => { scale = Math.min(250, Math.max(20, scale * (e.deltaY < 0 ? 1.1 : 0.9))); e.preventDefault(); });

const CELL_COLORS: Record<number, string> = { 1: "#cfe8cf", 2: "#c0392b", 3: "#f2b8b0", 4: "#ece3c8" };

function decode(b64: string) { return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); }

function draw() {
  const dpr = devicePixelRatio;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.fillStyle = "#3a3f4a";
  g.fillRect(0, 0, W, H);
  if (!recon) { requestAnimationFrame(draw); return; }
  const centre = recon.phone.position ?? [0, 0, 0];
  // World X → right, world −Z → up (top-down orthographic).
  const sx = (x: number) => W / 2 + (x - centre[0]) * scale;
  const sy = (z: number) => H / 2 + (z - centre[2]) * scale;

  const { origin, res, w, h } = recon.grid;
  const cells = decode(recon.grid.cells);
  for (let r = 0; r < h; r++) for (let c = 0; c < w; c++) {
    const v = cells[r * w + c];
    if (!v) continue;
    g.fillStyle = CELL_COLORS[v];
    g.fillRect(sx(origin[0] + c * res), sy(origin[1] + r * res), res * scale + 0.5, res * scale + 0.5);
  }
  g.strokeStyle = "#555b66"; g.lineWidth = 1;
  g.strokeRect(sx(origin[0]), sy(origin[1]), w * res * scale, h * res * scale);

  const pts = new Float32Array(decode(recon.points).buffer);
  const floor = recon.floor_y ?? 0;
  for (let i = 0; i < pts.length; i += 3) {
    const rel = pts[i + 1] - floor;
    g.fillStyle = rel < 0.06 ? "rgba(255,255,255,0.25)" : `hsl(${Math.max(0, 50 - rel * 40)},90%,60%)`;
    g.fillRect(sx(pts[i]) - 1, sy(pts[i + 2]) - 1, 2, 2);
  }

  if (recon.path.length > 1) {
    g.strokeStyle = "#4fc3f7"; g.lineWidth = 3; g.beginPath();
    recon.path.forEach(([x, z], i) => (i ? g.lineTo(sx(x), sy(z)) : g.moveTo(sx(x), sy(z))));
    g.stroke();
  }
  if (recon.waypoint) {
    const [x, z] = recon.waypoint;
    g.fillStyle = "#4fc3f7";
    g.beginPath(); g.moveTo(sx(x), sy(z) - 8); g.lineTo(sx(x) + 8, sy(z)); g.lineTo(sx(x), sy(z) + 8); g.lineTo(sx(x) - 8, sy(z)); g.fill();
  }

  for (const t of recon.targets) {
    const [x, , z] = t.position;
    g.strokeStyle = t.selected ? "#ffeb3b" : t.valid ? "#ffffff" : "#888";
    g.setLineDash(t.valid ? [] : [4, 4]);
    g.lineWidth = t.selected ? 3 : 1.5;
    g.beginPath(); g.arc(sx(x), sy(z), Math.max(4, t.sigma * scale), 0, Math.PI * 2); g.stroke();
    g.setLineDash([]);
    g.fillStyle = g.strokeStyle;
    g.beginPath(); g.arc(sx(x), sy(z), 3, 0, Math.PI * 2); g.fill();
    g.font = "12px system-ui";
    g.fillText(`${t.id} ±${Math.round(t.sigma * 100)}cm ${t.age.toFixed(0)}s${t.injected ? " [INJECTED]" : ""}`, sx(x) + 8, sy(z) - 6);
  }

  if (recon.listener) {
    const [x, , z] = recon.listener;
    g.strokeStyle = "#ce93d8"; g.lineWidth = 2;
    g.beginPath(); g.arc(sx(x), sy(z), 0.22 * scale, 0, Math.PI * 2); g.stroke();
  }
  if (recon.phone.position && recon.phone.forward) {
    const [x, , z] = recon.phone.position;
    const [fx, , fz] = recon.phone.forward;
    const n = Math.hypot(fx, fz) || 1;
    const ok = recon.phone.tracking === "normal";
    g.strokeStyle = g.fillStyle = ok ? "#00e676" : "#ff5252";
    g.lineWidth = 2;
    g.beginPath(); g.moveTo(sx(x), sy(z)); g.lineTo(sx(x + fx / n * 0.8), sy(z + fz / n * 0.8)); g.stroke();
    g.beginPath(); g.arc(sx(x), sy(z), 5, 0, Math.PI * 2); g.fill();
  }
  requestAnimationFrame(draw);
}
requestAnimationFrame(draw);

function connectViewer() {
  const ws = new WebSocket(`ws://${host}:8787/ws/viewer`);
  ws.onmessage = (e) => {
    recon = JSON.parse(e.data);
    const s = recon!.stats;
    $("stats").textContent = `vision ${Number(s.vision_fps).toFixed(1)} fps · depth ${Number(s.depth_ms).toFixed(0)} ms · detect ${Number(s.detect_ms).toFixed(0)} ms`
      + ` · frame age ${s.frame_age_ms ?? "–"} ms · pose ${Number(s.pose_hz).toFixed(0)} Hz · dropped ${s.dropped_frames}`
      + ` · RSS ${s.rss_mb} MB / budget ${s.budget_mb} MB · MPS ${s.mps_mb} MB${s.over_budget ? " · OVER BUDGET" : ""}`;
    $("injected").hidden = recon!.perception !== "injected";
  };
  ws.onclose = () => setTimeout(connectViewer, 1000);
}
connectViewer();

// Virtual phone client: commands, speech, guidance audio ---------------------------
const audio = new HotCold();
let control: WebSocket | null = null;
let lastGuidance = 0;
let guidance: Guidance | null = null;

function send(m: object) { if (control?.readyState === WebSocket.OPEN) control.send(JSON.stringify(m)); }
function log(text: string) {
  const li = document.createElement("li");
  li.textContent = text;
  $("log").prepend(li);
  while ($("log").children.length > 30) $("log").lastChild!.remove();
}
function speak(text: string) {
  log(`🔊 ${text}`);
  speechSynthesis.cancel();
  speechSynthesis.speak(new SpeechSynthesisUtterance(text));
}

function connectControl() {
  const ws = new WebSocket(`ws://${host}:8787/ws/control`);
  ws.onopen = () => { send({ type: "hello", role: "sim-app" }); reportAudio(); };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "guidance") { guidance = m; lastGuidance = performance.now(); onGuidance(m); }
    else if (m.type === "say") speak(m.text);
    else if (m.type === "cue") audio.cue(m.name);
    else if (m.type === "choices") showChoices(m.options);
  };
  ws.onclose = () => { control = null; setTimeout(connectControl, 1000); };
  control = ws;
}
connectControl();

function onGuidance(m: Guidance) {
  $("mode").textContent = m.mode + (m.stop_reason ? ` (${m.stop_reason})` : "");
  $("mode").dataset.mode = m.mode;
  $<HTMLInputElement>("nav").checked = m.navigation;
  const p = m.proximity, w = m.waypoint;
  $("prox").textContent = p ? `phone → target surface ${p.distance.toFixed(2)} m (confirm < ${p.threshold.toFixed(2)} m)${p.confirm ? " ✔ CLOSE" : ""}`
    : w ? `waypoint ${w.distance.toFixed(1)} m · ${w.instruction}` : "–";
  $("target").textContent = m.target ? `${m.target.id} ±${Math.round(m.target.sigma * 100)} cm · seen ${m.target.age.toFixed(1)} s ago${m.target.observed_now ? "" : " (cached, not verified now)"}` : "–";
  if ((m.mode === "probe" || m.mode === "hotcold") && p) audio.setProbe(p.distance);
  else if (m.mode === "walking" && w) audio.setWaypoint(w.pulse_interval, w.azimuth_head ?? w.azimuth_phone);
  else audio.silence();
}

// Client-side freshness: stale guidance silences audio even if the backend is unreachable.
setInterval(() => {
  if (guidance && performance.now() - lastGuidance > 1000) {
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

function reportAudio() { send({ type: "client_status", audio_ok: audio.ok, interrupted: false }); }
$("enableAudio").onclick = async () => {
  audio.start();
  await audio.ctx!.resume();
  $("enableAudio").textContent = "Audio on";
  reportAudio();
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
