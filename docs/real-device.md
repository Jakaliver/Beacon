# Real iPhone setup

The iPhone sends camera frames and ARKit poses to the Mac. Depth estimation, object
recognition and hold-to-talk speech recognition run on the Mac; hands-free voice mode
recognizes commands on the iPhone. The phone receives guidance. The live
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
vision and speech models, warms them up and installs web dependencies. Let it finish successfully before running `dev.sh`. Model warm-up should report
`vision warm-up ok on mps` on a supported Apple-silicon Mac.

Keep `dev.sh` running. It starts the backend on **8787** and the viewer on **5173**. Open
<http://localhost:8787/api/health> and wait for `vision_ready` and `speech_ready` to be `true`.
Then open <http://localhost:5173>. The browser only receives reconstruction snapshots;
all commands, recording and audio are handled by the iPhone app.

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
   Settings → **Hands-free voice** → **Start voice mode** also requests Speech Recognition permission for on-device commands.
5. The phone should show **Connected** and **Ready**. The health endpoint
   should now show `sensor_connected: true`.

To diagnose connectivity before changing code, open
`http://YOUR-MAC-HOST.local:8787/api/health` in Safari on the phone. If it cannot load, check
Wi-Fi/client isolation, VPN routing, the Mac firewall and that `dev.sh` is still running.
Allow incoming connections for the backend if macOS prompts. Use the Mac's Wi-Fi IP if
`.local` name resolution fails. USB installation alone does not configure this network link.

## 5. First camera and target test

1. Keep Trident open in the foreground. Start at **5 frames/sec** under Settings → Advanced on a
   MacBook Air; raise the rate only while the displayed camera age remains low.
2. Sweep slowly across a well-lit floor and nearby furniture. A floor patch of about 1 m²
   helps ARKit establish the floor height. The Mac view should show **Live**
   and an increasing point count.
3. Hold the phone ahead of your torso, facing forward, and tap **Calibrate**. If testing
   head tracking, wear compatible AirPods paired with the phone during calibration.
4. Press and hold **Hold to navigate**, say **find the bottle**, then release. The button
   shows when it is listening and sending your request. With VoiceOver, double-tap to
   start recording and double-tap again to send.
5. The selected target appears red in the Mac view. Keep it visible while moving closer:
   consistent new sightings refine its position and surface. Larger corrections require
   three agreeing observations so a single bad depth frame does not move the target.
6. **Stop** appears while a request or guidance is active. It silences guidance and cancels
   any pending voice request. To continue, hold the main button and say **resume**, or ask
   for another object. Audio changes and app interruptions can also stop guidance.

### iPhone Action button

In iPhone **Settings → Action Button → Shortcut → Choose a Shortcut**, choose
**Trident → Push to Talk**. This App Shortcut is available after installing Trident;
no custom shortcut needs to be created. iOS requires the user to choose the assignment.

Press and hold the Action button to open Trident and start a request. A haptic marks
the start of recording. Say what to find, then pause: roughly one second of silence
after speech sends the request. Activate the Action button again to send early.
Recording is capped at six seconds. **Stop** cancels the request without sending it.
The on-screen **Hold to navigate** keeps its hold/release behavior.

This uses Apple's App Shortcut activation, which does not supply a button-release
event. Unlock the iPhone when prompted: Trident needs its foreground camera session
and a reachable Mac. If disconnected, it waits up to eight seconds before reporting
the connection problem. Leaving the app cancels pending recording and transcription.

