# Limitations

## Current validation

Real iPhone camera capture, ARKit poses, Wi-Fi transport and Mac depth/object inference
have been exercised with the room viewer. Building the iPhone app does not by itself verify
perceived sound direction, AirPods head tracking or navigation accuracy. The latest audio
implementation comes from the main iPhone app and uses PHASE.

## Depth and the room display

- Depth is estimated from camera images. It has view-dependent scale error, especially
  around occlusions and close or distant objects. ARKit floor height helps correct scale;
  frames without enough visible floor reuse a running estimate.
- Only observed surfaces appear. Missing walls, floors or furniture are not filled in.
  An incomplete point cloud is not a complete room model.
- Navigation integrates map points within 4 m. The display samples depth up to 6 m, with
  up to 60,000 points in 2.5 cm cells. Confirmed points have no time expiry; the oldest
  observations are evicted only when the budget fills. A new world clears history.
- Display points need two sightings. Revisits average small depth and colour changes;
  removing points in observed free space needs three consistent depth observations.
  Modest depth overestimates can be repaired from closer views. Larger behind-surface
  differences are treated as possible occlusion, so hidden or ambiguous geometry can
  remain stale until it is seen clearly again. This is conservative fusion, not a global
  reconstruction optimiser, and does not eliminate monocular depth or ARKit drift.
- The phone prefers ARKit-classified floors. Its unclassified fallback requires a stable
  plane larger than 2 m² and at least 65 cm below the phone. Scan from normal holding height
  first. Without a trusted floor, the scan still displays, but floor-scale correction waits.
- The occupancy grid is 8×8 m with 10 cm cells and recentres as the phone moves. It can show
  a different footprint from the retained point cloud. Navigation now keeps height-bin
  occupancy and clearance between 0.06 m and 2.1 m above one estimated floor. Smaller
  hazards, thin geometry missed by sampling, transparent surfaces and ground-level changes
  are not reliably resolved. Unknown ground is blocked; this is not stair navigation.
- Red points lie inside the selected target's estimated box; they are not a separate
  per-point segmentation result. Camera-coloured dots use image pixels and soft splats,
  not a trained 3D Gaussian scene; lighting changes and occlusions can leave colour seams.
- Paused geometry stays visible and is labelled. It is not evidence of current detection.
- WebGL 2 is required. The browser is read-only and does not control capture or guidance.

## Detection and guidance

- Object recognition is limited to the detector's vocabulary: the COCO classes plus the
  household prompts in `EXTRA_PROMPTS` (`mac/beacon/perception.py`), such as doors and light
  switches. Small, cropped, distant and partly hidden objects may be missed or mislabelled.
  Extreme close-ups of a light switch, with no wall around it, are often missed.
- Depth may fall on an occluder instead of the requested object, shifting the target's
  estimated position. Proximity confirmation is an estimate, not grasp detection.
- Selected identity is retained offscreen, while new sightings refine its geometry. Closer
  views get more weight and large corrections require agreement. Similar objects along the
  same viewing direction remain ambiguous.
- Pathfinding is opt-in through push-to-talk. It requires observed floor and height
  clearance, including a recent local corridor and a fresh depth capture. Unknown or
  narrow spaces may have no usable route; depth error and conservative body inflation
  can make open gaps appear blocked. Two independent observations do not eliminate
  correlated monocular depth errors.
- Route position uses the phone's translation with an isotropic hand/body uncertainty
  allowance; rotating the phone cannot create walked-floor evidence. This is not a
  measured torso or foot position. The default footprint inflation rounds up to about
  0.7 m, so narrow doorways may be refused. AirPods do not supply a tracked head position.
- Object approaches check observed geometry; they do not model actual arm reach,
  bending or body posture. Extending the phone over furniture can pause guidance again.
- The stopping horizon uses estimated phone motion, the maximum permitted local-evidence
  age and configured response
  assumptions. These have not been validated as a person's stopping distance. The
  nonverbal pathfinding branch needs the [real-iPhone acceptance checks](pathfinding-testing.md)
  before merging; it has not been established as independent mobility assistance.
- Local network connectivity and foreground camera capture are required. The phone needs
  the Mac host name or IP; automatic discovery is not implemented.
