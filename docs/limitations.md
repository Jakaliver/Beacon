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
- The backend integrates map points within 4 m. The viewer retains up to 20,000 points in
  4.5 cm voxels for up to 90 seconds, which improves continuity while turning but can retain
  traces of moved objects or depth drift. A new camera world clears the display history.
- The occupancy grid is 8×8 m with 10 cm cells and recentres as the phone moves. It can show
  a different footprint from the retained point cloud. It does not model overhangs beyond
  obstacle heights from 0.15 m to 2.0 m above the floor.
- Red points lie inside the selected target's estimated box; they are not a separate
  per-point segmentation result. The floor ring includes position uncertainty.
- Paused geometry stays visible and is labelled. It is not evidence of current detection.
- WebGL 2 is required. The browser is read-only and does not control capture or guidance.

## Detection and guidance

- Object recognition is limited to the detector's supported COCO classes. Small, cropped,
  distant and partly hidden objects may be missed or mislabelled.
- Depth may fall on an occluder instead of the requested object, shifting the target's
  estimated position. Proximity confirmation is an estimate, not grasp detection.
- Walking guidance needs observed floor. Unknown or narrow spaces may have no usable route;
  depth error and obstacle inflation can make open gaps appear blocked.
- The body position is estimated behind the phone. Head orientation is measured separately;
  AirPods do not supply a tracked head position.
- Local network connectivity and foreground camera capture are required. The phone needs
  the Mac host name or IP; automatic discovery is not implemented.
