# Voice and spatial audio testing

Beacon uses **Calibrate** and **Talk to Beacon** on the main screen. Hold to record,
speak and release to send. The Mac transcribes the recording.
There is no wake-word listening or Action button activation in the main app. Use a
physical iPhone for microphone, spatial audio and AR tracking checks.

## Get the app and install

In a checkout with no uncommitted work:

```sh
git fetch origin
git switch main
git pull --ff-only origin main
open ios/Beacon/Beacon.xcodeproj
```

If the repository is not on the test Mac yet, clone
`git@github.com:Jakaliver/Trident.git` first.

Select scheme **Beacon**, choose the tester's signing team and a unique bundle
identifier, then build and run on their iPhone. The checked-in signing team belongs to
the existing project; each tester should replace it locally. Follow
[real iPhone setup](real-device.md) for device pairing and permissions.

On the Mac running perception, run `scripts/setup.sh` once, then `scripts/dev.sh`.
Set **Mac host** in the phone app to that Mac's local hostname or IP, without a URL scheme
or port. Both devices need the same reachable network. Confirm **Connected** and **Ready** on the main screen before testing object guidance. The installation Mac and backend
Mac can be different computers.

## Full-app acceptance checks

Use a well-lit room, a bottle or another object supported by the current detector,
and headphones paired with the iPhone. Start at a low camera frame rate if the test
Mac is slow. Stay in a clear area while checking spatial audio.

For each spoken request below, hold **Talk to Beacon**, speak and release to send.

1. Open Beacon and tap **Calibrate** with the phone pointing ahead. With compatible
   AirPods, face the same direction. Allow Microphone access when first recording.
2. Send **"loot mode on"**, then **"find the bottle"**. Check the **Heard:** text under
   Settings → Speaking voice and that the Mac starts a search. A single continuous
   chest sound should start only after a valid target is acquired.
3. Turn your head and move slowly while tracking stays normal. Listen for 45 seconds
   across two loop boundaries, checking for gaps, clicks or doubled sounds.
4. Send **"status"** or **"help"**. Guidance pauses while recording; the chest lowers
   while the reply speaks. Old replies must not queue up after a newer request.
5. Switch **Chest → Beeps → Chest** in Settings. Also test **"loot mode off/on"** and
   **"turn off/on loot mode"**. The object stays selected and one sound style plays.
   Check that this preference survives relaunch and does not resume a paused search.
6. Test **Stop**, then send **"resume"**. Stop must cancel a recording or pending request.
   A delayed transcript must not restart guidance. Test the same with **"pause"**.
7. Send **"start over"**, then **"resume"**: the old search must stay cleared. Find a new
   object, then send **"found it"**; this finishes without resetting tracking.
8. Leave or lock the app, disconnect the backend, lose tracking or disconnect headphones.
   Restore each condition and explicitly resume. There should be no leftover sound.
9. Leave Beacon open without touching the button and say **"Beacon, find the bottle"**.
   No recording or search should start. Reopen the app and repeat. Tap to record and
   check **"repeat"**, **"inspect"**, **"help"** and a new search still work.

The backend currently selects targets automatically. The phone also accepts recorded
**"left"**, **"right"** and **"the one on the left/right"** if choices are provided.
Exercise that dialogue in the separate Voice Lab below.

## Speaking voice

Leave the voice picker on **Automatic**, then tap **Try voice**. Automatic prefers a
Siri voice **only if iOS exposes one to the app**, otherwise the best available Apple
English voice, preferring premium/enhanced quality and British English on ties.
The UI shows the actual selected voice and explains the fallback. An explicit choice
in the picker is remembered and takes precedence over Automatic.

Installing a Siri voice does not guarantee it is available to third-party speech
synthesis. Apple's public API does not provide a switch to use the user's Siri voice;
see [Apple's speech synthesis presentation](https://developer.apple.com/videos/play/wwdc2020/10022/).
The implementation uses the supported voice inventory, with no private Siri identifiers.
If an enhanced English voice is installed in iPhone accessibility speech settings,
return to the app to refresh the list and compare **Try voice**.

## Optional Voice Lab check

Scheme **BeaconVoiceLab** installs a separate app and needs no Mac backend or camera.
Set its signing team and unique bundle identifier as well. It retains hands-free recognition for testing and shares the command coordinator,
voice selection and PHASE chest playback with Beacon,
with sample targets instead of live detections.

Start voice mode, say **"loot mode on"**, then **"find a bottle"**. When offered two matches, say **"left"**
or **"the one on the right"**. A chest loop should play from the selected sample
position. Test pause/resume, start over, found it, speech ducking and the gear menu's
Chest/Beeps setting. Voice Lab cannot validate AR tracking, real object detection,
network behavior or world alignment in the full app.

## Validation and feedback

Build both **Beacon** and **BeaconVoiceLab** with Xcode, then run these focused checks
after changes:

- `scripts/test-voice-directions.sh`: directional choices, loot commands and rejected phrases.
- `scripts/test-voice-session.sh`: speech coordination, button-only capture policy, revised commands and cancellation.
- `scripts/test-voice-lab-directional.sh`: object-selection dialogue.
- `scripts/test-voice-lab-sound.sh`: sound switching, saved loot preferences and audio lifecycle
  checks using a fake audio output.

These checks do not exercise a real microphone, speech voice, PHASE playback or ARKit.
Run the physical-device checks above to validate microphone recognition and spatial
playback; a successful build or unit test does not cover those behaviors.

For feedback, include `git rev-parse --short HEAD`, iPhone/iOS version, headphone model,
the command spoken, the displayed **Heard:** text, and expected versus actual behavior.
For audio issues, say whether Chest or Beeps was selected and whether the app was
speaking at the time. The bundled chest sound's source and processing are recorded in
[chest sound source](chest-sound-source.md).
