# Trident sensor and guidance protocol (v1)

Both sensor sources (the Three.js simulator and the iPhone app) use this
protocol. The Mac backend runs the same pipeline for both.

Server: `http://<mac-host>:8787`.

| Endpoint | Direction | Content |
|---|---|---|
| `ws /ws/sensor` | source → Mac | binary camera frames, JSON pose updates |
| `ws /ws/control` | both ways | JSON commands in, JSON guidance/speech out |
| `ws /ws/viewer` | Mac → viewer | JSON reconstruction snapshots (read-only) |
| `POST /api/transcribe` | client → Mac | 16 kHz mono 16-bit PCM WAV body, returns `{"text": ...}` |
| `GET /api/health` | | status |

Image traffic (`/ws/sensor`) is separate from control and guidance traffic (`/ws/control`).

## Coordinate conventions

World frame: right-handed, metres, gravity aligned, **+Y up**. This is the ARKit
world frame (and the Three.js default). The bird's-eye view shows the X–Z plane.

Camera frame (ARKit / Three.js camera): +X right, +Y up, **−Z forward**, in the
orientation of the transmitted image (for the iPhone this is the native
landscape sensor image, not rotated to the UI orientation).

`pose` is the 4×4 **camera-to-world** transform, **column-major**, 16 floats
(the layout of `simd_float4x4` and of `THREE.Matrix4.elements`).

The backend converts computer-vision camera axes (+X right, +Y down, +Z forward)
to the camera frame by negating Y and Z.

Intrinsics `[fx, fy, cx, cy]` are in pixels and always describe the **transmitted**
image. If a source rotates, scales or crops an image, it must transform the
intrinsics to match before sending.

## Timestamps and epochs

- `t`: source monotonic time in seconds (iPhone: `ARFrame.timestamp`;
  simulator: `(performance.timeOrigin + performance.now()) / 1000`).
- `seq`: increases by 1 per message of that kind, per session.
- `session`: random string chosen when the source connects.
- `epoch`: world-origin epoch. The source increments it when the AR world
  origin resets. The backend clears map, targets and route on any change.

The source captures `t`, `seq` and `pose` **at the moment the image is captured
or rendered**, before any asynchronous encoding.

## Binary frame message (`/ws/sensor`)

```
[uint32 little-endian: header length N][N bytes UTF-8 JSON header][JPEG bytes]
```

Header:

```json
{
  "v": 1, "type": "frame",
  "source": "sim" | "iphone",
  "session": "a1b2", "epoch": 0, "seq": 42, "t": 1234.567,
  "width": 640, "height": 480,
  "intrinsics": [fx, fy, cx, cy],
  "image_transform": {"rotation_deg": 0, "scale": 0.3333, "crop": [0, 0, 1920, 1440]},
  "pose": [16 floats],
  "tracking": "normal" | "limited" | "not_available",
  "perception": "real" | "injected",
  "injected": null
}
```

`image_transform` is informational (it documents how the transmitted image came
from the sensor image). The backend uses `intrinsics` as given.

`perception: "injected"` is a debug mode available only in the simulator. Then
`injected` holds `{"depth_w", "depth_h", "detections": [{"label", "bbox": [x0,y0,x1,y1]}]}` and the
binary payload after the JPEG holds `depth_w*depth_h` float32 metric depths.
Layout for injected frames: `[u32 N][header][u32 jpegLen][jpeg][float32 depth]`.
The backend labels all results from such frames as injected.

## Pose message (JSON text on `/ws/sensor`, ~30 Hz)

```json
{
  "v": 1, "type": "pose", "session": "a1b2", "epoch": 0, "seq": 901, "t": 1234.600,
  "pose": [16 floats],
  "tracking": "normal" | "limited" | "not_available",
  "tracking_reason": "excessive_motion" | null,
  "head": {"q": [x, y, z, w], "available": true} | null,
  "floor_y": -1.32 | null
}
```

- `head.q` is the headphone orientation in the headphones' own reference frame.
  It is **not** in world coordinates. The backend aligns it during `calibrate`.
  Head position is never sent.
- `floor_y`: optional floor height from ARKit horizontal plane detection.

## Control messages (client → Mac, JSON on `/ws/control`)

```json
{"type": "hello", "role": "iphone" | "sim-app"}
{"type": "command", "text": "find the bottle"}
{"type": "choose", "index": 1}
{"type": "stop", "reason": "user"}
{"type": "resume"}
{"type": "calibrate"}
{"type": "config", "navigation": true, "probe_offset": [0, 0, 0]}
{"type": "client_status", "audio_ok": true, "interrupted": false}
```

