import SwiftUI

struct VoiceModeControls: View {
    @ObservedObject var voice: VoiceSession
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(voice.status, systemImage: voice.isListening ? "mic.fill" : "mic.slash")
                .font(.headline)
                .foregroundStyle(voice.isListening ? .teal : .secondary)
                .accessibilityIdentifier("voice-status")
            if let error = voice.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                Button("Open iPhone Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button(voice.isEnabled ? "Turn voice mode off" : "Start voice mode") {
                if voice.isEnabled { voice.disable() }
                else { Task { await voice.enable() } }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Say Beacon followed by your request while the app is open.")
            HStack {
                Menu {
                    Button {
                        chooseVoice(nil)
                    } label: {
                        if voice.speaker.selectedVoiceIdentifier == nil {
                            Label("Automatic", systemImage: "checkmark")
                        } else { Text("Automatic") }
                    }
                    ForEach(voice.speaker.availableVoices) { option in
                        Button {
                            chooseVoice(option.id)
                        } label: {
                            if voice.speaker.selectedVoiceIdentifier == option.id {
                                Label(option.label, systemImage: "checkmark")
                            } else { Text(option.label) }
                        }
                    }
                } label: {
                    Label(voice.speaker.currentVoiceLabel, systemImage: "waveform")
                }
                .accessibilityLabel("Speaking voice, \(voice.speaker.currentVoiceLabel)")
                .accessibilityIdentifier("speaking-voice")
                Spacer()
                Button("Try voice") {
                    voice.hush()
                    voice.speaker.previewVoice()
                }
                .accessibilityIdentifier("preview-voice")
            }
            .font(.callout)
            if voice.speaker.selectedVoiceIdentifier == nil {
                Text(voice.speaker.automaticVoiceExplanation)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !voice.transcript.isEmpty {
                Text("Heard: \(voice.transcript)").font(.callout)
                    .accessibilityIdentifier("voice-transcript")
            }
            if !voice.lastResponse.isEmpty {
                Text(voice.lastResponse).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice-response")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refreshVoices)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshVoices() }
        }
    }

    private func chooseVoice(_ identifier: String?) {
        voice.objectWillChange.send()
        voice.hush()
        voice.speaker.selectVoice(identifier: identifier)
        voice.speaker.previewVoice()
    }

    private func refreshVoices() {
        voice.objectWillChange.send()
        voice.speaker.refreshVoices()
    }
}
