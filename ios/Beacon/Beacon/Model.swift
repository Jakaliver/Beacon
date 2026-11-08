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
    @Published private(set) var recordingFromActionButton = false
    @Published private(set) var transcribing = false
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var headTracking = false

    private let control = Connection(path: "/ws/control")
    private let sensor = Connection(path: "/ws/sensor")
    private let ar = ARSensor()
    private let audio = AudioGuide()
    private let haptics = ProximityHaptics()
    let voice = VoiceSession(allowsHandsFree: false)
    private var transcription: Task<Void, Never>?
    private var transcriptionGeneration = 0
    private var actionButtonRequest: Task<Void, Never>?
    private lazy var buttonHold = HoldToTalkSession(
        requestPermission: { await AVAudioApplication.requestRecordPermission() },
        startRecording: { [weak self] in self?.startTalking() ?? false },
        sendRecording: { [weak self] in self?.stopTalking() },
        discardRecording: { [weak self] in self?.discardRecording() },
        permissionDenied: { [weak self] in
            self?.recordingFromActionButton = false
            self?.voice.say("Allow microphone access in Settings.")
        }
    )
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
    private var audioOutputSignature = ""
    private var ticker: Timer?

    private var proximity = TargetProximity()
    private var wasConfirming = false
    private var lastPulse = Date.distantPast
    private var lastBeacon = Date.distantPast

    private static let reasonText = [
        "connection": "Connection lost.",
        "tracking_lost": "Tracking lost.",
        "stale": "Updates late.",
        "route_blocked": "No safe route.",
        "world_reset": "Tracking reset.",
        "rescan": "Scan again.",
        "audio": "Audio output changed.",
        "interrupted": "Interrupted.",
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
        haptics.stop()
        resetProbe()
        lastPulse = .distantPast
        lastBeacon = .distantPast
        tick()
    }

    func calibrate() {
        guard let pose, pose.tracking == "normal" else {
            ar.reset()
            voice.say("Resetting. Point ahead, then calibrate.")
            return
        }
        guard alignAudioForward() else {
            voice.say("Point ahead, then calibrate.")
            return
        }
        control.sendJSON(["type": "calibrate"])
        voice.say("Calibrated.")
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
            else { voice.say("Not available.") }
        case .chooseSide(let side):
            let matches = choices.filter {
                VoiceCommand.normalized($0.description).split(separator: " ").contains(Substring(side.rawValue))
            }
            if matches.count == 1, let choice = matches.first { choose(choice) }
            else if choices.isEmpty { voice.say("No matches yet.") }
            else { voice.say("Which one?") }
        case .repeatLast: voice.repeatResponse()
        case .status: voice.say(statusSummary)
        case .inspect: self.command("inspect")
        case .lootMode(let enabled):
            Settings.guidanceSoundStyle = enabled ? .chest : .beeps
            refreshGuidanceSound()
            voice.say(enabled ? "Loot mode on." : "Loot mode off.")
        case .help:
            voice.say("Hold Talk to Beacon, say find, calibrate, pause, resume, found it, or loot mode on or off, then release.")
        case .disableVoice: voice.disable()
        }
    }

    private func resetSearch(resetTracking: Bool) {
        voice.cancelPendingCommand()
        cancelTranscription()
        voice.hush()
        audio.silence()
        haptics.stop()
        resetProbe()
        guidance = nil
        mode = "idle"
        stopReason = nil
        choices = []
        searchCleared = true
        control.sendJSON(["type": "command", "text": "cancel"])
        if resetTracking { ar.reset() }
        voice.say(resetTracking ? "Starting fresh." : "Done.", urgent: true)
    }

    func resume() {
        cancelTranscription()
        guard !searchCleared else {
            voice.say("Nothing to resume.")
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
            voice.say(searchCleared ? "No target." : "Paused. Resume first.")
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
            haptics.stop()
            resetProbe()
            audio.start()
            _ = alignAudioForward()
        }
        control.sendJSON(["type": "command", "text": outgoing])
        if let confirmation { voice.say(confirmation) }
    }

    func choose(_ choice: Choice) {
        guard !searchCleared, stopReason == nil else {
            voice.say("Resume first.")
            return
        }
        control.sendJSON(["type": "choose", "index": choice.index])
        voice.say("Okay.")
    }

    private func startTalking() -> Bool {
        defer { if !recording { recordingFromActionButton = false } }
        guard foreground, !interrupted, controlUp, sensorUp, !recording, !transcribing else { return false }
        voice.hush()
        audio.silence()
        haptics.stop()
        resetProbe()
        recording = talk.start()
        if !recording {
            voice.say("Microphone not available.")
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        return recording
    }

    func beginTalking() {
        guard foreground, !interrupted, !recording, !transcribing else { return }
        guard controlUp && sensorUp else { return voice.say("Not connected to the Mac.") }
        actionButtonRequest?.cancel()
        actionButtonRequest = nil
        recordingFromActionButton = false
        buttonHold.press()
    }

    func actionButtonPushToTalk() {
        if buttonHold.isActive { buttonHold.toggle(); return }
        guard !transcribing else { return }
        if let pending = actionButtonRequest {
            pending.cancel()
            actionButtonRequest = nil
            return
        }
        actionButtonRequest = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.actionButtonRequest = nil } }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            // The shortcut can arrive before the screen on a cold launch.
            while UIApplication.shared.applicationState != .active {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            self.start()
            while !(self.controlUp && self.sensorUp) {
                guard !Task.isCancelled, self.foreground else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.voice.say("Not connected to the Mac.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, self.foreground, !self.interrupted, !self.transcribing else { return }
            self.recordingFromActionButton = true
            self.buttonHold.toggle()
        }
    }

    func endTalking() { buttonHold.release() }

    func cancelTalking() { buttonHold.cancel() }

    private func stopTalking() {
        guard recording else { return }
        recordingFromActionButton = false
        recording = false
        let wav = talk.stop()
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        guard let wav else {
            voice.say("Nothing recorded.")
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
                    voice.say("Didn't catch that.")
                } else {
                    voice.submit(text)
                }
            } catch {
                guard !Task.isCancelled, transcriptionGeneration == generation else { return }
                transcribing = false
                transcription = nil
                voice.say("Speech failed.")
            }
        }
    }

    private func cancelTranscription() {
        actionButtonRequest?.cancel()
        actionButtonRequest = nil
        recordingFromActionButton = false
        buttonHold.cancel()
        transcriptionGeneration += 1
        transcription?.cancel()
        transcription = nil
        transcribing = false
        discardRecording()
    }

    private func discardRecording() {
        if recording {
            _ = talk.stop()
            recording = false
        }
    }

    private func localStop(_ reason: String) {
        voice.cancelPendingCommand()
        cancelTranscription()
        audio.silence()
        haptics.stop()
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
        haptics.stop()
        cancelTranscription()
        if stopReason == nil { localStop("interrupted") }
        voice.enteredBackground()
    }

    func becameActive() {
        foreground = true
        guard started else { return }
        voice.becameActive()
        ar.resume()
        try? AVAudioSession.sharedInstance().setActive(true)
        audio.start()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        // Give the renderer room to run alongside camera capture and incoming scans.
        try? session.setPreferredIOBufferDuration(0.02)
        try? session.setActive(true)
        audioOutputSignature = Self.outputSignature(session)
    }

    private static func outputSignature(_ session: AVAudioSession) -> String {
        let ports = session.currentRoute.outputs.map { "\($0.uid):\($0.portType.rawValue)" }.joined(separator: ",")
        return "\(ports)|\(session.sampleRate)|\(session.outputNumberOfChannels)"
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable { self.autoStop("audio") }
                let signature = Self.outputSignature(AVAudioSession.sharedInstance())
                guard signature != self.audioOutputSignature else { return }
                self.audioOutputSignature = signature
                NSLog("Beacon audio: output changed; reason=%lu", reason.rawValue)
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
            // Audio follows local AR tracking. The server's listener can be
            // anchored during probing and arrives later than the phone pose.
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

    private var limitedTrackingSince: Date?
    private static let probeLimitedTracking: TimeInterval = 10  // matches the Mac's probe_limited_tracking_s

    private func update(pose sample: PoseSample) {
        pose = sample
        if sample.tracking == "normal" { audio.setPhonePose(sample.transform, epoch: sample.epoch) }
        if sample.tracking != tracking { tracking = sample.tracking }
        if sample.tracking == "normal" {
            limitedTrackingSince = nil
        } else if mode == "probe", sample.tracking == "limited" {
            // Touching the target covers the camera and ARKit limits tracking. Within reach that is
            // arrival, not a fault: the sound pauses (tick needs normal tracking) unless it lasts.
            let since = limitedTrackingSince ?? Date()
            limitedTrackingSince = since
            if Date().timeIntervalSince(since) > Self.probeLimitedTracking { autoStop("tracking_lost") }
        } else {
            autoStop("tracking_lost")
        }
    }

    private func tick() {
        let now = Date()
        audio.updateSpatialAudio()
        if audio.headTrackingLive != headTracking { headTracking = audio.headTrackingLive }
        let fresh = now.timeIntervalSince(guidanceAt) < 1
        if !fresh { autoStop("stale") }
        guard !recording, !transcribing, foreground, !searchCleared, stopReason == nil, fresh, tracking == "normal", let g = guidance else {
            audio.stopTargetLoop()
            haptics.stop()
            return resetProbe()
        }

        if ["walking", "probe", "hotcold"].contains(g.mode) { haptics.update(distance: phoneDistance(g)) }
        else { haptics.stop() }

        if let target = g.target, target.valid, let p = target.position,
           p.count == 3, pose?.epoch == g.epoch {
            audio.updateTargetPosition(SIMD3(p[0], p[1], p[2]))
        }
        if g.mode == "walking", let p = g.waypoint?.position, p.count == 3 {
            audio.updateWaypointPosition(SIMD3(p[0], p[1], p[2]))
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
            if let p = g.waypoint?.position, p.count == 3, now.timeIntervalSince(lastBeacon) >= 0.6,
               audio.beaconPing(at: SIMD3(p[0], p[1], p[2])) {
                lastBeacon = now
            }
        case "probe", "hotcold":
            probeTick(g, now: now)
        default:
            resetProbe()
        }
    }

    private func probeTick(_ g: Guidance, now: Date) {
        let interval: Double?
        let confirming: Bool
        if let distance = phoneDistance(g),
           let feedback = proximity.update(distance: distance, threshold: g.proximity?.threshold ?? 0.2) {
            interval = feedback.interval
            confirming = feedback.onObject
        } else {
            proximity.reset()
            interval = g.proximity?.pulseInterval
            confirming = g.proximity?.confirm ?? false
        }

        let source = g.target?.position.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
        if confirming {
            if (!wasConfirming || now.timeIntervalSince(lastPulse) >= 0.8), audio.confirm(at: source) {
                lastPulse = now
                wasConfirming = true
            }
        } else {
            if let interval, now.timeIntervalSince(lastPulse) >= interval, audio.pulse(at: source) {
                lastPulse = now
            }
            wasConfirming = false
        }
    }

    private func resetProbe() {
        proximity.reset()
        wasConfirming = false
    }

    /// Use the nearest observed surface, or the centre until surface samples arrive.
    private func phoneDistance(_ g: Guidance) -> Float? {
        guard let target = g.target, target.valid, let pose, pose.tracking == "normal", pose.epoch == g.epoch,
              let centre = target.position, centre.count == 3 else { return nil }
        let surface = (target.surface ?? []).filter { $0.count == 3 }.map { SIMD3($0[0], $0[1], $0[2]) }
        return TargetProximity.distance(camera: pose.transform, centre: SIMD3(centre[0], centre[1], centre[2]), surface: surface)
    }
}
