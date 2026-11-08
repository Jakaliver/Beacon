"""FastAPI/WebSocket server. See shared/PROTOCOL.md."""
import asyncio
import faulthandler
import signal
import json
import logging
import os
import struct
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager, suppress

import numpy as np
import psutil
import torch
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from .config import CONFIG
from .engine import DEBUG_DIR, Engine

log = logging.getLogger("beacon")
# Event log: what the user sent and what Beacon answered. Goes to the server's stderr.
events = logging.getLogger("beacon.events")
_handler = logging.StreamHandler()
_handler.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S"))
events.addHandler(_handler)
events.setLevel(logging.INFO)
events.propagate = False
faulthandler.register(signal.SIGUSR1)  # `kill -USR1 <pid>` prints all thread stacks
engine = Engine()
control_clients: set[WebSocket] = set()
viewer_clients: set[WebSocket] = set()
# The point cloud (up to ~1.5 MB) is resent only when it changed, and at most POINTS_HZ times a second.
viewer_points = {"version": None, "new_viewer": False, "sent": 0.0}
POINTS_HZ = 5
PHONE_POSE_HZ = 30
VIEWER_SEND_TIMEOUT = 0.25
pending: dict = {"frame": None}
# The newest sensor connection wins, so a forgotten simulator tab cannot fight a real phone.
active_sensor: dict = {"ws": None}
audio_status: dict[WebSocket, tuple[bool, bool]] = {}
control_roles: dict[WebSocket, str] = {}


def apply_audio_status() -> None:
    # A browser preview is not the phone's output device. Older viewers identify as
    # sim-app, so give an actual iPhone precedence over those clients as well.
    phones = {ws for ws, role in control_roles.items() if role == "iphone"}
    statuses = [status for ws, status in audio_status.items()
                if (ws in phones if phones else control_roles.get(ws) != "viewer")]
    # Existing iPhone builds handle audio failures locally and do not send status.
    engine.audio_ok = not statuses or any(ok for ok, _ in statuses)
    engine.interrupted = any(intr for _, intr in statuses)
frame_ready = asyncio.Event()
speech = {"model": None}
process = psutil.Process(os.getpid())
# All PyTorch MPS work (model load, inference, memory queries) stays on one thread:
# calling into MPS from several threads deadlocked in testing.
vision_thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="vision")
# MLX streams belong to their creating thread. Keep model loading and every
# transcription on the same worker, including simultaneous voice requests.
speech_thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="speech")
mps_mb = {"value": 0}


async def broadcast(clients: set[WebSocket], msgs: list[dict]) -> None:
    await broadcast_text(clients, [json.dumps(m) for m in msgs])


async def broadcast_text(clients: set[WebSocket], texts: list[str]) -> None:
    for ws in list(clients):
        try:
            for t in texts:
                await ws.send_text(t)
        except Exception:
            clients.discard(ws)


async def broadcast_viewer(text: str) -> None:
    """Disconnect slow viewers instead of holding live poses behind their socket backlog."""
    for ws in list(viewer_clients):
        try:
            await asyncio.wait_for(ws.send_text(text), timeout=VIEWER_SEND_TIMEOUT)
        except Exception:
            viewer_clients.discard(ws)
            # Closing lets the browser reconnect, rather than leaving an open but silent feed.
            with suppress(Exception):
                await asyncio.wait_for(ws.close(code=1013), timeout=min(0.05, VIEWER_SEND_TIMEOUT))


last_logged_mode = {"mode": None}
last_logged_safety = {"value": None}


async def publish_guidance() -> None:
    g = engine.step()
    msgs = engine.drain()
    for m in msgs:
        events.info("-> %s %s", m["type"], m.get("text") or m.get("name") or m.get("options"))
    if g and (g["mode"], g["stop_reason"]) != last_logged_mode["mode"]:
        last_logged_mode["mode"] = (g["mode"], g["stop_reason"])
        target = g["target"]
        events.info("mode %s%s target=%s", g["mode"], f" ({g['stop_reason']})" if g["stop_reason"] else "",
                    target and f"{target['id']} at {target['position']} locked={target.get('locked')}")
    if g:
        safety = g.get("safety") or {}
        state = (g.get("navigation"), safety.get("state"), safety.get("reason"))
        if state != last_logged_safety["value"]:
            last_logged_safety["value"] = state
            events.info("pathfinding=%s safety=%s reason=%s capture_age_ms=%s", *state, safety.get("age_ms"))
        msgs.append(g)
    if msgs:
        await broadcast(control_clients, msgs)


