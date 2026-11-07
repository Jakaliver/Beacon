import simd

/// Probe-mode feedback: the phone's camera axis is a torch beam. The beep's pitch says whether the beam
/// is on the object, its rate says how near the phone is. Pointing feedback by aim error, rather than by
/// distance alone, is what lets blind users home in on a target (smartphone pointing studies, AIDEN).
struct Torch {
    enum Aim: Int, Comparable {
        case off, near, on
        static func < (a: Aim, b: Aim) -> Bool { a.rawValue < b.rawValue }
    }

    struct Output: Equatable {
        let aim: Aim
        let distance: Float
        let interval: Double
    }

    private(set) var aim = Aim.off
    private var smoothedDistance: Float?

    /// `camera` is the ARKit camera-to-world transform (it looks along −Z). `extent` is the object's
    /// largest size and `surface` its sampled surface points, all in world metres.
    mutating func update(camera: simd_float4x4, centre: SIMD3<Float>, extent: Float,
                         surface: [SIMD3<Float>]) -> Output {
        let origin = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = -simd_normalize(SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
        let toCentre = centre - origin
        let range = max(simd_length(toCentre), 0.05)
        let angle = acos(min(1, max(-1, simd_dot(forward, toCentre / range))))
        // The object's own angular radius: a door needs less precise aim than a light switch.
        let radius = atan(max(extent, 0.02) / 2 / range)
        // Leaving a cone takes 30% more error than entering it, so the pitch does not flicker at an edge.
        func inside(_ cone: Float, _ level: Aim) -> Bool { angle < cone * (aim >= level ? 1.3 : 1) }
        aim = inside(radius + 0.10, .on) ? .on : inside(radius + 0.35, .near) ? .near : .off

        let nearest = surface.map { simd_distance(origin, $0) }.min() ?? range
        let distance = smoothedDistance.map { $0 + 0.4 * (nearest - $0) } ?? nearest
        smoothedDistance = distance
        return Output(aim: aim, distance: distance, interval: Self.interval(forDistance: distance))
    }

    mutating func reset() {
        aim = .off
        smoothedDistance = nil
    }

    /// 0.07 s at 10 cm to 0.6 s at 1 m and beyond: the whole range lies within arm's reach.
    static func interval(forDistance d: Float) -> Double {
        let near = 0.1, far = 1.0, fastest = 0.07, slowest = 0.6
        let u = (min(max(Double(d), near), far) - near) / (far - near)
        return fastest * pow(slowest / fastest, u)
    }
}
