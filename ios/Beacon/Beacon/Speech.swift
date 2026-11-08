import AVFoundation

/// Selection policy uses metadata from the public installed-voice inventory only. Siri names
/// and identifiers are evidence when present, never identifiers to invent or probe privately.
private struct SpeechVoiceMetadata {
    let identifier: String
    let name: String
    let language: String
    let quality: Int

    var identifiesSiri: Bool {
        [identifier, name].contains { value in
            value.lowercased().split(whereSeparator: { !$0.isLetter }).contains("siri")
        }
    }

    static func precedes(_ left: Self, _ right: Self) -> Bool {
        if left.identifiesSiri != right.identifiesSiri { return left.identifiesSiri }
        if left.quality != right.quality { return left.quality > right.quality }
        let leftBritish = left.language.lowercased().replacingOccurrences(of: "_", with: "-") == "en-gb"
        let rightBritish = right.language.lowercased().replacingOccurrences(of: "_", with: "-") == "en-gb"
        if leftBritish != rightBritish { return leftBritish }
        let nameOrder = left.name.localizedStandardCompare(right.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return left.identifier < right.identifier
    }
}

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    struct VoiceChoice: Identifiable, Equatable {
        let id: String
        let name: String
        let language: String
        let qualityLabel: String

        var label: String {
            let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
            return "\(name) · \(languageName) · \(qualityLabel)"
        }
    }

    private static let voicePreferenceKey = "speechVoiceIdentifier"
    private static let naturalSpeechRate: Float = 0.48
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceDiagnostics = ProcessInfo.processInfo.arguments.contains("--voice-diagnostics")
    private var installedVoices: [AVSpeechSynthesisVoice] = []
    private var current: AVSpeechUtterance?
    private var interrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private(set) var currentText: String?
    var onSpeakingChanged: ((Bool) -> Void)?
    var onFinished: (() -> Void)?

    var availableVoices: [VoiceChoice] {
        installedVoices.map {
            VoiceChoice(id: $0.identifier, name: $0.name, language: $0.language,
                        qualityLabel: Self.qualityLabel($0.quality))
        }
    }

    /// Nil means Automatic. A removed explicit choice falls back to the automatic policy.
    var selectedVoiceIdentifier: String? {
        guard let identifier = UserDefaults.standard.string(forKey: Self.voicePreferenceKey),
              installedVoices.contains(where: { $0.identifier == identifier }) else { return nil }
        return identifier
    }

    var currentVoiceLabel: String { resolvedVoice?.name ?? "No English voice installed" }

    var siriVoiceAvailable: Bool {
        installedVoices.contains { Self.metadata(for: $0).identifiesSiri }
    }

    var automaticVoiceExplanation: String {
        guard let voice = installedVoices.first else {
            return "No English voice is available to Beacon on this iPhone."
        }
        if Self.metadata(for: voice).identifiesSiri {
            return "Automatic uses \(voice.name), a Siri voice available to Beacon."
        }
        return "Siri’s voice isn’t available to Beacon on this iPhone. Automatic uses \(voice.name), the best installed English voice available to the app."
    }

    private var resolvedVoice: AVSpeechSynthesisVoice? {
        if let identifier = selectedVoiceIdentifier {
            return installedVoices.first(where: { $0.identifier == identifier })
        }
        return installedVoices.first
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        refreshVoices()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.interrupted = type == .began
                if self.interrupted { self.hush() }
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    /// Enumerates installed voices only. Looking up an unavailable identifier returns nil;
    /// this never requests downloads or Personal Voice permission.
    func refreshVoices() {
        var seen = Set<String>()
        installedVoices = AVSpeechSynthesisVoice.speechVoices().compactMap { candidate in
            guard Self.isSuitable(candidate), seen.insert(candidate.identifier).inserted,
                  let installed = AVSpeechSynthesisVoice(identifier: candidate.identifier),
                  Self.isSuitable(installed) else { return nil }
            return installed
        }.sorted { left, right in
            SpeechVoiceMetadata.precedes(Self.metadata(for: left), Self.metadata(for: right))
        }
        if voiceDiagnostics {
            for voice in installedVoices {
                print("[BeaconVoice] available id=\(voice.identifier) name=\(voice.name) quality=\(Self.qualityLabel(voice.quality))")
            }
            logSelectedVoice()
        }
    }

    func selectVoice(identifier: String?) {
        if let identifier {
            guard installedVoices.contains(where: { $0.identifier == identifier }) else { return }
            UserDefaults.standard.set(identifier, forKey: Self.voicePreferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.voicePreferenceKey)
        }
        logSelectedVoice()
    }

    func previewVoice() {
        hush()
        say("What are you looking for?")
    }

    private static func isSuitable(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let language = voice.language.lowercased().replacingOccurrences(of: "_", with: "-")
        // Provider extensions can implement their own network behaviour. Use Apple's installed
        // voices so choosing a more natural voice keeps this speech path entirely on the device.
        return (language == "en" || language.hasPrefix("en-"))
            && voice.identifier.hasPrefix("com.apple.")
            && !voice.voiceTraits.contains(.isNoveltyVoice)
            && !voice.voiceTraits.contains(.isPersonalVoice)
    }

    private static func metadata(for voice: AVSpeechSynthesisVoice) -> SpeechVoiceMetadata {
        SpeechVoiceMetadata(identifier: voice.identifier, name: voice.name,
                            language: voice.language, quality: voice.quality.rawValue)
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Standard"
        @unknown default: return "System"
        }
    }

    private func logSelectedVoice() {
        guard voiceDiagnostics else { return }
        if let voice = resolvedVoice {
            print("[BeaconVoice] selected id=\(voice.identifier) name=\(voice.name) quality=\(Self.qualityLabel(voice.quality))")
        } else {
            print("[BeaconVoice] selected id=none name=none quality=none")
        }
        print("[BeaconVoice] siriAvailable=\(siriVoiceAvailable)")
        fflush(stdout)
    }

    /// Speaks `text` now, interrupting older speech. A repeat of the phrase in progress is ignored.
    func say(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop responses during a call/Siri interruption instead of letting the synthesizer
        // hold them and speak stale guidance when the interruption ends.
        guard !interrupted, !text.isEmpty, current == nil || text != currentText else { return }
        if installedVoices.isEmpty { refreshVoices() }
        guard let voice = resolvedVoice else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.naturalSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = false
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        // Set the replacement first: a late cancellation of the old utterance cannot clear it.
        current = utterance
        currentText = text
        synthesizer.stopSpeaking(at: .immediate)
        onSpeakingChanged?(true)
        // The observer may itself hush or replace speech.
        guard current === utterance else { return }
        synthesizer.speak(utterance)
    }

    func hush() {
        let wasSpeaking = current != nil
        current = nil
        currentText = nil
        synthesizer.stopSpeaking(at: .immediate)
        if wasSpeaking { onSpeakingChanged?(false) }
    }

    private func completed(_ utterance: AVSpeechUtterance, naturally: Bool) {
        guard current === utterance else { return }
        current = nil
        currentText = nil
        onSpeakingChanged?(false)
        // The observer may have started replacement speech; do not reset its recognition state.
        if naturally, current == nil { onFinished?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.completed(utterance, naturally: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.completed(utterance, naturally: false) }
    }
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
        return recorder.record()
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
