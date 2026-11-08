# Voice and spatial audio testing

Beacon uses a large **Talk to Beacon** control on the main screen. Hold to record,
speak and release to send. The Mac transcribes the recording.
The Action button shortcut also supports activate-to-start, activate-again-to-send.
There is no wake-word listening in the main app. Use a
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

1. Open Beacon, hold **Talk to Beacon**, say **"calibrate"** and release with the phone pointing ahead. With compatible
   AirPods, face the same direction. Allow Microphone access when first recording.
2. Send **"find the bottle"**. Check the **Heard:** text under Settings → Speaking voice
   and that the Mac starts a search. Beeps should start only after a valid target is acquired.
3. Turn your head and move slowly while tracking stays normal. Listen for 45 seconds,
   checking for consistent direction and clean beeps without crackle or doubled sounds.
4. Send **"status"** or **"help"**. Guidance pauses while recording and while the reply
   speaks. Old replies must not queue up after a newer request.
5. On an existing installation that previously used another sound, find an object and
   confirm beeps still play. There is no Object sound selector or continuous audio loop.
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

## Proximity sounds

Move the phone towards a found object: the clean beeps should
speed up and turn into a short, rising double beep when close (normally within 20 cm of the observed surface).
Rotate the phone while keeping its position fixed; this must not change the proximity
cue. The damped sound stays anchored to the object, without a room tail. Small position
wobbles near the threshold should not alternate rapidly between single and double beeps.

Check the beeps very close to the object as well as farther away. They use fixed PCM
headroom, no automatic loudness boost, and distance gain capped at unity. New notes wait
for the preceding cue to finish; guidance also waits while the app speaks.
Listen for crackle during quick approach/close transitions.
Live listener-position and target-position updates are smoothed, and output-route notifications only restart
audio when the actual output or format changes. Compare stationary test beeps with live
guidance while moving the phone; both should remain clean.

PHASE uses only the direct head-tracked binaural path for all guidance cues.
Both early reflections and late reverb are absent from the pipeline, and the
engine's reverb preset is None. There are no simulated walls, ceilings, floors or
occluders. Check that turning your head gives one clear source direction without
secondary reflected directions or a lingering room tail.
The beep retains its 988 Hz fundamental and short rising pair. Its 60 ms notes have
a faster natural decay, softer upper detail and a brief textured attack for localization.
Listen for a clean, damped onset without a low thud, hiss or clipped ending.
The listener follows local AR translation in every guidance mode,
including the final approach, instead of the backend's stationary probe anchor.
Calibrate with the phone held at chest height and your head facing the same direction.
Walk sideways and towards a stationary target, then turn your head: the source should
stay at the object while its direction and level change. Rotating only the phone must
not move the listener. Source corrections ease into place without restarting playback.
Route waypoints still provide walking instructions when a path is active.

Head position remains an estimate (30 cm behind and 45 cm above the phone in the
calibrated direction); AirPods supply rotation, not absolute head translation. Keep
the phone near that calibrated holding position for the most accurate placement.
Judge placement and realism with AirPods;
build checks and PCM headroom tests cannot establish the perceptual result.

Proximity vibrations begin within 1.5 m during
walking and close guidance. They grow stronger, longer and faster as the phone approaches, reaching
full intensity within 5 cm. Rotate the phone without moving it: pulse strength should
remain unchanged. Recording, Stop, lost tracking and leaving the app must stop vibrations.

Facing the selected target with **your head through AirPods** adds a gentle repeated
vibration at any distance, including beyond 1.5 m. There is no pitch change.
The cue uses left/right heading only: it enters within 8° after a 120 ms dwell and
exits beyond 12° to avoid flicker. Target height and up/down head tilt are ignored.
Test left/right turns and looking up/down, then rotate only the phone: head-facing
feedback follows the AirPods, while close-range feedback still depends only on phone
position. Stronger proximity pulses take precedence near the object without stacking
vibrations. No live head tracking, invalid/stale guidance, Stop, recording or backgrounding
must clear the head-facing cue. Pitch and volume remain consistent.

For the Action button, choose Settings → Action Button → Shortcut → Beacon →
**Talk to Beacon**. iOS activates it with a press-and-hold: the first activation starts
recording and the next sends, with no silence timeout. Test a cold launch and an already
open app. Test activating twice during connection/permission setup: no delayed recording
should start after cancellation. The on-screen control remains hold-to-talk.

## Speaking voice

In Beacon **Settings → Speaking voice**, tap the current voice name, select an
installed voice and tap **Try voice**. The selected voice's quality is shown below
its name; menu entries also include language and quality. Your explicit choice is
remembered and takes precedence over Automatic.
Automatic retains its existing preference for a Siri voice only if iOS exposes one
to the app, then premium/enhanced quality and British English on ties.

Installing a Siri voice does not guarantee it is available to third-party speech
synthesis. Apple's public API does not provide a switch to use the user's Siri voice;
see [Apple's speech synthesis presentation](https://developer.apple.com/videos/play/wwdc2020/10022/).
The implementation uses the supported voice inventory, with no private Siri identifiers.
Download additional voices in iPhone **Settings → Accessibility → Read & Speak →
Voices → English** (called Spoken Content on older iOS versions). Open a voice and
use the cloud icon to download a Premium or Enhanced version when offered. Return
to Beacon to refresh the installed list, select the voice and compare **Try voice**.
Returning to the app refreshes availability without replacing your manual choice.

## Optional Voice Lab check

Scheme **BeaconVoiceLab** installs a separate app and needs no Mac backend or camera.
Set its signing team and unique bundle identifier as well. It retains hands-free recognition for testing and shares the command coordinator,
voice selection and synthesized PHASE beeps with Beacon,
with sample targets instead of live detections.

Start voice mode and say **"find a bottle"**. When offered two matches, say **"left"**
or **"the one on the right"**. Beeps should play from the selected sample position.
Test pause/resume, start over, found it and speech suppression. Voice Lab cannot validate
AR tracking, real object detection, network behavior or world alignment in the full app.

## Validation and feedback

Build both **Beacon** and **BeaconVoiceLab** with Xcode, then run these focused checks
after changes:

- `scripts/test-voice-directions.sh`: directional choices and rejected phrases.
- `scripts/test-voice-session.sh`: speech coordination, button-only capture policy, revised commands and cancellation.
- `scripts/test-voice-lab-directional.sh`: object-selection dialogue.
- `scripts/test-voice-lab-sound.sh`: beep placement, legacy-preference handling and audio lifecycle
  checks using a fake audio output.
- `scripts/test-guidance-audio.sh`: position-only proximity, rotation independence, close-distance
  hysteresis, waveform/mix headroom, bounded distance gain, note overlap prevention and
  two-note separation. An optional directory argument exports WAV previews.

These checks do not exercise a real microphone, speech voice, PHASE playback or ARKit.
Run the physical-device checks above to validate microphone recognition and spatial
playback; a successful build or unit test does not cover those behaviors.

For feedback, include `git rev-parse --short HEAD`, iPhone/iOS version, headphone model,
the command spoken, the displayed **Heard:** text, and expected versus actual behavior.
For audio issues, say whether the app was speaking at the time and whether the beeps
were stationary or playing during live guidance.
