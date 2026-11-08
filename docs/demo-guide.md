# Live room demo

1. Start `scripts/dev.sh` on the Mac and open <http://localhost:5173>.
2. Open Beacon on the iPhone. Both devices must share Wi-Fi; the app should show **Connected**.
3. Keep AirPods connected to the iPhone. Use the phone for commands and audio guidance.
4. Scan a well-lit floor and nearby furniture slowly. The web view builds a grey point cloud,
   with the iPhone marked **YOU**. The header shows **Live** when observations are fresh.
5. Hold **Talk to Beacon**, say **"find the bottle"**, and release. Once selected, it appears in
   red in the web view with its estimated distance. The browser does not select targets.
6. Switch between **3D** and **Overhead**. **Fit room** restores automatic framing after
   manual camera movement. **Locate** centres the selected target.

The web page only displays reconstruction. All microphone, calibration, stop/resume,
object requests and audio controls are in the iPhone app. Locking the phone or leaving
Beacon pauses camera capture; the browser marks the last scan as paused.

See [real-device setup](real-device.md) if the phone does not connect and
[limitations](limitations.md) for what the estimated geometry can and cannot show.
