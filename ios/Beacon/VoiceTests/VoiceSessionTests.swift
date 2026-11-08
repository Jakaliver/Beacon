import Combine
import Foundation

/// Controllable I/O boundaries. The production coordinator is compiled unchanged against these.
@MainActor
final class VoiceListener: ObservableObject {
    @Published private(set) var isListening = false
    var status = "Test listener"
    var errorMessage: String?
    var onTranscript: ((String, Bool) -> Void)?
    var nextStartDelay: Duration = .zero
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var resumeCount = 0
    private(set) var resetCount = 0
    private var generation = 0
    private var wanted = false

    init(allowsVoiceChat: Bool = false) {}
    func start() async {
        startCount += 1
        generation += 1
        let ticket = generation
        wanted = true
        let delay = nextStartDelay
        nextStartDelay = .zero
        try? await Task.sleep(for: delay)
        guard ticket == generation, wanted else { return }
        isListening = startSucceeds
    }
    func stop() { generation += 1; wanted = false; isListening = false }
    func suspend() { generation += 1; isListening = false }
    func resume() async { resumeCount += 1; if wanted { isListening = true } }
    func resetUtterance() { resetCount += 1 }
    func loseCapture() { isListening = false }
    func emit(_ text: String, final: Bool) { onTranscript?(text, final) }
}

@MainActor
final class Speaker {
    private(set) var currentText: String?
    private(set) var spoken: [String] = []
    var onSpeakingChanged: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    func say(_ text: String) {
        currentText = text
        spoken.append(text)
        onSpeakingChanged?(true)
    }
    func hush() {
        let active = currentText != nil
        currentText = nil
        if active { onSpeakingChanged?(false) }
    }
    func finish() {
        guard currentText != nil else { return }
        currentText = nil
        onSpeakingChanged?(false)
        onFinished?()
    }
}

@MainActor
final class VoiceSessionSuite {
    private(set) var checks = 0
    private(set) var failures = 0

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    private func wait(_ duration: Duration) async { try? await Task.sleep(for: duration) }
    private func ready() async -> VoiceSession {
        let session = VoiceSession()
        await session.enable()
        session.hush()
        expect(session.isEnabled && session.isListening, "voice session enables")
        return session
    }

    func removedSoundCommandsStayInactive() async {
        let session = await ready()
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        for text in ["loot", "loot mode", "loot mode on", "loot mode off", "turn on loot mode"] {
            session.listener.emit(text, final: true)
            session.submit(text)
        }
        expect(commands.isEmpty, "removed sound commands cannot start guidance or become object requests")
        expect(session.awaitingObject, "unsupported commands preserve the object prompt")
        session.submit("find the bottle")
        expect(commands == [.find("the bottle")], "normal object requests still work after an unsupported command")
        session.disable()
    }

    func objectConversation() async {
        let session = await ready()
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        session.submit("help")
        session.submit("status")
        session.submit("calibrate")
        expect(session.awaitingObject, "help, status, and calibration preserve an object prompt")
        for text in ["don't stop", "do not reset", "I said stop earlier", "no thanks", "yes"] {
            session.listener.emit(text, final: true)
        }
        expect(commands == [.help, .status, .calibrate], "negation and conversation cannot become object targets")
        expect(session.awaitingObject, "rejected replies leave the object prompt available")
        session.submit("Hey Beacon, please find")
        expect(commands.count == 3, "a bare find asks for an object instead of starting a search")
        session.listener.emit("the red reset button", final: true)
        expect(commands.last == .find("the red reset button"), "bare object replies preserve their description")
        expect(!session.awaitingObject, "a target completes the object prompt")
        session.submit("start over")
        expect(session.awaitingObject, "start over permits another object reply")
        session.submit("found it")
        expect(session.awaitingObject, "completion permits another object reply")
        session.submit("pause")
        expect(!session.awaitingObject, "pause prevents an incidental noun from starting a search")
        let count = commands.count
        session.listener.emit("blue bottle", final: true)
        expect(commands.count == count, "bare targets require an active prompt")
        session.disable()
    }

