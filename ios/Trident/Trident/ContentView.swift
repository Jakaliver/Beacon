import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var typed = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    status
                    BigButton(title: "Calibrate", hint: "Face ahead and hold the phone in front of you, then double tap.",
                              color: .indigo) { model.calibrate() }
                    findButton
                    HStack(spacing: 14) {
                        BigButton(title: "Repeat", hint: "Repeats the last instruction.", color: .teal) {
                            model.command("repeat", confirmation: "Repeat")
                        }
                        BigButton(title: "Inspect", hint: "Describes what the camera sees.", color: .teal) {
                            model.command("inspect", confirmation: "Inspecting")
                        }
                    }
                    BigButton(title: "Test 3D sound", hint: "Plays a beep that travels ahead, right, behind and left of you.",
                              color: .purple, height: 64) { model.testSound() }
                    BigButton(title: "Stop", hint: "Silences all guidance immediately.", color: .red, height: 160) {
                        model.stop()
                    }
                    BigButton(title: "Resume", hint: "Restarts guidance when the connection and tracking are ready.",
                              color: .green) { model.resume() }
                    ForEach(model.choices) { choice in
                        BigButton(title: "\(choice.index). \(choice.description)", hint: "Selects this object.",
                                  color: .orange, height: 64) { model.choose(choice) }
                    }
                    HStack {
                        TextField("Type a command", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .onSubmit(sendTyped)
                        Button("Send", action: sendTyped)
                            .accessibilityHint("Sends the typed command to the Mac.")
                    }
                }
                .padding()
            }
            .navigationTitle("Trident")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showSettings, onDismiss: model.applySettings) { SettingsView() }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.controlUp && model.sensorUp ? "Mac connected" : "Mac not connected",
                  systemImage: model.controlUp && model.sensorUp ? "wifi" : "wifi.slash")
            Text("Tracking: \(model.tracking)")
            Text(model.stopReason.map { "Stopped: \($0)" } ?? "Mode: \(model.mode)")
                .foregroundStyle(model.stopReason == nil ? Color.primary : Color.red)
        }
        .font(.title3.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.statusSummary)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var findButton: some View {
        Text(model.recording ? "Listening… release to send" : "Hold to find object")
            .font(.title2.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(model.recording ? Color.orange : Color.blue, in: RoundedRectangle(cornerRadius: 18))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.startTalking() }
                .onEnded { _ in model.stopTalking() })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.recording ? "Listening. Find object" : "Find object")
            .accessibilityHint("Double tap to start speaking, and double tap again to send. You can also hold.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggleTalking() }
    }

    private func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.command(text, confirmation: "Sent")
        typed = ""
    }
}

private struct BigButton: View {
    let title: String
    let hint: String
    let color: Color
    var height: CGFloat = 90
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .accessibilityHint(hint)
    }
}

private struct SettingsView: View {
    @AppStorage(Settings.hostKey) private var host = Settings.defaultHost
    @AppStorage(Settings.frameRateKey) private var frameRate = Settings.defaultFrameRate
    @AppStorage(Settings.reverseHeadTurnKey) private var reverseHeadTurn = false
    @AppStorage(Settings.reverseHeadTiltKey) private var reverseHeadTilt = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Mac host", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Stepper("Frame rate: \(Int(frameRate)) per second", value: $frameRate, in: 2...15)
                Toggle("Reverse head turn", isOn: $reverseHeadTurn)
                    .accessibilityHint("Turn on if sounds move the wrong way when you turn your head")
                Toggle("Reverse head tilt", isOn: $reverseHeadTilt)
                    .accessibilityHint("Turn on if sounds move the wrong way when you look up or down")
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
