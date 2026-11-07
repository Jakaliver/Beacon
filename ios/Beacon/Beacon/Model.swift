import AVFoundation
import SwiftUI
import simd

struct Guidance: Decodable {
    struct Target: Decodable {
        let valid: Bool
        let position: [Float]?
        let extent: [Float]?
        let surface: [[Float]]?
    }
    struct Proximity: Decodable {
        let pulseInterval: Double?
        let confirm: Bool?
        let threshold: Float?
    }
    struct Waypoint: Decodable {
        let position: [Float]
    }
    let mode: String
    let epoch: Int
    let target: Target?
    let proximity: Proximity?
    let waypoint: Waypoint?
    let listener: [Float]?
}

struct Choice: Decodable, Identifiable {
    let index: Int
    let description: String
    var id: Int { index }
}

private struct Incoming: Decodable {
    let type: String
    let text: String?
    let name: String?
    let options: [Choice]?
}



@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var controlUp = false
    @Published private(set) var sensorUp = false
    @Published private(set) var tracking = "not_available"
    @Published private(set) var mode = "idle"
    @Published private(set) var stopReason: String?
    @Published private(set) var recording = false
    @Published private(set) var recordingFromButton = false
    @Published private(set) var transcribing = false
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var headTracking = false

    private let control = Connection(path: "/ws/control")
    private let sensor = Connection(path: "/ws/sensor")
    private let ar = ARSensor()
    private let audio = AudioGuide()
    let voice = VoiceSession(requiresWakeWord: true)
    private var transcription: Task<Void, Never>?
    private var transcriptionGeneration = 0
    private var buttonRequest: Task<Void, Never>?
    private var buttonRecording: Task<Void, Never>?
    private var handsFreeStartup: Task<Void, Never>?
    // A reset remains authoritative until a new search. Network latency must never
    // let old guidance, choices or speech restart a cancelled session.
    private var searchCleared = false
    private let talk = PushToTalk()

    private var guidance: Guidance?
    private var guidanceAt = Date.distantPast
    private var pose: PoseSample?
    private var interrupted = false
    private var foreground = true
    private var connectedHost: String?
    private var started = false
    private var ticker: Timer?

    private var smoothedDistance: Float?
    private var phoneInterval: Double?
    private var phoneConfirm = false
    private var wasConfirming = false
    private var torch = Torch()
    private var lastPulse = Date.distantPast
    private var lastBeacon = Date.distantPast

    private static let reasonText = [
        "connection": "Connection to the Mac lost.",
        "tracking_lost": "Tracking lost. Move the phone slowly.",
        "stale": "Guidance or phone updates are out of date.",
        "route_blocked": "No safe route.",
        "world_reset": "Tracking was reset.",
        "rescan": "Target needs a rescan.",
        "audio": "Audio output changed.",
        "interrupted": "Audio was interrupted.",
    ]

    private var isGuiding: Bool { mode == "walking" || mode == "probe" || mode == "hotcold" }

    var statusSummary: String {
        let link = controlUp && sensorUp ? "Mac connected" : controlUp || sensorUp ? "Mac partly connected" : "Mac not connected"
        let state = stopReason.map { "Stopped, \($0.replacingOccurrences(of: "_", with: " "))" } ?? "Mode \(mode)"
        return "\(link). Tracking \(tracking.replacingOccurrences(of: "_", with: " ")). \(state). Head tracking \(headTracking ? "on" : "off")."
    }

    func start() {
        guard !started else { return }
        started = true
        voice.onCommand = { [weak self] command in self?.handleVoice(command) }
        voice.onUserCommand = { [weak self] in self?.cancelTranscription() }
        voice.onSpeakingChanged = { [weak self] speaking in self?.audio.setGuidanceDucked(speaking) }
        audio.onDiagnostic = { [weak self] message in
            self?.control.sendJSON(["type": "audio_diagnostic", "message": message])
        }
        configureAudioSession()
        audio.start()
        observeAudioSession()
        voice.onEnabledChanged = { enabled in
            UserDefaults.standard.set(enabled, forKey: "handsFreeEnabled")
        }
        enableHandsFreeIfWanted()

        control.onOpen = { [weak self] in
            self?.controlUp = true
            self?.control.sendJSON(["type": "hello", "role": "iphone"])
            self?.audio.reportStatus()
        }
        control.onClose = { [weak self] in self?.connectionLost(control: true) }
        control.onText = { [weak self] in self?.handle($0) }
        sensor.onOpen = { [weak self] in
            self?.sensorUp = true
            self?.ar.newSensorSession()
        }
        sensor.onClose = { [weak self] in self?.connectionLost(control: false) }

        ar.link = sensor
        ar.onPose = { [weak self] in self?.update(pose: $0) }
        ar.start(frameRate: Settings.frameRate)
        connect()

        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audio-self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.audio.runPlaybackCheck() }
        }
        #endif
    }

    func applySettings() {
        ar.setFrameRate(Settings.frameRate)
        if connectedHost != Settings.host || !controlUp || !sensorUp { connect() }
        refreshGuidanceSound()
    }

    private func connect() {
        connectedHost = Settings.host
        control.connect(host: Settings.host)
        sensor.connect(host: Settings.host)
    }

    func refreshGuidanceSound() {
        audio.silence()
        resetProbe()
        lastPulse = .distantPast
        lastBeacon = .distantPast
        tick()
    }

    func calibrate() {
        guard let pose, pose.tracking == "normal" else {
            ar.reset()
            voice.say("Resetting tracking. Hold the phone ahead, then say Beacon, calibrate.")
            return
        }
        guard alignAudioForward() else {
            voice.say("Hold the phone upright, pointing ahead, then say Beacon, calibrate.")
            return
        }
        control.sendJSON(["type": "calibrate"])
        voice.say("Calibrated. Ahead is where the phone points.")
    }

    /// Audio "ahead" = the phone's current horizontal heading in the AR world.
    private func alignAudioForward() -> Bool {
        guard let pose, pose.tracking == "normal" else { return false }
        let look = -pose.transform.columns.2
        let horizontal = SIMD3<Float>(look.x, 0, look.z)
        guard simd_length(horizontal) > 0.3 else { return false }
        audio.setForward(simd_normalize(horizontal))
        return true
    }

    func stop() {
        cancelTranscription()
        localStop("user")
    }

    private func handleVoice(_ command: VoiceCommand) {
        switch command {
        case .find(let object): self.command("find \(object)")
        case .calibrate: calibrate()
        case .pause: stop()
        case .resume: resume()
        case .startOver: resetSearch(resetTracking: true)
        case .finish: resetSearch(resetTracking: false)
        case .choose(let index):
            if let choice = choices.first(where: { $0.index == index }) { choose(choice) }
            else { voice.say("That choice is not available. Say Beacon, status to hear the current state.") }
        case .chooseSide(let side):
            let matches = choices.filter {
                VoiceCommand.normalized($0.description).split(separator: " ").contains(Substring(side.rawValue))
            }
            if matches.count == 1, let choice = matches.first { choose(choice) }
            else if choices.isEmpty { voice.say("I haven't found any matches to choose from yet.") }
            else { voice.say("I can't pick out a single match on your \(side.rawValue). Tell me which option you mean.") }
        case .repeatLast: voice.repeatResponse()
        case .status: voice.say(statusSummary)
        case .inspect: self.command("inspect")
        case .lootMode(let enabled):
            Settings.guidanceSoundStyle = enabled ? .chest : .beeps
            refreshGuidanceSound()
            voice.say(enabled ? "Loot mode on." : "Loot mode off.")
        case .help:
            voice.say("Say Beacon, followed by find an object, calibrate, pause, resume, or start over. Say Beacon, status for progress, or Beacon, found it to finish. Say Beacon, loot mode on for chest sounds, or Beacon, loot mode off for normal guidance.")
        case .disableVoice: voice.disable()
        }
    }

    private func resetSearch(resetTracking: Bool) {
        voice.cancelPendingCommand()
        cancelTranscription()
        voice.hush()
        audio.silence()
        resetProbe()
        guidance = nil
        mode = "idle"
        stopReason = nil
        choices = []
        searchCleared = true
        control.sendJSON(["type": "command", "text": "cancel"])
        if resetTracking { ar.reset() }
        voice.say(resetTracking ? "Starting fresh. Say Beacon, find, then the object." : "Finished. Say Beacon when you need another object.", urgent: true)
    }

    func resume() {
        cancelTranscription()
        guard !searchCleared else {
            voice.say("There is no search to resume. Say Beacon, find, then the object.")
            return
        }
        let blocker: String? =
            !(controlUp && sensorUp) ? "No connection to the Mac."
            : tracking != "normal" ? "Tracking is not ready. Move the phone slowly."
            : interrupted ? "Audio is interrupted."
            : nil
        if let blocker {
            voice.say("Cannot resume. \(blocker)")
            return
        }
        stopReason = nil
        resetProbe()
        audio.restart()
        control.sendJSON(["type": "resume"])
        voice.say("Resuming")
    }

    func command(_ text: String, confirmation: String? = nil) {
        // Every command uses the same local interruption/reset behaviour.
        let parsed = VoiceCommand.parse(text)
        switch parsed {
        case .pause: stop(); return
        case .startOver: resetSearch(resetTracking: true); return
        case .finish: resetSearch(resetTracking: false); return
        case .resume: resume(); return
        case .calibrate: calibrate(); return
        case .repeatLast, .status, .help, .choose, .chooseSide, .disableVoice, .lootMode:
            if let parsed { handleVoice(parsed) }
            return
        case .inspect where searchCleared || stopReason != nil:
            voice.say(searchCleared ? "There is no target to inspect. Say Beacon, find, then the object."
                      : "Search paused. Say Beacon, resume before inspecting the target.")
            return
        default: break
        }
        cancelTranscription()
        guard controlUp else { return voice.say("Not connected to the Mac.") }
        var outgoing = text
        if case .find(let object) = parsed {
            outgoing = "find \(object)"
            // Asking to find something is a deliberate action: it clears any earlier stop, and
            // "ahead" for the audio becomes where the phone points now (no separate Calibrate needed).
            stopReason = nil
            searchCleared = false
            guidance = nil
            choices = []
            mode = "searching"
            audio.silence()
            resetProbe()
            audio.start()
            _ = alignAudioForward()
        }
        control.sendJSON(["type": "command", "text": outgoing])
        if let confirmation { voice.say(confirmation) }
    }

    func choose(_ choice: Choice) {
        guard !searchCleared, stopReason == nil else {
            voice.say("Resume your search before choosing a match.")
            return
        }
        control.sendJSON(["type": "choose", "index": choice.index])
        voice.say("Okay.")
    }

    private func enableHandsFreeIfWanted() {
        guard handsFreeStartup == nil, !voice.isEnabled,
              UserDefaults.standard.object(forKey: "handsFreeEnabled") as? Bool != false else { return }
        handsFreeStartup = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.handsFreeStartup = nil } }
            while self.buttonRequest != nil || self.recording || self.transcribing {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, self.foreground else { return }
            await self.voice.enable(greet: false)
        }
    }

    func startTalking() {
        guard !recording, !transcribing else { return }
        guard controlUp && sensorUp else { return voice.say("Not connected to the Mac.") }
        cancelTranscription(resumeVoice: false)
        handsFreeStartup?.cancel()
        handsFreeStartup = nil
        voice.listener.suspend()
        voice.hush()
        audio.silence()
        resetProbe()
        recording = talk.start()
        if !recording {
            voice.say("Microphone not available.")
            resumeVoiceAfterRecording()
        }
    }

    /// A screen tap or shortcut starts one request. A second activation sends
    /// early; otherwise a pause in speech ends the request.
    func talkToBeacon() {
        if recording { stopTalking(); return }
        guard !transcribing else { return }
        if buttonRequest != nil {
            cancelTranscription()
            return
        }
        buttonRequest = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.buttonRequest = nil } }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            // A cold launch may invoke the intent before SwiftUI appears. Use the
            // same model as the screen and wait for foreground camera access.
            while UIApplication.shared.applicationState != .active {
                guard !Task.isCancelled else { return }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.buttonRequest = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            self.start()
            while !(self.controlUp && self.sensorUp) {
                guard !Task.isCancelled else { return }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.buttonRequest = nil
                    self.voice.say("Not connected to the Mac.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled, self.foreground else { return }
            self.buttonRequest = nil
            guard allowed else {
                self.voice.say("Allow microphone access for Beacon in iPhone Settings.")
                return
            }
            self.startTalking()
            guard self.recording else { return }
            self.recordingFromButton = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.buttonRecording = Task { [weak self] in
                var endpoint = VoiceRequestEndpoint()
                let began = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let self, self.recordingFromButton else { return }
                    if endpoint.shouldFinish(at: ProcessInfo.processInfo.systemUptime - began,
                                             power: self.talk.averagePower, isRecording: self.talk.isRecording) {
                        self.stopTalking()
                        return
                    }
                }
            }
        }
    }

    func stopTalking() {
        guard recording else { return }
        buttonRecording?.cancel()
        buttonRecording = nil
        recordingFromButton = false
        recording = false
        let wav = talk.stop()
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        resumeVoiceAfterRecording()
        guard let wav else {
            voice.say("No recording was captured. Please try again.")
            return
        }
        transcribing = true
        transcription = Task {
            do {
                let text = try await PushToTalk.transcribe(wav, host: Settings.host)
                guard !Task.isCancelled, transcriptionGeneration == generation else { return }
                transcribing = false
                transcription = nil
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voice.say("I did not hear a request.")
                } else {
                    voice.submit(text)
                }
            } catch {
                guard !Task.isCancelled, transcriptionGeneration == generation else { return }
                transcribing = false
                transcription = nil
                voice.say("Speech recognition failed. Check the Mac connection.")
            }
        }
    }

    private func cancelTranscription(resumeVoice: Bool = true) {
        buttonRequest?.cancel()
        buttonRequest = nil
        buttonRecording?.cancel()
        buttonRecording = nil
        recordingFromButton = false
        transcriptionGeneration += 1
        transcription?.cancel()
        transcription = nil
        transcribing = false
        if recording {
            _ = talk.stop()
            recording = false
            if resumeVoice { resumeVoiceAfterRecording() }
        }
    }

    private func resumeVoiceAfterRecording() {
        Task { [weak self] in
            guard let self, !self.recording, self.foreground else { return }
            if self.voice.isEnabled { await self.voice.listener.resume() }
            else { self.enableHandsFreeIfWanted() }
        }
    }

    func toggleTalking() { recording ? stopTalking() : startTalking() }

    private func localStop(_ reason: String) {
        voice.cancelPendingCommand()
        cancelTranscription()
        audio.silence()
        resetProbe()
        stopReason = reason
        voice.say(Self.reasonText[reason].map { "Stopped. \($0)" } ?? "Paused", urgent: true)
        control.sendJSON(["type": "stop", "reason": reason])
    }

    /// Automatic stops fire only while guidance is active; the user's Stop always works.
    private func autoStop(_ reason: String) {
        if stopReason == nil && isGuiding { localStop(reason) }
    }

    private func connectionLost(control isControl: Bool) {
        if isControl { controlUp = false } else { sensorUp = false }
        if recording || transcribing { localStop("connection") }
        else { autoStop("connection") }
    }

    func enteredBackground() {
        foreground = false
        handsFreeStartup?.cancel()
        handsFreeStartup = nil
        cancelTranscription(resumeVoice: false)
        if stopReason == nil { localStop("interrupted") }
        voice.enteredBackground()
    }

    func becameActive() {
        foreground = true
        guard started else { return }
        voice.becameActive()
        enableHandsFreeIfWanted()
        ar.resume()
        try? AVAudioSession.sharedInstance().setActive(true)
        audio.start()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setActive(true)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable { self.autoStop("audio") }
                if !self.interrupted { self.audio.restart() }
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated {
                guard let self else { return }
                self.interrupted = began
                if began {
                    if self.recording || self.transcribing || self.stopReason == nil { self.localStop("interrupted") }
                } else {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.audio.restart()
                }
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let decoder = Self.decoder
        guard let message = try? decoder.decode(Incoming.self, from: data) else { return }
        switch message.type {
        case "guidance":
            guard !searchCleared, let g = try? decoder.decode(Guidance.self, from: data),
                  stopReason == nil || g.mode == "stopped" else { return }
            if g.mode == "stopped" && mode != "stopped" { audio.silence() }
            guidance = g
            guidanceAt = Date()
            if g.mode != mode { mode = g.mode }
            if g.mode != "choosing" && !choices.isEmpty { choices = [] }
            if let l = g.listener, l.count == 3 { audio.setListener(SIMD3(l[0], l[1], l[2])) }
        case "say":
            if !searchCleared, stopReason == nil, let text = message.text { voice.say(text) }
        case "choices":
            guard !searchCleared, stopReason == nil else { return }
            choices = message.options ?? []
        case "cue":
            guard !searchCleared, stopReason == nil, let name = message.name else { return }
            audio.cue(name)
        default:
            break
        }
    }

    private func update(pose sample: PoseSample) {
        pose = sample
        if sample.tracking != tracking { tracking = sample.tracking }
        if sample.tracking != "normal" { autoStop("tracking_lost") }
    }

    private func tick() {
        let now = Date()
        if audio.headTrackingLive != headTracking { headTracking = audio.headTrackingLive }
        let fresh = now.timeIntervalSince(guidanceAt) < 1
        if !fresh { autoStop("stale") }
        guard !recording, !transcribing, foreground, !searchCleared, stopReason == nil, fresh, tracking == "normal", let g = guidance else {
            audio.stopTargetLoop()
            return resetProbe()
        }

        if Settings.guidanceSoundStyle == .chest {
            resetProbe()
            if ["walking", "probe", "hotcold"].contains(g.mode),
               let target = g.target, target.valid, let p = target.position,
               p.count == 3, p.allSatisfy({ $0.isFinite }), pose?.epoch == g.epoch {
                audio.startOrUpdateTargetLoop(at: SIMD3(p[0], p[1], p[2]))
            } else { audio.stopTargetLoop() }
            return
        }
        audio.stopTargetLoop()

        switch g.mode {
        case "walking":
            resetProbe()
            if let p = g.waypoint?.position, p.count == 3, now.timeIntervalSince(lastBeacon) >= 0.6 {
                audio.beaconPing(at: SIMD3(p[0], p[1], p[2]))
                lastBeacon = now
            }
        case "probe":
            torchTick(g, now: now)
        case "hotcold":
            // Direct target proximity without routing (milestone 1 behaviour).
            probeTick(g, now: now)
        default:
            resetProbe()
        }
    }

    private func probeTick(_ g: Guidance, now: Date) {
        let interval: Double?
        let confirming: Bool
        if let d = phoneDistance(g) {
            let smoothed = smoothedDistance.map { $0 + 0.3 * (d - $0) } ?? d
            smoothedDistance = smoothed
            let threshold = g.proximity?.threshold ?? 0.2
            phoneConfirm = phoneConfirm ? smoothed < threshold * 1.3 : smoothed < threshold
            let target = Self.pulseInterval(forDistance: smoothed)
            if let current = phoneInterval, abs(target - current) / current < 0.08 {
                interval = current
            } else {
                phoneInterval = target
                interval = target
            }
            confirming = phoneConfirm
        } else {
            smoothedDistance = nil
            phoneInterval = nil
            phoneConfirm = false
            interval = g.proximity?.pulseInterval
            confirming = g.proximity?.confirm ?? false
        }

        let source = g.target?.position.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
        if confirming {
            if !wasConfirming || now.timeIntervalSince(lastPulse) >= 0.8 {
                audio.confirm(at: source)
                lastPulse = now
            }
        } else if let interval, now.timeIntervalSince(lastPulse) >= interval {
            audio.pulse(at: source)
            lastPulse = now
        }
        wasConfirming = confirming
    }

    /// Within reach the phone is a torch: a steady tone whose pitch says whether it points at the object
    /// and whose loudness says how near it is.
    /// Computed from the phone's own pose every tick, so it has no network delay.
    private func torchTick(_ g: Guidance, now: Date) {
        guard let target = g.target, target.valid, let pose, pose.tracking == "normal", pose.epoch == g.epoch,
              let c = target.position, c.count == 3 else {
            audio.stopTorch()
            return probeTick(g, now: now)
        }
        let centre = SIMD3(c[0], c[1], c[2])
        let surface = (target.surface ?? []).filter { $0.count == 3 }.map { SIMD3($0[0], $0[1], $0[2]) }
        let out = torch.update(camera: pose.transform, centre: centre, extent: target.extent?.max() ?? 0.1,
                               surface: surface)
        let threshold = g.proximity?.threshold ?? 0.2
        phoneConfirm = phoneConfirm ? out.distance < threshold * 1.3 : out.distance < threshold
        // Reached: the tone stops and the double beep repeats, so arrival cannot be mistaken for aim.
        audio.setTorch(phoneConfirm ? nil : out.aim, gain: out.gain, at: centre)
        if phoneConfirm, !wasConfirming || now.timeIntervalSince(lastPulse) >= 0.8 {
            audio.confirm(at: centre)
            lastPulse = now
        }
        wasConfirming = phoneConfirm
    }

    private func resetProbe() {
        torch.reset()
        audio.stopTorch()
        smoothedDistance = nil
        phoneInterval = nil
        phoneConfirm = false
        wasConfirming = false
    }

    /// Distance from the phone camera centre to the nearest target surface point, only when it can be trusted.
    private func phoneDistance(_ g: Guidance) -> Float? {
        guard let target = g.target, target.valid, let pose, pose.tracking == "normal", pose.epoch == g.epoch,
              let surface = target.surface, !surface.isEmpty else { return nil }
        let c = pose.transform.columns.3
        let camera = SIMD3<Float>(c.x, c.y, c.z)
        return surface.lazy
            .filter { $0.count == 3 }
            .map { simd_distance(camera, SIMD3($0[0], $0[1], $0[2])) }
            .min()
    }

    /// 0.08 s at ≤ 0.15 m to 1.2 s at ≥ 3 m, exponential so that small changes near the object are audible.
    nonisolated static func pulseInterval(forDistance d: Float) -> Double {
        // Calm range: distance is also heard as loudness, so the knocks need not race like a metal detector.
        let near = 0.15, far = 3.0, fastest = 0.22, slowest = 1.0
        let u = (min(max(Double(d), near), far) - near) / (far - near)
        return fastest * pow(slowest / fastest, u)
    }
}
