import AVFoundation
import SwiftUI
import simd

struct Guidance: Decodable {
    struct Target: Decodable {
        let valid: Bool
        let position: [Float]?
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

enum Settings {
    static let hostKey = "host"
    static let frameRateKey = "frameRate"
    static let defaultHost = "Malins-Macbook-Pro-3.local"
    static let reverseHeadTurnKey = "reverseHeadTurn"
    static let reverseHeadTiltKey = "reverseHeadTilt"
    static let soundHeightKey = "soundHeight"  // metres; positive raises sounds
    static let defaultFrameRate = 10.0

    static var host: String { UserDefaults.standard.string(forKey: hostKey) ?? defaultHost }
    static var frameRate: Double {
        let value = UserDefaults.standard.double(forKey: frameRateKey)
        return value > 0 ? value : defaultFrameRate
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var controlUp = false
    @Published private(set) var sensorUp = false
    @Published private(set) var tracking = "not_available"
    @Published private(set) var mode = "idle"
    @Published private(set) var stopReason: String?
    @Published private(set) var recording = false
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var headTracking = false

    private let control = Connection(path: "/ws/control")
    private let sensor = Connection(path: "/ws/sensor")
    private let ar = ARSensor()
    private let audio = AudioGuide()
    private let speaker = Speaker()
    private let talk = PushToTalk()

    private var guidance: Guidance?
    private var guidanceAt = Date.distantPast
    private var pose: PoseSample?
    private var interrupted = false
    private var started = false
    private var ticker: Timer?

    private var smoothedDistance: Float?
    private var phoneInterval: Double?
    private var phoneConfirm = false
    private var wasConfirming = false
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
        audio.onDiagnostic = { [weak self] message in
            self?.control.sendJSON(["type": "audio_diagnostic", "message": message])
        }
        configureAudioSession()
        audio.start()
        observeAudioSession()
        AVAudioApplication.requestRecordPermission { _ in }

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
        connect()
    }

    private func connect() {
        control.connect(host: Settings.host)
        sensor.connect(host: Settings.host)
    }

    func calibrate() {
        guard let pose, pose.tracking == "normal" else {
            ar.reset()
            speaker.say("Resetting tracking. Hold the phone ahead of you, then press Calibrate again.")
            return
        }
        guard alignAudioForward() else {
            speaker.say("Hold the phone upright, pointing ahead, and press Calibrate again.")
            return
        }
        control.sendJSON(["type": "calibrate"])
        speaker.say("Calibrated. Ahead is where the phone points.")
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

    func stop() { localStop("user") }

    func resume() {
        let blocker: String? =
            !(controlUp && sensorUp) ? "No connection to the Mac."
            : tracking != "normal" ? "Tracking is not ready. Move the phone slowly."
            : interrupted ? "Audio is interrupted."
            : nil
        if let blocker {
            speaker.say("Cannot resume. \(blocker)")
            return
        }
        stopReason = nil
        resetProbe()
        audio.restart()
        control.sendJSON(["type": "resume"])
        speaker.say("Resuming")
    }

    func command(_ text: String, confirmation: String? = nil) {
        guard controlUp else { return speaker.say("Not connected to the Mac.") }
        if text.lowercased().contains("find") {
            // Asking to find something is a deliberate action: it clears any earlier stop, and
            // "ahead" for the audio becomes where the phone points now (no separate Calibrate needed).
            stopReason = nil
            resetProbe()
            audio.start()
            _ = alignAudioForward()
        }
        control.sendJSON(["type": "command", "text": text])
        if let confirmation { speaker.say(confirmation) }
    }

    func choose(_ choice: Choice) {
        control.sendJSON(["type": "choose", "index": choice.index])
        speaker.say("Choice \(choice.index)")
    }

    func startTalking() {
        guard !recording else { return }
        speaker.hush()
        recording = talk.start()
        if !recording { speaker.say("Microphone not available.") }
    }

    func stopTalking() {
        guard recording else { return }
        recording = false
        guard let wav = talk.stop() else { return }
        Task {
            do {
                let text = try await PushToTalk.transcribe(wav, host: Settings.host)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speaker.say("I did not hear a request.")
                } else {
                    command(text)
                }
            } catch {
                speaker.say("Speech recognition failed. Check the Mac connection.")
            }
        }
    }

    func toggleTalking() { recording ? stopTalking() : startTalking() }

    private func localStop(_ reason: String) {
        audio.silence()
        resetProbe()
        stopReason = reason
        speaker.say(Self.reasonText[reason].map { "Stopped. \($0)" } ?? "Stopped")
        control.sendJSON(["type": "stop", "reason": reason])
    }

    /// Automatic stops fire only while guidance is active; the user's Stop always works.
    private func autoStop(_ reason: String) {
        if stopReason == nil && isGuiding { localStop(reason) }
    }

    private func connectionLost(control isControl: Bool) {
        if isControl { controlUp = false } else { sensorUp = false }
        autoStop("connection")
    }

    func enteredBackground() {
        if stopReason == nil { localStop("interrupted") }
    }

    func becameActive() {
        guard started else { return }
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
                    if self.stopReason == nil { self.localStop("interrupted") }
                } else {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.audio.restart()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let message = try? decoder.decode(Incoming.self, from: data) else { return }
        switch message.type {
        case "guidance":
            guard let g = try? decoder.decode(Guidance.self, from: data) else { return }
            if g.mode == "stopped" && mode != "stopped" { audio.silence() }
            guidance = g
            guidanceAt = Date()
            if g.mode != mode { mode = g.mode }
            if g.mode != "choosing" && !choices.isEmpty { choices = [] }
            if let l = g.listener, l.count == 3 { audio.setListener(SIMD3(l[0], l[1], l[2])) }
        case "say":
            if let text = message.text { speaker.say(text) }
        case "choices":
            choices = message.options ?? []
        case "cue":
            guard let name = message.name, name == "stop" || stopReason == nil else { return }
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
        guard stopReason == nil, fresh, tracking == "normal", let g = guidance else { return resetProbe() }

        switch g.mode {
        case "walking":
            resetProbe()
            if let p = g.waypoint?.position, p.count == 3, now.timeIntervalSince(lastBeacon) >= 0.6 {
                audio.beaconPing(at: SIMD3(p[0], p[1], p[2]))
                lastBeacon = now
            }
        case "probe", "hotcold":
            // hotcold: direct target proximity without routing (milestone 1 behaviour).
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

    private func resetProbe() {
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
