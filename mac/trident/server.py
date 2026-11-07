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
from .engine import Engine

log = logging.getLogger("trident")
faulthandler.register(signal.SIGUSR1)  # `kill -USR1 <pid>` prints all thread stacks
engine = Engine()
control_clients: set[WebSocket] = set()
viewer_clients: set[WebSocket] = set()
pending: dict = {"frame": None}
frame_ready = asyncio.Event()
speech = {"model": None}
process = psutil.Process(os.getpid())
# All PyTorch MPS work (model load, inference, memory queries) stays on one thread:
# calling into MPS from several threads deadlocked in testing.
vision_thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="vision")
mps_mb = {"value": 0}


async def broadcast(clients: set[WebSocket], msgs: list[dict]) -> None:
    texts = [json.dumps(m) for m in msgs]
    for ws in list(clients):
        try:
            for t in texts:
                await ws.send_text(t)
        except Exception:
            clients.discard(ws)


async def publish_guidance() -> None:
    g = engine.step()
    msgs = engine.drain()
    if g:
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
    """Keeps stop rules running even when pose updates stop arriving."""
    n = 0
    while True:
        await asyncio.sleep(0.1)
        try:
            await publish_guidance()
            n += 1
            if n % 2 == 0 and viewer_clients:
                snap = await asyncio.to_thread(engine.snapshot)
                snap["stats"].update(memory_stats())
                await broadcast(viewer_clients, [snap])
        except Exception:
            log.exception("guidance/viewer tick failed")


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
    speech["model"] = await asyncio.to_thread(Speech)
    log.warning("speech model ready")


@asynccontextmanager
async def lifespan(_: FastAPI):
    tasks = [asyncio.create_task(t()) for t in (vision_worker, ticker, load_speech)]
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.get("/api/health")
def health() -> dict:
    return {"vision_ready": engine.perception is not None, "speech_ready": speech["model"] is not None,
            "sensor_connected": engine.sensor_connected, "mode": engine.mode, **memory_stats()}


@app.post("/api/transcribe")
async def transcribe(request: Request) -> dict:
    if speech["model"] is None:
        return {"text": "", "error": "speech model still loading"}
    body = await request.body()
    if len(body) > 2_000_000:
        return {"text": "", "error": "recording too long"}
    text = await asyncio.to_thread(speech["model"].transcribe_wav, body)
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
    engine.sensor_connected = True
    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            if msg.get("bytes") is not None:
                header, jpeg, depth = parse_frame(msg["bytes"])
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
            with engine.lock:
                if kind == "command":
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
                        engine.navigation = bool(m["navigation"])
                    if "probe_offset" in m:
                        engine.probe_offset = np.asarray(m["probe_offset"], float)
                elif kind == "client_status":
                    engine.audio_ok = bool(m.get("audio_ok", True))
                    engine.interrupted = bool(m.get("interrupted", False))
            await publish_guidance()
    except WebSocketDisconnect:
        pass
    finally:
        control_clients.discard(ws)


@app.websocket("/ws/viewer")
async def viewer(ws: WebSocket) -> None:
    await ws.accept()
    viewer_clients.add(ws)
    with suppress(WebSocketDisconnect):
        while True:
            await ws.receive_text()
    viewer_clients.discard(ws)

