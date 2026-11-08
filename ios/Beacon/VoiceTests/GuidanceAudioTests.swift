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

    static func lowFrequencyFraction(_ samples: [Float]) -> Double {
        // Parseval's relation: measure the actual energy below 600 Hz, where the old
        // waypoint's low resonant body produced the unwanted thud.
        let total = energy(samples[...]) * Double(samples.count)
        let topBin = Int(600 * Double(samples.count) / GuidanceSounds.sampleRate)
        var low = 0.0
        for bin in 0...topBin {
            var real = 0.0, imaginary = 0.0
            for (i, value) in samples.enumerated() {
                let phase = 2 * Double.pi * Double(bin * i) / Double(samples.count)
                real += Double(value) * cos(phase)
                imaginary += Double(value) * sin(phase)
            }
            low += (real * real + imaginary * imaginary) * (bin == 0 ? 1 : 2)
        }
        return low / total
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
            precondition(samples.allSatisfy { $0.isFinite && abs($0) <= 0.241 }, "\(name) must retain at least 12 dB of sample headroom")
            precondition(samples.first == 0 && samples.last == 0, "\(name) must have clean boundaries")
            precondition(energy(samples[...]) > 0.1, "\(name) must be audible")
            precondition(abs(samples.reduce(0, +) / Float(samples.count)) < 0.003, "\(name) must have negligible DC offset")
            precondition(lowFrequencyFraction(samples) < 0.001, "\(name) must not contain a low thudding body")
        }
        let tick = GuidanceSounds.onObject
        let window = Int(0.005 * GuidanceSounds.sampleRate)
        var previousAudible = false, attacks = 0
        for start in stride(from: 0, to: tick.count, by: window) {
            let audible = energy(tick[start..<min(start + window, tick.count)]) > 0.005
            if audible && !previousAudible { attacks += 1 }
            previousAudible = audible
        }
        precondition(attacks == 2, "The close cue must contain two distinct short beeps")
        precondition(Double(tick.count) / GuidanceSounds.sampleRate < 0.2, "The double cue should remain compact")
        precondition(GuidanceSounds.waypoint == GuidanceSounds.pulse, "Walking and approaching must use the same clean sound")
        precondition(Double(GuidanceSounds.pulse.count) / GuidanceSounds.sampleRate < TargetProximity.interval(forDistance: 0),
                     "Approach taps must fit within the fastest repeat interval")

        let roomSend = 1 + GuidanceSounds.earlyReflections + GuidanceSounds.lateReverb
        let peak = sounds.flatMap { $0.1 }.map { abs($0) }.max()!
        precondition(Double(peak) * roomSend * 2 < 0.75,
                     "Two coincident dry/reflected peaks should still retain mixing headroom")
        let curve = GuidanceSounds.distanceGains
        for point in curve { precondition((0...1).contains(point.y), "Distance attenuation must never amplify") }
        for (before, after) in zip(curve, curve.dropFirst()) {
            precondition(after.x > before.x && after.y <= before.y, "Distance gain must decline continuously")
        }
        var timing = GuidanceCueTiming()
        let beepLength = Double(GuidanceSounds.pulse.count) / GuidanceSounds.sampleRate
        let pairLength = Double(GuidanceSounds.onObject.count) / GuidanceSounds.sampleRate
        precondition(timing.start(at: 0, duration: beepLength))
        precondition(!timing.start(at: 0.02, duration: pairLength), "Entering the close zone cannot stack notes")
        precondition(timing.start(at: 0.09, duration: pairLength), "Retry the close cue when the previous note has finished")
        precondition(!timing.start(at: 0.20, duration: beepLength), "A mode change cannot interrupt the two-note cue")
        precondition(timing.start(at: 0.27, duration: beepLength))
        timing.reset()
        precondition(timing.start(at: 0.28, duration: beepLength), "Stop/reset must release the timing gate")

        var motion = GuidanceListenerMotion()
        precondition(motion.update(towards: .zero, at: 0) == .zero)
        let step = motion.update(towards: SIMD3(1, 0, 0), at: 0.02)!
        precondition(step.x > 0 && step.x < 0.3, "A live position update must not jump the audio listener")
        var settled = step
        for i in 2...30 { settled = motion.update(towards: SIMD3(1, 0, 0), at: Double(i) * 0.02)! }
        precondition(settled.x > 0.99 && settled.x <= 1, "Audio position converges without overshoot")
        precondition(motion.update(towards: SIMD3(.nan, 0, 0), at: 0.7) == settled, "Invalid poses cannot enter the audio scene")

        let facing = SIMD3<Float>(0, 0, -1)
        let listener = GuidanceListenerGeometry.position(camera: camera(position: position, yaw: 0),
                                                          calibratedForward: facing, soundHeight: 0)!
        for yaw: Float in [0, 0.5, 1.5, .pi] {
            precondition(GuidanceListenerGeometry.position(camera: camera(position: position, yaw: yaw),
                           calibratedForward: facing, soundHeight: 0) == listener,
                         "Turning the phone cannot slide the virtual listener around the object")
        }
        let movement = SIMD3<Float>(0.5, 0.1, -0.2)
        let movedListener = GuidanceListenerGeometry.position(camera: camera(position: position + movement, yaw: 1),
                                                              calibratedForward: facing, soundHeight: 0)!
        precondition(simd_distance(movedListener - listener, movement) < 0.0001,
                     "Close approach and sideways movement must move the listener, never leave it anchored")
        precondition(abs(listener.y - position.y - 0.45) < 0.0001 && abs(listener.z - position.z - 0.3) < 0.0001,
                     "Audio originates from the estimated ears, not the camera lens")
        let raised = GuidanceListenerGeometry.position(camera: camera(position: position, yaw: 0),
                                                       calibratedForward: facing, soundHeight: 0.2)!
        precondition(abs(listener.y - raised.y - 0.2) < 0.0001, "Keep the sound-height preference")
        precondition(GuidanceListenerGeometry.position(camera: camera(position: SIMD3(.nan, 0, 0), yaw: 0),
                         calibratedForward: facing, soundHeight: 0) == nil)
        precondition(GuidanceListenerGeometry.position(camera: matrix_identity_float4x4,
                         calibratedForward: .zero, soundHeight: 0) == nil)

        let distances: [Float] = [1.5, 1.3, 1.2, 0.8, 0.4, 0.2, 0.1, 0.05]
        let haptics = distances.map { TargetProximity.hapticPulse(forDistance: $0)! }
        for (far, near) in zip(haptics, haptics.dropFirst()) {
            precondition(near.intensity > far.intensity && near.interval < far.interval,
                         "Vibrations must grow stronger and faster as the phone gets closer")
        }
        precondition(haptics.last!.intensity == 1 && haptics.last!.interval >= 0.13,
                     "Final positioning gets full intensity with distinct pulses")
        precondition(haptics.allSatisfy { $0.duration < $0.interval && (0...1).contains($0.intensity) })
        precondition(TargetProximity.hapticPulse(forDistance: 2) == nil)
        precondition(TargetProximity.hapticPulse(forDistance: 1.51) == nil)
        precondition(TargetProximity.hapticPulse(forDistance: -0.1) == nil)
        precondition(TargetProximity.hapticPulse(forDistance: .nan) == nil)
        print("Guidance: proximity, audio headroom/timing, live world positioning and earlier progressive haptics passed")

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
