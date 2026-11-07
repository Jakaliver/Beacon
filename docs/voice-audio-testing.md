# Voice and spatial audio testing

Hands-free voice and spatial chest audio are integrated into **Beacon** on `main`.
The main screen has **Calibrate** and **Talk to Beacon**. Tap once, speak and pause to
send, or say **"Beacon"** followed by your command. Hands-free listening starts when
the app opens and can be disabled in Settings. It does not listen in the background.
Use a physical iPhone for microphone, spatial audio and AR tracking checks.

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

1. Open Beacon, allow Microphone and Speech Recognition access, and wait for listening.
   If previously disabled, enable Hands-free voice in Settings. Say **"Beacon, calibrate"** with the phone
   held ahead. With compatible AirPods, face the same direction as the phone.
2. Say **"Beacon, loot mode on"**, then **"Beacon, find the bottle"**. Check the **Heard:**
   text in Settings and that the Mac starts a search.
   Close Settings to return to the main controls; hands-free listening continues.
   Once a valid target is acquired, a single continuous chest sound should come from
   its position. There should be no repeating guidance beeps in Chest mode. Searching
   without a valid target should not start the chest loop.
3. Turn your head and move the phone slowly while keeping tracking normal. The sound
   should remain aligned with the target. Listen for at least **45 seconds** to cross
   two loop boundaries; report audible gaps, clicks, doubled sounds or drifting position.
4. While it is playing, say **"Beacon, status"** or **"Beacon, help"**. The chest should become quieter
   while the reply speaks, then return to its previous level. Try another command before
   a reply ends: old replies must not accumulate and play back later. If a command is
   masked by speech, also try **"Beacon, pause"** and record the difference.
5. Open Settings → **Object sound**. Switch **Chest → Beeps → Chest** while guiding.
   Each switch should take effect immediately, with only one style playing. Dismissing
   Settings without changing Mac host should preserve the connection and target.
   Relaunch and confirm the selected sound style is remembered.
   Also say **"Beacon, loot mode off"** to switch to Beeps, then **"Beacon, loot mode on"**
   to select the chest. **"Beacon, turn on/off loot mode"** and **"Beacon, enable/disable
   loot mode"** also work. Confirm the Settings selection follows the command, the same
   object stays selected, and no old sound continues after switching. Try this while
   paused and before finding an object: only the preference should change, without
   starting or resuming guidance. Tap **Talk to Beacon** or use the Action button to
   submit the same commands without the wake word. Loot mode off restores normal guidance,
   including the torch tone within reach in probe mode.
6. Say **"Beacon, pause"**, then **"Beacon, resume"**. Audio should stop promptly and resume only when
   connection and tracking are ready. Repeat using **Stop**, then tap **Talk to Beacon**, say **"Beacon, resume"** and pause. A partially heard command must not restart guidance after Stop.
7. Say **"Beacon, start over"**. The target and old guidance should clear and tracking should
   reset. Say **"Beacon, resume"**: it should ask for a new search, without restoring the old
   sound. Start another find, then say **"Beacon, found it"**; this ends the search without
   resetting tracking. Old queued replies and target sounds must stay cleared.
8. During guidance, leave or lock the app, disconnect the backend, lose tracking, or
   disconnect headphones. Check each separately. Guidance should stop and the app
   should report the reason where applicable. Restore the condition and explicitly
   resume. Confirm there is no leftover chest loop or delayed command after stopping.
9. Check **"Beacon, repeat"**, **"Beacon, inspect"**, **"Beacon, help"**, and **"Beacon, turn off voice mode"**.
   The **Talk to Beacon** button should still work with voice mode off or on. Disabling voice mode
   stops listening; use **"Beacon, pause"** or **Stop** to stop object guidance.

The current backend automatically selects targets; it does not currently emit a
multiple-object choice prompt. The phone supports **"Beacon, left"**, **"Beacon, right"**, and
**"Beacon, the one on the left/right"** if choices are provided. Exercise that dialogue in
Voice Lab below; voice mode does not add backend object disambiguation.

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
Set its signing team and unique bundle identifier as well. It uses the same speech
recognizer, command coordinator, voice selection and PHASE chest playback as Beacon,
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
- `scripts/test-voice-session.sh`: speech coordination, wake words, revised commands and cancellation.
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
