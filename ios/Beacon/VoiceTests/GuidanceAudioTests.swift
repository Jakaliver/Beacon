import Foundation
import simd

@main
struct GuidanceAudioTests {
    static func camera(position: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(position, 1)))
    }

    static func energy(_ samples: ArraySlice<Float>) -> Double {
        samples.reduce(0) { $0 + Double($1 * $1) }
    }

    static func main() throws {
        let centre = SIMD3<Float>(0, 0, -0.5)
        let surface = [centre + SIMD3(0, 0, 0.04), centre - SIMD3(0, 0, 0.04)]
        let position = SIMD3<Float>(0, 0, -0.30)
        for yaw: Float in [0, 0.5, 1.5, .pi] {
            let distance = TargetProximity.distance(camera: camera(position: position, yaw: yaw), centre: centre, surface: surface)!
            precondition(abs(distance - 0.16) < 0.001, "Rotating the phone cannot change proximity")
            var feedback = TargetProximity()
            precondition(feedback.update(distance: distance, threshold: 0.2)!.onObject,
                         "Close feedback must work even when the camera points away")
        }
        let farther = TargetProximity.distance(camera: camera(position: .zero, yaw: 0), centre: centre, surface: surface)!
        precondition(abs(farther - 0.46) < 0.001, "Moving the phone changes proximity")
        let sideways = TargetProximity.distance(camera: camera(position: SIMD3(1, 0, -0.3), yaw: .pi), centre: centre, surface: surface)!
        precondition(sideways > 1, "Lateral phone movement changes proximity too")
        precondition(TargetProximity.distance(camera: matrix_identity_float4x4, centre: centre, surface: []) == 0.5,
                     "Missing surface data falls back to target position")
        precondition(TargetProximity.distance(camera: matrix_identity_float4x4, centre: centre,
                                              surface: [SIMD3(.nan, 0, 0)]) == 0.5, "Invalid samples are ignored")

        var feedback = TargetProximity()
        precondition(!feedback.update(distance: farther, threshold: 0.2)!.onObject)
        for _ in 0..<20 { _ = feedback.update(distance: 0.15, threshold: 0.2) }
        precondition(feedback.update(distance: 0.15, threshold: 0.2)!.onObject, "Approaching switches to ticks")
        for _ in 0..<20 { _ = feedback.update(distance: 0.23, threshold: 0.2) }
        precondition(feedback.update(distance: 0.23, threshold: 0.2)!.onObject, "Small wobbles keep the close cue")
        for _ in 0..<20 { _ = feedback.update(distance: 0.4, threshold: 0.2) }
        precondition(!feedback.update(distance: 0.4, threshold: 0.2)!.onObject, "Moving away restores approach taps")
        precondition(feedback.update(distance: .nan, threshold: 0.2) == nil, "Invalid distances cannot retain a close cue")
        precondition(TargetProximity.interval(forDistance: 0.3) < TargetProximity.interval(forDistance: 1.5),
                     "Taps accelerate as the phone approaches")

        let sounds = [("approach", GuidanceSounds.pulse), ("on-object", GuidanceSounds.onObject),
                      ("waypoint", GuidanceSounds.waypoint), ("stop", GuidanceSounds.stop), ("rescan", GuidanceSounds.rescan)]
        for (name, samples) in sounds {
            precondition(samples.allSatisfy { $0.isFinite && abs($0) <= 0.61 }, "\(name) must retain sample headroom")
            precondition(samples.first == 0 && samples.last == 0, "\(name) must have clean boundaries")
            precondition(energy(samples[...]) > 0.1, "\(name) must be audible")
            precondition(abs(samples.reduce(0, +) / Float(samples.count)) < 0.003, "\(name) must have negligible DC offset")
        }
        let tick = GuidanceSounds.onObject
        let after20ms = Int(0.020 * GuidanceSounds.sampleRate)
        precondition(energy(tick[after20ms...]) / energy(tick[...]) < 0.001, "The tick must decay quickly without a ringing tail")
        precondition(Double(GuidanceSounds.pulse.count) / GuidanceSounds.sampleRate < TargetProximity.interval(forDistance: 0),
                     "Approach taps must fit within the fastest repeat interval")
        print("Guidance audio: position-only proximity, rotation invariance, hysteresis, invalid data, waveform headroom and decay passed")

        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, samples) in sounds { try writeWAV(samples, to: directory.appendingPathComponent(name + ".wav")) }
            let pause = Array(repeating: Float(0), count: Int(GuidanceSounds.sampleRate * 0.35))
            var preview: [Float] = []
            for _ in 0..<3 { preview += GuidanceSounds.pulse + pause }
            for _ in 0..<4 { preview += GuidanceSounds.onObject + pause }
            try writeWAV(preview, to: directory.appendingPathComponent("approach-to-tick.wav"))
        }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        text("RIFF"); number(36 + bytes); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(GuidanceSounds.sampleRate)); number(UInt32(GuidanceSounds.sampleRate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(bytes)
        for sample in samples { number(Int16((max(-1, min(1, sample)) * 32767).rounded())) }
        try data.write(to: url)
    }
}
