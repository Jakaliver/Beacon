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
    private let queue = DispatchQueue(label: "trident.ar", qos: .userInteractive)
    private let encodeQueue = DispatchQueue(label: "trident.encode", qos: .userInitiated)
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
    private var encoding = false
    private var pending: (pixels: CVPixelBuffer, header: [String: Any])?

    private static func newSessionID() -> String { String(UInt32.random(in: 0...UInt32.max), radix: 16) }

    private var configuration: ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
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
            self.session.run(self.configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func newSensorSession() {
        queue.async {
            self.sessionID = Self.newSessionID()
            self.frameSeq = 0
            self.poseSeq = 0
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let (tracking, reason) = Self.describe(camera.trackingState)
        let pose = Self.columnMajor(camera.transform)
        let t = frame.timestamp

        if t - lastPoseT >= 1.0 / 30 - 0.002 {
            lastPoseT = t
            poseSeq += 1
            let message: [String: Any] = [
                "v": 1, "type": "pose", "session": sessionID, "epoch": epoch, "seq": poseSeq, "t": t,
                "pose": pose, "tracking": tracking, "tracking_reason": reason ?? NSNull(),
                "head": NSNull(), "floor_y": Self.floorY(frame) ?? NSNull(),
            ]
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

    /// World y of the lowest horizontal plane larger than 1 m².
    private static func floorY(_ frame: ARFrame) -> Float? {
        frame.anchors
            .compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal && $0.planeExtent.width * $0.planeExtent.height > 1 }
            .map { $0.transform.columns.3.y }
            .min()
    }
}
