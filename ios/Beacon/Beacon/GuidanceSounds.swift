import Foundation

/// One clean beep timbre throughout; the close cue pairs two short, rising notes.
/// PHASE supplies the room reflections and spatial position during playback.
enum GuidanceSounds {
    static let sampleRate = 44_100.0
    static let pulse = beep(hz: 1175)
    static let waypoint = pulse
    static let onObject = pulse + silence(0.022) + beep(hz: 1568)
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
        let peak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * (0.6 / max(peak, 0.0001)) }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }
}
