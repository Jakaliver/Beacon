import AVFoundation

final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private var current = ""

    /// Speaks `text` now, interrupting older speech. A repeat of the phrase in progress is ignored.
    func say(_ text: String) {
        if synthesizer.isSpeaking {
            if text == current { return }
            synthesizer.stopSpeaking(at: .immediate)
        }
        current = text
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func hush() { synthesizer.stopSpeaking(at: .immediate) }
}

final class PushToTalk {
    private var recorder: AVAudioRecorder?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("ptt.wav")

    func start() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        self.recorder = recorder
        return recorder.record(forDuration: 6)
    }

    func stop() -> Data? {
        guard let recorder else { return nil }
        recorder.stop()
        self.recorder = nil
        return try? Data(contentsOf: url)
    }

    static func transcribe(_ wav: Data, host: String) async throws -> String {
        guard let url = URL(string: "http://\(host):8787/api/transcribe") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: wav)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
    }
}
