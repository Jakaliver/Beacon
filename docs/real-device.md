# Real iPhone setup

Status: the app builds for the iOS device and simulator SDKs. It has **not** run on a real
iPhone yet. Treat every step below as needing verification.

## Requirements

- iPhone with iOS 18+ (no LiDAR needed), AirPods paired with the iPhone (AirPods Max, Pro or
  3rd generation and later for head tracking).
- Mac and iPhone on the same Wi-Fi. Client isolation on the network must be off.
- Xcode 16+ and XcodeGen (`brew install xcodegen`).

## Build and install

```sh
cd ios/Trident
xcodegen generate          # only after editing project.yml
open Trident.xcodeproj
```

In Xcode: select the **Trident** target → Signing & Capabilities → choose your Team. Keep the
**Head Pose** entitlement (`com.apple.developer.coremotion.head-pose`); `AVAudioEnvironmentNode`
needs it for listener head tracking. If your team cannot sign it, remove it from
`Trident/Trident.entitlements`; audio then plays without head tracking. Build and run on the phone.

If Xcode reports "iOS 26.x is not installed", add the iOS platform in Xcode → Settings → Components.

## Connect

1. On the Mac: `scripts/dev.sh`. Find the Mac's address: `scutil --get LocalHostName` gives
   `<name>.local`, or use its IP address.
2. In the app's settings sheet, set the host (default `trident-mac.local`). Allow the
   camera, microphone, motion and local-network prompts.
3. The status line should read "Mac connected. Tracking normal."
4. The Reconstruction pane on the Mac shows the real phone's map. You can leave the
   Simulator tab closed. Two sensor sources at once replace each other's session.

## Use

1. Put on the AirPods. Hold the phone ahead of your torso, facing forward, and press
   **Calibrate**. This aligns the audio "forward" with the phone's ARKit heading. The app
   does not assume headphone orientation uses ARKit coordinates.
2. Sweep the phone slowly, including the floor, so ARKit finds the floor plane. The app
   sends its height as `floor_y`, and the Mac uses it to check depth scale.
3. Hold **Find object** and say "find the bottle". Release to send.
4. Follow the guidance: the walking beacon is spatial and placed at the next waypoint. Probe
   pulses are centred.
5. **Stop** works without the Mac. Guidance also stops when the connection drops, tracking
   fails, guidance is older than 1 s, the audio route changes, or the app is interrupted.
   Press **Resume** to continue.

## What to verify on the device

- Image orientation and intrinsics: the reconstruction must stay stable while you walk around
  a stationary object.
- That the 640×480 JPEG and the pose come from the same `ARFrame`.
- The beacon direction after Calibrate, by listening, and that head rotation changes the
  direction but not the hot/cold rate.
- Microphone route: the built-in mic is preferred while AirPods are connected.
- Frame rate and latency over your Wi-Fi (the viewer shows frame age and dropped frames).
