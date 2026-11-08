import Foundation

@MainActor
final class VoiceSession {
    struct Response { let text: String; let urgent: Bool }
    var onCommand: ((VoiceCommand) -> Void)?
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var responses: [Response] = []
    init(allowsVoiceChat: Bool = false) {}
    func say(_ text: String, urgent: Bool = false) { responses.append(Response(text: text, urgent: urgent)) }
    func repeatResponse() {}
    func disable() {}
    func enteredBackground() {}
}

@MainActor
final class VoiceLabSoundSuite {
    private(set) var checks = 0
    private(set) var failures = 0
    private let left = SIMD3<Float>(-0.8, 0, -1.3)
    private let right = SIMD3<Float>(0.8, 0, -1.3)

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    private func wait(_ duration: Duration) async { try? await Task.sleep(for: duration) }
    private func awaitChoices(_ model: VoiceLabModel) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while model.state != .choosing && clock.now < deadline { await wait(.milliseconds(25)) }
        expect(model.state == .choosing, "search eventually offers choices")
    }

    func chosenAnchorAndLifecycle() async {
        // Existing installs may still have the retired preference. It must not silence guidance.
        let defaults = UserDefaults.standard
        let key = "guidanceSoundStyle"
        let saved = defaults.object(forKey: key)
        defaults.set("chest", forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let audio = AudioGuide()
        let model = VoiceLabModel(audio: audio)
        expect(audio.startCount == 0 && audio.pulses.isEmpty, "initial state stays silent")
        model.handle(.find("a bottle"))
        expect(audio.startCount == 0 && audio.pulses.isEmpty, "searching does not play a target sound")
        await awaitChoices(model)
        expect(audio.pulses.isEmpty, "unselected matches stay silent")
        model.handle(.chooseSide(.left))
        expect(audio.pulses == [left], "a legacy sound preference still produces a beep at the left anchor")
        await wait(.milliseconds(900))
        expect(audio.pulses.count >= 2 && audio.pulses.allSatisfy { $0 == left }, "beeps repeat at the selected anchor")
        model.handle(.pause)
        let pausedPulses = audio.pulses.count
        model.refreshGuidanceSound()
        await wait(.milliseconds(900))
        expect(model.state == .paused && audio.pulses.count == pausedPulses, "pause cancels queued beeps and refresh cannot resume them")
        model.handle(.resume)
        expect(model.state == .guiding && audio.pulses.count == pausedPulses + 1 && audio.pulses.last == left,
               "explicit resume beeps at the same target")
        model.handle(.find("a cup"))
        let replacementPulses = audio.pulses.count
        await awaitChoices(model)
        expect(audio.pulses.count == replacementPulses, "replacement search cancels the old beep timer")
        model.handle(.chooseSide(.right))
        expect(audio.pulses.last == right, "right selection uses the right anchor")
        model.handle(.finish)
        let finishedPulses = audio.pulses.count
        model.handle(.resume)
        await wait(.milliseconds(900))
        expect(model.state == .finished && model.selected == nil && audio.pulses.count == finishedPulses,
               "finish clears the target and resume cannot restart it")
    }

    func speechBackgroundAndInterruptions() async {
        let audio = AudioGuide()
        let model = VoiceLabModel(audio: audio)
        model.handle(.find("a phone"))
        await awaitChoices(model)
        model.handle(.chooseSide(.right))
        model.voice.onSpeakingChanged?(true)
        let spokenPulses = audio.pulses.count
        await wait(.milliseconds(900))
        expect(audio.ducked && audio.pulses.count == spokenPulses && model.selected == 2,
               "speech suppresses beeps without losing the selected target")
        model.voice.onSpeakingChanged?(false)
        await wait(.milliseconds(900))
        expect(!audio.ducked && audio.pulses.count > spokenPulses && audio.pulses.last == right,
               "beeps continue at the same target after speech")
        model.enteredBackground()
        let backgroundPulses = audio.pulses.count
        model.refreshGuidanceSound()
        await wait(.milliseconds(900))
        expect(model.state == .paused && audio.pulses.count == backgroundPulses, "backgrounding cancels queued beeps")
        model.handle(.resume)
        expect(audio.pulses.count == backgroundPulses + 1 && audio.pulses.last == right,
               "explicit resume restores the selected object after background")
        model.audioInterruptionBegan()
        model.audioInterruptionBegan()
        let interruptedPulses = audio.pulses.count
        let interruptedStarts = audio.startCount
        model.handle(.resume)
        model.handle(.chooseSide(.left))
        model.refreshGuidanceSound()
        await wait(.milliseconds(900))
        expect(model.state == .paused && model.selected == 2 && audio.pulses.count == interruptedPulses
               && audio.startCount == interruptedStarts, "commands cannot restart or switch guidance during an interruption")
        model.audioInterruptionEnded()
        await wait(.milliseconds(900))
        expect(model.state == .paused && audio.pulses.count == interruptedPulses, "ending an interruption does not resume automatically")
        model.handle(.resume)
        expect(model.state == .guiding && audio.pulses.count == interruptedPulses + 1 && audio.pulses.last == right,
               "explicit resume restores the same object after interruption")
        model.audioInterruptionBegan()
        model.handle(.startOver)
        model.audioInterruptionEnded()
        model.handle(.resume)
        let resetPulses = audio.pulses.count
        await wait(.milliseconds(900))
        expect(model.state == .ready && model.selected == nil && audio.pulses.count == resetPulses,
               "reset during interruption discards the old target and timer")
    }
}

@main
struct VoiceLabSoundTests {
    @MainActor
    static func main() async {
        let suite = VoiceLabSoundSuite()
        await suite.chosenAnchorAndLifecycle()
        await suite.speechBackgroundAndInterruptions()
        guard suite.failures == 0 else {
            print("Voice Lab sound: \(suite.failures) of \(suite.checks) checks failed")
            exit(EXIT_FAILURE)
        }
        print("Voice Lab sound: \(suite.checks) checks passed against the production model with fake audio")
    }
}
