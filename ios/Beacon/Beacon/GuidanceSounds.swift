import Foundation
import simd

/// One damped beep timbre throughout; the close cue pairs two short, rising notes.
/// PHASE supplies direct binaural placement with no reflections or reverb.
enum GuidanceSounds {
    static let sampleRate = 44_100.0
    // Leave more than 12 dB of sample headroom before spatialization.
    static let peak: Float = 0.24
    // Softened inverse-distance spreading, capped at unity beside the listener.
    // Avoid a flat close-range plateau so small movements still change loudness.
    static let distanceGains: [SIMD2<Double>] = [
        SIMD2(0, 1), SIMD2(0.25, 0.95), SIMD2(0.5, 0.83), SIMD2(1, 0.6),
        SIMD2(2, 0.35), SIMD2(4, 0.185), SIMD2(8, 0.094), SIMD2(20, 0),
    ]
    static let pulse = beep(hz: 988)
    static let waypoint = pulse
    static let onObject = pulse + silence(0.022) + beep(hz: 1319)
    static let stop = pulse
    static let rescan = pulse

    /// A soft tonal attack across several harmonics gives the spatial renderer
    /// more frequency detail than a nearly pure sine. The upper partials fade
    /// quickly, keeping the same lower pitch without a shrill sustained tone.
    private static func beep(hz: Double) -> [Float] {
        let count = Int(0.060 * sampleRate)
        let detail = localizationAttack(count: count)
        let samples = (0..<count).map { i -> Float in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * hz * t
            let attack = sin(.pi / 2 * min(1, t / 0.003))
            let release = sin(.pi / 2 * min(1, Double(count - 1 - i) / (sampleRate * 0.012)))
            let envelope = attack * attack * release * release * exp(-t / 0.028)
            let partials = 0.22 * sin(2 * phase) + 0.12 * sin(3 * phase)
                + 0.075 * sin(4 * phase) + 0.04 * sin(5 * phase) + 0.02 * sin(6 * phase)
            let tone = sin(phase) + partials * exp(-t / 0.025)
            return Float(tone * envelope + detail[i])
        }
        let sourcePeak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * (peak / max(sourcePeak, 0.0001)) }
    }

    /// A quiet, band-shaped 18 ms attack gives the binaural filters more spectral
    /// detail. It ends before the tonal body, so the beep keeps its pitch and does
    /// not acquire a sustained hiss. Fixed noise makes repeated cues consistent.
    private static func localizationAttack(count: Int) -> [Double] {
        var seed: UInt32 = 0x42656163
        var low = 0.0, high = 0.0
        let lowBlend = 1 - exp(-2 * Double.pi * 1_800 / sampleRate)
        let highBlend = 1 - exp(-2 * Double.pi * 5_500 / sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            guard t < 0.018 else { return 0 }
            seed = 1_664_525 &* seed &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            low += lowBlend * (noise - low)
            high += highBlend * (noise - high)
            let fadeIn = sin(.pi / 2 * min(1, t / 0.002))
            let fadeOut = cos(.pi / 2 * t / 0.018)
            return 0.40 * (high - low) * fadeIn * fadeIn * fadeOut * fadeOut
        }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }
}

/// ARKit tracks the phone, not the ears. Approximate the head 30 cm behind and
/// 45 cm above the phone held at chest height. Keep that offset in the calibrated
/// world frame: rotating the phone or turning the head must not move the listener.
enum GuidanceListenerGeometry {
    static func position(camera: simd_float4x4, calibratedForward: SIMD3<Float>,
                         soundHeight: Float) -> SIMD3<Float>? {
        let phone = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let flat = SIMD3<Float>(calibratedForward.x, 0, calibratedForward.z)
        guard phone.x.isFinite, phone.y.isFinite, phone.z.isFinite, soundHeight.isFinite,
              flat.x.isFinite, flat.z.isFinite, simd_length(flat) > 0.001 else { return nil }
        return phone - simd_normalize(flat) * 0.3 + SIMD3(0, 0.45 - soundHeight, 0)
    }
}

/// Let an existing note finish before starting another cue, including mode transitions.
/// This gates new starts; it never cuts off a note's natural decay.
struct GuidanceCueTiming {
    private var readyAt = -Double.infinity

    mutating func start(at time: Double, duration: Double) -> Bool {
        guard time >= readyAt else { return false }
        readyAt = time + duration + 0.02
        return true
    }

    mutating func reset() { readyAt = -Double.infinity }
}

/// Smooth network pose steps before they reach the audio renderer. Head rotation
/// remains live; only listener translation is eased over a short 80 ms window.
struct GuidanceListenerMotion {
    private var position: SIMD3<Float>?
    private var lastUpdate: Double?

    mutating func update(towards target: SIMD3<Float>, at time: Double) -> SIMD3<Float>? {
        guard target.x.isFinite, target.y.isFinite, target.z.isFinite, time.isFinite else { return position }
        guard let current = position, let lastUpdate else {
            position = target
            self.lastUpdate = time
            return target
        }
        let elapsed = min(0.1, max(0, time - lastUpdate))
        let blend = Float(1 - exp(-elapsed / 0.08))
        let next = current + (target - current) * blend
        position = next
        self.lastUpdate = time
        return next
    }
}
