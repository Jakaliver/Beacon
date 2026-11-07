# Limitations

## Verified only in the simulator

- Everything ran against rendered images on the Mac. The native app compiles, but ARKit
  capture, intrinsics, Bluetooth audio, AirPods head tracking and Wi-Fi latency are untested.
- The Web Audio beacon is a stereo-pan preview. It does not verify Apple spatial audio.

## Monocular depth

- Depth Anything V2 Metric (Hypersim) has a view-dependent scale error. In the simulator it
  ranged from about 0.7× to 1.6×. Trident corrects each frame with the known floor height
  (from ARKit plane detection, or simulated plane detection). Frames without enough visible
  floor (at least 1 m²) reuse a running scale. Objects are also kept from sinking below the floor.
- Measured in the clear-room scene: target estimates within about 5 cm at 1–2.5 m, and about
  10–15 cm when the phone is within 0.5 m. The confirm threshold is therefore ≥ 0.2 m and
  grows with uncertainty. This is phone proximity, not grasp detection.
- Objects seen only through gaps (for example, under a table between its legs) take the depth of
  the occluder. Their position can be wrong by more than 0.5 m.
- Map points are integrated only within 4 m, because far depth noise produced false obstacles.

## Detection

- YOLO11n detects the 26 cm bottle reliably from about 2.5 m. Beyond that, the user must walk
  closer while scanning.
- Only COCO classes are supported (`find the giraffe` is refused with an explanation). Some
  labels are imperfect: the simulator sofa is sometimes "bed" or "bench".
- A target that moved while unseen is noticed only when the phone looks at its old position
  again, from 0.7–5 m. Very close views do not count as evidence, because the detector often
  misses cropped objects.

## Mapping and routing

- The grid is 8×8 m with 10 cm cells and re-centres as the user moves. Long walks forget
  geometry that falls off the edge.
- Walking guidance needs observed floor. Floor right next to the feet is often not in view
  while the phone is held ahead, so Trident may stop with "no safe route yet" until the user
  scans down and around. Cells seen clear of obstacles without a confirmed floor are allowed
  at triple cost. Cells the body has stood on count as floor.
- Obstacles smear along view rays because of depth error. Inflation (about 0.46 m in total)
  covers body radius, clearance, hand/body offset, depth and latency. Narrow gaps can
  therefore look closed.
- The body position is estimated as 0.3 m behind the phone along its heading. Deliberate
  reaching while walking is not detected separately, except through Probe mode.
- The map has no overhang model beyond obstacle heights from 0.15 m to 2.0 m above the floor.

## Not built

- No orbitable 3D point-cloud view (optional in the brief).
- No Bonjour discovery: the phone needs the Mac host name or IP address.
- No automated test suite: each module has a small `python -m trident.<module>` self-check.
