import AVFoundation
import Combine
import Speech
import UIKit

/// The tap lives for the whole listening session; swapping a request does not restart audio.
/// Audio buffers are delivered by AVAudioEngine off the main actor.
private final class VoiceAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replace(with request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}

/// Continuous, strictly on-device dictation. Commands and output-echo filtering belong to the caller.
@MainActor
final class VoiceListener: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var status = "Voice off"
    @Published private(set) var errorMessage: String?
    @Published private(set) var echoCancellationActive = false
    var onTranscript: ((String, Bool) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let allowsVoiceChat: Bool
    private let sink = VoiceAudioSink()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var renewal: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var wantsListening = false
    private var suspended = false
    private var interrupted = false
    private var backgrounded = false
    private var starting = false
    private var lastTranscript = ""
    private var consecutiveFailures = 0
    private var utteranceStartedAt = Date.distantPast
    private var routeSignature = ""
    private var changedSessionMode = false

    init(locale: Locale = Locale(identifier: "en-GB"), allowsVoiceChat: Bool = false) {
        self.allowsVoiceChat = allowsVoiceChat
        recognizer = SFSpeechRecognizer(locale: locale)
        super.init()
        recognizer?.delegate = self
        observeLifecycle()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        renewal?.cancel()
        recovery?.cancel()
        sink.replace(with: nil)
        engine?.stop()
        recognitionTask?.cancel()
    }

    func start() async {
        wantsListening = true
        suspended = false
        consecutiveFailures = 0
        await activate()
    }

    func stop() {
        wantsListening = false
        suspended = false
        stopCapture()
        errorMessage = nil
        status = "Voice off"
    }

    /// Temporarily releases the microphone (for example, for manual push-to-talk).
    func suspend() {
        suspended = true
        stopCapture()
        status = "Voice paused"
    }

    func resume() async {
        suspended = false
        await activate()
    }

    /// Discard a consumed command and any late callbacks while retaining the audio engine/tap.
    func resetUtterance() {
        guard isListening, shouldRun else { return }
        beginUtterance()
    }

    private var shouldRun: Bool {
        wantsListening && !suspended && !interrupted && !backgrounded
    }

    private func activate() async {
        guard shouldRun, !isListening, !starting else { return }
        starting = true
        generation += 1
        let token = generation
        errorMessage = nil
        status = "Checking voice permissions"

        let speechPermission = await Self.speechPermission()
        guard token == generation, shouldRun else { return }
        guard speechPermission == .authorized else {
            fail("Allow Speech Recognition for Trident in Settings to use local voice commands.")
            return
        }
        let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        guard token == generation, shouldRun else { return }
        guard microphoneAllowed else {
            fail("Allow Microphone access for Trident in Settings to use voice commands.")
            return
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            fail("On-device speech recognition is unavailable for this language on this iPhone. Voice stays offline; no audio was sent to a server.")
            return
        }
        guard recognizer.isAvailable else {
            fail("On-device speech recognition is temporarily unavailable. Try enabling voice again.")
            return
        }

        do {
            try startCapture()
            starting = false
            isListening = true
            status = "Listening on device"
            beginUtterance()
        } catch {
            fail("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let existing = SFSpeechRecognizer.authorizationStatus()
        guard existing == .notDetermined else { return existing }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func startCapture() throws {
        let session = AVAudioSession.sharedInstance()
        // Share the application's session with PHASE and speech output. Never switch it to
        // measurement/record-only or deactivate it when listening stops.
        if session.category != .playAndRecord || session.mode != .default {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        }
        // Supported recent iPhones can cancel speaker echo without changing PHASE's .default mode.
        // This preference is optional; older hardware keeps the same unprocessed capture path.
        if !allowsVoiceChat, #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
            try? session.setPrefersEchoCancelledInput(true)
        }
        try session.setActive(true)
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
           session.preferredInput?.uid != mic.uid {
            // This is a preference, not a requirement. A route that rejects the override can
            // still have a usable microphone, whose format is checked when capture starts.
            try? session.setPreferredInput(mic)
        }

        // Voice-processing IO changes the session to voiceChat. Only the isolated Voice Lab
        // opts into that tradeoff; the main app keeps PHASE's default-mode output untouched.
        let speakerRoute = session.currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
        if allowsVoiceChat && speakerRoute {
            do {
                try session.setMode(.voiceChat)
                changedSessionMode = true
                engine = try makeEngine(voiceProcessing: true)
            }
            catch {
                // Some hardware routes reject voice processing. Fall back without blocking voice.
                try session.setMode(.default)
                changedSessionMode = false
                engine = try makeEngine(voiceProcessing: false)
            }
        } else {
            engine = try makeEngine(voiceProcessing: false)
        }
        echoCancellationActive = engine?.inputNode.isVoiceProcessingEnabled == true
        if #available(iOS 18.2, *), session.isEchoCancelledInputEnabled {
            echoCancellationActive = true
        }
        routeSignature = currentRouteSignature()
    }

    private func makeEngine(voiceProcessing: Bool) throws -> AVAudioEngine {
        let candidate = AVAudioEngine()
        let input = candidate.inputNode
        var tapInstalled = false
        do {
            if voiceProcessing {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceError.noInput
            }
            let sink = sink
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                sink.append(buffer)
            }
            tapInstalled = true
            candidate.prepare()
            try candidate.start()
            guard allowsVoiceChat || AVAudioSession.sharedInstance().mode == .default else {
                throw VoiceError.incompatibleProcessing
            }
            return candidate
        } catch {
            candidate.stop()
            if tapInstalled { input.removeTap(onBus: 0) }
            if input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(false) }
            throw error
        }
    }

    private func beginUtterance() {
        guard shouldRun, isListening, let recognizer else { return }
        // Recheck before every finite task, including after an audio/service reset. The local
        // requirement must never rely on an availability check from an earlier task.
        guard recognizer.supportsOnDeviceRecognition else {
            fail("On-device speech recognition is unavailable. Voice stays offline; no audio was sent to a server.")
            return
        }
        guard recognizer.isAvailable else {
            fail("On-device speech recognition is temporarily unavailable.")
            return
        }
        cancelUtterance()
        let token = generation
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = true
        next.taskHint = .dictation
        request = next
        lastTranscript = ""
        utteranceStartedAt = Date()
        sink.replace(with: next)
        recognitionTask = recognizer.recognitionTask(with: next) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.receive(result, error: error, generation: token)
            }
        }
        // Speech tasks are finite. Renew before the usual task limit without cycling the mic.
        renewal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.generation == token, self.shouldRun else { return }
            self.beginUtterance()
        }
    }

    private func receive(_ result: SFSpeechRecognitionResult?, error: Error?, generation token: Int) {
        guard token == generation, shouldRun, isListening else { return }
        if let result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != lastTranscript || result.isFinal {
                lastTranscript = text
                consecutiveFailures = 0
                errorMessage = nil
                onTranscript?(text, result.isFinal)
                // The consumer may have reset the utterance or stopped voice in its callback.
                guard token == generation, shouldRun, isListening else { return }
            }
            if result.isFinal {
                rotateAfter(delay: 0.15)
                return
            }
        }
        if let error {
            // Long quiet tasks regularly end without a transcription. Rapid repeated errors
            // indicate an unavailable local recognizer, rather than something to spin on forever.
            let quickFailure = lastTranscript.isEmpty && Date().timeIntervalSince(utteranceStartedAt) < 3
            consecutiveFailures = quickFailure ? consecutiveFailures + 1 : 0
            if consecutiveFailures >= 3 {
                fail("Local speech recognition could not continue: \(error.localizedDescription)")
            } else {
                rotateAfter(delay: quickFailure ? 1 : 0.2)
            }
        }
    }

    private func rotateAfter(delay: Double) {
        cancelUtterance()
        let token = generation
        renewal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == token, self.shouldRun else { return }
            self.beginUtterance()
        }
    }

    private func cancelUtterance() {
        generation += 1
        renewal?.cancel()
        renewal = nil
        sink.replace(with: nil)
        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func stopCapture() {
        starting = false
        isListening = false
        recovery?.cancel()
        recovery = nil
        cancelUtterance()
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        echoCancellationActive = false
        if changedSessionMode {
            try? AVAudioSession.sharedInstance().setMode(.default)
            changedSessionMode = false
        }
    }

    private func fail(_ message: String) {
        stopCapture()
        errorMessage = message
        status = "Voice unavailable"
    }

    private func recoverCapture() {
        guard shouldRun, !starting else { return }
        stopCapture()
        status = "Reconnecting microphone"
        let token = generation
        recovery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.generation == token, self.shouldRun else { return }
            await self.activate()
        }
    }

    private func currentRouteSignature() -> String {
        let session = AVAudioSession.sharedInstance()
        return (session.currentRoute.inputs + session.currentRoute.outputs).map(\.uid).joined(separator: "|")
            + "|\(session.sampleRate)"
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, action: @escaping @MainActor (VoiceListener, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { if let self { action(self, note) } }
            })
        }
        observe(AVAudioSession.routeChangeNotification) { listener, _ in
            guard listener.isListening, listener.currentRouteSignature() != listener.routeSignature else { return }
            listener.recoverCapture()
        }
        observe(.AVAudioEngineConfigurationChange) { listener, note in
            guard let changed = note.object as? AVAudioEngine, changed === listener.engine,
                  listener.isListening, !changed.isRunning else { return }
            listener.recoverCapture()
        }
        observe(AVAudioSession.interruptionNotification) { listener, note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            listener.interrupted = type == .began
            if type == .began {
                listener.stopCapture()
                if listener.wantsListening { listener.status = "Voice interrupted" }
            } else if listener.shouldRun {
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    listener.recoverCapture()
                } else {
                    listener.suspended = true
                    listener.status = "Voice paused after interruption"
                }
            }
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { listener, _ in
            listener.recoverCapture()
        }
        observe(UIApplication.didEnterBackgroundNotification) { listener, _ in
            listener.backgrounded = true
            listener.stopCapture()
            if listener.wantsListening { listener.status = "Voice paused in background" }
        }
        observe(UIApplication.didBecomeActiveNotification) { listener, _ in
            listener.backgrounded = false
            if listener.shouldRun { listener.recoverCapture() }
        }
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.shouldRun else { return }
            if available {
                if !self.isListening { self.recoverCapture() }
            } else {
                self.fail("On-device speech recognition is temporarily unavailable.")
            }
        }
    }
}

private enum VoiceError: LocalizedError {
    case noInput
    case incompatibleProcessing

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input is available on this audio route."
        case .incompatibleProcessing: return "Voice processing changed the application's shared audio mode."
        }
    }
}
