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

Open <http://localhost:5173>. The left pane is the **Simulator** (fake world). The right
pane is the **Reconstruction** (only what Trident estimated). Click **Enable audio**, then
follow [docs/demo-guide.md](docs/demo-guide.md).

Requirements: Apple-silicon Mac, Python 3.11 and [uv](https://docs.astral.sh/uv/), Node 20+,
Xcode 16+ with XcodeGen for the iPhone app.

## Layout

```
mac/trident/            FastAPI backend: perception, mapping, targets, planner, guidance engine, speech
web/simulator/          Three.js fake world, simulated phone/head/body, sensor adapter
web/reconstruction-viewer/  bird's-eye view + virtual phone client (commands, push-to-talk, Web Audio)
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

## Configuration

Environment variables for the backend:

- `TRIDENT_MEMORY_BUDGET_MB` (default `16384`): shown against measured RSS in the viewer.
- `TRIDENT_PARAKEET`: speech model (default `mlx-community/parakeet-tdt-0.6b-v3`).
- `TRIDENT_DEBUG_DIR`: writes the latest upright frame with detections, sampled point
  clouds and an observation log there.

Other tuning values (inflation margins, probe radii, timeouts) are in `mac/trident/config.py`.

Self-checks: `cd mac && for m in geometry mapping targets planner speech; do uv run python -m trident.$m; done`
