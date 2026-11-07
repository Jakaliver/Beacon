import Foundation
import simd

/// Standalone checks for probe-mode torch feedback.
@main
struct TorchTests {
    static func camera(at p: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        // Rotation about +Y; yaw 0 looks along −Z.
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(p, 1)))
    }

    static func check(_ ok: Bool, _ message: String) {
        if !ok { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
        let bottle = SIMD3<Float>(0, 0, -0.5)
        let surface = [bottle + SIMD3(0, 0, 0.04), bottle - SIMD3(0, 0, 0.04)]
        var torch = Torch()
        let aimed = torch.update(camera: camera(at: .zero, yaw: 0), centre: bottle, extent: 0.08, surface: surface)
        check(aimed.aim == .on, "pointing straight at the bottle is on target")
        check(abs(aimed.distance - 0.46) < 0.001, "distance is to the nearest surface point")

        torch.reset()
        check(torch.update(camera: camera(at: .zero, yaw: 0.3), centre: bottle, extent: 0.08, surface: surface).aim == .near,
              "17 degrees off is near")
        torch.reset()
        check(torch.update(camera: camera(at: .zero, yaw: 1.0), centre: bottle, extent: 0.08, surface: surface).aim == .off,
              "57 degrees off is off")

        // Hysteresis: 12 degrees is outside the on cone when entering, but holds an existing lock.
        torch.reset()
        _ = torch.update(camera: camera(at: .zero, yaw: 0), centre: bottle, extent: 0.08, surface: surface)
        check(torch.update(camera: camera(at: .zero, yaw: 0.21), centre: bottle, extent: 0.08, surface: surface).aim == .on,
              "a small wobble keeps the lock")
        torch.reset()
        check(torch.update(camera: camera(at: .zero, yaw: 0.21), centre: bottle, extent: 0.08, surface: surface).aim == .near,
              "the same angle does not enter the lock")

        // A 0.9 m door at 1 m is on target even 25 degrees off its centre.
        torch.reset()
        let door = SIMD3<Float>(0, 0, -1)
        check(torch.update(camera: camera(at: .zero, yaw: 0.44), centre: door, extent: 0.9, surface: [door]).aim == .on,
              "large objects have a wider cone")

        check(Torch.interval(forDistance: 0.05) == 0.07 && abs(Torch.interval(forDistance: 2) - 0.6) < 1e-9,
              "interval spans arm's reach")
        check(Torch.interval(forDistance: 0.3) < Torch.interval(forDistance: 0.6) * 0.7,
              "30 cm and 60 cm sound clearly different")
        print("torch ok")
    }
}
