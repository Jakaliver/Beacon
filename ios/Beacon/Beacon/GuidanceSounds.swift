import Foundation

/// One clean beep timbre throughout; the close cue pairs two short, rising notes.
/// PHASE supplies the room reflections and spatial position during playback.
enum GuidanceSounds {
    static let sampleRate = 44_100.0
    // Leave more than 12 dB of sample headroom before spatialization and room tails.
    static let peak: Float = 0.24
    static let earlyReflections = 0.30
    static let lateReverb = 0.16
    // Gain is capped at unity even when the source is beside the listener.
    static let distanceGains: [SIMD2<Double>] = [
        SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 0.75), SIMD2(2, 0.35),
        SIMD2(4, 0.15), SIMD2(8, 0.06), SIMD2(20, 0),
    ]
    static let pulse = beep(hz: 988)
    static let waypoint = pulse
    static let onObject = pulse + silence(0.022) + beep(hz: 1319)
    static let stop = pulse
    static let rescan = pulse

    /// Rounded sine chime with a little harmonic brightness. No impact noise, low
    /// resonant body or pitch drop: those made the previous cues sound like thuds.
    private static func beep(hz: Double) -> [Float] {
        let count = Int(0.065 * sampleRate)
        let samples = (0..<count).map { i -> Float in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * hz * t
            let attack = sin(.pi / 2 * min(1, t / 0.003))
            let release = sin(.pi / 2 * min(1, Double(count - 1 - i) / (sampleRate * 0.012)))
            let envelope = attack * attack * release * release * exp(-t / 0.045)
            let tone = sin(phase) + 0.04 * sin(2 * phase) + 0.015 * sin(3 * phase)
            return Float(tone * envelope)
        }
        let sourcePeak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * (peak / max(sourcePeak, 0.0001)) }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }
}

/// Let an existing note finish before starting another cue, including mode transitions.
/// This gates new starts; it never cuts off a note or removes its room tail.
struct GuidanceCueTiming {
    private var readyAt = -Double.infinity

    mutating func start(at time: Double, duration: Double) -> Bool {
        guard time >= readyAt else { return false }
        readyAt = time + duration + 0.02
        return true
    }

    mutating func reset() { readyAt = -Double.infinity }
}
