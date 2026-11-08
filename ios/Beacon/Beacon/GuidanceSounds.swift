import Foundation
import simd

/// One clean beep timbre throughout; the close cue pairs two short, rising notes.
/// PHASE supplies the room reflections and spatial position during playback.
enum GuidanceSounds {
    static let sampleRate = 44_100.0
    // Leave more than 12 dB of sample headroom before spatialization and room tails.
    static let peak: Float = 0.24
    static let earlyReflections = 0.32
    static let lateReverb = 0.22
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
        let count = Int(0.065 * sampleRate)
        let samples = (0..<count).map { i -> Float in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * hz * t
            let attack = sin(.pi / 2 * min(1, t / 0.003))
            let release = sin(.pi / 2 * min(1, Double(count - 1 - i) / (sampleRate * 0.012)))
            let envelope = attack * attack * release * release * exp(-t / 0.045)
            let partials = 0.22 * sin(2 * phase) + 0.12 * sin(3 * phase)
                + 0.075 * sin(4 * phase) + 0.04 * sin(5 * phase) + 0.02 * sin(6 * phase)
            let tone = sin(phase) + partials * exp(-t / 0.035)
            return Float(tone * envelope)
        }
        let sourcePeak = samples.map { abs($0) }.max() ?? 1
        return samples.map { $0 * (peak / max(sourcePeak, 0.0001)) }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }
}

/// A thin acoustic slab. Its local X/Z axes span the surface and +Y is its
/// inward-facing normal; thickness extends away from the room interior.
struct GuidanceAcousticSurface {
    enum Kind { case wall, floor, ceiling }
    let kind: Kind
    let transform: simd_float4x4
    let size: SIMD3<Float>

    init?(kind: Kind, anchor: simd_float4x4, centre: SIMD3<Float>,
          extent: SIMD2<Float>, rotation: Float) {
        let values = [anchor.columns.0, anchor.columns.1, anchor.columns.2, anchor.columns.3,
                      SIMD4(centre, rotation), SIMD4(extent.x, extent.y, 0, 0)]
        guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }),
              extent.x >= 0.4, extent.y >= 0.4, extent.x * extent.y >= 0.75,
              extent.x <= 20, extent.y <= 20 else { return nil }
        self.kind = kind
        size = SIMD3((extent.x * 5).rounded() / 5, 0.02, (extent.y * 5).rounded() / 5)
        var local = simd_float4x4(simd_quatf(angle: rotation, axis: SIMD3(0, 1, 0)))
        // Put the slab behind its face rather than inside the room.
        local.columns.3 = SIMD4(centre - SIMD3(0, 0.01, 0), 1)
        transform = anchor * local
    }
}

/// An intentionally assumed, moderately large room. Anchor it once per AR world,
/// so the reflections stay put when the listener moves or recalibrates heading.
enum GuidanceRoomAcoustics {
    static let dimensions = SIMD3<Float>(7, 3, 9)

    static func surfaces(around listener: SIMD3<Float>) -> [GuidanceAcousticSurface] {
        guard listener.x.isFinite, listener.y.isFinite, listener.z.isFinite else { return [] }
        let floor = listener.y - 1.6
        let centre = SIMD3(listener.x, floor + dimensions.y / 2, listener.z)
        func slab(_ kind: GuidanceAcousticSurface.Kind, at position: SIMD3<Float>,
                  axis: SIMD3<Float>, angle: Float, extent: SIMD2<Float>) -> GuidanceAcousticSurface? {
            var anchor = simd_float4x4(simd_quatf(angle: angle, axis: axis))
            anchor.columns.3 = SIMD4(position, 1)
            return GuidanceAcousticSurface(kind: kind, anchor: anchor,
                                            centre: .zero, extent: extent, rotation: 0)
        }
        return [
            slab(.floor, at: SIMD3(centre.x, floor, centre.z), axis: SIMD3(1, 0, 0), angle: 0,
                 extent: SIMD2(dimensions.x, dimensions.z)),
            slab(.ceiling, at: SIMD3(centre.x, floor + dimensions.y, centre.z), axis: SIMD3(1, 0, 0), angle: .pi,
                 extent: SIMD2(dimensions.x, dimensions.z)),
            slab(.wall, at: centre + SIMD3(-dimensions.x / 2, 0, 0), axis: SIMD3(0, 0, 1), angle: -.pi / 2,
                 extent: SIMD2(dimensions.y, dimensions.z)),
            slab(.wall, at: centre + SIMD3(dimensions.x / 2, 0, 0), axis: SIMD3(0, 0, 1), angle: .pi / 2,
                 extent: SIMD2(dimensions.y, dimensions.z)),
            slab(.wall, at: centre + SIMD3(0, 0, -dimensions.z / 2), axis: SIMD3(1, 0, 0), angle: .pi / 2,
                 extent: SIMD2(dimensions.x, dimensions.y)),
            slab(.wall, at: centre + SIMD3(0, 0, dimensions.z / 2), axis: SIMD3(1, 0, 0), angle: -.pi / 2,
                 extent: SIMD2(dimensions.x, dimensions.y)),
        ].compactMap { $0 }
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
