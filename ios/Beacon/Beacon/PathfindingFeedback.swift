import Foundation

/// Wire safety is tied to a depth capture in the phone's AR clock, never packet receipt time.
struct PathfindingSafety: Decodable {
    enum State: String, Decodable { case clear, caution, blocked, unknown }
    let state: State
    let reason: String?
    let captureT: Double?
    let frameSeq: Int?
    let ageMs: Double?
    let validForMs: Double
    let distance: Double?
}

struct PathfindingSource: Decodable {
    let session: String?
    let epoch: Int?
    let poseSeq: Int?
    let poseT: Double?
    let frameSeq: Int?
    let frameT: Double?
}

/// Pure policy, shared by the app and command-line tests. No audio/UI work or timers live here.
struct PathfindingFeedback {
    struct Pose {
        let session: String
        let epoch: Int
        let timestamp: Double
        let sampledAt: Double
        let trackingNormal: Bool
    }
    struct Assessment {
        let state: PathfindingSafety.State
        let reason: String?
        var permitsMovement: Bool { state == .clear || state == .caution }
        static func unknown(_ reason: String) -> Self { Self(state: .unknown, reason: reason) }
    }
    enum Signal: Equatable { case none, caution, stop }
    enum Channel: Equatable { case silent, route, target }
    struct Decision {
        let signal: Signal
        let mustStop: Bool
        let permitsMovement: Bool
    }

    private(set) var requiresResume = false
    private var searchResumeUntil: Double?
    private var healthySince: Double?
    private var previousState: PathfindingSafety.State?
    private var lastCaution = -Double.infinity

    static func assess(safety: PathfindingSafety?, source: PathfindingSource?, epoch: Int?,
                       pose: Pose?, receivedAt: Double?, now: Double) -> Assessment {
        guard now.isFinite, let pose, pose.trackingNormal, pose.timestamp.isFinite,
              pose.sampledAt.isFinite, now >= pose.sampledAt, now - pose.sampledAt <= 0.5 else {
            return .unknown("pose_unavailable")
        }
        guard let receivedAt, receivedAt.isFinite, now >= receivedAt, now - receivedAt <= 1 else {
            return .unknown("guidance_late")
        }
        guard let source, source.session == pose.session, source.epoch == pose.epoch, epoch == pose.epoch else {
            return .unknown("world_changed")
        }
        guard let safety, let capture = safety.captureT, capture.isFinite,
              let frame = safety.frameSeq, frame >= 0, frame == source.frameSeq,
              let sourceCapture = source.frameT, sourceCapture.isFinite, abs(sourceCapture - capture) < 0.001,
              safety.validForMs.isFinite, safety.validForMs > 0 else {
            return .unknown("capture_unavailable")
        }
        // AR timestamps and system uptime need not share an origin. Advance the most recent
        // AR timestamp only by elapsed local monotonic time since that sample was delivered.
        let phoneNow = pose.timestamp + now - pose.sampledAt
        let age = phoneNow - capture
        let lifetime = min(safety.validForMs / 1000, 1.5)
        guard age >= -0.05, age <= lifetime,
              let sourcePose = source.poseT, sourcePose.isFinite,
              phoneNow - sourcePose >= -0.05, phoneNow - sourcePose <= 0.5 else {
            return .unknown("capture_late")
        }
        if let reportedAge = safety.ageMs,
           !reportedAge.isFinite || reportedAge < 0 || reportedAge / 1000 > lifetime {
            return .unknown("capture_late")
        }
        return Assessment(state: safety.state, reason: safety.reason)
    }

    mutating func update(_ assessment: Assessment, now: Double, active: Bool) -> Decision {
        if let deadline = searchResumeUntil {
            if now < deadline { return Decision(signal: .none, mustStop: false, permitsMovement: false) }
            searchResumeUntil = nil
        }
        guard active else {
            // A manual pause mutes alerts, but fresh stable clearance must still be
            // observed so a later explicit resume is not stranded behind an old latch.
            if assessment.permitsMovement {
                if healthySince == nil { healthySince = now }
            } else { healthySince = nil }
            return Decision(signal: .none, mustStop: false, permitsMovement: false)
        }
        let prior = previousState
        previousState = assessment.state
        if assessment.permitsMovement {
            if healthySince == nil { healthySince = now }
            let caution = !requiresResume && assessment.state == .caution && prior != .caution && now - lastCaution >= 3
            if caution { lastCaution = now }
            return Decision(signal: caution ? .caution : .none, mustStop: false, permitsMovement: !requiresResume)
        }
        healthySince = nil
        let mustStop = !requiresResume
        requiresResume = true
        // One alert per latched pause. Rescanning must not cause periodic nagging or
        // queue another alarm when the reason flickers between blocked and unknown.
        let signal: Signal = mustStop ? .stop : .none
        return Decision(signal: signal, mustStop: mustStop, permitsMovement: false)
    }

    mutating func resume(_ assessment: Assessment, now: Double) -> Bool {
        guard assessment.permitsMovement else { healthySince = nil; return false }
        if requiresResume {
            guard let healthySince, now - healthySince >= 0.3 else { return false }
        }
        requiresResume = false
        return true
    }

    mutating func resumeSearch(at now: Double) {
        reset()
        searchResumeUntil = now + 1
    }

    mutating func acceptGuidance(mode: String) {
        if mode != "stopped" { searchResumeUntil = nil }
    }

    mutating func cancelSearchResume() { searchResumeUntil = nil }
    mutating func reset() { self = Self() }

    static func shouldSilenceForStoppedGuidance(incomingMode: String, currentMode: String, locallyStopped: Bool) -> Bool {
        incomingMode == "stopped" && currentMode != "stopped" && !locallyStopped
    }

    static func isSearchOnlyResume(mode: String, hasTarget: Bool, safetyReason: String?) -> Bool {
        !hasTarget && ["searching", "choosing", "stopped"].contains(mode) && safetyReason == "no_target"
    }

    static func configurationMatches(requested: Bool, requestID: String, acknowledged: Bool?, acknowledgementID: String?) -> Bool {
        !requestID.isEmpty && acknowledged == requested && acknowledgementID == requestID
    }

    static func channel(navigation: Bool, mode: String, permitted: Bool, hasWaypoint: Bool) -> Channel {
        guard permitted else { return .silent }
        if mode == "walking" { return navigation && hasWaypoint ? .route : .silent }
        return ["probe", "hotcold"].contains(mode) ? .target : .silent
    }
}

/// Route and stop sounds remain short and use the same conservative headroom as object cues.
/// A higher single chime means a waypoint; a descending pair means stop, not object proximity.
enum PathfindingSounds {
    static let sampleRate = 44_100.0
    static let waypoint = chime(1568)
    static let stop = chime(1568) + Array(repeating: Float(0), count: Int(sampleRate * 0.045)) + chime(784)

    private static func chime(_ frequency: Double) -> [Float] {
        let count = Int(sampleRate * 0.075)
        let values = (0..<count).map { i -> Float in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * frequency * t
            let attack = sin(.pi / 2 * min(1, t / 0.004))
            let release = sin(.pi / 2 * min(1, Double(count - 1 - i) / (sampleRate * 0.014)))
            return Float((sin(phase) + 0.025 * sin(2 * phase)) * attack * attack * release * release * exp(-t / 0.05))
        }
        let peak = values.map { abs($0) }.max() ?? 1
        return values.map { $0 * (0.22 / max(peak, 0.0001)) }
    }
}
