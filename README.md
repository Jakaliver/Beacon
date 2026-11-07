# Trident

Trident helps a blind user find an object with a handheld iPhone and audio feedback.
The iPhone captures camera frames, ARKit poses and speech. A Mac on the same Wi-Fi runs
all heavy work locally: metric depth, object segmentation, speech recognition, mapping,
target tracking and route planning. No cloud services or paid APIs.

Development happens first in a Three.js simulator that feeds the same backend pipeline as
the real phone.

## Status

| Part | State |
|---|---|
| Milestone 1: find an object, hot/cold audio on the Mac | Works in the simulator with real Depth Anything V2 + YOLO11 inference |
| Milestone 2: obstacle map, A* routing, spoken turns, Probe mode | Works in the simulator; see [limitations](docs/limitations.md) |
| Milestone 3: native iPhone app with spatial audio | Builds for device and simulator SDKs; **not yet run on a real iPhone** |
| Local speech (Parakeet) | Works on the Mac (push-to-talk in the browser and the `/api/transcribe` endpoint) |

## Quick start (Mac)

```sh
scripts/setup.sh   # once, needs internet: Python deps, model weights, 3D assets, warm-up
scripts/dev.sh     # backend on :8787, simulator + reconstruction on :5173
```

Open <http://localhost:5173> for the **Live room**: an overhead 3D reconstruction with
grey scan points, a red selected target, camera position and optional route overlay.
Drag to orbit, right-drag to pan, and scroll/pinch to zoom. **Top down** switches to an
orthographic floor plan; **Fit room**, **Locate**, and **Follow camera** control framing.
The layer switches control scan points, observed floor and route independently.

**Simulator lab** opens <http://localhost:5173/?lab=1>, with the fake-world simulator
on the left and reconstruction on the right. Open **Audio preview → Enable audio**, then
follow [docs/demo-guide.md](docs/demo-guide.md). The simulator is also available directly
at <http://localhost:5173/simulator/>.

To preview the graphics without the backend or model downloads:

```sh
cd web && npm ci && npm run dev
```

Open <http://localhost:5173/reconstruction-viewer/?preview=1>. This is explicitly labelled
sample data and disables guidance commands. Live mode never substitutes sample geometry
for missing camera data; disconnected or stale scans are marked as cached.

Requirements: Apple-silicon Mac, Python 3.11 and [uv](https://docs.astral.sh/uv/), Node 20+,
Xcode 16+ with XcodeGen for the iPhone app.

## Layout

```
mac/trident/            FastAPI backend: perception, mapping, targets, planner, guidance engine, speech
web/simulator/          Three.js fake world, simulated phone/head/body, sensor adapter
web/reconstruction-viewer/  live 3D room view + virtual phone client (commands, push-to-talk, Web Audio)
ios/Trident/            SwiftUI/ARKit/AVAudioEngine app (XcodeGen project.yml + generated .xcodeproj)
shared/PROTOCOL.md      sensor, control, guidance and viewer message contracts
scripts/                setup.sh, dev.sh
docs/                   demo guide, real-device setup, models and licences, limitations
```

## Pipeline

```
iPhone (ARKit + camera)  ─┐
                          ├─ /ws/sensor (JPEG + pose metadata) ─→ upright rotation
Simulator (rendered RGB) ─┘                                       → Depth Anything V2 metric + YOLO11n-seg
                                                                  → floor-based scale check
                                                                  → rolling 2.5D grid + target tracks
                                                                  → guidance engine (modes, stop rules, A*)
                          /ws/control (guidance, speech, cues) ←──┤
                          /ws/viewer  (reconstruction only)    ←──┘
```

The simulator and the reconstruction viewer are separate pages and separate data flows.
The viewer imports nothing from the simulator and only receives backend output.
Its point cloud uses a reusable GPU buffer (up to 20,000 points), a single textured floor
plane and simple target outlines. Rendering is capped at 30 fps, skips unchanged frames
and hidden tabs, and uses no shadows, postprocessing, external fonts or model assets.

## Configuration

Environment variables for the backend:

- `TRIDENT_MEMORY_BUDGET_MB` (default `16384`): shown against measured RSS in the viewer.
- `TRIDENT_PARAKEET`: speech model (default `mlx-community/parakeet-tdt-0.6b-v3`).
- `TRIDENT_DEBUG_DIR`: writes the latest upright frame with detections, sampled point
  clouds and an observation log there.

Other tuning values (inflation margins, probe radii, timeouts) are in `mac/trident/config.py`.

Self-checks: `cd mac && for m in geometry mapping targets planner speech; do uv run python -m trident.$m; done`
