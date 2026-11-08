import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// Keeps state tests independent of the device's PHASE engine and audio session.
@MainActor
protocol VoiceLabAudioOutput: AnyObject {
    func start()
    func silence()
    func setListener(_ position: SIMD3<Float>)
    func setForward(_ forward: SIMD3<Float>)
    @discardableResult func pulse(at position: SIMD3<Float>?) -> Bool
    func setGuidanceDucked(_ ducked: Bool)
}

extension AudioGuide: VoiceLabAudioOutput {}

/// Deliberately simulated perception so the voice flow can be exercised without a Mac or camera.
@MainActor
final class VoiceLabModel: ObservableObject {
    enum State: String {
        case ready = "Ready", searching = "Searching", choosing = "Choose a match"
        case guiding = "Guiding", paused = "Paused", finished = "Finished"
    }
    @Published private(set) var state: State = .ready
    @Published private(set) var target = ""
    @Published private(set) var calibrated = false
    @Published private(set) var selected: Int?
    let voice = VoiceSession(allowsVoiceChat: true)
    private var work: Task<Void, Never>?
    private var generation = 0
    private var stateBeforePause: State = .ready
    private let audio: any VoiceLabAudioOutput
    private var soundWork: Task<Void, Never>?
    private var soundGeneration = 0
    private var audioInterrupted = false
    private var interruptionObserver: NSObjectProtocol?

    init(audio: any VoiceLabAudioOutput = AudioGuide()) {
        self.audio = audio
        audio.setListener(.zero)
        audio.setForward(SIMD3<Float>(0, 0, -1))
        voice.onCommand = { [weak self] in self?.handle($0) }
        voice.onSpeakingChanged = { [weak self] speaking in self?.audio.setGuidanceDucked(speaking) }
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                if type == .began { self?.audioInterruptionBegan() }
                else { self?.audioInterruptionEnded() }
            }
        }
        #endif
    }

    deinit {
        work?.cancel()
        soundWork?.cancel()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    var summary: String {
        switch state {
        case .ready: return "What would you like to find?"
        case .searching: return "I'm looking for \(target)."
        case .choosing: return "There's one on your left and one on your right. Which one?"
        case .guiding: return "It's on your \(selectedSide), about one and a half metres away."
        case .paused: return pauseReply
        case .finished: return "All done. What would you like to find next?"
        }
    }

    func handle(_ command: VoiceCommand) {
        if audioInterrupted {
            switch command {
            case .find, .resume, .choose, .chooseSide:
                voice.say("Audio is interrupted. Try again when it's ready.")
                return
            default: break
            }
        }
        switch command {
        case .find(let object):
            cancelWork()
            target = object
            selected = nil
            beginSearch()
        case .calibrate:
            audio.setForward(SIMD3<Float>(0, 0, -1))
            calibrated = true
            voice.say("Forward is set for this demo.")
        case .pause:
            guard state != .paused else { voice.say("We're still paused. Say resume when you're ready."); return }
            stateBeforePause = state
            cancelWork()
            state = .paused
            voice.say(pauseReply, urgent: true)
        case .resume:
            guard state == .paused else { voice.say(summary); return }
            if stateBeforePause == .searching {
                beginSearch(resuming: true)
            } else {
                state = stateBeforePause
                if state == .guiding { refreshGuidanceSound() }
                voice.say(state == .guiding ? "Let's continue. \(summary)" : summary)
            }
        case .startOver:
            cancelWork()
            stateBeforePause = .ready
            state = .ready
            target = ""
            selected = nil
            calibrated = false
            voice.say("Let's start again. What would you like to find?", urgent: true)
        case .finish:
            cancelWork()
            stateBeforePause = .ready
            state = .finished
            target = ""
            selected = nil
            voice.say("All done. What would you like to find next?", urgent: true)
        case .chooseSide(let side):
            handle(.choose(side == .left ? 1 : 2))
        case .choose(let number):
            guard state == .choosing, (1...2).contains(number) else {
                voice.say(choiceReply)
                return
            }
            selected = number
            state = .guiding
            refreshGuidanceSound()
            voice.say("Okay, the \(selectedSide) one. It's about one and a half metres away. Say found it when you're done.")
        case .help:
            voice.say(helpReply)
        case .status, .inspect:
            voice.say(summary)
        case .repeatLast:
            voice.repeatResponse()
        case .disableVoice:
            voice.disable()
        }
    }

    func enteredBackground() {
        stopGuidanceSound()
        if state == .searching || state == .guiding || state == .choosing {
            stateBeforePause = state
            cancelWork()
            state = .paused
        }
        voice.enteredBackground()
    }

    /// Start guidance at the selected sample object, cancelling any previous timer.
    func refreshGuidanceSound() {
        stopGuidanceSound()
        guard state == .guiding, !audioInterrupted, let selected else { return }
        let anchor = SIMD3<Float>(selected == 1 ? -0.8 : 0.8, 0, -1.3)
        audio.setListener(.zero)
        audio.start()
        audio.pulse(at: anchor)
        let ticket = soundGeneration
        soundWork = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self,
                      self.soundGeneration == ticket, self.state == .guiding,
                      !self.audioInterrupted else { return }
                self.audio.pulse(at: anchor)
            }
        }
    }

    /// An OS interruption pauses progress; only an explicit Resume can restart the sound.
    func audioInterruptionBegan() {
        audioInterrupted = true
        stopGuidanceSound()
        if state == .searching || state == .choosing || state == .guiding {
            stateBeforePause = state
            cancelWork()
            state = .paused
        }
    }

    func audioInterruptionEnded() {
        audioInterrupted = false
    }

    private func stopGuidanceSound() {
        soundGeneration += 1
        soundWork?.cancel()
        soundWork = nil
        audio.silence()
    }

    private var selectedSide: String { selected == 1 ? "left" : "right" }

    private var pauseReply: String {
        switch stateBeforePause {
        case .searching: return "I've paused the search for \(target). Say resume when you're ready."
        case .choosing: return "We'll keep those choices. Say resume when you're ready."
        case .guiding: return "Directions are paused. Say resume when you're ready."
        default: return "We're paused. Say resume when you're ready."
        }
    }

    private var choiceReply: String {
        switch state {
        case .choosing: return "Which one would you like, left or right?"
        case .searching: return "I'm still looking for \(target). I'll let you know when there are matches."
        case .paused: return "We're paused. Say resume before choosing."
        case .guiding: return "You've already chosen the \(selectedSide) one. Say start over to choose again."
        default: return "Let's find something first. What are you looking for?"
        }
    }

    private var helpReply: String {
        switch state {
        case .ready, .finished:
            return "Tell me what you'd like to find, like find a bottle. You can also say calibrate."
        case .searching:
            return "I'm looking for \(target). You can say pause to wait, or start over for a new search."
        case .choosing:
            return "Say left or right to pick a match. You can say pause anytime."
        case .guiding:
            return "Say pause to stop directions, repeat to hear them again, or found it when you're done."
        case .paused:
            return "Say resume to continue, or start over for a new search."
        }
    }

    private func beginSearch(resuming: Bool = false) {
        state = .searching
        voice.say(resuming ? "I'll keep looking for \(target)." : "I'll look for \(target).")
        let ticket = generation
        work = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled, let self, self.generation == ticket, self.state == .searching else { return }
            self.state = .choosing
            self.voice.say("In this demo, there's one on your left and one on your right. Which one?")
        }
    }

    private func cancelWork() {
        stopGuidanceSound()
        generation += 1
        work?.cancel()
        work = nil
    }
}
