import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    @AppStorage(Settings.guidanceSoundStyleKey) private var soundStyle = GuidanceSoundStyle.chest.rawValue

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
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trident").font(.title2.weight(.semibold))
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
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(model.recording ? "Release to navigate" : model.transcribing ? "Sending request…" : "Hold to navigate")
                    .font(.title2.weight(.semibold))
                Text(model.recording ? "Listening…" : model.transcribing ? "One moment" : "Say “find the bottle”, then release")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(.systemBackground))
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(Color.primary.opacity(connected ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 22))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in model.startTalking() }
            .onEnded { _ in model.stopTalking() })
        .disabled(!connected || model.transcribing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.recording ? "Release to navigate. Listening" : model.transcribing ? "Sending request" : "Hold to navigate")
        .accessibilityHint("Double tap to start speaking, then double tap again to send. Say the object you want to find, or say resume.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.toggleTalking() }
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
        if model.recording { return "Speak your request, then release the button." }
        if model.transcribing { return "You can tap Stop to cancel." }
        if !connected { return "Connect to the same Wi-Fi and add your Mac’s address in Settings." }
        if model.tracking != "normal" { return "Point the camera at the room and move slowly while tracking settles." }
        if !model.choices.isEmpty { return "More than one match is in view." }
        if guiding { return "Follow the object’s sound. Tap Stop whenever you need to pause." }
        if model.mode == "searching" { return "Slowly scan the room with the camera." }
        if model.stopReason != nil || model.mode == "stopped" { return "Hold the button to say “resume”, or ask for a different object." }
        return "Calibrate, then hold the button and say what you want to find."
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
                Section("Hands-free voice") {
                    VoiceModeControls(voice: voice)
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