    func revisedUtterances() async {
        let session = await ready()
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        session.listener.emit("find keys", final: false)
        session.listener.emit("don't find keys", final: true)
        await wait(.milliseconds(750))
        expect(commands.isEmpty, "a rejected final revision cancels an earlier pending find")
        session.listener.emit("find wallet", final: false)
        session.listener.emit("I said wallet", final: false)
        await wait(.milliseconds(750))
        expect(commands.isEmpty, "an unrecognized partial revision also cancels pending work")
        session.listener.emit("find red bottle", final: false)
        session.listener.emit("find red water bottle", final: true)
        await wait(.milliseconds(750))
        expect(commands == [.find("red water bottle")], "only the final refined target executes")
        session.listener.emit("find red water bottle", final: true)
        expect(commands.count == 1, "duplicate recognizer delivery does not repeat the command")
        session.submit("find red water bottle")
        expect(commands.count == 2, "explicit typed repetition is not mistaken for recognizer duplication")
        session.disable()
    }

    func externalStopCancelsPendingInput() async {
        let session = await ready()
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        session.listener.emit("find a bottle", final: false)
        session.cancelPendingCommand()
        await wait(.milliseconds(750))
        expect(commands.isEmpty, "a local Stop/reset invalidates a previously heard partial command")
        session.listener.emit("find a bottle", final: true)
        expect(commands == [.find("a bottle")], "a fresh deliberate command still works after a local stop")
        session.disable()
    }

    func interruptionAndBackground() async {
        let session = await ready()
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        session.listener.emit("find keys", final: false)
        session.say("A stale result")
        session.listener.loseCapture()
        session.listener.emit("pause", final: true)
        await wait(.milliseconds(750))
        expect(commands.isEmpty, "capture loss cancels settled commands and ignores late callbacks")
        expect(!session.speaker.spoken.contains("A stale result"), "capture loss cancels queued speech")

        await session.listener.resume()
        session.listener.emit("find bottle", final: false)
        session.enteredBackground()
        session.say("Late background result", urgent: true)
        session.submit("help")
        await wait(.milliseconds(750))
        expect(commands.isEmpty, "backgrounding cancels commands and rejects late submissions")
        expect(!session.speaker.spoken.contains("Late background result"), "backgrounding suppresses late speech")
        let resumes = session.listener.resumeCount
        session.becameActive()
        session.disable()
        await Task.yield()
        expect(session.listener.resumeCount == resumes, "a queued foreground resume cannot undo disable")
        expect(!session.isEnabled && !session.isListening, "disable leaves capture stopped")
        session.submit("help")
        expect(commands == [.help], "typed controls remain usable with microphone mode off")
        session.hush()
    }

    func activationRaces() async {
        let session = VoiceSession()
        session.listener.nextStartDelay = .milliseconds(250)
        let oldStart = Task { await session.enable() }
        while session.listener.startCount == 0 { await Task.yield() }
        session.disable()
        await session.enable()
        session.submit("find keys")
        await oldStart.value
        expect(session.isEnabled && session.isListening, "an old start cannot stop a newer voice session")
        expect(!session.awaitingObject, "an old start cannot reopen a completed object prompt")
        session.disable()

        let failed = VoiceSession()
        failed.listener.startSucceeds = false
        await failed.enable()
        expect(!failed.isEnabled, "failed capture startup allows a new enable attempt")
        failed.listener.startSucceeds = true
        await failed.enable()
        expect(failed.isEnabled && failed.isListening, "enable can recover after a failed start")
        failed.disable()
    }

