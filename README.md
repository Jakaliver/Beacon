# Trident

Trident uses an iPhone camera and local Mac models to locate objects and provide spatial
audio guidance. The iPhone runs the app, captures ARKit poses and camera frames, accepts
commands and plays guidance through headphones. The Mac runs depth estimation, object
recognition, hold-to-talk speech recognition, mapping and target tracking locally.
Hands-free voice mode recognizes commands on the iPhone. Say "find the bottle",
"calibrate", "pause", "resume", "start over" or "found it" while the app is open.
Found objects play a continuous spatial chest sound by default; choose **Chest** or
**Beeps** in Settings. See the [voice and audio test guide](docs/voice-audio-testing.md)
for installation, expected behavior and checks on a real iPhone.

The browser is a **read-only room visualization**: grey LiDAR-style dots, a white iPhone
marker, and the selected target in red. It connects only to `/ws/viewer`. It has no microphone,
audio playback, commands, guidance controls or simulated camera.

## Start

```sh
scripts/setup.sh   # once: Python dependencies, model weights, warm-up and web dependencies
scripts/dev.sh     # backend on :8787, room view on :5173
```

Open <http://localhost:5173>. Keep Trident open on an iPhone connected to the same Wi-Fi.
See [iPhone setup](docs/real-device.md) for signing, installation and connection settings.

On the iPhone, tap **Calibrate**, then **Hold to navigate**: say what to find and release.
**Stop** appears during active requests or guidance. Connection settings live behind the gear.
You can also assign **Trident → Push to Talk** to the iPhone's Action button in Settings.
Press to start, speak, then pause to send; press again to send early.
Use the iPhone app to find an object. Its selected target appears automatically in the room
view. **3D** slowly circles the scan at 30° above horizontal, completing a turn in 90
seconds. Drag or zoom to pause and inspect; press **3D** to resume. **Overhead** shows a
stationary floor plan, **Fit** restores automatic framing, and **Locate** centres the
selected target. Right-drag to pan and scroll/pinch to zoom. In Overhead mode, drag to pan.
**First person** follows the iPhone's position and viewing direction through the point
cloud, with a level horizon and perspective depth. Move the phone to look around. If
tracking pauses, it holds the last valid view; choose **3D** to return to the room orbit.

**Colour** switches the grey LiDAR view to soft dots coloured from their source camera
pixels. Selected targets remain red. The scan builds up to 60,000 points in 2.5 cm cells.
Repeated sightings refine depth and colour; confirmed points remain when you turn away.
New points need two sightings, and removing incorrect geometry requires three consistent
depth observations. Occluded walls are preserved. There is no time expiry for confirmed
points; the oldest observations leave only when the point budget is full. Closer, consistent
sightings also refine the target position. Paused or disconnected scans are labelled.
A fresh camera session clears the old room.
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

Floor height is automatic. The iPhone prefers an ARKit-classified floor, otherwise waits
for a stable, large plane below the phone. Scan a wide floor patch from normal holding
height; camera geometry can still display while floor detection settles.

## Configuration and checks

- `TRIDENT_PARAKEET`: speech model, default `mlx-community/parakeet-tdt-0.6b-v3`.
- `TRIDENT_MEMORY_BUDGET_MB`: memory budget reported by `/api/health`, default `16384`.
- `TRIDENT_VIEWER_HZ`: room view updates per second, default `5`. The point cloud is only resent
  when it changes, and at most 5 times a second, so a fast Mac can use `30`. Put per-machine values in `mac/local.env`
  (not in Git), for example `TRIDENT_VIEWER_HZ=30`; `scripts/dev.sh` loads it.
- The iPhone's camera frame rate is in the app's Settings (2–30 per second, default 20).
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
