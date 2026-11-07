import ARKit
import CoreImage
import ImageIO

struct PoseSample {
    let transform: simd_float4x4
    let tracking: String
    let epoch: Int
}

/// Runs ARKit on its own queue and streams poses and JPEG frames to `/ws/sensor`.
final class ARSensor: NSObject, ARSessionDelegate {
    static let outputWidth = 640
    static let outputHeight = 480

    var link: Connection?
    var onPose: ((PoseSample) -> Void)?

    private let session = ARSession()
    private let queue = DispatchQueue(label: "beacon.ar", qos: .userInteractive)
    private let encodeQueue = DispatchQueue(label: "beacon.encode", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Owned by `queue`.
    private var frameInterval = 0.1
    private var epoch = 0
    private var sessionID = ARSensor.newSessionID()
    private var frameSeq = 0
    private var poseSeq = 0
    private var lastFrameT = -Double.infinity
    private var lastPoseT = -Double.infinity
    private var lastPlanesT = -Double.infinity
    private var floorEstimate: Float?
    private var floorCandidate: Float?
    private var floorCandidateSince = 0.0
    private var encoding = false
    private var pending: (pixels: CVPixelBuffer, header: [String: Any])?

    private static func newSessionID() -> String { String(UInt32.random(in: 0...UInt32.max), radix: 16) }

    private var configuration: ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        return config
    }

    func start(frameRate: Double) {
        setFrameRate(frameRate)
        session.delegate = self
        session.delegateQueue = queue
        session.run(configuration)
    }

    func resume() { session.run(configuration) }

    func setFrameRate(_ fps: Double) {
        queue.async { self.frameInterval = 1 / max(1, fps) }
    }