    func feedbackReplacement() async {
        let session = await ready()
        session.say("Already heard", urgent: true)
        session.speaker.finish()
        session.say("Stale queued response")
        session.say("Already heard")
        await wait(.milliseconds(180))
        expect(session.speaker.spoken == ["Already heard"], "duplicate suppression still cancels older queued feedback")
        session.repeatResponse()
        expect(session.speaker.spoken == ["Already heard", "Already heard"], "repeat explicitly replays completed feedback")
        session.say("Interrupted response", urgent: true)
        session.hush()
        session.say("Interrupted response", urgent: true)
        expect(session.speaker.spoken.filter { $0 == "Interrupted response" }.count == 2,
               "interrupted feedback can be spoken again")
        session.say("Older queued response")
        session.say("Newest response")
        await wait(.milliseconds(180))
        expect(session.speaker.spoken.last == "Newest response", "newer feedback replaces pending speech")
        expect(!session.speaker.spoken.contains("Older queued response"), "superseded feedback never plays")
        session.say("After disable")
        session.disable()
        await wait(.milliseconds(180))
        expect(!session.speaker.spoken.contains("After disable"), "disable cancels pending feedback")
    }

    func screenButtonOnly() async {
        let session = VoiceSession(allowsHandsFree: false)
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        await session.enable()
        expect(!session.isEnabled && !session.isListening, "screen-only sessions cannot enable hands-free capture")
        expect(session.listener.startCount == 0, "screen-only sessions never request recognition or open its microphone")
        session.listener.emit("Beacon, find the bottle", final: true)
        expect(commands.isEmpty, "ambient wake commands cannot start a search")
        session.submit("find the bottle")
        expect(commands == [.find("the bottle")], "a completed screen recording still starts the search")
        session.submit("calibrate")
        expect(commands.last == .calibrate, "screen requests retain calibration commands")
        session.enteredBackground()
        session.becameActive()
        await wait(.milliseconds(50))
        expect(session.listener.resumeCount == 0, "returning to the app never resumes a hands-free microphone")
        await session.enable(greet: false)
        expect(session.listener.startCount == 0, "a later enable request remains blocked")
        session.say("Found it.", urgent: true)
        expect(session.speaker.spoken.last == "Found it.", "spoken guidance stays available")
    }

    func beaconWakeWord() async {
        let session = VoiceSession(requiresWakeWord: true)
        var commands: [VoiceCommand] = []
        var enabled: [Bool] = []
        session.onCommand = { commands.append($0) }
        session.onEnabledChanged = { enabled.append($0) }
        await session.enable(greet: false)
        expect(session.isListening && !session.awaitingObject, "Beacon starts ready for an addressed command")
        session.listener.emit("find the bottle", final: true)
        session.listener.emit("I told Beacon to stop", final: true)
        await wait(.milliseconds(180))
        expect(commands.isEmpty && session.speaker.spoken.isEmpty, "unaddressed conversation stays silent")
        session.listener.emit("Beacon, find the bottle", final: true)
        expect(commands == [.find("the bottle")], "Beacon prefix starts a search")
        session.listener.emit("resume", final: true)
        expect(commands.count == 1, "later commands still require the wake word")
        session.listener.emit("Hey Beacon, pause", final: false)
        expect(commands.last == .pause, "an addressed pause interrupts immediately")
        session.listener.emit("Beacon", final: true)
        expect(session.awaitingObject, "the wake word alone opens a brief object prompt")
        session.listener.emit("my red keys", final: true)
        expect(commands.last == .find("my red keys"), "a prompted object reply needs no second wake word")
        expect(!session.awaitingObject, "one reply closes the follow-up window")
        session.listener.emit("Beacon, found it", final: true)
        expect(!session.awaitingObject, "finishing does not expose ambient conversation as another request")
        session.submit("find my wallet")
        expect(commands.last == .find("my wallet"), "the screen button can submit without a wake word")
        session.listener.emit("calibrate", final: true)
        expect(commands.last == .find("my wallet"), "ambient calibration also requires Beacon")
        session.listener.emit("Beacon, calibrate", final: true)
        expect(commands.last == .calibrate, "Beacon can calibrate hands free in Voice Lab")
        session.listener.emit("Hey Beacon, status", final: true)
        expect(commands.last == .status, "addressed status commands work")
        session.submit("help")
        expect(commands.last == .help, "button requests work without a wake word")
        let count = commands.count
        session.listener.emit("Beacon, find a phone", final: false)
        session.listener.emit("I said find a phone", final: true)
        await wait(.milliseconds(750))
        expect(commands.count == count, "a revision removing the wake word cancels the earlier request")
        session.say("Beacon, find a cup", urgent: true)
        session.listener.emit("Beacon, find a cup", final: true)
        expect(commands.count == count, "spoken examples cannot trigger their own wake command")
        session.disable()
        expect(enabled == [true, false], "explicit listening changes can be remembered by the app")

        let cancelled = VoiceSession(requiresWakeWord: true)
        cancelled.listener.nextStartDelay = .milliseconds(200)
        let startup = Task { await cancelled.enable(greet: false) }
        await wait(.milliseconds(30))
        startup.cancel()
        await startup.value
        expect(!cancelled.isEnabled && !cancelled.isListening, "a cancelled automatic start cannot take over the button microphone")
    }