async def vision_worker() -> None:
    from .perception import Perception
    loop = asyncio.get_running_loop()
    engine.perception = await loop.run_in_executor(vision_thread, Perception)
    engine.labels = set(engine.perception.labels.values())
    log.warning("vision models ready on %s", engine.perception.device)
    while True:
        await frame_ready.wait()
        frame_ready.clear()
        item, pending["frame"] = pending["frame"], None
        if item is None:
            continue
        try:
            await loop.run_in_executor(vision_thread, process_and_measure, *item)
        except Exception:
            log.exception("frame processing failed")


async def ticker() -> None:
    """Keep stop rules responsive independently of viewer work or viewer backpressure."""
    while True:
        await asyncio.sleep(0.1)
        try:
            await publish_guidance()
        except Exception:
            log.exception("guidance tick failed")


def encoded_viewer_snapshot(with_points: bool) -> tuple[dict, str]:
    """Build and serialize the larger payload away from the event loop."""
    snap = engine.snapshot(with_points)
    snap["stats"].update(memory_stats())
    return snap, json.dumps(snap)


class ViewerPublisher:
    """One WebSocket writer, one outstanding reconstruction, no queue of old poses."""
    def __init__(self) -> None:
        self.next_phone = self.next_recon = 0.0
        self.pending_snapshot: asyncio.Task | None = None

    async def tick(self, now: float) -> None:
        if not viewer_clients:
            if self.pending_snapshot is not None and self.pending_snapshot.done():
                with suppress(Exception):
                    self.pending_snapshot.result()
                self.pending_snapshot = None
            return
        if now + 1e-9 >= self.next_phone:
            # Deadlines advance from now, not the previous deadline: stalled sends skip
            # intermediate poses instead of replaying them once the viewer catches up.
            self.next_phone = now + 1 / PHONE_POSE_HZ
            await broadcast_viewer(json.dumps(engine.phone_snapshot()))
        if self.pending_snapshot is not None and self.pending_snapshot.done():
            completed, self.pending_snapshot = self.pending_snapshot, None
            try:
                snap, text = completed.result()
                if snap["scan_id"] == engine.phone_snapshot()["scan_id"]:
                    await broadcast_viewer(text)
                else:
                    viewer_points["new_viewer"] = True  # discard work from a reset scan
            except Exception:
                viewer_points["new_viewer"] = True
                log.exception("viewer snapshot failed")
        if self.pending_snapshot is None and now + 1e-9 >= self.next_recon:
            self.next_recon = now + 1 / max(1.0, CONFIG.viewer_hz)
            with_points = wants_points(engine.surfaces.version, now)
            self.pending_snapshot = asyncio.create_task(asyncio.to_thread(encoded_viewer_snapshot, with_points))


async def viewer_publisher() -> None:
    publisher = ViewerPublisher()
    try:
        while True:
            await asyncio.sleep(1 / max(PHONE_POSE_HZ, CONFIG.viewer_hz))
            try:
                await publisher.tick(asyncio.get_running_loop().time())
            except Exception:
                log.exception("viewer tick failed")
    finally:
        if publisher.pending_snapshot is not None:
            publisher.pending_snapshot.cancel()


def wants_points(version: int, now: float) -> bool:
    if not viewer_points["new_viewer"] and (
            version == viewer_points["version"] or now - viewer_points["sent"] < 1 / POINTS_HZ):
        return False
    viewer_points.update(version=version, new_viewer=False, sent=now)
    return True


def process_and_measure(*item) -> None:
    engine.process_frame(*item)
    if torch.backends.mps.is_available():
        mps_mb["value"] = round(torch.mps.current_allocated_memory() / 2**20)


def memory_stats() -> dict:
    rss = process.memory_info().rss
    return {"rss_mb": round(rss / 2**20), "mps_mb": mps_mb["value"],
            "budget_mb": CONFIG.memory_budget_mb, "over_budget": rss / 2**20 > CONFIG.memory_budget_mb}


async def load_speech() -> None:
    from .speech import Speech
    speech["model"] = await asyncio.get_running_loop().run_in_executor(speech_thread, Speech)
    log.warning("speech model ready")


