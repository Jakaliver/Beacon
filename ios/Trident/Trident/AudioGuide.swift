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
    // Head motion arrives on its own high-priority queue, not the busy main thread, to cut delay and
    // jitter. `headLock` guards the state shared with the main thread (setForward).
    private let headQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let headLock = NSLock()
    /// For the status line: whether AirPods head motion is arriving.
    private(set) var headTrackingLive = false
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

    // Beeps with soft harmonics: a pure sine cannot be placed in space; harmonics give the ear direction cues.
    private lazy var beaconBuffer = beep(hz: 660, seconds: 0.16)
    private lazy var pulseBuffer = beep(hz: 1000, seconds: 0.09)
    private lazy var confirmBuffer = sequence([beep(hz: 1000, seconds: 0.09), beep(hz: 1000, seconds: 0.09)])
    private lazy var stopBuffer = tone([(660, 0.1), (440, 0.18)], harmonic: 0.2)
    private lazy var rescanBuffer = tone([(700, 0.06), (0, 0.05), (700, 0.06)], harmonic: 0.2)

    init() {
        engine.attach(environment)
        for player in [beacon, probe] {
            engine.attach(player)
            engine.connect(player, to: environment, format: format)
        }
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        // .auto: Apple's highest-quality renderer for the current hardware (newer than HRTFHQ on AirPods).
        for player in [beacon, probe] {
            player.renderingAlgorithm = .auto
            player.sourceMode = .pointSource
            player.pointSourceInHeadMode = .bypass
            player.reverbBlend = 0.2
        }
        // A little room reverb moves binaural sound out of the head and into the room.
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        environment.reverbParameters.level = -8
        environment.isListenerHeadTrackingEnabled = Self.automaticHeadTracking
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 0.5
        environment.distanceAttenuationParameters.maximumDistance = 10
        environment.distanceAttenuationParameters.rolloffFactor = 1.2
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
        headMotion.startDeviceMotionUpdates(to: headQueue) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            self.headLock.withLock {
                self.latestHead = attitude
                self.headTrackingLive = true
                if self.headReference == nil { self.headReference = attitude.copy() as? CMAttitude }
                self.applyHead()
            }
        }
    }

    /// Listener forward = calibrated world forward, turned by the head's yaw since calibration.
    private func applyHead() {
        var yaw: Float = 0, pitch: Float = 0
        if let head = latestHead?.copy() as? CMAttitude, let reference = headReference {
            head.multiply(byInverseOf: reference)
            let defaults = UserDefaults.standard
            yaw = Float(head.yaw) * (defaults.bool(forKey: Settings.reverseHeadTurnKey) ? -1 : 1)
            pitch = Float(head.pitch) * (defaults.bool(forKey: Settings.reverseHeadTiltKey) ? -1 : 1)
        }
        // Turn: rotation about +Y; a positive yaw (turn left) swings forward towards −X.
        let c = cos(yaw), s = sin(yaw)
        let flat = SIMD3<Float>(baseForward.x * c + baseForward.z * s, 0, -baseForward.x * s + baseForward.z * c)
        // Tilt: a positive pitch (look up) lifts forward towards +Y and tips "up" backwards.
        let worldUp = SIMD3<Float>(0, 1, 0)
        let f = flat * cos(pitch) + worldUp * sin(pitch)
        let u = worldUp * cos(pitch) - flat * sin(pitch)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: f.x, y: f.y, z: f.z), up: AVAudio3DVector(x: u.x, y: u.y, z: u.z))
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

    /// `position` is the body estimate at phone height; the ears are higher, so a table-top target sounds below.
    func setListener(_ position: SIMD3<Float>) {
        environment.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y + 0.3, z: position.z)
    }

    /// Call while the user faces where the phone points: that world direction becomes "ahead".
    func setForward(_ forward: SIMD3<Float>) {
        headLock.withLock {
            baseForward = forward
            headReference = latestHead?.copy() as? CMAttitude
            applyHead()
        }
    }

    func beaconPing(at position: SIMD3<Float>) {
        place(beacon, at: position)
        play(beaconBuffer, on: beacon)
    }

    /// Positions a source. Echo grows with distance (the direct-to-reverberant ratio), which is how
    /// the ear judges how far away a real sound is.
    private func place(_ player: AVAudioPlayerNode, at p: SIMD3<Float>) {
        player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
        let l = environment.listenerPosition
        let d = simd_distance(p, SIMD3<Float>(l.x, l.y, l.z))
        player.reverbBlend = min(0.5, max(0.08, 0.06 + 0.12 * d))
    }

    /// Hot/cold pulses come from the estimated target position, so the user hears where it is.
    /// Without a position they fall back to the listener (centred).
    func pulse(at position: SIMD3<Float>?) { playAt(position, pulseBuffer) }
    func confirm(at position: SIMD3<Float>?) { playAt(position, confirmBuffer) }

    private func playAt(_ position: SIMD3<Float>?, _ buffer: AVAudioPCMBuffer) {
        guard let p = position else { return playCentred(buffer) }
        place(probe, at: p)
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
        // The engine can fail to start (app launched in the background) or stop (route or interruption
        // changes). Recover here, or every guidance sound is silently lost while speech still works.
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            start()
            guard engine.isRunning else { return }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// A rounded beep: fundamental plus decaying harmonics up to ~8 kHz, smooth attack and release.
    private func beep(hz: Double, seconds: Double) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let n = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let out = buffer.floatChannelData![0]
        let harmonics = (1...8).filter { Double($0) * hz < 8_000 }
        for i in 0..<n {
            let t = Double(i) / rate
            var v = 0.0
            for k in harmonics { v += sin(2 * .pi * hz * Double(k) * t) / Double(k * k) * (k == 1 ? 1 : 1.6) }
            let envelope = min(1, t / 0.006, (seconds - t) / 0.025)
            out[i] = Float(0.4 * envelope * v)
        }
        return buffer
    }

    private func sequence(_ parts: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer {
        let gap = Int(0.05 * format.sampleRate)
        let total = parts.reduce(0) { $0 + Int($1.frameLength) + gap }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let out = buffer.floatChannelData![0]
        var i = 0
        for p in parts {
            let src = p.floatChannelData![0]
            for j in 0..<Int(p.frameLength) { out[i + j] = src[j] }
            i += Int(p.frameLength)
            for j in 0..<gap { out[i + j] = 0 }
            i += gap
        }
        return buffer
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
