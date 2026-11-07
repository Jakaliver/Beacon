// Read-only room display. The iPhone owns commands, recording and guidance audio.
import { RoomView } from "./room-view";
import type { Recon } from "./types";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const params = new URLSearchParams(location.search);
const endpoint = new URL(location.href);
endpoint.port = params.get("backend") ?? "8787";
const socketURL = `${location.protocol === "https:" ? "wss:" : "ws:"}//${endpoint.host}/ws/viewer`;
let room: RoomView | null = null;
let recon: Recon | null = null;
let lastSnapshot = 0;
let connected = false;
let socket: WebSocket | null = null;
let retry = 0;
let destroyed = false;
let pointCount = 0;

try {
  room = new RoomView($("roomCanvas"), $("targetLabel"), $("scaleBar"), $("phoneLabel"));
} catch (error) {
  $("renderError").hidden = false;
  $("emptyState").hidden = true;
  console.error("Room renderer unavailable", error);
}

function setView(view: "3d" | "plan") {
  room?.setView(view);
  $("view3d").setAttribute("aria-pressed", String(view === "3d"));
  $("viewPlan").setAttribute("aria-pressed", String(view === "plan"));
  $("interactionHint").textContent = view === "plan"
    ? "Drag to pan · Scroll to zoom"
    : "Drag to orbit · Scroll to zoom · Right-drag to pan";
}
$("view3d").onclick = () => setView("3d");
$("viewPlan").onclick = () => setView("plan");
$("fitRoom").onclick = () => room?.setAutoFit(true);
$("focusTarget").onclick = () => room?.focusTarget();

function displaySnapshot(snapshot: Recon) {
  recon = snapshot;
  lastSnapshot = performance.now();
  const metric = room?.update(snapshot);
  pointCount = metric?.points ?? 0;
  $("pointCount").textContent = pointCount.toLocaleString();
  $("mappedArea").textContent = metric ? metric.area.toFixed(1) : "—";
  $("emptyState").hidden = !room || pointCount > 0;
  $("injected").hidden = snapshot.perception !== "injected";
  const target = snapshot.targets.find(t => t.selected);
  $("targetCard").hidden = !target;
  $("noTarget").hidden = !!target;
  if (target) {
    $("targetName").textContent = target.label;
    const phone = snapshot.phone.position;
    const distance = phone ? Math.hypot(...target.position.map((v, i) => v - phone[i])).toFixed(1) : null;
    $("targetDistance").textContent = distance ? `${distance} m` : "—";
    $("targetLabelText").textContent = `${target.label.toUpperCase()}${distance ? ` · ${distance} m` : ""}`;
  }
  updateFreshness();
}

function updateFreshness() {
  const elapsed = lastSnapshot ? performance.now() - lastSnapshot : Infinity;
  const age = recon?.stats.observation_age_ms;
  const frameAge = typeof age === "number" ? age + Number(recon?.stats.frame_age_ms ?? 0) + elapsed : Infinity;
  const poseAge = recon?.stats.pose_age_ms;
  const live = connected && elapsed < 1500 && frameAge < 2500
    && typeof poseAge === "number" && poseAge + elapsed < 1000
    && recon?.stats.sensor_connected === true && recon.phone.tracking === "normal";
  const injected = recon?.perception === "injected";
  $("connection").dataset.state = live ? "live" : recon ? "paused" : "waiting";
  $("connectionText").textContent = live ? injected ? "Debug feed" : "Live" : !connected ? "Connecting" : pointCount ? "Scan paused" : "Waiting for iPhone";
  $("scanCaption").textContent = injected ? "Debug observations" : live ? "Live camera scan" : pointCount ? "Last camera scan" : "Camera reconstruction";
  $("frameAge").textContent = Number.isFinite(frameAge)
    ? frameAge < 60_000 ? `${(frameAge / 1000).toFixed(1)}s ago` : `${Math.floor(frameAge / 60_000)}m ago`
    : "";
  $("emptyHint").textContent = !connected
    ? "Start the Mac backend, then open Trident on your iPhone."
    : recon?.phone.tracking && recon.phone.tracking !== "normal"
    ? "Move the iPhone slowly while camera tracking settles."
    : "Open Trident on your iPhone and scan the floor and nearby furniture.";
  const target = recon?.targets.find(t => t.selected);
  if (target) {
    const stale = !live || target.age + elapsed / 1000 > 1.5;
    $("targetState").textContent = !target.valid ? "Unverified" : !live ? "Paused" : target.locked ? "Position locked" : stale ? "Last seen" : "Tracked";
  }
}

function connect() {
  if (destroyed) return;
  const ws = new WebSocket(socketURL);
  socket = ws;
  ws.onopen = () => { room?.resetScan(); connected = true; updateFreshness(); };
  ws.onmessage = event => {
    try {
      const snapshot = JSON.parse(event.data) as Recon;
      if (snapshot.grid && snapshot.phone && Array.isArray(snapshot.targets) && typeof snapshot.points === "string") displaySnapshot(snapshot);
    } catch (error) { console.warn("Skipped invalid reconstruction snapshot", error); }
  };
  ws.onclose = () => {
    connected = false;
    updateFreshness();
    if (!destroyed) retry = window.setTimeout(connect, 1000);
  };
}
const freshnessTimer = window.setInterval(updateFreshness, 500);
connect();

function dispose() {
  destroyed = true;
  clearInterval(freshnessTimer);
  clearTimeout(retry);
  socket?.close();
  room?.dispose();
}
addEventListener("pagehide", event => { if (!event.persisted) dispose(); });
import.meta.hot?.dispose(dispose);
