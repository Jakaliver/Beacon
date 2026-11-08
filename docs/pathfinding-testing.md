# Nonverbal pathfinding: real iPhone branch test

Branch: `codex/nonverbal-pathfinding`. Keep this branch unmerged until the physical
iPhone checks below have been completed and reviewed. Unit checks and an iPhone SDK
build do not establish real-world clearance, spatial-audio accuracy or felt haptics.

## Install on the test laptop

In a clean checkout:

```sh
git fetch origin
git switch codex/nonverbal-pathfinding
git pull --ff-only origin codex/nonverbal-pathfinding
git rev-parse --short HEAD
open ios/Beacon/Beacon.xcodeproj
```

Build the **Beacon** scheme for a **physical iPhone**, using the tester's signing
team and bundle identifier. The checked-in project is ready to open; XcodeGen is
only needed after changing `project.yml`. See [device setup](real-device.md) for
pairing, signing and permissions. Do not use the separate Voice Lab to validate
pathfinding: it does not receive real camera geometry.

Update the Mac backend from this same branch. Run `scripts/setup.sh` if dependencies
or model files are missing, then `scripts/dev.sh`. Wait for `vision_ready` and
`speech_ready` at `http://localhost:8787/api/health`.

On the phone, configure **Settings → Apps → Beacon → Mac host** with the backend
Mac's local hostname or IP, without a scheme or port. Return to Beacon to apply the
change. Both devices must be on a network that allows them to communicate. Existing
saved host and sound preferences are retained.

## Interaction contract

- The main app screen has one interactive control: **Talk to Beacon**. Hold to record
  and release to send. No calibration, stop, settings, object-choice or navigation
  buttons are added to the screen. Connection and guidance status remain readable.
- Existing commands remain available, including **find**, **calibrate**, **pause**,
  **resume**, **start over**, **found it**, and **loot mode on/off**.
- The only new command actions are **pathfinding on** and **pathfinding off**.
- With pathfinding off, the selected object's existing Chest/Beeps behavior remains.
- With pathfinding on, walking uses a distinct spatial waypoint cue for either sound
  preference. The target's chest loop must not draw the user straight across a detour.
  Close approach returns to the object's selected sound style.
- Caution and stop feedback use short haptics; a stop also has a distinct audio cue.
  There are no spoken turn-by-turn directions or repeating obstacle explanations.
- Stale or unobserved space pauses movement guidance. Repeated unchanged warnings must
  not build a queue. Use the existing **resume** command after addressing the cause;
  switching pathfinding or loot mode must not silently resume a paused search.

## Physical acceptance checks

Use a sighted tester in a level, well-lit room with a clear retreat area and a second
person to move test obstacles. Validate direction and warnings while stationary
before following any route. Do not use stairs, drop-offs or glass as walking targets.
This remains a prototype; missing sensor evidence must never be treated as clearance.
Allow generous room around the route: the current phone/body allowance uses roughly
a 0.7 m radius before additional movement margin, so ordinary narrow doorways may
be refused. Reaching the phone over furniture may also pause guidance; do not treat
approach mode as permission to reach through an obstacle.

For every spoken action below, use the same push-to-talk button.

| Check | Procedure | Required result |
|---|---|---|
| One-control screen | Open the app and inspect its accessible controls. | Only push-to-talk is interactive; no hidden choice, Stop or settings button. |
| Configuration | Change Mac host in iPhone Settings and return. | App connects to the chosen laptop; stored sound preferences remain. |
| Default behavior | On a fresh install, check pathfinding starts off; explicitly switch it off before finding a supported object. | Existing direct object guidance works without route cues. Later launches retain the chosen pathfinding preference. |
| Toggle while searching | Start finding an object, then enable pathfinding. | The current search/target is retained; state reflects the acknowledged setting. |
| Open route | Scan the floor and surrounding body-height space, then select an object across a clear area. | Fresh observed space permits a waypoint cue; no spoken turn sequence. |
| Detour | Place a chair/box between the user and target; observe an adequately wide route around it. | Cue follows the observed detour and never directs through the obstacle. If coverage is inadequate, pause rather than invent a route. |
| Both sound styles | Repeat the detour with loot mode on and off. | Both use route cues during walking; no competing target chest loop. The object sound returns only for approach. |
| Low obstacle | While stationary, observe a low box and then look above it. | Looking above it must not erase its occupied space or authorize a path through it. |
| New obstacle | Have the second person place an obstacle in the next route segment. | Route sound is suppressed and stop feedback occurs before any further movement is suggested. |
| Unseen corridor | Turn the camera away from the next segment and wait for evidence to expire. | Movement cues stop; the state explains that observations are missing or stale. |
| Phone-only rotation | Rotate the phone without moving the torso. | No newly walked/free cells or false arrival are inferred from the rotation. |
| Resume | Clear a blockage, observe the corridor again, then say resume. | Resume is refused until evidence supports it; restoring tracking alone must not restart movement. |
| Explicit pause | Say pause; toggle pathfinding and loot mode; wait. | No movement or target sound restarts until an explicit resume or new search. |
| Pause during search | Enable pathfinding, begin finding an object that is not yet visible, pause, then resume. | Searching resumes without requiring a route to a nonexistent target; movement remains gated when a target is found. |
| Toggle after cancellation | Say start over or found it, then toggle pathfinding. | The setting acknowledgement updates without reviving the cancelled target or leaving the app waiting indefinitely. |
| Pending request | Release a request, then begin another hold before transcription completes. | The old result cannot execute. Only the newest released request is accepted. |
| Warning during speech input | Hold push-to-talk while the second person obstructs a previously usable corridor. | Stop feedback remains available while recording; the older route cannot restart on release. |
| Link/tracking loss | Disconnect the backend, cover the camera, then leave/lock the app in separate trials. | Guidance stops promptly and does not replay on recovery. |
| World reset | Say start over, then resume. | Old geometry, target, route and feedback do not reappear. A new find is required. |
| Approach | Approach a target on an accessible surface, then try a target separated by a barrier while remaining stationary. | The route endpoint must be accessible; proximity across a barrier cannot count as arrival or permission to reach. |

Haptics must be distinguishable on the actual phone and must not cause repeated camera
tracking loss. Listen with the intended headphones for spatial direction, overlap and
headroom. A stop must interrupt a route cue even if another sound is already playing.

## Record before merging

For each test, record pass/fail, the commit hash, phone/iOS and headphone models,
backend laptop, sound style, exact spoken request, displayed state, and the backend
event log. For missed or late warnings, include capture age and the timing of the
obstacle appearance and audible/haptic response. Report repeated false stops too:
a route that never emits a cue in a genuinely clear observed corridor is also a failure.

Record physical results separately from automated checks. Merge only after the
real-device results have been reviewed; do not infer a pass from a successful build.

## Repeat the automated checks

With the backend dependencies installed, from the repository root:

```sh
cd mac
uv run python -m unittest discover -s tests
cd ..
bash scripts/test-pathfinding-feedback.sh
bash scripts/test-hold-to-talk.sh
bash scripts/test-voice-directions.sh
bash scripts/test-voice-session.sh
bash scripts/test-guidance-audio.sh
```

These exercise synthetic geometry, state transitions, command parsing and sound
generation. They do not validate model accuracy or real iPhone audio and haptics.
