import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    @AppStorage(Settings.guidanceSoundStyleKey) private var soundStyle = GuidanceSoundStyle.beeps.rawValue

    private var connected: Bool { model.controlUp && model.sensorUp }
    private var guiding: Bool { ["walking", "probe", "hotcold"].contains(model.mode) && model.stopReason == nil }
    private var canStop: Bool {
        model.recording || model.transcribing || (model.stopReason == nil && ["searching", "choosing", "walking", "probe", "hotcold"].contains(model.mode))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Spacer(minLength: 48)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(statusTitle)
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(statusDetail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    if !model.choices.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(model.choices) { choice in
                                Button { model.choose(choice) } label: {
                                    HStack {
                                        Text(choice.description).multilineTextAlignment(.leading)
                                        Spacer(minLength: 12)
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Selects this object for guidance.")
                            }
                        }
                        .padding(.top, 24)
                    }
                    Spacer(minLength: 40)
                    VStack(spacing: 12) {
                        Button { model.calibrate() } label: {
                            Label("Calibrate", systemImage: "scope")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.16), lineWidth: 1))
                        .disabled(model.recording || model.transcribing)
                        .accessibilityHint("Face ahead with the phone pointing forwards, then activate to align the audio.")
                        navigateButton
                        Button("Stop", role: .destructive) { model.stop() }
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .opacity(canStop ? 1 : 0)
                            .disabled(!canStop)
                            .accessibilityHidden(!canStop)
                            .accessibilityHint("Stops recording, cancels a pending request and silences guidance immediately.")
                    }
                }
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showSettings, onDismiss: model.applySettings) { SettingsView(voice: model.voice) }
        .onChange(of: soundStyle) { _, _ in model.refreshGuidanceSound() }
        .onChange(of: model.recording) { _, recording in
            if recording { showSettings = false }
        }
        .onDisappear { model.cancelTalking() }
    }

    private var header: some View {
        HStack(alignment: .center) {
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
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.recording || model.transcribing)
            .accessibilityLabel("Settings")
        }
    }

    private var navigateButton: some View {
        VStack(spacing: 16) {
            Image(systemName: model.recording ? "waveform" : model.transcribing ? "ellipsis" : "mic.fill")
                .font(.system(size: 28, weight: .medium))
            VStack(spacing: 6) {
                Text(model.recording ? "Listening…" : model.transcribing ? "Sending request…" : "Talk to Beacon")
                    .font(.title2.weight(.semibold))
                Text(model.recording ? (model.recordingFromActionButton ? "Press Action button again to send" : "Release to send") : model.transcribing ? "One moment" : "Hold to speak · release to send")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(.systemBackground))
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(Color.primary.opacity(connected ? (model.recording ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityHidden(true)
        .overlay {
            HoldToTalkControl(
                enabled: connected && !model.transcribing,
                label: model.recording ? (model.recordingFromActionButton ? "Listening. Press Action button again to send" : "Listening. Release to send") : model.transcribing ? "Sending request" : "Talk to Beacon",
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
        if model.recording {
            return model.recordingFromActionButton ? "Speak, then press the Action button again to send your request." : "Keep holding while you speak. Release to send your request."
        }
        if model.transcribing { return "You can tap Stop to cancel." }
        if !connected { return "Connect to the same Wi-Fi and add your Mac’s address in Settings." }
        if model.tracking != "normal" { return "Point the camera at the room and move slowly while tracking settles." }
        if !model.choices.isEmpty { return "More than one match is in view." }
        if guiding { return "Follow the sound. Vibrations get stronger as your phone gets closer." }
        if model.mode == "searching" { return "Slowly scan the room with the camera." }
        if model.stopReason != nil || model.mode == "stopped" { return "Hold below and say “resume”, or ask for a different object." }
        return "Calibrate, then hold below and say what you want to find."
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

private struct SettingsView: View {
    @ObservedObject var voice: VoiceSession
    @AppStorage(Settings.hostKey) private var host = Settings.defaultHost
    @AppStorage(Settings.frameRateKey) private var frameRate = Settings.defaultFrameRate
    @AppStorage(Settings.reverseHeadTurnKey) private var reverseHeadTurn = false
    @AppStorage(Settings.reverseHeadTiltKey) private var reverseHeadTilt = false
    @AppStorage(Settings.soundHeightKey) private var soundHeight = 0.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Speaking voice") {
                    VoiceModeControls(voice: voice, showsListeningControls: false)
                }
                GuidanceSoundSettings()
                Section("Connection") {
                    TextField("Mac host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    DisclosureGroup("Advanced") {
                        Stepper("Frame rate: \(Int(frameRate)) per second", value: $frameRate, in: 2...30)
                        Toggle("Reverse head turn", isOn: $reverseHeadTurn)
                            .accessibilityHint("Turn on if sounds move the wrong way when you turn your head")
                        Toggle("Reverse head tilt", isOn: $reverseHeadTilt)
                            .accessibilityHint("Turn on if sounds move the wrong way when you look up or down")
                        VStack(alignment: .leading) {
                            Text("Sound height: \(soundHeight > 0 ? "+" : "")\(Int((soundHeight * 100).rounded())) cm")
                            Slider(value: $soundHeight, in: -0.6...0.6, step: 0.05)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Moves guidance sounds up or down to match the objects")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
