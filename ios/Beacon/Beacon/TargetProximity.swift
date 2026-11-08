import simd

/// Proximity depends only on the phone's position, never its viewing direction.
struct TargetProximity {
    struct HapticPulse {
        let intensity: Float
        let sharpness: Float
        let duration: Double
        let interval: Double
    }

    /// A continuous distance gradient, strongest in the last 5 cm. It remains
    /// useful inside the audio's wider close zone for precise final positioning.
    static func hapticPulse(forDistance distance: Float) -> HapticPulse? {
        guard distance.isFinite, distance >= 0, distance <= 1.5 else { return nil }
        let closeness = min(1, max(0, (1.5 - distance) / 1.45))
        return HapticPulse(intensity: 0.25 + 0.75 * closeness,
                           sharpness: 0.3 + 0.4 * closeness,
                           duration: 0.025 + 0.035 * Double(closeness),
                           interval: 0.8 * pow(0.14 / 0.8, Double(closeness)))
    }

    struct Output {
        let interval: Double
        let onObject: Bool
    }

    private var smoothedDistance: Float?
    private var previousInterval: Double?
    private var onObject = false

    mutating func update(distance: Float, threshold: Float) -> Output? {
        guard distance.isFinite, distance >= 0 else { reset(); return nil }
        let smoothed = smoothedDistance.map { $0 + 0.3 * (distance - $0) } ?? distance
        smoothedDistance = smoothed
        let threshold = threshold.isFinite && threshold > 0 ? threshold : 0.2
        onObject = smoothed < threshold * (onObject ? 1.3 : 1)
        let target = Self.interval(forDistance: smoothed)
        let interval: Double
        if let current = previousInterval, abs(target - current) / current < 0.08 { interval = current }
        else { interval = target }
        previousInterval = interval
        return Output(interval: interval, onObject: onObject)
    }

    mutating func reset() { self = Self() }

    static func distance(camera: simd_float4x4, centre: SIMD3<Float>, surface: [SIMD3<Float>]) -> Float? {
        let position = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        guard finite(position) else { return nil }
        if let nearest = surface.filter(finite).map({ simd_distance(position, $0) }).min() { return nearest }
        return finite(centre) ? simd_distance(position, centre) : nil
    }

    /// A calm approach rhythm: 1 s at 3 m, down to 0.22 s near the object.
    static func interval(forDistance distance: Float) -> Double {
        let fraction = (min(max(Double(distance), 0.15), 3) - 0.15) / (3 - 0.15)
        return 0.22 * pow(1 / 0.22, fraction)
    }
}
