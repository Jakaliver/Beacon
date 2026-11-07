import Foundation

/// Ends an Action-button request after speech followed by a pause. The six-second
/// cap also handles silence, background noise and a recorder that stops early.
struct VoiceRequestEndpoint {
    private var speechDuration: TimeInterval = 0
    private var previousTime: TimeInterval = 0
    private var lastSpeechAt: TimeInterval?

    mutating func shouldFinish(at elapsed: TimeInterval, power: Float, isRecording: Bool) -> Bool {
        if !isRecording || elapsed >= 6 { return true }
        let step = max(0, min(0.1, elapsed - previousTime))
        previousTime = elapsed
        if power.isFinite && power > -42 {
            speechDuration += step
            lastSpeechAt = elapsed
        }
        guard speechDuration >= 0.15, let lastSpeechAt else { return false }
        return elapsed >= 1 && elapsed - lastSpeechAt >= 0.9
    }
}
