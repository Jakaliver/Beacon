# Demo guide (virtual)

Start with `scripts/dev.sh` and open <http://localhost:5173/?lab=1> (or choose **Simulator
lab** from the room view). Wait until **Session details** shows `vision … fps` (the models
load in a few seconds). Open **Audio preview → Enable audio** in the Reconstruction pane:
guidance stops with reason `audio` while audio is off.

Simulator keys work after you click the 3D view:

| Keys | Moves |
|---|---|
| `W` `S` / `A` `D` / `Q` `E` | body: walk / turn / sidestep (carries head and phone) |
| `←` `→` / `↑` `↓` | head only: turn / tilt |
| `I` `K` `J` `L` `U` `O` | phone position relative to the body |
| `T` `G` / `F` `H` / `R` `Y` | phone pitch / yaw / roll |

The phone is held upright, so its camera sends a landscape image rolled by 90°, as a real
iPhone does. The backend rotates frames upright before running the models.

The simulator status line shows a **ground-truth** phone-to-target distance. It exists only
for checking estimates. It is never sent to Trident.

## Every session: first sweep

1. Click **Point down** for 1–2 s. This simulates ARKit floor-plane detection, which gives
   the backend a metric floor height for its depth-scale check.
2. Click **Hold ahead**. Turn a little left and right (`A`/`D`) to start the map.

## Milestone 1: find a bottle with hot/cold audio

Scene **M1: clear room**. Leave **Route guidance** unchecked.

1. Type `find the bottle` (or click **Find bottle**, or hold **Hold to talk** and say it).
2. Trident says "Found the bottle, about 2.2 metres ahead". Mode becomes `hotcold`.
3. Walk forward (`W`). Pulses speed up. At about 1.1 m Trident says "Stop walking…" and
   enters `probe`: the listener (purple ring) stays fixed.
4. Click **Reach to target**, then lower the phone (`O`) and push it forward (`I`). Near the
   bottle a three-note chime confirms proximity, and the panel shows `✔ CLOSE`.

Things to check:

- Head only (`←`/`→`): the distance does not change.
- Phone only (`I`/`K`/`O`): the distance changes, and the purple listener ring stays put.
- Turn away (`A`): the target stays at the same place in the reconstruction. The panel says
  "cached, not verified now", and the ± uncertainty grows.
- **Inspect** speaks mode, distance, direction, age and uncertainty.

## Milestone 2: obstacles and routing

Check **Route guidance**. In walking mode Trident says "turn left / turn right / continue".
A low triangle beacon (stereo-panned towards the waypoint, relative to the head) differs from
the high probe blips. The room view shows the computed path (pale blue) and the waypoint.

- **M2: target behind a table**: the route bends around the table. At the approach point
  Trident switches to Probe mode.
- **M2: newly introduced obstacle**: start guidance, walk a step, then **Drop obstacle
  ahead** (an unrecognised box). Trident replans or stops with "no safe route yet". Turn
  left and right to scan, then **Resume**.
- **M2: blocked route**: a partition with one gap. **Drop obstacle in gap** blocks it: Trident
  stops with reason `route_blocked`.
- **Two similar targets**: Trident lists both and asks "Say choose and a number". It never
  switches by itself.
- **Object on a table**: walk close and probe around the table top.

Unknown space is never walkable. When Trident has not seen enough floor, it stops instead
of guessing.

## Faults and world events (Simulator pane)

| Control | Expected |
|---|---|
| Tracking lost | immediate stop `tracking_lost`; Resume is refused until tracking is normal |
| Disconnect | stop `connection`; Resume refused while disconnected |
| Delay slider (≥ 600 ms) | stop `stale` or `connection` |
| AR world reset | new epoch: map, targets and route cleared, stop `world_reset` |
| Move target (unseen) | nothing changes until the phone looks at the old place again, then "not where I expected" |
| Point down | tracking continues; the cached target stays valid for up to 30 s |

After any stop, guidance resumes only on **Resume**, and only when conditions are valid.

## Injected perception (debug only)

Set **Perception source → Injected perception**. The simulator then sends rendered depth
and projected boxes in place of camera inference. A red banner appears in both panes, targets
are tagged `[INJECTED]`, and **Inspect** says so. Use it only to debug geometry and routing.
