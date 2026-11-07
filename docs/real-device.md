# Real iPhone setup

The iPhone sends camera frames and ARKit poses to the Mac. Depth estimation, object
recognition and speech recognition run on the Mac; the phone receives guidance. The live
3D room is displayed in the Mac's browser. Both devices must stay connected while testing.

## 1. Install Xcode and prepare the phone

- Use an ARKit-capable iPhone running **iOS 18 or later**. LiDAR is not required.
- Install the current **Xcode** from the Mac App Store, open it once, accept its licence
  and install the iOS platform components it requests. Choose a version that supports
  the iOS version on your phone; the command-line tools alone cannot build the app.
- In Xcode Settings, add your Apple Account under **Accounts / Apple Accounts**. A free
  **Personal Team** is sufficient for the current app.
- Connect the unlocked phone by USB, tap **Trust**, and let Xcode pair with it. In newer
  Xcode versions use **Device Hub**; older versions use **Window → Devices and Simulators**.
- On the phone, open **Settings → Privacy & Security → Developer Mode**, enable it,
  restart, then confirm. The option may not appear until pairing with Xcode has begun.

After installing Xcode in `/Applications/Xcode.app`, select its developer tools:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Sources: [Xcode download](https://developer.apple.com/xcode/),
[compatible Xcode and OS versions](https://developer.apple.com/xcode/system-requirements/),
[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device),
[Apple's signing workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html).

## 2. Set up and start the Mac backend

From the repository root, with Homebrew and Node 20+ installed:

```sh
brew install uv
bash scripts/setup.sh
bash scripts/dev.sh
```

`setup.sh` is a one-time online setup. It installs the Python environment, downloads the
vision and speech models, warms them up, installs web dependencies and downloads simulator
assets. Let it finish successfully before running `dev.sh`. Model warm-up should report
`vision warm-up ok on mps` on a supported Apple-silicon Mac.

Keep `dev.sh` running. It starts the backend on **8787** and the viewer on **5173**. Open
<http://localhost:8787/api/health> and wait for `vision_ready` and `speech_ready` to be `true`.
Then open <http://localhost:5173/reconstruction-viewer/>. This is live mode: do not add
`?preview=1`, which displays sample geometry instead.

For a real-phone session, close any **Simulator lab** or `/simulator/` tabs. Opening the
room viewer alone does not start a simulated sensor. The newest sensor connection wins.

## 3. Sign and install the iPhone app

The generated Xcode project is already checked in. From the repository root:

```sh
open ios/Trident/Trident.xcodeproj
```

1. Select the blue **Trident** project, then **TARGETS → Trident → Signing & Capabilities**.
2. Enable **Automatically manage signing** and choose **your** Personal Team. The checked-in
   project contains another developer's team; replace it locally.
3. Change **Bundle Identifier** to a unique identifier you control, for example
   `com.yourname.trident.dev`, if Xcode cannot register the checked-in identifier.
4. Choose the **Trident** scheme and your **physical iPhone** as the run destination.
5. Press **⌘R**. Leave the phone unlocked while Xcode prepares and installs the app.
   If asked to trust your developer account, follow the prompt under iPhone Settings →
   General → VPN & Device Management.

The current branch **does not require the Head Pose entitlement**. It uses
`CMHeadphoneMotionManager` for AirPods motion instead. Do not add the restricted entitlement
for a free Personal Team. Compatible AirPods are useful for spatial/head-tracked audio;
no headphones are needed just to check the camera feed and room reconstruction.

XcodeGen is optional for normal builds. If you edit `ios/Trident/project.yml`, install
it with `brew install xcodegen`, set your own `DEVELOPMENT_TEAM` and bundle identifier in
that file, then run `(cd ios/Trident && xcodegen generate)`. Regenerating from the unchanged
file will restore the checked-in developer's signing settings.

## 4. Connect the phone to your Mac

1. Put both devices on the same Wi-Fi, on a network that allows devices to communicate.
2. Find the Mac's local hostname:

   ```sh
   scutil --get LocalHostName
   ```

   Append `.local` to the result. Alternatively, use the Wi-Fi IP shown in macOS Network
   settings (`ipconfig getifaddr en0` when Wi-Fi is on `en0`).
3. In Trident on the phone, tap **Settings** (gear), enter that hostname/IP under **Mac host**,
   then tap **Done**. Enter only the host, **without** `http://`, `ws://` or `:8787`.
   The app currently defaults to another developer's Mac, so you must change this.
4. Allow Camera, Microphone, Motion and Local Network permissions when requested.
5. The phone should show **Mac connected** and **Tracking: normal**. The health endpoint
   should now show `sensor_connected: true`.

To diagnose connectivity before changing code, open
`http://YOUR-MAC-HOST.local:8787/api/health` in Safari on the phone. If it cannot load, check
Wi-Fi/client isolation, VPN routing, the Mac firewall and that `dev.sh` is still running.
Allow incoming connections for the backend if macOS prompts. Use the Mac's Wi-Fi IP if
`.local` name resolution fails. USB installation alone does not configure this network link.

## 5. First camera and target test

1. Keep Trident open in the foreground. Start at **5 frames/sec** in its Settings on a
   MacBook Air; raise the rate after checking latency in the viewer's **Session details**.
2. Sweep slowly across a well-lit floor and nearby furniture. A floor patch of about 1 m²
   helps ARKit establish the floor height. The Mac view should show **Live reconstruction**
   and an increasing point count.
3. Hold the phone ahead of your torso, facing forward, and tap **Calibrate**. If testing
   head tracking, wear compatible AirPods paired with the phone during calibration.
4. For the first object test, type **find the bottle** and tap **Send**. This isolates
   camera/detection setup from microphone setup. Once working, hold **Find object**, say
   the same request and release to send.
5. The selected target appears red in the Mac view. Current `main` locks its position after
   consistent sightings; send a new **find** command to reacquire an object that moved.
6. **Stop** silences guidance locally; **Resume** restarts when the connection and tracking
   are ready. Audio changes and app interruptions can also stop guidance.

## Troubleshooting

| Symptom | Check |
|---|---|
| `xcodebuild` says it needs Xcode | Install the full app, open it once, then run `xcode-select --switch` above. |
| iOS platform or device support missing | Install the requested component in Xcode Settings → Components, or update Xcode to support the phone's iOS. |
| Signing or provisioning error | Choose your own Team and unique bundle identifier. Keep automatic signing on; do not add Head Pose. |
| `uv: command not found` | Install `uv` with Homebrew and reopen Terminal if its PATH has not updated. |
| `vision_ready: false` / `speech_ready: false` | Wait for model loading and check the backend terminal. Re-run setup online if downloads did not finish. |
| Connected, but no room points | Allow Camera/Local Network access, wait for normal tracking, scan the floor, and check `vision_ready`. |
| Room stops changing | Check frame/pose age in the viewer, keep the app foregrounded, and close competing simulator tabs. |
| Sounds turn the wrong way with your head | Recalibrate while facing ahead; try the app's **Reverse head turn** setting. |

The browser build and backend self-checks can run without Xcode. A successful local
Xcode build, signing, device permissions, ARKit capture and audio still need verification
on the particular Mac/iPhone pair being used.