Check a cold launch, a second press to send, silence after speaking, and Stop while
recording or sending. `bash scripts/test-action-button.sh` checks the automatic
end-of-request timing; the physical button assignment and microphone need an iPhone.
See [Apple's Action button setup](https://support.apple.com/guide/iphone/use-and-customize-the-action-button-iphe89d61d66/ios).

### Reading the room view

The view builds up to 60,000 depth points. Move slowly and revisit areas from closer views:
a second sighting confirms new dots, repeated observations refine them, and three consistent
depth readings repair incorrect geometry. Confirmed dots stay when you turn away; they
only leave when overwritten, the scan resets, or the point budget fills. **Colour** uses
the matching camera pixels for soft coloured dots; switch it off for the grey LiDAR view.
The colour preference survives a page refresh.
Floor height is automatic: scan a wide floor patch. ARKit-classified floors are preferred;
an unclassified plane must be stable, over 2 m² and at least 65 cm below the phone.
Low surfaces are dark grey in monochrome mode; higher surfaces are brighter. The
white **iPhone** arrow shows camera position and direction. Your selected object
has a red outline and label; its distance appears in the bottom status bar.

Use **3D** to see height, **Overhead** for a floor plan, and **Fit** to restore automatic
framing after dragging or zooming. **Locate** centres the selected target.
**First person** places the view at the iPhone camera and follows its direction, including
looking up and down. Move the phone to look around; a paused scan holds the last valid
camera position. Select **3D** or **Overhead** to return to the external room views.
Use **Hold to navigate** in the iPhone app to select a target; the browser is read-only.
The geometry comes from monocular depth estimates, not a hardware LiDAR scan.

Trident keeps the iPhone screen awake while open. Manually locking it or leaving the app
pauses capture. The viewer keeps the last scan and labels it paused until fresh frames return.
All speech and spatial guidance play on the iPhone. The browser never opens an audio or
microphone session and cannot change the phone's guidance state.
Guidance plays a continuous chest sound at the found object's position by default, with
distance attenuation and a subtle small-room reverb. Settings → **Object sound** switches
between **Chest** and the original **Beeps**. The chest sound lowers while the app speaks.
For the hands-free controls and audio acceptance checks, use the
[voice and audio test guide](voice-audio-testing.md).
With AirPods on, face where the phone points and press **Calibrate** so head turns keep
the sound aligned with the object. The reverb is a room preset, not measured room acoustics.

## Troubleshooting

| Symptom | Check |
|---|---|
| `xcodebuild` says it needs Xcode | Install the full app, open it once, then run `xcode-select --switch` above. |
| iOS platform or device support missing | Install the requested component in Xcode Settings → Components, or update Xcode to support the phone's iOS. |
| Signing or provisioning error | Choose your own Team and unique bundle identifier. Keep automatic signing on; do not add Head Pose. |
| `uv: command not found` | Install `uv` with Homebrew and reopen Terminal if its PATH has not updated. |
| `vision_ready: false` / `speech_ready: false` | Wait for model loading and check the backend terminal. Re-run setup online if downloads did not finish. |
| Connected, but no room points | Allow Camera/Local Network access, wait for normal tracking, scan the floor, and check `vision_ready`. |
| Room stops changing | Check the camera age in the viewer and keep the iPhone app foregrounded. |
| Speech works, but guidance is silent | Connect AirPods to the **iPhone**, check its audio output, then send a new **find** command or hold the main button and say **resume**. Listen for the spoken stop reason if guidance pauses. |
| Sounds turn the wrong way with your head | Recalibrate while facing ahead; try the app's **Reverse head turn** setting. |

For a playback check independent of camera detection, launch an installed **Debug** build
with the following command, substituting your device identifier and bundle identifier:

```sh
xcrun devicectl device process launch --device YOUR_DEVICE_ID --terminate-existing \
  --console YOUR_BUNDLE_ID -- --audio-self-test
```

After five seconds, it plays ten evenly spaced pulses. **Stop** cancels the sequence.
The console reports the active audio route, playback failures and completed sounds;
confirm that the pulses are actually audible through the selected output. Launch the app
again without `--audio-self-test` for normal use. Without headphones, audio defaults to
the phone's speaker.

The browser build and backend self-checks can run without Xcode. A successful local
Xcode build, signing, device permissions, ARKit capture and audio still need verification
on the particular Mac/iPhone pair being used.
