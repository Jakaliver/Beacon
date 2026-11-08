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
    let navigation: Bool?
    let navigationRequestId: String?
    let source: PathfindingSource?
    let safety: PathfindingSafety?
    let stopReason: String?
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
    @Published private(set) var controlUp = false
    @Published private(set) var sensorUp = false
    @Published private(set) var tracking = "not_available"
    @Published private(set) var mode = "idle"
    @Published private(set) var stopReason: String?
    @Published private(set) var recording = false
    @Published private(set) var transcribing = false
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var headTracking = false
    @Published private(set) var pathfindingStatus = "Pathfinding off"
    @Published private(set) var pathfindingEnabled = UserDefaults.standard.bool(forKey: "pathfindingEnabled")

    private let control = Connection(path: "/ws/control")
    private let sensor = Connection(path: "/ws/sensor")
    private let ar = ARSensor()
    private let audio = AudioGuide()
    let voice = VoiceSession(allowsHandsFree: false)
    private var transcription: Task<Void, Never>?
    private var transcriptionGeneration = 0
    private lazy var buttonHold = HoldToTalkSession(
        requestPermission: { await AVAudioApplication.requestRecordPermission() },
        startRecording: { [weak self] in self?.startTalking() ?? false },
        sendRecording: { [weak self] in self?.stopTalking() },
        discardRecording: { [weak self] in self?.discardRecording() },
        permissionDenied: { [weak self] in self?.voice.say("Allow microphone access in Settings.") }
    )
    // A reset remains authoritative until a new search. Network latency must never
    // let old guidance, choices or speech restart a cancelled session.
    private var searchCleared = false
    private let talk = PushToTalk()

    private var guidance: Guidance?
    private var guidanceAt = Date.distantPast
    private var pose: PoseSample?
    private var guidanceReceivedAt: TimeInterval?
    private var navigationAcknowledged = false
    private var navigationRequestID = UUID().uuidString
    private var navigationRequestedAt = -TimeInterval.infinity
    private var pathfindingFeedback = PathfindingFeedback()
    private var audioChannel = PathfindingFeedback.Channel.silent
    private var interrupted = false
    private var foreground = true
    private var connectedHost: String?
    private var started = false
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
            self?.sendPathfindingConfiguration()
            if let reason = self?.stopReason { self?.control.sendJSON(["type": "stop", "reason": reason]) }
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
        case .pathfinding(let enabled): setPathfinding(enabled)
        case .lootMode(let enabled):
            Settings.guidanceSoundStyle = enabled ? .chest : .beeps
            refreshGuidanceSound()
            voice.say(enabled ? "Loot mode on." : "Loot mode off.")
        case .help:
            voice.say("Hold Talk to Beacon, say find, calibrate, pause, resume, found it, loot mode on or off, or pathfinding on or off, then release.")
        case .disableVoice: voice.disable()
        }
    }

    private func sendPathfindingConfiguration() {
        navigationRequestedAt = ProcessInfo.processInfo.systemUptime
        navigationRequestID = UUID().uuidString
        navigationAcknowledged = false
        control.sendJSON(["type": "config", "navigation": pathfindingEnabled, "navigation_request_id": navigationRequestID])
    }

    private func setPathfinding(_ enabled: Bool) {
        pathfindingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "pathfindingEnabled")
        pathfindingFeedback.reset()
        audio.silence()
        audioChannel = .silent
        resetProbe()
        lastBeacon = .distantPast
        sendPathfindingConfiguration()
        // Changing preference never releases an existing user/safety pause.
        voice.say(enabled ? "Pathfinding on." : "Pathfinding off.")
    }

    private func resetSearch(resetTracking: Bool) {
        voice.cancelPendingCommand()
        cancelTranscription()
        voice.hush()
        audio.silence()
        resetProbe()
        guidance = nil
        guidanceReceivedAt = nil
        pathfindingFeedback.reset()
        audioChannel = .silent
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
        if pathfindingEnabled {
            let searchingOnly = guidance.map {
                configurationMatches($0) && PathfindingFeedback.isSearchOnlyResume(mode: $0.mode,
                    hasTarget: $0.target != nil, safetyReason: $0.safety?.reason)
            } ?? false
            if searchingOnly {
                // Searching emits no movement cue. A target acquired later must pass safety anew.
                pathfindingFeedback.resumeSearch(at: ProcessInfo.processInfo.systemUptime)
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                let assessment = assessPathfinding(at: now)
                guard pathfindingFeedback.resume(assessment, now: now) else {
                    emitPathfindingSignal(.stop)
                    return
                }
            }
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
        case .repeatLast, .status, .help, .choose, .chooseSide, .disableVoice, .lootMode, .pathfinding:
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
            guidanceReceivedAt = nil
            pathfindingFeedback.reset()
            audioChannel = .silent
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
            voice.say("Resume first.")
            return
        }
        control.sendJSON(["type": "choose", "index": choice.index])
        voice.say("Okay.")
    }

    private func startTalking() -> Bool {
        guard foreground, !interrupted, controlUp, sensorUp, !recording, !transcribing else { return false }
        voice.hush()
        // A just-fired safety cue already silenced motion audio; starting PTT must not cut it short.
        if !pathfindingFeedback.requiresResume { audio.silence() }
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
        guard foreground, !interrupted, !recording else { return }
        if transcribing { cancelTranscription() }
        guard controlUp && sensorUp else { return voice.say("Not connected to the Mac.") }
        buttonHold.press()
    }

    func endTalking() { buttonHold.release() }

    func cancelTalking() { buttonHold.cancel() }

    private func stopTalking() {
        guard recording else { return }
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
        pathfindingFeedback.cancelSearchResume()
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
        if stopReason == nil && isGuiding {
            if pathfindingEnabled {
                stopPathfindingForSystem(reason)
            } else { localStop(reason) }
        }
    }

    private func connectionLost(control isControl: Bool) {
        if isControl { controlUp = false } else { sensorUp = false }
        if recording || transcribing {
            cancelTranscription()
            if pathfindingEnabled { stopPathfindingForSystem("connection") }
            else { localStop("connection") }
        } else if pathfindingEnabled && stopReason == nil && ["searching", "choosing"].contains(mode) {
            stopPathfindingForSystem("connection")
        } else { autoStop("connection") }
    }

    func enteredBackground() {
        foreground = false
        cancelTranscription()
        if stopReason == nil {
            if pathfindingEnabled { stopPathfindingForSystem("interrupted") }
            else { localStop("interrupted") }
        }
        voice.enteredBackground()
    }

    func becameActive() {
        foreground = true
        guard started else { return }
        voice.becameActive()
        applySettings()
        ar.resume()
        try? AVAudioSession.sharedInstance().setActive(true)
        audio.start()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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
                    if self.recording || self.transcribing || self.stopReason == nil {
                        self.cancelTranscription()
                        if self.pathfindingEnabled { self.stopPathfindingForSystem("interrupted") }
                        else { self.localStop("interrupted") }
                    }
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
            guard let g = try? decoder.decode(Guidance.self, from: data), configurationMatches(g) else { return }
            // Configuration acknowledgements survive cancel/reset; old search contents do not.
            navigationAcknowledged = true
            guard !searchCleared, stopReason == nil || g.mode == "stopped" else { return }
            if let pose {
                guard g.epoch == pose.epoch, g.source?.session == pose.session else { return }
                if let previous = guidance?.source, previous.session == g.source?.session,
                   previous.epoch == g.source?.epoch {
                    if let old = previous.poseSeq, let new = g.source?.poseSeq, new < old { return }
                    if let old = previous.frameSeq, let new = g.source?.frameSeq, new < old { return }
                }
            }
            if PathfindingFeedback.shouldSilenceForStoppedGuidance(incomingMode: g.mode, currentMode: mode,
                locallyStopped: stopReason != nil) { audio.silence() }
            guidance = g
            pathfindingFeedback.acceptGuidance(mode: g.mode)
            guidanceAt = Date()
            guidanceReceivedAt = ProcessInfo.processInfo.systemUptime
            if g.mode != mode { mode = g.mode }
            if g.mode != "choosing" && !choices.isEmpty { choices = [] }
            if let l = g.listener, l.count == 3, l.allSatisfy({ $0.isFinite }), pose?.epoch == g.epoch { audio.setListener(SIMD3(l[0], l[1], l[2])) }
        case "say":
            if !searchCleared, stopReason == nil, let text = message.text { voice.say(text) }
        case "choices":
            guard !searchCleared, stopReason == nil else { return }
            choices = message.options ?? []
        case "cue":
            guard !searchCleared, stopReason == nil, let name = message.name else { return }
            // Pathfinding stop/rescan feedback is driven by the timestamped safety state.
            if !pathfindingEnabled || !["stop", "rescan"].contains(name) { audio.cue(name) }
        default:
            break
        }
    }

    private func update(pose sample: PoseSample) {
        pose = sample
        if sample.tracking != tracking { tracking = sample.tracking }
        if sample.tracking != "normal" { autoStop("tracking_lost") }
    }

    private func configurationMatches(_ guidance: Guidance) -> Bool {
        PathfindingFeedback.configurationMatches(requested: pathfindingEnabled, requestID: navigationRequestID,
            acknowledged: guidance.navigation, acknowledgementID: guidance.navigationRequestId)
    }

    private func assessPathfinding(at now: TimeInterval) -> PathfindingFeedback.Assessment {
        guard controlUp && sensorUp, !interrupted else { return .unknown("connection_or_audio") }
        guard let g = guidance, configurationMatches(g), g.navigation == true else { return .unknown("configuration_pending") }
        let localPose = pose.map { PathfindingFeedback.Pose(session: $0.session, epoch: $0.epoch,
            timestamp: $0.timestamp, sampledAt: $0.sampledAt, trackingNormal: $0.tracking == "normal") }
        let assessment = PathfindingFeedback.assess(safety: g.safety, source: g.source, epoch: g.epoch,
            pose: localPose, receivedAt: guidanceReceivedAt, now: now)
        if assessment.permitsMovement && g.mode == "walking" && validWaypoint(g) == nil {
            return .unknown("waypoint_unavailable")
        }
        return assessment
    }

    private func validWaypoint(_ guidance: Guidance) -> SIMD3<Float>? {
        guard let p = guidance.waypoint?.position, p.count == 3, p.allSatisfy({ $0.isFinite }) else { return nil }
        return SIMD3(p[0], p[1], p[2])
    }

    private func latchPathfindingStop(_ reason: String) {
        // Keep an in-progress PTT request: a hazard must not swallow "pause" or "pathfinding off".
        voice.hush()
        audio.silence()
        audioChannel = .silent
        resetProbe()
        stopReason = reason
        control.sendJSON(["type": "stop", "reason": reason])
    }

    private func stopPathfindingForSystem(_ reason: String) {
        pathfindingFeedback.cancelSearchResume()
        let decision = pathfindingFeedback.update(.unknown(reason), now: ProcessInfo.processInfo.systemUptime, active: true)
        if decision.mustStop { latchPathfindingStop("pathfinding_unknown") }
        emitPathfindingSignal(decision.signal)
    }

    private func emitPathfindingSignal(_ signal: PathfindingFeedback.Signal) {
        guard foreground else { return }
        switch signal {
        case .none: break
        case .caution: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .stop:
            voice.hush()
            if !interrupted { audio.pathfindingStop() }
            else { audio.silence() }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func pathfindingPermitsGuidance(at now: TimeInterval) -> Bool {
        guard pathfindingEnabled else { return true }
        let safetyPause = stopReason?.hasPrefix("pathfinding_") == true
        let backendSafetyPause = guidance?.mode == "stopped" && guidance?.stopReason != "user"
        let monitored = isGuiding || safetyPause || backendSafetyPause || pathfindingFeedback.requiresResume
        guard monitored, foreground, !searchCleared else { return false }
        // Allow the configuration acknowledgement to arrive, with all movement cues held.
        if !navigationAcknowledged, now - navigationRequestedAt < 1 { return false }
        let manuallyPaused = stopReason != nil && !safetyPause
        let assessment = assessPathfinding(at: now)
        let decision = pathfindingFeedback.update(assessment, now: now, active: !manuallyPaused)
        if decision.mustStop {
            latchPathfindingStop(assessment.state == .blocked ? "pathfinding_blocked" : "pathfinding_unknown")
        }
        emitPathfindingSignal(decision.signal)
        return decision.permitsMovement
    }

    private func refreshPathfindingStatus(at now: TimeInterval) {
        let label = pathfindingEnabled ? "Pathfinding on" : "Pathfinding off"
        let text: String
        if !controlUp || !sensorUp {
            text = "\(label) · disconnected"
        } else if !navigationAcknowledged {
            text = "\(label) · waiting for Mac"
        } else if !pathfindingEnabled {
            text = label
        } else if searchCleared || mode == "idle" {
            text = "\(label) · say find an object"
        } else {
            let assessment = assessPathfinding(at: now)
            if assessment.permitsMovement {
                text = stopReason != nil || pathfindingFeedback.requiresResume
                    ? "\(label) · paused, say resume" : "\(label) · \(assessment.state == .caution ? "caution" : "ready")"
            } else {
                let reasons = [
                    "connection_or_audio": "connection or audio unavailable", "pose_unavailable": "tracking unavailable",
                    "guidance_late": "updates late", "world_changed": "tracking reset",
                    "capture_unavailable": "waiting for camera", "capture_late": "camera view too old",
                    "configuration_pending": "waiting for Mac", "waypoint_unavailable": "route not ready",
                    "floor_unknown": "scan the floor", "unknown_floor": "scan the floor", "unseen_floor": "scan the floor",
                    "no_floor": "scan the floor", "unobserved": "scan ahead", "obstacle": "obstacle ahead",
                    "no_depth": "waiting for camera", "stale_capture": "camera view too old",
                    "capture_clock_mismatch": "camera timing unavailable", "sensor_unavailable": "tracking unavailable",
                    "motion_too_fast": "move the phone slowly", "outside_map": "scan this area",
                    "start_unobserved": "scan the floor nearby", "corridor_unobserved": "scan the path ahead",
                    "route_blocked": "no clear route", "no_target": "searching for an object", "disabled": "pathfinding off",
                ]
                let reason = assessment.reason.flatMap { reasons[$0] }
                    ?? (assessment.state == .blocked ? "obstacle ahead" : "scan ahead")
                text = "\(label) · \(assessment.state == .blocked ? "blocked" : "coverage unknown"): \(reason)"
            }
        }
        if pathfindingStatus != text { pathfindingStatus = text }
    }

    private func tick() {
        let now = Date()
        if audio.headTrackingLive != headTracking { headTracking = audio.headTrackingLive }
        let fresh = now.timeIntervalSince(guidanceAt) < 1
        // Safety runs before PTT/transcription gates and uses source capture age, not packet age.
        let monotonicNow = ProcessInfo.processInfo.systemUptime
        let permitted = pathfindingPermitsGuidance(at: monotonicNow)
        refreshPathfindingStatus(at: monotonicNow)
        if !fresh && !pathfindingEnabled { autoStop("stale") }
        guard !recording, !transcribing, foreground, !searchCleared, stopReason == nil, fresh,
              permitted, tracking == "normal", let g = guidance, configurationMatches(g), pose?.epoch == g.epoch else {
            audio.stopTargetLoop()
            return resetProbe()
        }
        let waypoint = validWaypoint(g)
        let channel = PathfindingFeedback.channel(navigation: pathfindingEnabled && g.navigation == true,
            mode: g.mode, permitted: permitted, hasWaypoint: waypoint != nil)
        if channel != audioChannel {
            audio.silence()
            audioChannel = channel
            lastBeacon = .distantPast
            lastPulse = .distantPast
            resetProbe()
        }
        switch channel {
        case .route:
            audio.stopTargetLoop()
            if let waypoint, now.timeIntervalSince(lastBeacon) >= 0.6, audio.routePing(at: waypoint) {
                lastBeacon = now
            }
        case .target:
            if Settings.guidanceSoundStyle == .chest {
                resetProbe()
                if let target = g.target, target.valid, let p = target.position,
                   p.count == 3, p.allSatisfy({ $0.isFinite }) {
                    audio.startOrUpdateTargetLoop(at: SIMD3(p[0], p[1], p[2]))
                } else { audio.stopTargetLoop() }
            } else {
                audio.stopTargetLoop()
                probeTick(g, now: now)
            }
        case .silent:
            audio.stopTargetLoop()
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
