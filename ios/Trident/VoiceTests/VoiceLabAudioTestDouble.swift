import Foundation

/// Records spatial requests without constructing PHASE or activating an audio session.
final class AudioGuide {
    private(set) var startCount = 0
    private(set) var silenceCount = 0
    private(set) var loopStartCount = 0
    private(set) var loopPosition: SIMD3<Float>?
    private(set) var pulses: [SIMD3<Float>?] = []
    private(set) var ducked = false
    private(set) var listener: SIMD3<Float>?
    private(set) var forward: SIMD3<Float>?

    func start() { startCount += 1 }
    func silence() { silenceCount += 1; loopPosition = nil }
    func setListener(_ position: SIMD3<Float>) { listener = position }
    func setForward(_ direction: SIMD3<Float>) { forward = direction }
    func pulse(at position: SIMD3<Float>?) { pulses.append(position) }
    func startOrUpdateTargetLoop(at position: SIMD3<Float>) {
        loopStartCount += 1
        loopPosition = position
    }
    func stopTargetLoop() { loopPosition = nil }
    func setGuidanceDucked(_ value: Bool) { ducked = value }
}
