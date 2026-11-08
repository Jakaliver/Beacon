import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    private var connected: Bool { model.controlUp && model.sensorUp }
    private var guiding: Bool { ["walking", "probe", "hotcold"].contains(model.mode) && model.stopReason == nil }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Spacer(minLength: 24)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(statusTitle)
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(statusDetail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.pathfindingStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 16)
                    talkButton
                        .layoutPriority(1)
                }
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(.systemBackground))
        .onDisappear { model.cancelTalking() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Beacon").font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Circle().fill(connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                Text(connected ? "Connected" : "Not connected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connected ? "Mac connected" : "Mac not connected")
        }
    }

    private var talkButton: some View {
        VStack(spacing: 16) {
            Image(systemName: model.recording ? "waveform" : model.transcribing ? "ellipsis" : "mic.fill")
                .font(.system(size: 28, weight: .medium))
            VStack(spacing: 6) {
                Text(model.recording ? "Listening…" : model.transcribing ? "Sending request…" : "Talk to Beacon")
                    .font(.title2.weight(.semibold))
                Text(model.recording ? "Release to send" : model.transcribing ? "Hold to replace request" : "Hold to speak · release to send")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(.systemBackground))
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(Color.primary.opacity(connected ? (model.recording ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityHidden(true)
        .overlay {
            HoldToTalkControl(
                enabled: connected,
                label: model.recording ? "Listening. Release to send" : model.transcribing ? "Sending request. Hold to replace" : "Talk to Beacon",
                onPress: model.beginTalking,
                onRelease: model.endTalking,
                onCancel: model.cancelTalking
            )
        }
    }

    private var statusTitle: String {
        if model.recording { return "What are you looking for?" }
        if model.transcribing { return "Processing your request" }
        if !connected { return "Connect to your Mac" }
        if model.tracking != "normal" { return "Hold the phone steady" }
        if !model.choices.isEmpty { return "Choose your object" }
        if guiding { return "Follow the sound" }
        if model.mode == "searching" { return "Looking for your object" }
        if model.stopReason != nil || model.mode == "stopped" { return "Paused" }
        return "Ready"
    }

    private var statusDetail: String {
        if model.recording { return "Keep holding while you speak. Release to send your request." }
        if model.transcribing { return "Hold again to replace this request." }
        if !connected { return "Use the same Wi-Fi as your Mac. Set its address in the iPhone Settings app under Apps → Beacon." }
        if model.tracking != "normal" { return "Point the camera at the room and move slowly while tracking settles." }
        if !model.choices.isEmpty {
            let options = model.choices.map(\.description).joined(separator: "\n")
            return options + "\nHold below and say which object you want."
        }
        if guiding { return "Follow the guidance sounds. Hold below and say “stop” to pause." }
        if model.mode == "searching" { return "Slowly scan the room with the camera. Hold below and say “stop” to pause." }
        if model.stopReason != nil || model.mode == "stopped" { return "Hold below and say “resume”, or ask for a different object." }
        return "Hold below and say “calibrate”, then ask for the object you want to find."
    }
}

/// UIKit supplies distinct release and cancellation events, including when a scroll
/// or system gesture takes over. A cancelled hold must never send a partial request.
private struct HoldToTalkControl: UIViewRepresentable {
    let enabled: Bool
    let label: String
    let onPress: () -> Void
    let onRelease: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> Control { Control() }

    func updateUIView(_ control: Control, context: Context) {
        control.onPress = onPress
        control.onRelease = onRelease
        control.onCancel = onCancel
        if !enabled { control.cancelTracking(with: nil) }
        control.isEnabled = enabled
        control.isAccessibilityElement = true
        control.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        control.accessibilityLabel = label
        control.accessibilityHint = "Double-tap and hold to speak, then lift your finger to send."
    }

    static func dismantleUIView(_ control: Control, coordinator: ()) {
        control.cancelTracking(with: nil)
    }

    final class Control: UIControl {
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        var onCancel: (() -> Void)?
        private var holding = false

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard isEnabled, !holding else { return false }
            holding = true
            onPress?()
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { true }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard holding else { return }
            holding = false
            onRelease?()
        }

        override func cancelTracking(with event: UIEvent?) {
            super.cancelTracking(with: event)
            guard holding else { return }
            holding = false
            onCancel?()
        }

        override func accessibilityActivate() -> Bool {
            UIAccessibility.post(notification: .announcement, argument: accessibilityHint)
            return true
        }
    }
}
