import Combine
import Foundation

/// Shared voice interaction for the real app and the independent Voice Lab.
@MainActor
final class VoiceSession: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastResponse = ""
    @Published private(set) var lastCommand = ""
    @Published private(set) var awaitingObject = false

    let listener: VoiceListener
    let speaker = Speaker()
    var onCommand: ((VoiceCommand) -> Void)?
    var onUserCommand: (() -> Void)?
    var onSpeakingChanged: ((Bool) -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?
    private let requiresWakeWord: Bool
    private let allowsHandsFree: Bool
    private var followUpUntil = Date.distantPast

    private var subscriptions: Set<AnyCancellable> = []
    private var commandTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var commandGeneration = 0
    private var feedbackGeneration = 0
    private var lifecycleGeneration = 0
    private var lastAccepted = ""
    private var acceptedAt = Date.distantPast
    private var lastSpoken = ""
    private var recentSpeech: [String: Date] = [:]
    private var lastCompletedResponse = ""
    private var completedAt = Date.distantPast
    private var pendingFeedback: String?
    private var userUtteranceActive = false
    private var foreground = true

    var isListening: Bool { listener.isListening }
    var status: String { isEnabled ? listener.status : "Voice mode off" }
    var errorMessage: String? { listener.errorMessage }

    init(allowsVoiceChat: Bool = false, requiresWakeWord: Bool = false, allowsHandsFree: Bool = true) {
        self.requiresWakeWord = requiresWakeWord
        self.allowsHandsFree = allowsHandsFree
        listener = VoiceListener(allowsVoiceChat: allowsVoiceChat)
        listener.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        listener.$isListening.removeDuplicates().dropFirst().sink { [weak self] listening in
            guard let self, !listening else { return }
            // An interruption or capture restart invalidates the partial utterance, even when
            // voice mode remains enabled. Request-only rotations keep isListening true.
            self.cancelCommand()
            self.userUtteranceActive = false
            self.lastAccepted = ""
            self.hush()
        }.store(in: &subscriptions)
        listener.onTranscript = { [weak self] text, final in self?.receive(text, final: final) }
        speaker.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.onSpeakingChanged?(speaking)
            if speaking, let text = self.speaker.currentText {
                self.lastSpoken = text
                self.lastResponse = text
            } else {
                self.rememberEcho(self.lastSpoken)
            }
        }
        speaker.onFinished = { [weak self] in
            guard let self else { return }
            self.lastCompletedResponse = self.lastSpoken
            self.completedAt = Date()
            guard self.commandTask == nil, !self.userUtteranceActive,
                  self.isEnabled, self.foreground else { return }
            self.listener.resetUtterance()
        }
    }

    func enable(greet: Bool = true) async {
        guard allowsHandsFree, !isEnabled, foreground else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isEnabled = true
        await listener.start()
        if Task.isCancelled {
            if lifecycleGeneration == generation {
                isEnabled = false
                listener.suspend()
            }
            return
        }
        // An older permission/start operation must not stop or greet a newer session.
        guard lifecycleGeneration == generation, isEnabled, foreground else { return }
        if listener.isListening {
            if greet { say(requiresWakeWord ? "Ready." : "What are you looking for?") }
            awaitingObject = !requiresWakeWord
            onEnabledChanged?(true)
        } else {
            isEnabled = false
            awaitingObject = false
            onEnabledChanged?(false)
        }
    }

    func disable() {
        lifecycleGeneration += 1
        isEnabled = false
        awaitingObject = false
        userUtteranceActive = false
        lastAccepted = ""
        cancelCommand()
        hush()
        listener.stop()
        onEnabledChanged?(false)
    }

    func enteredBackground() {
        lifecycleGeneration += 1
        foreground = false
        userUtteranceActive = false
        lastAccepted = ""
        cancelCommand()
        hush()
        listener.suspend()
    }

    func becameActive() {
        foreground = true
        guard allowsHandsFree, isEnabled else { return }
        let generation = lifecycleGeneration
        Task { [weak self] in
            guard let self, self.isEnabled, self.foreground,
                  self.lifecycleGeneration == generation else { return }
            await self.listener.resume()
        }
    }

    /// Keep one pending response. A newer event replaces it before speech starts.
    func say(_ text: String, urgent: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard foreground, !text.isEmpty else { return }
        if !urgent, pendingFeedback == text { return }
        feedbackGeneration += 1
        let generation = feedbackGeneration
        feedbackTask?.cancel()
        feedbackTask = nil
        pendingFeedback = nil
        if speaker.currentText == text { return }
        speaker.hush()
        // Cancel an older queued response before suppressing something already heard.
        // Interrupted speech is never marked completed, so it can be requested again.
        if !urgent, text == lastCompletedResponse, Date().timeIntervalSince(completedAt) < 2 { return }
        if urgent {
            speaker.say(text)
            return
        }
        pendingFeedback = text
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.foreground, self.feedbackGeneration == generation else { return }
            self.feedbackTask = nil
            self.pendingFeedback = nil
            self.speaker.say(text)
        }
    }

    func hush() {
        feedbackGeneration += 1
        feedbackTask?.cancel()
        feedbackTask = nil
        pendingFeedback = nil
        speaker.hush()
    }

    func repeatResponse() {
        guard foreground else { return }
        let text = lastResponse
        hush()
        if !text.isEmpty { speaker.say(text) }
    }

    /// Keyboard and accessible buttons use precisely the same command path.
    func submit(_ text: String) { receive(text, final: true, fromMicrophone: false) }

    /// A local Stop/reset must also discard speech already being settled by the recognizer.
    func cancelPendingCommand() {
        cancelCommand()
        userUtteranceActive = false
        lastAccepted = ""
        listener.resetUtterance()
    }

    private func receive(_ text: String, final: Bool, fromMicrophone: Bool = true) {
        guard foreground, !fromMicrophone || (isEnabled && listener.isListening) else { return }
        var normalized = VoiceCommand.normalized(text)
        guard !normalized.isEmpty else { return }
        if fromMicrophone {
            guard let cleaned = removingEcho(from: normalized) else { return }
            normalized = cleaned
            if requiresWakeWord {
                if awaitingObject && Date() >= followUpUntil { awaitingObject = false }
                guard Self.hasWakePrefix(normalized) || awaitingObject else {
                    cancelCommand()
                    userUtteranceActive = false
                    if final { listener.resetUtterance() }
                    return
                }
            }
        }
        transcript = text
        // A revised hypothesis invalidates its predecessor even if the revision is not a command
        // (for example, "find keys" becoming "don't find keys").
        cancelCommand()
        userUtteranceActive = fromMicrophone && !final
        if fromMicrophone, normalized == lastAccepted, Date().timeIntervalSince(acceptedAt) < 1.2 {
            userUtteranceActive = false
            if final { listener.resetUtterance() }
            return
        }
        let bareFind = Self.isObjectPrompt(normalized)
        let command = VoiceCommand.parse(normalized)
            ?? (awaitingObject && !bareFind ? Self.objectReply(normalized).map(VoiceCommand.find) : nil)
        guard command != nil || bareFind else {
            if final {
                listener.resetUtterance()
                say(awaitingObject ? "What are you looking for?"
                    : "Sorry, I didn't catch that. You can ask me for help.")
            }
            return
        }
        hush() // A recognised request interrupts feedback before endpoint detection finishes.
        let generation = commandGeneration
        let execute = { [weak self] in
            guard let self, self.commandGeneration == generation, self.foreground,
                  !fromMicrophone || (self.isEnabled && self.listener.isListening) else { return }
            self.lastAccepted = normalized
            self.acceptedAt = Date()
            self.lastCommand = text
            self.commandTask = nil
            self.userUtteranceActive = false
            self.listener.resetUtterance()
            self.onUserCommand?()
            if bareFind {
                self.awaitingObject = true
                self.followUpUntil = Date().addingTimeInterval(10)
                self.say("What should I look for?")
                return
            }
            guard let command else { return }
            switch command {
            case .disableVoice:
                self.disable()
                self.say("Voice mode off.", urgent: true)
            case .repeatLast:
                self.repeatResponse()
            case .startOver, .finish:
                self.awaitingObject = !self.requiresWakeWord
                self.onCommand?(command)
            case .find, .pause, .resume:
                self.awaitingObject = false
                self.onCommand?(command)
            default:
                self.onCommand?(command)
            }
        }
        if final || command?.isImmediate == true {
            execute()
        } else {
            commandTask = Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                execute()
            }
        }
    }

    private func cancelCommand() {
        commandGeneration += 1
        commandTask?.cancel()
        commandTask = nil
    }

    private func removingEcho(from text: String) -> String? {
        let addressed = Self.withoutAddress(text)
        let rejections = ["no", "not", "never", "don't", "dont", "do not", "i said", "you said",
                          "i don't", "i do not", "i haven't", "i have not", "i am not", "i'm not"]
        if rejections.contains(where: { addressed == $0 || addressed.hasPrefix($0 + " ") }) { return text }
        recentSpeech = recentSpeech.filter { $0.value > Date() }
        var spoken = Array(recentSpeech.keys)
        if let current = speaker.currentText { spoken.append(VoiceCommand.normalized(current)) }
        guard !spoken.isEmpty else { return text }
        // A wake prefix disambiguates a user interruption from a command quoted in spoken help.
        if Self.hasWakePrefix(text), !spoken.contains(text) { return text }
        for output in spoken where (" " + output + " ").contains(" " + text + " ") {
            return nil
        }
        // Recognition can begin midway through our output, then include the user's command.
        // Strip only whole words and only when the remainder has a supported interpretation.
        let words = text.split(separator: " ")
        if words.count > 1 {
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let prefix = words.prefix(count).joined(separator: " ")
                guard spoken.contains(where: { (" " + $0 + " ").contains(" " + prefix + " ") }) else { continue }
                guard count >= 2 || spoken.contains(prefix) else { continue }
                let remainder = words.dropFirst(count).joined(separator: " ")
                if VoiceCommand.parse(remainder) != nil || Self.isObjectPrompt(remainder) { return remainder }
                if count >= 2, awaitingObject, let object = Self.objectReply(remainder) { return object }
            }
        }
        return text
    }

    private func rememberEcho(_ text: String) {
        let normalized = VoiceCommand.normalized(text)
        guard !normalized.isEmpty else { return }
        recentSpeech = recentSpeech.filter { $0.value > Date() }
        recentSpeech[normalized] = Date().addingTimeInterval(0.5)
    }

    private static func hasWakePrefix(_ text: String) -> Bool {
        let text = text.hasPrefix("please ") ? String(text.dropFirst(7)) : text
        return text == "beacon" || text == "hey beacon"
            || text.hasPrefix("hey beacon ") || text.hasPrefix("beacon ")
    }

    private static func withoutAddress(_ text: String) -> String {
        var result = text
        if result.hasPrefix("please ") { result = String(result.dropFirst(7)) }
        if result == "beacon" || result == "hey beacon" { return "" }
        for prefix in ["hey beacon ", "beacon "] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
        if result.hasPrefix("please ") { result = String(result.dropFirst(7)) }
        if result.hasSuffix(" please") { result = String(result.dropLast(7)) }
        return result
    }

    private static func isObjectPrompt(_ text: String) -> Bool {
        let request = withoutAddress(text)
        if request.isEmpty && hasWakePrefix(text) { return true }
        if ["find an object", "find something"].contains(request) { return true }
        // Let the shared parser define find aliases, including any added by the real app.
        let marker = "requested object"
        guard VoiceCommand.parse(request) == nil,
              case .find(let target) = VoiceCommand.parse(request + " " + marker) else { return false }
        return target == marker
    }

    /// A bare noun phrase is useful after an object prompt; arbitrary rejected commands are not.
    /// This is intentionally conservative. An explicit "find …" still preserves any description.
    private static func objectReply(_ text: String) -> String? {
        let reply = withoutAddress(text)
        let words = reply.split(separator: " ")
        guard let first = words.first, words.count <= 20 else { return nil }
        let conversationalStarts: Set<String> = [
            "no", "not", "never", "don't", "dont", "do", "does", "did", "cannot", "can't",
            "i", "i'm", "i've", "i'll", "you", "you're", "we", "they", "he", "she", "it",
            "what", "why", "when", "where", "how", "can", "could", "would", "should",
            "that's", "that", "this", "please", "hey", "beacon", "thank", "thanks",
            "loot", "turn", "enable", "disable",
        ]
        guard !conversationalStarts.contains(String(first)),
              !["yes", "yeah", "okay", "ok", "sure", "alright", "later", "never mind"].contains(reply)
        else { return nil }
        return reply
    }
}
