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
        let audio = AudioGuide()
        let model = VoiceLabModel(audio: audio, soundStyle: { .chest })
        expect(audio.startCount == 0 && audio.loopPosition == nil, "initial state does not start guidance audio")
        model.handle(.find("a bottle"))
        expect(audio.startCount == 0 && audio.pulses.isEmpty, "searching does not play a target sound")
        await awaitChoices(model)
        expect(audio.loopPosition == nil, "unselected matches stay silent")
        model.handle(.chooseSide(.left))
        expect(audio.loopPosition == left && audio.loopStartCount == 1, "left selection starts one persistent loop at the left anchor")
        await wait(.milliseconds(900))
        expect(audio.loopStartCount == 1 && audio.pulses.isEmpty, "chest style does not retrigger the loop or emit beeps")
        model.handle(.pause)
        expect(model.state == .paused && audio.loopPosition == nil, "pause stops the target loop synchronously")
        model.refreshGuidanceSound()
        expect(audio.loopPosition == nil, "settings refresh cannot resume paused guidance")
        model.handle(.resume)
        expect(model.state == .guiding && audio.loopPosition == left, "explicit resume restores the same target loop")
        model.handle(.find("a cup"))
        expect(model.state == .searching && audio.loopPosition == nil, "a replacement search immediately stops the old loop")
        await awaitChoices(model)
        model.handle(.chooseSide(.right))
        expect(audio.loopPosition == right, "right selection uses the right anchor")
        model.handle(.finish)
        expect(model.state == .finished && audio.loopPosition == nil && model.selected == nil,
               "finish stops audio and clears the target")
        let finishedStarts = audio.loopStartCount
        model.handle(.resume)
        expect(audio.loopStartCount == finishedStarts, "finished guidance cannot be restarted by resume")
    }

    func liveStyleChangesAndBeepCancellation() async {
        let audio = AudioGuide()
        var style = GuidanceSoundStyle.chest
        let model = VoiceLabModel(audio: audio, soundStyle: { style })
        model.handle(.find("keys"))
        await awaitChoices(model)
        model.handle(.chooseSide(.left))
        style = .beeps
        model.refreshGuidanceSound()
        expect(audio.loopPosition == nil && audio.pulses.count == 1 && audio.pulses.last! == left,
               "switching to beeps stops the loop and beeps at the selected anchor")
        await wait(.milliseconds(900))
        expect(audio.pulses.count >= 2 && audio.pulses.allSatisfy { $0 == left },
               "beeps repeat at the same selected object")
        style = .chest
        model.refreshGuidanceSound()
        let pulsesBeforeLoop = audio.pulses.count
        await wait(.milliseconds(900))
        expect(audio.loopPosition == left && audio.pulses.count == pulsesBeforeLoop,
               "switching back to chest cancels the old beep timer")
        style = .beeps
        model.refreshGuidanceSound()
        model.handle(.pause)
        let pausedPulses = audio.pulses.count
        await wait(.milliseconds(900))
        expect(audio.pulses.count == pausedPulses && model.state == .paused,
               "no queued beep escapes pause")
        model.handle(.resume)
        expect(audio.pulses.count == pausedPulses + 1 && audio.loopPosition == nil,
               "resume uses the currently selected beep style")
        model.handle(.startOver)
        let resetPulses = audio.pulses.count
        await wait(.milliseconds(900))
        expect(model.state == .ready && audio.pulses.count == resetPulses && audio.loopPosition == nil,
               "start over cancels every pending guidance sound")
    }

    func lootCommandsPersistAndRespectState() async {
        let defaults = UserDefaults.standard
        let key = Settings.guidanceSoundStyleKey
        let savedValue = defaults.object(forKey: key)
        defer {
            if let savedValue { defaults.set(savedValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        Settings.guidanceSoundStyle = .beeps
        let audio = AudioGuide()
        // Exercise the production Settings closure, not an injected style that ignores commands.
        let model = VoiceLabModel(audio: audio)
        defer { model.handle(.startOver) }

        let idleResponses = model.voice.responses.count
        model.voice.onCommand?(.lootMode(true))
        expect(Settings.guidanceSoundStyle == .chest && defaults.string(forKey: key) == "chest",
               "loot mode on persists chest style in the real settings")
        expect(model.state == .ready && model.selected == nil && audio.startCount == 0
               && audio.loopPosition == nil && audio.pulses.isEmpty,
               "turning loot mode on while idle does not start guidance")
        expect(model.voice.responses.count == idleResponses + 1,
               "loot mode on acknowledges the command")
        model.voice.onCommand?(.lootMode(false))
        expect(Settings.guidanceSoundStyle == .beeps && defaults.string(forKey: key) == "beeps",
               "loot mode off persists beep style in the real settings")
        expect(model.voice.responses.count == idleResponses + 2,
               "loot mode off acknowledges the command")
        expect(model.state == .ready && audio.startCount == 0 && audio.pulses.isEmpty,
               "turning loot mode off while idle does not start guidance")

        model.handle(.calibrate)
        model.handle(.find("my bottle"))
        await awaitChoices(model)
        model.handle(.chooseSide(.right))
        expect(audio.loopPosition == nil && audio.pulses.last == right,
               "a new search uses the sound preference saved by the voice command")
        let beepsBeforeChest = audio.pulses.count
        model.voice.onCommand?(.lootMode(true))
        expect(model.state == .guiding && model.target == "my bottle" && model.selected == 2 && model.calibrated,
               "loot mode on preserves the current search, selected object, and calibration")
        expect(audio.loopPosition == right && audio.pulses.count == beepsBeforeChest,
               "loot mode on immediately replaces beeps with a loop at the selected object")
        let chestStarts = audio.loopStartCount
        await wait(.milliseconds(900))
        expect(audio.pulses.count == beepsBeforeChest && audio.loopStartCount == chestStarts,
               "the cancelled beep timer cannot interrupt the persistent chest loop")

        model.voice.onCommand?(.lootMode(false))
        expect(model.state == .guiding && model.target == "my bottle" && model.selected == 2 && model.calibrated,
               "loot mode off preserves the same selected object and workflow")
        expect(audio.loopPosition == nil && audio.pulses.count == beepsBeforeChest + 1 && audio.pulses.last == right,
               "loot mode off stops the loop and immediately starts beeps at the same object")
        await wait(.milliseconds(900))
        expect(audio.pulses.count >= beepsBeforeChest + 2 && audio.pulses.allSatisfy { $0 == right },
               "loot mode off keeps repeating beeps at the selected object")

        model.handle(.pause)
        let pausedStarts = audio.startCount
        let pausedPulses = audio.pulses.count
        model.voice.onCommand?(.lootMode(true))
        expect(model.state == .paused && model.selected == 2 && model.target == "my bottle"
               && Settings.guidanceSoundStyle == .chest && audio.loopPosition == nil,
               "a paused loot mode command changes the saved preference without resuming the search")
        await wait(.milliseconds(900))
        expect(audio.startCount == pausedStarts && audio.pulses.count == pausedPulses && audio.loopPosition == nil,
               "no pending guidance sound escapes a paused style change")
        model.voice.onCommand?(.lootMode(false))
        expect(model.state == .paused && Settings.guidanceSoundStyle == .beeps
               && audio.startCount == pausedStarts && audio.pulses.count == pausedPulses,
               "turning loot mode off while paused also stays silent")
        model.handle(.resume)
        expect(model.state == .guiding && model.selected == 2 && audio.loopPosition == nil
               && audio.pulses.count == pausedPulses + 1 && audio.pulses.last == right,
               "explicit resume uses the beep preference selected while paused")
        model.handle(.pause)
        model.voice.onCommand?(.lootMode(true))
        model.handle(.resume)
        expect(model.state == .guiding && model.selected == 2 && audio.loopPosition == right,
               "explicit resume also uses chest style selected while paused")

        model.handle(.startOver)
        let resetStarts = audio.startCount
        let resetPulses = audio.pulses.count
        model.voice.onCommand?(.lootMode(false))
        await wait(.milliseconds(900))
        expect(model.state == .ready && model.selected == nil && model.target.isEmpty
               && audio.startCount == resetStarts && audio.pulses.count == resetPulses && audio.loopPosition == nil,
               "a loot mode command after reset cannot resurrect the previous target or audio")
    }

    func speechBackgroundAndInterruptions() async {
        let audio = AudioGuide()
        let model = VoiceLabModel(audio: audio, soundStyle: { .chest })
        model.handle(.find("a phone"))
        await awaitChoices(model)
        model.handle(.chooseSide(.right))
        let firstLoopStarts = audio.loopStartCount
        model.voice.onSpeakingChanged?(true)
        expect(audio.ducked && audio.loopPosition == right, "speech ducks the loop without moving or stopping it")
        model.voice.onSpeakingChanged?(false)
        expect(!audio.ducked && audio.loopStartCount == firstLoopStarts, "speech ending restores gain without restarting the loop")
        model.enteredBackground()
        expect(model.state == .paused && audio.loopPosition == nil, "backgrounding stops audio and preserves a paused workflow")
        model.refreshGuidanceSound()
        expect(audio.loopPosition == nil, "a settings refresh in background cannot restart playback")
        model.handle(.resume)
        expect(audio.loopPosition == right, "explicit resume restores the selected object after background")
        model.audioInterruptionBegan()
        model.audioInterruptionBegan()
        expect(model.state == .paused && audio.loopPosition == nil, "repeated OS interruptions stop audio without losing the saved state")
        let interruptedStarts = audio.startCount
        model.handle(.resume)
        model.handle(.chooseSide(.left))
        model.refreshGuidanceSound()
        expect(model.state == .paused && audio.startCount == interruptedStarts && model.selected == 2,
               "commands and settings cannot restart or switch guidance during an OS interruption")
        model.audioInterruptionEnded()
        expect(model.state == .paused && audio.loopPosition == nil, "ending an OS interruption does not resume automatically")
        model.handle(.resume)
        expect(model.state == .guiding && audio.loopPosition == right, "explicit resume restores the same object after an OS interruption")
        model.audioInterruptionBegan()
        model.handle(.startOver)
        model.audioInterruptionEnded()
        model.handle(.resume)
        expect(model.state == .ready && model.selected == nil && audio.loopPosition == nil,
               "reset during interruption discards the old target permanently")
    }
}

@main
struct VoiceLabSoundTests {
    @MainActor
    static func main() async {
        let suite = VoiceLabSoundSuite()
        await suite.chosenAnchorAndLifecycle()
        await suite.liveStyleChangesAndBeepCancellation()
        await suite.lootCommandsPersistAndRespectState()
        await suite.speechBackgroundAndInterruptions()
        guard suite.failures == 0 else {
            print("Voice Lab sound: \(suite.failures) of \(suite.checks) checks failed")
            exit(EXIT_FAILURE)
        }
        print("Voice Lab sound: \(suite.checks) checks passed against the production model with fake audio")
    }
}
