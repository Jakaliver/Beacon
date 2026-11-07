import AVFoundation
import CoreMotion
import simd

/// Spatial guidance sounds. Positions are ARKit world coordinates; both frames are right-handed, +Y up, −Z forward.
///
/// Head tracking: Apple's automatic listener head tracking needs the Head Pose capability, which
/// personal (free) development teams cannot sign. So the listener is rotated from AirPods motion
/// (CMHeadphoneMotionManager) instead, never together with the automatic mode. The headphones'
/// orientation is not assumed to be in ARKit coordinates: Calibrate stores the head attitude while the
/// user faces where the phone points, and later head turns are applied relative to that.
final class AudioGuide {
    private let headMotion = CMHeadphoneMotionManager()
    private var headReference: CMAttitude?
    private var latestHead: CMAttitude?
    private var baseForward = SIMD3<Float>(0, 0, -1)
    /// Paid developer teams: set true and restore the Head Pose entitlement in project.yml.
    static let automaticHeadTracking = false
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let beacon = AVAudioPlayerNode()
    private let probe = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private lazy var beaconBuffer = tone([(520, 0.14), (780, 0.06)], harmonic: 0.5)
    private lazy var pulseBuffer = tone([(1400, 0.035)], harmonic: 0)
    private lazy var confirmBuffer = tone([(880, 0.09), (1320, 0.14)], harmonic: 0.2)
    private lazy var stopBuffer = tone([(660, 0.1), (440, 0.18)], harmonic: 0.2)
    private lazy var rescanBuffer = tone([(700, 0.06), (0, 0.05), (700, 0.06)], harmonic: 0.2)

    init() {
        engine.attach(environment)
        for player in [beacon, probe] {
            engine.attach(player)
            engine.connect(player, to: environment, format: format)
        }
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        let hq = AVAudio3DMixingRenderingAlgorithm.HRTFHQ
        let algorithm = environment.applicableRenderingAlgorithms.contains(NSNumber(value: hq.rawValue)) ? hq : .auto
        for player in [beacon, probe] {
            player.renderingAlgorithm = algorithm
            player.sourceMode = .pointSource
            player.pointSourceInHeadMode = .bypass
        }
        environment.isListenerHeadTrackingEnabled = Self.automaticHeadTracking
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.rolloffFactor = 0.5
    }

    func start() {
        guard !engine.isRunning else { return }
        try? engine.start()
        beacon.play()
        probe.play()
        if !Self.automaticHeadTracking { startHeadTracking() }
    }

    private func startHeadTracking() {
        guard headMotion.isDeviceMotionAvailable, !headMotion.isDeviceMotionActive else { return }
        headMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            self.latestHead = attitude
            if self.headReference == nil { self.headReference = attitude.copy() as? CMAttitude }
            self.applyHead()
        }
    }

    /// Listener forward = calibrated world forward, turned by the head's yaw since calibration.
    private func applyHead() {
        var yaw: Float = 0
        if let head = latestHead?.copy() as? CMAttitude, let reference = headReference {
            head.multiply(byInverseOf: reference)
            yaw = Float(head.yaw) * (UserDefaults.standard.bool(forKey: Settings.reverseHeadTurnKey) ? -1 : 1)
        }
        // Rotation about +Y: a positive yaw (turn left) swings forward towards −X.
        let c = cos(yaw), s = sin(yaw)
        let f = SIMD3<Float>(baseForward.x * c + baseForward.z * s, 0, -baseForward.x * s + baseForward.z * c)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: f.x, y: 0, z: f.z), up: AVAudio3DVector(x: 0, y: 1, z: 0))
    }

    func restart() {
        engine.stop()
        start()
    }

    func silence() {
        beacon.stop()
        probe.stop()
        if engine.isRunning {
            beacon.play()
            probe.play()
        }
    }

    func setListener(_ position: SIMD3<Float>) {
        environment.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
    }

    /// Call while the user faces where the phone points: that world direction becomes "ahead".
    func setForward(_ forward: SIMD3<Float>) {
        baseForward = forward
        headReference = latestHead?.copy() as? CMAttitude
        applyHead()
    }

    func beaconPing(at position: SIMD3<Float>) {
        beacon.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        play(beaconBuffer, on: beacon)
    }

    /// Hot/cold pulses come from the estimated target position, so the user hears where it is.
    /// Without a position they fall back to the listener (centred).
    func pulse(at position: SIMD3<Float>?) { playAt(position, pulseBuffer) }
    func confirm(at position: SIMD3<Float>?) { playAt(position, confirmBuffer) }

    private func playAt(_ position: SIMD3<Float>?, _ buffer: AVAudioPCMBuffer) {
        guard let p = position else { return playCentred(buffer) }
        probe.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
        play(buffer, on: probe)
    }

    func cue(_ name: String) {
        switch name {
        case "stop": silence(); playCentred(stopBuffer)
        case "rescan": playCentred(rescanBuffer)
        default: break
        }
    }

    private func playCentred(_ buffer: AVAudioPCMBuffer) {
        probe.position = environment.listenerPosition
        play(buffer, on: probe)
    }

    private func play(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// Mono tone sequence; a frequency of 0 is silence. `harmonic` adds a second partial for a softer timbre.
    private func tone(_ segments: [(hz: Double, seconds: Double)], harmonic: Float) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let total = segments.reduce(0) { $0 + Int($1.seconds * rate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        var i = 0
        for (hz, seconds) in segments {
            let n = Int(seconds * rate)
            for j in 0..<n {
                let phase = 2 * Double.pi * hz * Double(j) / rate
                let envelope = Float(min(1, Double(j) / (0.004 * rate), Double(n - j) / (0.012 * rate)))
                let wave = Float(sin(phase)) + harmonic * Float(sin(2 * phase))
                samples[i] = hz == 0 ? 0 : 0.5 * envelope * wave / (1 + harmonic)
                i += 1
            }
        }
        return buffer
    }
}