@asynccontextmanager
async def lifespan(_: FastAPI):
    tasks = [asyncio.create_task(t()) for t in (vision_worker, ticker, viewer_publisher, load_speech)]
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(title="Beacon", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.get("/api/health")
def health() -> dict:
    return {"vision_ready": engine.perception is not None, "speech_ready": speech["model"] is not None,
            "sensor_connected": engine.sensor_connected, "mode": engine.mode,
            "navigation": engine.navigation, "safety": engine.safety.copy(), **memory_stats()}


@app.post("/api/transcribe")
async def transcribe(request: Request) -> dict:
    if speech["model"] is None:
        return {"text": "", "error": "speech model still loading"}
    body = await request.body()
    if len(body) > 2_000_000:
        return {"text": "", "error": "recording too long"}
    text = await asyncio.get_running_loop().run_in_executor(speech_thread, speech["model"].transcribe_wav, body)
    events.info("heard (%.1f s of audio): %r", max(0, len(body) - 44) / 32000, text)
    return {"text": text}


def parse_frame(data: bytes) -> tuple[dict, bytes, np.ndarray | None]:
    (n,) = struct.unpack_from("<I", data, 0)
    header = json.loads(data[4:4 + n])
    rest = data[4 + n:]
    if header.get("perception") == "injected":
        (jl,) = struct.unpack_from("<I", rest, 0)
        inj = header["injected"]
        depth = np.frombuffer(rest[4 + jl:], np.float32).reshape(inj["depth_h"], inj["depth_w"])
        return header, rest[4:4 + jl], depth
    return header, rest, None


@app.websocket("/ws/sensor")
async def sensor(ws: WebSocket) -> None:
    await ws.accept()
    events.info("sensor connected from %s", ws.client.host if ws.client else "?")
    active_sensor["ws"] = ws
    engine.sensor_connected = True
    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if active_sensor["ws"] is not ws:
                continue
            if msg.get("bytes") is not None:
                header, jpeg, depth = parse_frame(msg["bytes"])
                if DEBUG_DIR and header["seq"] % 15 == 0:
                    with open(f"{DEBUG_DIR}/raw.jpg", "wb") as f:
                        f.write(jpeg)
                    with open(f"{DEBUG_DIR}/raw.json", "w") as f:
                        json.dump(header, f)
                if pending["frame"] is not None:
                    engine.stats["dropped_frames"] += 1
                pending["frame"] = (header, jpeg, depth)
                frame_ready.set()
            elif msg.get("text"):
                m = json.loads(msg["text"])
                if m.get("type") == "pose":
                    engine.on_pose(m)
                    await publish_guidance()
    except WebSocketDisconnect:
        pass
    finally:
        events.info("sensor disconnected")
        if active_sensor["ws"] is ws:
            active_sensor["ws"] = None
            engine.sensor_connected = False
            await publish_guidance()


@app.websocket("/ws/control")
async def control(ws: WebSocket) -> None:
    await ws.accept()
    control_clients.add(ws)
    try:
        while True:
            m = json.loads(await ws.receive_text())
            kind = m.get("type")
            if kind != "client_status":
                events.info("<- %s", {k: v for k, v in m.items() if k != "type"} | {"type": kind})
            with engine.lock:
                if kind == "hello" and m.get("role") in {"iphone", "sim-app", "viewer"}:
                    control_roles[ws] = m["role"]
                    if m["role"] == "viewer":
                        audio_status.pop(ws, None)
                    apply_audio_status()
                elif kind == "command":
                    engine.command(m.get("text", ""))
                elif kind == "choose":
                    engine.choose(int(m["index"]))
                elif kind == "stop":
                    reason = m.get("reason", "user")
                    engine.stop(reason, "Stopped." if reason == "user" else f"Stopped: {reason}.")
                elif kind == "resume":
                    engine.resume()
                elif kind == "calibrate":
                    engine.calibrate(quiet=False)
                elif kind == "config":
                    if "navigation" in m:
                        engine.set_navigation(bool(m["navigation"]), m.get("navigation_request_id"))
                    if "probe_offset" in m:
                        engine.probe_offset = np.asarray(m["probe_offset"], float)
                elif kind == "client_status" and control_roles.get(ws) != "viewer":
                    audio_status[ws] = (bool(m.get("audio_ok", True)), bool(m.get("interrupted", False)))
                    apply_audio_status()
            await publish_guidance()
    except WebSocketDisconnect:
        pass
    finally:
        control_clients.discard(ws)
        audio_status.pop(ws, None)
        control_roles.pop(ws, None)
        with engine.lock:
            apply_audio_status()


@app.websocket("/ws/viewer")
async def viewer(ws: WebSocket) -> None:
    await ws.accept()
    viewer_points["new_viewer"] = True  # the next snapshot carries the full point cloud
    viewer_clients.add(ws)
    with suppress(WebSocketDisconnect):
        while True:
            await ws.receive_text()
    viewer_clients.discard(ws)

