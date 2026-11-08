import Foundation

/// Short acoustic-style transients. Generated once, then spatialized at the object by PHASE.
enum GuidanceSounds {
    static let sampleRate = 44_100.0
    static let pulse = knock(hz: 620, seconds: 0.095)
    static let waypoint = knock(hz: 460, seconds: 0.12)
    static let onObject = tick()
    static let stop = knock(hz: 620, seconds: 0.07) + silence(0.035) + knock(hz: 410, seconds: 0.10)
    static let rescan = knock(hz: 850, seconds: 0.065) + silence(0.065) + knock(hz: 850, seconds: 0.065)

    /// Muted wood/ceramic body with a soft contact transient, rather than a sustained oscillator.
    private static func knock(hz: Double, seconds: Double) -> [Float] {
        let modes: [(ratio: Double, gain: Double, decay: Double)] = [
            (1, 1, 0.023), (1.48, 0.30, 0.014), (2.16, 0.13, 0.009), (3.07, 0.05, 0.005),
        ]
        var noiseState: UInt32 = 0x62656163
        var filtered = 0.0
        let count = Int(seconds * sampleRate)
        let samples = (0..<count).map { i -> Float in
            let t = Double(i) / sampleRate
            noiseState = 1_664_525 &* noiseState &+ 1_013_904_223
            let noise = Double(noiseState >> 8) / 8_388_608 - 1
            filtered += 0.32 * (noise - filtered)
            var value = 0.16 * filtered * exp(-t / 0.003)
            for mode in modes {
                // A tiny downward settling of the resonances makes the impact less electronic.
                let phase = 2 * Double.pi * hz * mode.ratio * (t + 0.00006 * (1 - exp(-t / 0.003)))
                value += mode.gain * sin(phase) * exp(-t / mode.decay)
            }
            let attack = min(1, t / 0.0012)
            let release = min(1, Double(count - 1 - i) / (sampleRate * 0.008))
            return Float(value * attack * release)
        }
        return normalized(samples)
    }

    /// A small mechanical tick: a rounded broadband contact and very short resonances.
    /// There is no held note or long tail to smear the position cue.
    private static func tick() -> [Float] {
        let count = Int(0.035 * sampleRate)
        var noiseState: UInt32 = 0x7469636b
        var lowPass = 0.0
        var lowBody = 0.0
        let samples = (0..<count).map { i -> Float in
            let t = Double(i) / sampleRate
            noiseState = 1_664_525 &* noiseState &+ 1_013_904_223
            let noise = Double(noiseState >> 8) / 8_388_608 - 1
            lowPass += 0.45 * (noise - lowPass)
            lowBody += 0.06 * (lowPass - lowBody)
            let contact = 0.5 * (lowPass - lowBody) * exp(-t / 0.0025)
            let body = 0.75 * sin(2 * Double.pi * 1750 * t) * exp(-t / 0.0045)
                + 0.24 * sin(2 * Double.pi * 2870 * t) * exp(-t / 0.0028)
                + 0.10 * sin(2 * Double.pi * 4210 * t) * exp(-t / 0.0016)
            let attack = min(1, t / 0.00045)
            let release = min(1, Double(count - 1 - i) / (sampleRate * 0.004))
            return Float((contact + body) * attack * release)
        }
        return normalized(samples)
    }

    private static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * (0.6 / max(peak, 0.0001)) }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }
}
