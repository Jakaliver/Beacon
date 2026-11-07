import Foundation

/// Records the production model's speech boundary without opening audio devices.
@MainActor
final class VoiceSession {
    struct Response {
        let text: String
        let urgent: Bool
    }

    var onCommand: ((VoiceCommand) -> Void)?
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var responses: [Response] = []
    private(set) var backgroundCount = 0

    init(allowsVoiceChat: Bool = false) {}
    func say(_ text: String, urgent: Bool = false) {
        responses.append(Response(text: text, urgent: urgent))
    }
    func repeatResponse() {}
    func disable() {}
    func enteredBackground() { backgroundCount += 1 }
}

@MainActor
final class VoiceLabDirectionalSuite {
    private(set) var checks = 0
    private(set) var failures = 0

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private func wait(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    private func awaitChoices(_ model: VoiceLabModel, _ context: String) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while model.state != .choosing && clock.now < deadline {
            await wait(.milliseconds(25))
        }
        expect(model.state == .choosing, "\(context): search offers choices")
    }

    func directionalSelectionGuards() async {
        let model = VoiceLabModel()
        model.voice.onCommand?(.chooseSide(.left))
        expect(model.state == .ready && model.selected == nil, "left without a search cannot select a match")
        model.voice.onCommand?(.find("the red bottle"))
        model.handle(.chooseSide(.right))
        expect(model.state == .searching && model.selected == nil, "right before matches arrive cannot select a match")
        expect(model.target == "the red bottle", "directional selection preserves the requested object")
        await awaitChoices(model, "left choice")
        model.handle(.help)
        expect(model.state == .choosing && model.selected == nil, "help keeps both choices available")
        model.voice.onCommand?(.chooseSide(.left))
        expect(model.state == .guiding && model.selected == 1, "left selects the left demo match through the production callback")
        expect(model.target == "the red bottle", "left guidance retains its target")
        model.handle(.chooseSide(.right))
        expect(model.state == .guiding && model.selected == 1, "a later right cannot silently switch active guidance")
        model.handle(.pause)
        expect(model.state == .paused && model.voice.responses.last?.urgent == true, "pause interrupts guidance with urgent feedback")
        model.handle(.chooseSide(.right))
        expect(model.state == .paused && model.selected == 1, "a direction cannot bypass paused guidance")
        model.handle(.resume)
        expect(model.state == .guiding && model.selected == 1, "resume restores the chosen left match")
        model.handle(.find("the blue cup"))
        expect(model.state == .searching && model.selected == nil, "a new object clears the prior directional selection")
        await awaitChoices(model, "right choice")
        model.handle(.chooseSide(.right))
        expect(model.state == .guiding && model.selected == 2 && model.target == "the blue cup",
               "right selects the right demo match for the new object")
    }

    func repeatedBackgroundAndResume() async {
        let model = VoiceLabModel()
        model.handle(.find("a wallet"))
        model.enteredBackground()
        model.enteredBackground()
        expect(model.state == .paused && model.voice.backgroundCount == 2, "repeated background events pause search and reach voice")
        let backgroundResponses = model.voice.responses.count
        await wait(.milliseconds(1800))
        expect(model.state == .paused && model.selected == nil, "backgrounded search cannot produce a selection")
        expect(model.voice.responses.count == backgroundResponses, "backgrounded search emits no delayed result")
        model.handle(.resume)
        expect(model.state == .searching && model.target == "a wallet", "explicit resume restarts the same search")
        await awaitChoices(model, "backgrounded search")
        model.enteredBackground()
        model.enteredBackground()
        model.handle(.pause)
        model.handle(.chooseSide(.left))
        expect(model.state == .paused && model.selected == nil, "left cannot select while choices are paused")
        model.handle(.resume)
        expect(model.state == .choosing && model.target == "a wallet", "repeated interruptions preserve the choice step")
        model.handle(.chooseSide(.right))
        expect(model.state == .guiding && model.selected == 2, "right works after resuming choices")
        model.enteredBackground()
        model.enteredBackground()
        model.handle(.resume)
        expect(model.state == .guiding && model.selected == 2, "backgrounding guidance preserves its directional choice")
    }

    func resetAndFinishDiscardOldChoices() async {
        let model = VoiceLabModel()
        model.handle(.calibrate)
        model.handle(.find("keys"))
        await awaitChoices(model, "finish setup")
        model.handle(.chooseSide(.left))
        model.handle(.pause)
        model.handle(.finish)
        expect(model.state == .finished && model.target.isEmpty && model.selected == nil,
               "finish clears the target and direction even while paused")
        expect(model.calibrated && model.voice.responses.last?.urgent == true,
               "finish retains calibration and interrupts feedback")
        model.handle(.resume)
        model.handle(.chooseSide(.right))
        expect(model.state == .finished && model.selected == nil, "resume or direction cannot revive finished guidance")
        model.handle(.find("a phone"))
        model.handle(.pause)
        model.handle(.startOver)
        expect(model.state == .ready && model.target.isEmpty && model.selected == nil && !model.calibrated,
               "start over clears the paused request, selection, and calibration")
        expect(model.voice.responses.last?.urgent == true, "start over interrupts feedback")
        let resetResponses = model.voice.responses.count
        await wait(.milliseconds(1800))
        expect(model.state == .ready && model.voice.responses.count == resetResponses,
               "cancelled search cannot announce choices after reset")
        model.handle(.resume)
        model.handle(.chooseSide(.left))
        expect(model.state == .ready && model.selected == nil, "reset cannot restore an old direction")
        model.enteredBackground()
        expect(model.state == .ready, "backgrounding an idle model does not create a saved search")
    }

    func finishCancelsPendingResults() async {
        let model = VoiceLabModel()
        model.handle(.find("a backpack"))
        model.handle(.help)
        model.handle(.status)
        expect(model.state == .searching && model.target == "a backpack", "help and status preserve the pending search")
        model.handle(.finish)
        let finishedResponses = model.voice.responses.count
        await wait(.milliseconds(1800))
        expect(model.state == .finished && model.target.isEmpty && model.selected == nil,
               "finish cancels a pending result and clears its object")
        expect(model.voice.responses.count == finishedResponses, "finished search cannot interrupt later speech with stale matches")
    }
}

@main
struct VoiceLabDirectionalTests {
    @MainActor
    static func main() async {
        let suite = VoiceLabDirectionalSuite()
        await suite.directionalSelectionGuards()
        await suite.repeatedBackgroundAndResume()
        await suite.resetAndFinishDiscardOldChoices()
        await suite.finishCancelsPendingResults()
        guard suite.failures == 0 else {
            print("Voice Lab directions: \(suite.failures) of \(suite.checks) checks failed")
            exit(EXIT_FAILURE)
        }
        print("Voice Lab directions: \(suite.checks) checks passed against the production model")
    }
}