Command text accepts `find [object]`, `stop`, `cancel`, `repeat`, `inspect`,
`resume`, `calibrate`, `choose N`, `navigation on|off`.

## Guidance messages (Mac → client, JSON on `/ws/control`)

`guidance`, sent on every pose update (~30 Hz):

```json
{
  "type": "guidance",
  "mode": "idle" | "searching" | "choosing" | "walking" | "probe" | "stopped",
  "stop_reason": null | "user" | "tracking_lost" | "connection" | "stale" | "route_blocked" | "audio" | "interrupted" | "world_reset" | "rescan",
  "epoch": 0,
  "source": {"pose_seq": 901, "pose_t": 1234.600, "frame_seq": 40, "frame_t": 1234.400},
  "perception": "real" | "injected",
  "target": null | {
    "id": "bottle-1", "label": "bottle",
    "position": [x, y, z], "extent": [ex, ey, ez],
    "surface": [[x, y, z], ...],
    "sigma": 0.12, "age": 0.4, "valid": true, "observed_now": true
  },
  "proximity": null | {"distance": 0.82, "pulse_interval": 0.45, "confirm": false, "threshold": 0.2},
  "waypoint": null | {"position": [x, y, z], "distance": 1.4, "azimuth_head": -0.4, "azimuth_phone": -0.3, "instruction": "turn left"},
  "listener": [x, y, z],
  "audio_yaw_offset": 0.0
}
```

- `proximity.distance` is from the phone probe point to the nearest point of
  the target surface estimate. It is phone proximity, not grasp detection.
- `azimuth_*`: radians, positive = to the right.
- `listener`: approximate body position. In Probe mode it stays fixed at mode
  entry.

Other Mac → client messages:

```json
{"type": "say", "text": "Found a bottle about 2 metres ahead."}
{"type": "choices", "options": [{"index": 1, "id": "bottle-1", "description": "left, 2.1 metres"}]}
{"type": "cue", "name": "stop" | "confirm" | "rescan"}
```

### Phone-side proximity

For responsive probing the iPhone computes distance from its newest ARKit
pose to `target.surface` itself. It uses the target only while
`target.valid` is true, `guidance.epoch` equals the current AR epoch, and the
last guidance message is under 1 s old. It must not treat a cached target as
continuously verified: `observed_now` says whether the latest processed frame
saw it.

## Viewer messages (Mac → viewer, `/ws/viewer`, ~5 Hz)

```json
{
  "type": "recon", "epoch": 0, "perception": "real",
  "grid": {"origin": [x0, z0], "res": 0.1, "w": 80, "h": 80, "cells": "<base64 uint8>"},
  "points": "<base64 float32 xyz...>",
  "phone": {"position": [..], "forward": [..], "tracking": "normal"},
  "listener": [..], "mode": "probe",
  "targets": [{"id", "label", "position", "extent", "sigma", "age", "selected"}],
  "path": [[x, z], ...], "waypoint": [x, z] | null,
  "proximity": {...} | null,
  "stats": {"vision_fps": 7.9, "frame_age_ms": 120, "pose_hz": 30, "rss_mb": 2100, "mps_mb": 900, "budget_mb": 16384, "dropped_frames": 12}
}
```

Grid cell values: `0` unknown, `1` observed free, `2` occupied, `3` inflated
(blocked for walking), `4` floor seen but uncertain.

Viewer `stats` also includes `sensor_connected` (boolean), `observation_age_ms`
(elapsed time since the last processed frame, or null) and `pose_age_ms`
(elapsed time since the last received pose, or null). These ages are recomputed
for every snapshot, even when the sensor stops sending. `frame_age_ms` remains
the capture-to-processing latency measured for the last frame. The room viewer
uses the elapsed ages plus time since receipt to distinguish live and cached data.

`scan_id` is an opaque string that changes whenever the backend resets its world,
including reconnects with a new sensor session and tracking resets within the same
AR epoch. `stats.map_version` increments when depth observations are integrated.
The viewer uses these to retain a bounded, 4.5 cm voxel display history (up to
20,000 measured points, expiring after 90 seconds without observation), skipping
duplicate snapshots and clearing history on a world reset. This display history
does not affect the occupancy map, target positions, or navigation. Target entries
also expose `locked`, so the viewer can distinguish a locked position from a fresh
detection.