    func reset() {
        queue.async {
            self.epoch += 1
            self.floorEstimate = nil
            self.floorCandidate = nil
            self.lastPlanesT = -Double.infinity
            self.session.run(self.configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func newSensorSession() {
        queue.async {
            self.sessionID = Self.newSessionID()
            self.frameSeq = 0
            self.poseSeq = 0
            self.lastPlanesT = -Double.infinity
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let (tracking, reason) = Self.describe(camera.trackingState)
        let pose = Self.columnMajor(camera.transform)
        let t = frame.timestamp

        if t - lastPoseT >= 1.0 / 30 - 0.002 {
            lastPoseT = t
            if tracking == "normal" { updateFloor(frame) }
            poseSeq += 1
            var message: [String: Any] = [
                "v": 1, "type": "pose", "session": sessionID, "epoch": epoch, "seq": poseSeq, "t": t,
                "pose": pose, "tracking": tracking, "tracking_reason": reason ?? NSNull(),
                "head": NSNull(), "floor_y": floorEstimate ?? NSNull(), "floor_source": "arkit",
            ]
            if tracking == "normal", t - lastPlanesT >= 1 {
                lastPlanesT = t
                message["planes"] = Self.planes(frame)
            }
            link?.sendJSON(message)
            let sample = PoseSample(transform: camera.transform, tracking: tracking, epoch: epoch)
            DispatchQueue.main.async { self.onPose?(sample) }
        }

        guard t - lastFrameT >= frameInterval - 0.002, link?.isConnected == true else { return }
        lastFrameT = t
        frameSeq += 1
        let pixels = frame.capturedImage
        let srcW = Float(CVPixelBufferGetWidth(pixels)), srcH = Float(CVPixelBufferGetHeight(pixels))
        let sx = Float(Self.outputWidth) / srcW, sy = Float(Self.outputHeight) / srcH
        let k = camera.intrinsics
        let header: [String: Any] = [
            "v": 1, "type": "frame", "source": "iphone", "session": sessionID, "epoch": epoch,
            "seq": frameSeq, "t": t, "width": Self.outputWidth, "height": Self.outputHeight,
            "intrinsics": [k[0][0] * sx, k[1][1] * sy, k[2][0] * sx, k[2][1] * sy],
            "image_transform": ["rotation_deg": 0, "scale": sx, "crop": [0, 0, Int(srcW), Int(srcH)]],
            "pose": pose, "tracking": tracking, "perception": "real", "injected": NSNull(),
        ]
        if encoding {
            pending = (pixels, header)
        } else {
            encodeAndSend(pixels, header)
        }
    }

    private func encodeAndSend(_ pixels: CVPixelBuffer, _ header: [String: Any]) {
        encoding = true
        encodeQueue.async {
            let message = self.packFrame(pixels, header)
            let finish: (Bool) -> Void = { _ in
                self.queue.async {
                    self.encoding = false
                    if let next = self.pending {
                        self.pending = nil
                        self.encodeAndSend(next.pixels, next.header)
                    }
                }
            }
            guard let message, let link = self.link else { return finish(false) }
            link.send(.data(message), completion: finish)
        }
    }

    private func packFrame(_ pixels: CVPixelBuffer, _ header: [String: Any]) -> Data? {
        let source = CIImage(cvPixelBuffer: pixels)
        let scaleY = CGFloat(Self.outputHeight) / source.extent.height
        let aspect = (CGFloat(Self.outputWidth) / source.extent.width) / scaleY
        let scaled = source
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: aspect])
            .cropped(to: CGRect(x: 0, y: 0, width: Self.outputWidth, height: Self.outputHeight))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = ciContext.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: [quality: 0.6]),
              let json = try? JSONSerialization.data(withJSONObject: header) else { return nil }
        var data = Data(capacity: 4 + json.count + jpeg.count)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(jpeg)
        return data
    }

    func sessionInterruptionEnded(_ session: ARSession) { reset() }

    func session(_ session: ARSession, didFailWithError error: Error) { reset() }

    static func columnMajor(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private static func describe(_ state: ARCamera.TrackingState) -> (String, String?) {
        switch state {
        case .normal: return ("normal", nil)
        case .notAvailable: return ("not_available", nil)
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return ("limited", "excessive_motion")
            case .insufficientFeatures: return ("limited", "insufficient_features")
            case .initializing: return ("limited", "initializing")
            case .relocalizing: return ("limited", "relocalizing")
            @unknown default: return ("limited", "unknown")
            }
        }
    }

    /// Send ARKit's observed plane geometry, in the same world frame as depth and targets.
    private static func planes(_ frame: ARFrame) -> [[String: Any]] {
        let anchors: [ARPlaneAnchor] = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        let nearby = anchors.filter { anchor in
            simd_distance(anchor.transform.columns.3, frame.camera.transform.columns.3) < 8
        }
        let largest = nearby.sorted { a, b in
            a.planeExtent.width * a.planeExtent.height > b.planeExtent.width * b.planeExtent.height
        }
        return largest.prefix(32).compactMap { anchor -> [String: Any]? in
                let geometry = anchor.geometry
                guard geometry.vertices.count >= 3, geometry.vertices.count <= 1024 else { return nil }
                let vertices = geometry.vertices.map { point -> [Float] in
                    let world = anchor.transform * SIMD4<Float>(point, 1)
                    return [world.x, world.y, world.z]
                }
                let kind: String
                switch anchor.classification {
                case .floor: kind = "floor"
                case .wall: kind = "wall"
                case .ceiling: kind = "ceiling"
                case .table: kind = "table"
                case .seat: kind = "seat"
                default: kind = anchor.alignment == .vertical ? "vertical" : "horizontal"
                }
                return ["id": anchor.identifier.uuidString, "kind": kind,
                        "vertices": vertices, "indices": geometry.triangleIndices.map { Int($0) }]
            }
    }

    /// Prefer a classified floor. An unclassified patch must be large, below the
    /// phone, and consistent over time so the first visible tabletop cannot win.
    private func updateFloor(_ frame: ARFrame) {
        let horizontal = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        let classified = horizontal.filter { $0.classification == .floor && $0.planeExtent.width * $0.planeExtent.height > 0.5 }
        let candidates = classified.isEmpty ? horizontal.filter { plane in
            let kind = plane.classification
            return kind != .table && kind != .seat && kind != .ceiling
                && plane.planeExtent.width * plane.planeExtent.height > 2
                && frame.camera.transform.columns.3.y - plane.transform.columns.3.y > 0.65
        } : classified
        guard let height = candidates.map({ $0.transform.columns.3.y }).min() else {
            floorCandidate = nil
            return
        }
        if let estimate = floorEstimate, abs(height - estimate) < 0.1 {
            floorEstimate = estimate * 0.95 + height * 0.05
            return
        }
        if let candidate = floorCandidate, abs(height - candidate) < 0.08 {
            floorCandidate = candidate * 0.9 + height * 0.1
            if frame.timestamp - floorCandidateSince >= (classified.isEmpty ? 1.5 : 0.5) {
                floorEstimate = floorCandidate
            }
        } else {
            floorCandidate = height
            floorCandidateSince = frame.timestamp
        }
    }
}
