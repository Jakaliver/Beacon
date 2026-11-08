import SwiftUI

struct VoiceLabView: View {
    @ObservedObject var model: VoiceLabModel
    @State private var command = ""
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("A sample scene for testing voice controls. No camera or Mac connection.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.state.rawValue).font(.largeTitle.bold())
                            .accessibilityIdentifier("lab-state")
                        Text(model.summary).font(.title3)
                        Label(model.calibrated ? "Sample heading calibrated" : "Sample heading not calibrated",
                              systemImage: model.calibrated ? "checkmark.circle" : "location.north")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                    VoiceModeControls(voice: model.voice)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Try saying").font(.headline)
                        Text("“Find a bottle” · “Calibrate”\n“Pause” · “Resume” · “Start over”\n“The one on the left” · “Found it” · “Help”")
                            .font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Pause") { model.voice.submit("pause") }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        Button("Start over") { model.voice.submit("start over") }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Type a test command").font(.headline)
                        HStack {
                            TextField("For example, find a bottle", text: $command)
                                .textFieldStyle(.roundedBorder)
                                .focused($commandFocused)
                                .submitLabel(.send)
                                .accessibilityIdentifier("test-command")
                                .onSubmit(send)
                            Button("Send", action: send)
                                .accessibilityIdentifier("send-command")
                        }
                        Text("Uses the same command flow as the microphone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Beacon Voice Lab")
        }
    }

    private func send() {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.voice.submit(command)
        command = ""
        commandFocused = false
    }
}