    func echoAndBargeIn() async {
        let session = await ready()
        var commands: [VoiceCommand] = []
        session.onCommand = { commands.append($0) }
        session.say("You can say pause or resume.", urgent: true)
        session.listener.emit("pause", final: false)
        expect(commands.isEmpty, "commands quoted inside spoken help do not execute themselves")
        session.listener.emit("Hey Beacon, pause", final: false)
        expect(commands == [.pause], "a wake-prefixed stop interrupts spoken help promptly")
        expect(session.speaker.currentText == nil, "a user command interrupts current speech")
        session.say("Looking for a bottle.", urgent: true)
        session.listener.emit("for a bottle resume", final: true)
        expect(commands.last == .resume, "a command following a fragment of speaker echo survives filtering")
        let count = commands.count
        session.say("Do not move.", urgent: true)
        session.listener.emit("do not reset", final: true)
        session.say("I said to stay here.", urgent: true)
        session.listener.emit("I said reset", final: true)
        expect(commands.count == count, "echo stripping cannot turn negation or incidental mentions into commands")
        session.say("Find a bottle.", urgent: true)
        session.say("Paused.", urgent: true)
        session.listener.emit("find a bottle", final: true)
        expect(commands.count == count, "echo from interrupted speech is still rejected after replacement")
        session.say("The sample scene is ready.", urgent: true)
        let resets = session.listener.resetCount
        session.listener.emit("could you", final: false)
        session.speaker.finish()
        expect(session.listener.resetCount == resets, "speech completion cannot truncate a user's partial utterance")
        session.listener.emit("help", final: true)
        expect(commands.last == .help, "the user can finish the command after speech ends")

        session.say("Find a wallet.", urgent: true)
        session.speaker.finish()
        let beforeEcho = commands.count
        session.listener.emit("find a wallet", final: true)
        expect(commands.count == beforeEcho, "the short speaker tail is rejected after natural completion")
        await wait(.milliseconds(600))
        session.listener.emit("find a wallet", final: true)
        expect(commands.last == .find("a wallet"), "echo protection expires instead of permanently blocking a phrase")
        session.disable()
    }
}

@main
struct VoiceSessionTests {
    @MainActor
    static func main() async {
        let suite = VoiceSessionSuite()
        await suite.removedSoundCommandsStayInactive()
        await suite.objectConversation()
        await suite.revisedUtterances()
        await suite.externalStopCancelsPendingInput()
        await suite.interruptionAndBackground()
        await suite.activationRaces()
        await suite.feedbackReplacement()
        await suite.echoAndBargeIn()
        await suite.beaconWakeWord()
        await suite.screenButtonOnly()
        guard suite.failures == 0 else {
            print("Voice session: \(suite.failures) of \(suite.checks) checks failed")
            exit(EXIT_FAILURE)
        }
        print("Voice session: \(suite.checks) coordinator checks passed")
    }
}
