# Trident

Trident uses an iPhone camera and local Mac models to locate objects and provide spatial
audio guidance. The iPhone runs the app, captures ARKit poses and camera frames, accepts
commands and plays guidance through headphones. The Mac runs depth estimation, object
recognition, speech recognition, mapping and target tracking locally.

The browser is a **read-only room visualization**: grey measured surfaces, a white iPhone
marker, and the selected target in red. It connects only to `/ws/viewer`. It has no microphone,
audio playback, commands, guidance controls or simulated camera.

## Start

```sh
scripts/setup.sh   # once: Python dependencies, model weights, warm-up and web dependencies
scripts/dev.sh     # backend on :8787, room view on :5173
```

Open <http://localhost:5173>. Keep Trident open on an iPhone connected to the same Wi-Fi.
See [iPhone setup](docs/real-device.md) for signing, installation and connection settings.

Use the iPhone app to find an object. Its selected target appears automatically in the room
view. **3D** shows height, **Overhead** shows the floor plan, **Fit room** restores automatic
framing, and **Locate** centres the selected target. Drag to orbit, right-drag to pan and
scroll/pinch to zoom. In Overhead mode, drag to pan.

The scan retains up to 20,000 measured points for up to 90 seconds as the camera turns.
Paused or disconnected scans are labelled. A fresh camera session clears the old room.
This is estimated monocular depth, not hardware LiDAR or a complete model of unseen surfaces.

## Layout

```
mac/trident/               local perception, mapping, targets, guidance, speech and server
web/reconstruction-viewer/ read-only Three.js room visualization
ios/Trident/               SwiftUI, ARKit and PHASE spatial audio app
shared/PROTOCOL.md         sensor, control and reconstruction message contracts
scripts/                   setup.sh and dev.sh
docs/                      phone setup, demo guide, model licences and limitations
```

Camera frames and poses travel from the iPhone to `/ws/sensor`. Commands and audio guidance
travel between the iPhone and `/ws/control`. The web view receives reconstruction snapshots
from `/ws/viewer` without controlling either stream.

The renderer reuses a fixed GPU point buffer, one floor texture and simple target outlines.
It draws at most 30 frames per second, skips unchanged frames and hidden tabs, and needs no
external model assets, shadows or postprocessing.

## Configuration and checks

- `TRIDENT_PARAKEET`: speech model, default `mlx-community/parakeet-tdt-0.6b-v3`.
- `TRIDENT_MEMORY_BUDGET_MB`: memory budget reported by `/api/health`, default `16384`.
- `TRIDENT_DEBUG_DIR`: optional local image, point-cloud and observation logs.
- Mapping and guidance settings: `mac/trident/config.py`.
- Requirements: Apple-silicon Mac, Python 3.11, uv, Node and Xcode supporting your iPhone.

```sh
cd web
npm test
npm run build
```

Backend checks: `cd mac && for m in geometry mapping targets planner; do uv run python -m trident.$m; done`.
See [limitations](docs/limitations.md) for the practical limits of estimated depth and guidance.
