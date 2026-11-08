import Foundation

@main
struct PathfindingFeedbackTests {
    static let now = 100.0
    static let pose = PathfindingFeedback.Pose(session: "phone", epoch: 2, timestamp: 10, sampledAt: now, trackingNormal: true)
    static func safety(_ state: PathfindingSafety.State = .clear, capture: Double = 9.7, sequence: Int = 7,
                       age: Double? = 300, validity: Double = 1500) -> PathfindingSafety {
        PathfindingSafety(state: state, reason: nil, captureT: capture, frameSeq: sequence,
                          ageMs: age, validForMs: validity, distance: 1.2)
    }
    static func source(session: String = "phone", epoch: Int = 2, capture: Double = 9.7, sequence: Int = 7,
                       poseT: Double = 10) -> PathfindingSource {
        PathfindingSource(session: session, epoch: epoch, poseSeq: 15, poseT: poseT, frameSeq: sequence, frameT: capture)
    }
    static func assess(_ safety: PathfindingSafety? = safety(), source: PathfindingSource? = source(),
                       pose: PathfindingFeedback.Pose? = pose, time: Double = now,
                       receivedAt: Double? = now, epoch: Int = 2) -> PathfindingFeedback.Assessment {
        PathfindingFeedback.assess(safety: safety, source: source, epoch: epoch, pose: pose, receivedAt: receivedAt, now: time)
    }
    static func main() throws {
        precondition(assess().state == .clear, "Different AR/uptime clock origins must work")
        precondition(assess(safety(.caution)).state == .caution)
        precondition(assess(safety(.blocked)).state == .blocked)
        precondition(assess(nil).state == .unknown, "Missing safety must fail closed")
        precondition(assess(source: nil).state == .unknown)
        precondition(assess(source: source(session: "old-phone")).state == .unknown, "Old connection sessions cannot authorize motion")
        precondition(assess(epoch: 1).state == .unknown)
        precondition(assess(source: source(epoch: 1)).state == .unknown)
        precondition(assess(source: source(sequence: 6)).state == .unknown)
        precondition(assess(source: source(capture: 9.6)).state == .unknown)
        precondition(assess(source: source(poseT: 9.4)).state == .unknown)
        precondition(assess(safety(capture: 10.2), source: source(capture: 10.2)).state == .unknown, "Future captures cannot authorize motion")
        precondition(assess(safety(capture: 8), source: source(capture: 8)).state == .unknown, "A newly received old frame stays stale")
        precondition(assess(safety(age: 1501)).state == .unknown)
        precondition(assess(safety(validity: 0)).state == .unknown)
        precondition(assess(safety(capture: 8, validity: 9000), source: source(capture: 8)).state == .unknown, "Wire TTL cannot exceed local maximum")
        precondition(assess(time: 100.6).state == .unknown, "Pose loss expires locally even while packets arrive")
        precondition(assess(receivedAt: 98.9).state == .unknown)
        precondition(assess(receivedAt: 100.1).state == .unknown)
        let lost = PathfindingFeedback.Pose(session: "phone", epoch: 2, timestamp: 10, sampledAt: now, trackingNormal: false)
        precondition(assess(pose: lost).state == .unknown)
        let later = PathfindingFeedback.Pose(session: "phone", epoch: 2, timestamp: 11.2, sampledAt: 100.8, trackingNormal: true)
        precondition(assess(pose: later, time: 100.9, receivedAt: 100.9).state == .unknown,
                     "Repeated receipts never refresh the originating capture")

        var policy = PathfindingFeedback()
        let clear = PathfindingFeedback.Assessment(state: .clear, reason: nil)
        let caution = PathfindingFeedback.Assessment(state: .caution, reason: "near")
        let blocked = PathfindingFeedback.Assessment(state: .blocked, reason: "obstacle")
        precondition(policy.update(clear, now: 0, active: true).permitsMovement)
        precondition(policy.update(caution, now: 1, active: true).signal == .caution)
        precondition(policy.update(caution, now: 2, active: true).signal == .none, "No caution queue")
        _ = policy.update(clear, now: 2.1, active: true)
        precondition(policy.update(caution, now: 2.2, active: true).signal == .none, "Debounce caution flicker")
        let stop = policy.update(blocked, now: 3, active: true)
        precondition(stop.mustStop && stop.signal == .stop && !stop.permitsMovement)
        precondition(policy.update(.unknown("new reason"), now: 3.1, active: true).signal == .none,
                     "Changing stop reason must not queue a second alarm")
        precondition(policy.update(blocked, now: 8, active: true).signal == .none)
        precondition(policy.update(blocked, now: 9, active: true).signal == .none, "A latched stop remains one-shot")
        precondition(!policy.resume(blocked, now: 9.1))
        precondition(!policy.update(clear, now: 10, active: true).permitsMovement, "Clear must not automatically resume")
        precondition(!policy.resume(clear, now: 10.1), "Require stable clearance")
        _ = policy.update(clear, now: 10.4, active: true)
        precondition(policy.resume(clear, now: 10.4))
        precondition(policy.update(clear, now: 10.5, active: true).permitsMovement)
        precondition(policy.update(blocked, now: 10.6, active: true).signal == .stop, "A new threat after explicit resume interrupts immediately")
        precondition(policy.update(blocked, now: 70.6, active: true).signal == .none, "A 60-second blocked rescan must not repeat an alarm")
        precondition(policy.update(blocked, now: 80, active: false).signal == .none, "Manual pause must not keep vibrating")
        _ = policy.update(clear, now: 81, active: false)
        precondition(policy.update(clear, now: 81.4, active: false).signal == .none)
        precondition(policy.resume(clear, now: 81.4), "A user pause after a hazard must still allow explicit resume once clear")
        policy.reset()
        precondition(!policy.requiresResume)

        precondition(PathfindingFeedback.configurationMatches(requested: false, requestID: "off-2", acknowledged: false, acknowledgementID: "off-2"))
        precondition(!PathfindingFeedback.configurationMatches(requested: true, requestID: "on-3", acknowledged: false, acknowledgementID: "off-2"), "Delayed off packet cannot play target cues after on")
        precondition(!PathfindingFeedback.configurationMatches(requested: true, requestID: "on-3", acknowledged: true, acknowledgementID: "on-1"), "Old clear/on packet cannot acknowledge a newer on request")
        precondition(!PathfindingFeedback.configurationMatches(requested: false, requestID: "off-2", acknowledged: true, acknowledgementID: "on-1"))
        precondition(!PathfindingFeedback.configurationMatches(requested: false, requestID: "off-2", acknowledged: false, acknowledgementID: nil))

        precondition(!PathfindingFeedback.shouldSilenceForStoppedGuidance(incomingMode: "stopped", currentMode: "walking", locallyStopped: true), "Backend stop ACK must not truncate a local stop chime")
        precondition(PathfindingFeedback.shouldSilenceForStoppedGuidance(incomingMode: "stopped", currentMode: "walking", locallyStopped: false), "An external stop must silence old motion cues")
        precondition(!PathfindingFeedback.shouldSilenceForStoppedGuidance(incomingMode: "stopped", currentMode: "stopped", locallyStopped: false))
        precondition(PathfindingFeedback.isSearchOnlyResume(mode: "stopped", hasTarget: false, safetyReason: "no_target"), "A paused search can resume without a movement clearance")
        precondition(!PathfindingFeedback.isSearchOnlyResume(mode: "stopped", hasTarget: true, safetyReason: "no_target"))
        precondition(!PathfindingFeedback.isSearchOnlyResume(mode: "walking", hasTarget: false, safetyReason: "no_target"))
        precondition(!PathfindingFeedback.isSearchOnlyResume(mode: "stopped", hasTarget: false, safetyReason: "corridor_unobserved"))

        var searchResume = PathfindingFeedback()
        _ = searchResume.update(.unknown("no_target"), now: 0, active: true)
        searchResume.resumeSearch(at: 1)
        searchResume.acceptGuidance(mode: "stopped")
        let waiting = searchResume.update(.unknown("no_target"), now: 1.02, active: true)
        precondition(!waiting.mustStop && waiting.signal == .none && !waiting.permitsMovement,
                     "Old stopped/no-target snapshots cannot cancel an explicit search resume")
        searchResume.acceptGuidance(mode: "searching")
        precondition(searchResume.update(clear, now: 1.1, active: true).permitsMovement,
                     "A later acquired target may pass fresh safety after search resume")
        searchResume.resumeSearch(at: 2)
        precondition(searchResume.update(.unknown("no_target"), now: 3.1, active: true).mustStop,
                     "An unanswered search resume must time out safely")
        searchResume.resumeSearch(at: 4)
        searchResume.cancelSearchResume()
        precondition(searchResume.update(blocked, now: 4.01, active: true).mustStop,
                     "Explicit/system stop overrides a pending search resume immediately")

        // Sound stays on the object for both Chest and Beeps. Only the alignment
        // vibration follows the waypoint while taking a detour.
        precondition(PathfindingFeedback.channel(navigation: true, mode: "walking", permitted: true, hasWaypoint: true) == .target,
                     "Walking must keep sound at the target, not move it to a waypoint")
        precondition(PathfindingFeedback.alignment(navigation: true, mode: "walking", permitted: true, hasWaypoint: true) == .route,
                     "Walking vibration must follow the route even while sound follows the target")
        precondition(PathfindingFeedback.channel(navigation: true, mode: "walking", permitted: false, hasWaypoint: true) == .silent)
        precondition(PathfindingFeedback.channel(navigation: true, mode: "walking", permitted: true, hasWaypoint: false) == .silent)
        precondition(PathfindingFeedback.channel(navigation: false, mode: "walking", permitted: true, hasWaypoint: true) == .silent)
        precondition(PathfindingFeedback.alignment(navigation: true, mode: "walking", permitted: true, hasWaypoint: false) == .none,
                     "Missing route geometry cannot authorize an alignment vibration")
        precondition(PathfindingFeedback.alignment(navigation: false, mode: "walking", permitted: true, hasWaypoint: true) == .none,
                     "A leftover walking packet cannot guide after pathfinding is disabled")
        for mode in ["probe", "hotcold"] {
            for navigation in [false, true] {
                for hasWaypoint in [false, true] {
                    precondition(PathfindingFeedback.channel(navigation: navigation, mode: mode, permitted: true, hasWaypoint: hasWaypoint) == .target)
                    precondition(PathfindingFeedback.alignment(navigation: navigation, mode: mode, permitted: true, hasWaypoint: hasWaypoint) == .target,
                                 "Direct finding and close approach retain target-facing vibration without needing a route")
                }
            }
        }
        for mode in ["walking", "probe", "hotcold"] {
            for navigation in [false, true] {
                precondition(PathfindingFeedback.channel(navigation: navigation, mode: mode, permitted: false, hasWaypoint: true) == .silent,
                             "A safety stop mutes even the target's guidance sound")
                precondition(PathfindingFeedback.alignment(navigation: navigation, mode: mode, permitted: false, hasWaypoint: true) == .none,
                             "A safety stop cannot emit reassuring alignment vibration")
            }
        }
        for mode in ["stopped", "idle", "searching", "choosing", "unknown"] {
            for navigation in [false, true] {
                precondition(PathfindingFeedback.channel(navigation: navigation, mode: mode, permitted: true, hasWaypoint: true) == .silent)
                precondition(PathfindingFeedback.alignment(navigation: navigation, mode: mode, permitted: true, hasWaypoint: true) == .none,
                             "Inactive or unknown modes cannot retain an old route or target alignment")
            }
        }
        let stopSamples = PathfindingSounds.stop
        precondition(stopSamples.first == 0 && stopSamples.last == 0)
        precondition(stopSamples.allSatisfy { $0.isFinite && abs($0) <= 0.221 })
        precondition(stopSamples.reduce(0) { $0 + $1 * $1 } > 0.1)
        precondition(Double(stopSamples.count) / PathfindingSounds.sampleRate < 0.3)
        precondition(PathfindingSounds.stop != GuidanceSounds.onObject, "Stop must not sound like close confirmation")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(PathfindingSafety.self, from: Data("""
            {"state":"clear","reason":null,"capture_t":9.7,"frame_seq":7,"age_ms":300,"valid_for_ms":1500,"distance":null}
            """.utf8))
        precondition(decoded.captureT == 9.7 && decoded.frameSeq == 7 && decoded.validForMs == 1500)
        print("Pathfinding: capture age/identity, stale packets, stop latch/resume, target audio, route/target alignment and stop sound headroom passed")
    }
}
