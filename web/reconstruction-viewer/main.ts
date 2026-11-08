// Read-only room display. The iPhone owns commands, recording and guidance audio.
import { RoomView, type RoomViewMode } from "./room-view";
import { PhoneState } from "./phone-state";
import type { PhonePose, Recon } from "./types";

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
let currentView: RoomViewMode = "3d";
const phoneState = new PhoneState();

try {
  room = new RoomView($("roomCanvas"), $("targetLabel"), $("scaleBar"));
} catch (error) {
  $("renderError").hidden = false;
  $("emptyState").hidden = true;
  console.error("Room renderer unavailable", error);
}

function setView(view: RoomViewMode) {
  currentView = view;
  room?.setView(view);
  $("view3d").setAttribute("aria-pressed", String(view === "3d"));
  $("viewPlan").setAttribute("aria-pressed", String(view === "plan"));
  $("viewFirst").setAttribute("aria-pressed", String(view === "first"));
  $("fitRoom").hidden = $("focusTarget").hidden = $("sceneScale").hidden = view === "first";
  $("roomCanvas").setAttribute("aria-label", view === "first"
    ? "First-person room scan following the iPhone camera. Move the phone to look around."
    : view === "plan" ? "Overhead room scan. Drag to pan and scroll to zoom."
    : "Interactive room scan. Drag to orbit, right-drag to pan, scroll to zoom.");
  $("interactionHint").textContent = view === "plan"
    ? "Drag to pan · Scroll to zoom"
    : view === "first" ? "Following iPhone · Move the phone to look around"
    : "Drag to pause · Scroll to zoom · 3D to resume";
  updateFreshness();
}
$("view3d").onclick = () => setView("3d");
$("viewPlan").onclick = () => setView("plan");
$("viewFirst").onclick = () => setView("first");
$("fitRoom").onclick = () => room?.setAutoFit(true);
$("focusTarget").onclick = () => room?.focusTarget();
let colourEnabled = $("viewColour").getAttribute("aria-pressed") === "true";
try {
  const saved = localStorage.getItem("beacon.viewer.colour") ?? localStorage.getItem("trident.viewer.colour");
  if (saved !== null) colourEnabled = saved === "true";
} catch { /* Private browsing may disable storage. */ }
$("viewColour").setAttribute("aria-pressed", String(colourEnabled));
room?.setColourMode(colourEnabled);
$("viewColour").onclick = () => {
  const enabled = $("viewColour").getAttribute("aria-pressed") !== "true";
  $("viewColour").setAttribute("aria-pressed", String(enabled));
  room?.setColourMode(enabled);
  try { localStorage.setItem("beacon.viewer.colour", String(enabled)); } catch { /* Optional preference. */ }
};

function clearScene() {
  room?.resetScan();
  recon = null;
  lastSnapshot = 0;
  pointCount = 0;
  $("pointCount").textContent = "0";
  $("mappedArea").textContent = "—";
  $("targetCard").hidden = true;
  $("noTarget").hidden = false;
}

function displayPhone(snapshot: PhonePose) {
  const result = phoneState.update(snapshot, performance.now());
  if (!result.accepted) return;
  if (result.reset) clearScene();
  updateFreshness();
}

function displaySnapshot(snapshot: Recon) {
  const result = phoneState.update(snapshot, performance.now());
  if (!phoneState.isCurrentWorld(snapshot)) return;
  if (result.reset) clearScene();
  recon = snapshot;
  lastSnapshot = performance.now();
  const metric = room?.update(snapshot);
  pointCount = metric?.points ?? 0;
  $("pointCount").textContent = pointCount.toLocaleString();
  $("mappedArea").textContent = metric ? metric.area.toFixed(1) : "—";
  $("injected").hidden = snapshot.perception !== "injected";
  const target = snapshot.targets.find(t => t.selected);
  $("targetCard").hidden = !target;
  $("noTarget").hidden = !!target;
  if (target) {
    $("targetName").textContent = target.label;
    $("targetLabelText").textContent = target.label;
  }
  updateFreshness();
}

function updateFreshness() {
  const phone = phoneState.location(performance.now(), connected);
  room?.updatePhone(phone);
  $<HTMLButtonElement>("viewFirst").disabled = !phone.position || !phone.forward;
  $("emptyState").hidden = !room || pointCount > 0 || !!phone.position;
  const elapsed = lastSnapshot ? performance.now() - lastSnapshot : Infinity;
  const age = recon?.stats.observation_age_ms;
  const frameAge = typeof age === "number" ? age + Number(recon?.stats.frame_age_ms ?? 0) + elapsed : Infinity;
  const live = connected && elapsed < 1500 && frameAge < 2500
    && phone.state === "live";
  const injected = recon?.perception === "injected";
  if (currentView === "first") $("interactionHint").textContent = phone.state === "live"
    ? "Following iPhone · Move the phone to look around"
    : "Last iPhone view · Waiting for live tracking";
  $("connection").dataset.state = live ? "live" : recon ? "paused" : "waiting";
  $("connectionText").textContent = live ? injected ? "Debug feed" : "Live" : !connected ? "Connecting" : pointCount ? "Scan paused" : "Waiting for iPhone";
  $("frameAge").textContent = !live && Number.isFinite(frameAge)
    ? frameAge < 60_000 ? `${(frameAge / 1000).toFixed(1)}s ago` : `${Math.floor(frameAge / 60_000)}m ago`
    : "";
  $("emptyHint").textContent = !connected
    ? "Start the Mac backend, then open Beacon on your iPhone."
    : recon?.phone.tracking && recon.phone.tracking !== "normal"
    ? "Move the iPhone slowly while camera tracking settles."
    : "Open Beacon on your iPhone and scan the room.";
  const target = recon?.targets.find(t => t.selected);
  if (target) {
    const distance = phone.position ? Math.hypot(...target.position.map((v, i) => v - phone.position![i])) : null;
    $("targetDistance").textContent = distance === null ? "—" : `${distance.toFixed(1)} m`;
    const stale = !live || target.age + elapsed / 1000 > 1.5;
    $("targetState").textContent = !target.valid ? "Unverified" : !live ? "" : stale ? "Last seen" : "Tracked";
  }
}

function connect() {
  if (destroyed) return;
  const ws = new WebSocket(socketURL);
  socket = ws;
  ws.onopen = () => { phoneState.reset(); clearScene(); connected = true; updateFreshness(); };
  ws.onmessage = event => {
    try {
      const snapshot = JSON.parse(event.data) as Recon | PhonePose;
      if ("type" in snapshot && snapshot.type === "phone_pose") displayPhone(snapshot as PhonePose);
      else if ("grid" in snapshot && snapshot.grid && snapshot.phone && Array.isArray(snapshot.targets)
        && (typeof snapshot.points === "string" || snapshot.points === undefined)) displaySnapshot(snapshot);
    } catch (error) { console.warn("Skipped invalid reconstruction snapshot", error); }
  };
  ws.onclose = () => {
    connected = false;
    updateFreshness();
    if (!destroyed) retry = window.setTimeout(connect, 1000);
  };
}
const freshnessTimer = window.setInterval(updateFreshness, 250);
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
