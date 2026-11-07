import AVFoundation
import CoreMotion
import PHASE
import simd

/// Spatial guidance sounds, rendered with PHASE (Apple's Physical Audio Spatialization Engine): each sound
/// has a direct path, early reflections and a late reverb tail in a room model, plus geometric distance
/// spreading. Positions are ARKit world coordinates; ARKit and PHASE are both right-handed, +Y up, −Z forward.
///
/// Head tracking: Apple's automatic head tracking needs the Head Pose capability, which personal (free)
/// development teams cannot sign. So the listener is rotated from AirPods motion (CMHeadphoneMotionManager)
/// instead, never together with the automatic mode. The headphones' orientation is not assumed to be in ARKit
/// coordinates: Calibrate stores the head attitude while the user faces where the phone points, and later
/// head turns are applied relative to that.
final class AudioGuide {
    /// Paid developer teams: set true and restore the Head Pose entitlement in project.yml.
    static let automaticHeadTracking = false

    /// For the status line: whether AirPods head motion is arriving.
    private(set) var headTrackingLive = false

    private let engine = PHASEEngine(updateMode: .automatic)
    private let listener: PHASEListener
    private let targetSource: PHASESource
    private let beaconSource: PHASESource
    private let cueSource: PHASESource
    private var running = false
    private var playing: [PHASESoundEvent] = []
    private var mixerIDs: [String: String] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private let headMotion = CMHeadphoneMotionManager()
    // Head motion arrives on its own high-priority queue, not the busy main thread, to cut delay and
    // jitter. `headLock` guards the listener state shared with the main thread.
    private let headQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let headLock = NSLock()
    private var headReference: CMAttitude?
    private var latestHead: CMAttitude?
    private var baseForward = SIMD3<Float>(0, 0, -1)
    private var listenerPosition = SIMD3<Float>(0, 0, 0)
    private var listenerForward = SIMD3<Float>(0, 0, -1)
    private var listenerUp = SIMD3<Float>(0, 1, 0)

    init() {
        engine.defaultReverbPreset = .mediumRoom
        listener = PHASEListener(engine: engine)
        targetSource = PHASESource(engine: engine)
        beaconSource = PHASESource(engine: engine)
        cueSource = PHASESource(engine: engine)
        for object in [listener, targetSource, beaconSource, cueSource] as [PHASEObject] {
            try? engine.rootObject.addChild(object)
        }
        if Self.automaticHeadTracking, #available(iOS 18.0, *) {
            listener.automaticHeadTrackingFlags = .orientation
        }
        // Beeps with soft harmonics: a pure sine cannot be placed in space; harmonics give the ear direction cues.
        register("pulse", Self.beep(hz: 520, seconds: 0.1))
        register("confirm", Self.beep(hz: 520, seconds: 0.1) + Self.silence(0.05) + Self.beep(hz: 520, seconds: 0.1))
        register("beacon", Self.beep(hz: 380, seconds: 0.16))
        register("stop", Self.tone([(660, 0.1), (440, 0.18)], harmonic: 0.2))
        register("rescan", Self.tone([(700, 0.06), (0, 0.05), (700, 0.06)], harmonic: 0.2))
        headLock.withLock { updateListener() }
    }

    /// One PHASE sound event per sound: sampler → spatial mixer with direct path, early reflections and late reverb.
    private func register(_ name: String, _ samples: [Float]) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = try? engine.assetRegistry.registerSoundAsset(data: data, identifier: name, format: format,
                                                         normalizationMode: .dynamic)
        guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission, .earlyReflections, .lateReverb])
        else { return }
        pipeline.entries[PHASESpatialCategory.earlyReflections]?.sendLevel = 0.6
        pipeline.entries[PHASESpatialCategory.lateReverb]?.sendLevel = 0.3
        let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline, identifier: "\(name)-mixer")
        let distance = PHASEGeometricSpreadingDistanceModelParameters()
        distance.rolloffFactor = 1.0
        distance.fadeOutParameters = PHASEDistanceModelFadeOutParameters(cullDistance: 20)
        mixer.distanceModelParameters = distance
        let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: name, mixerDefinition: mixer)
        sampler.playbackMode = .oneShot
        sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
        _ = try? engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: "\(name)-event")
        mixerIDs[name] = mixer.identifier
    }

    func start() {
        ensureRunning()
        if !Self.automaticHeadTracking { startHeadTracking() }
    }

    func restart() {
        engine.stop()
        running = false
        start()
    }

    /// The engine can fail to start (app launched in the background) or stop (route or interruption
    /// changes). Recover before playing, or every guidance sound is silently lost while speech still works.
    private func ensureRunning() {
        guard !running else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        running = (try? engine.start()) != nil
    }

    func silence() {
        playing.forEach { $0.stopAndInvalidate() }
        playing.removeAll()
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

    /// Listener orientation = calibrated world forward, turned and tilted by the head since calibration.
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
        listenerForward = flat * cos(pitch) + worldUp * sin(pitch)
        listenerUp = worldUp * cos(pitch) - flat * sin(pitch)
        updateListener()
    }

    /// Call with `headLock` held.
    private func updateListener() {
        let f = simd_normalize(listenerForward)
        let right = simd_normalize(simd_cross(f, listenerUp))
        let up = simd_cross(right, f)
        listener.transform = simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-f, 0),
                                                     SIMD4(listenerPosition, 1)))
    }

    /// `position` is the body estimate at phone height; the ears are higher, so a table-top target sounds below.
    func setListener(_ position: SIMD3<Float>) {
        headLock.withLock {
            listenerPosition = position + SIMD3<Float>(0, 0.3, 0)
            updateListener()
        }
    }

    /// Call while the user faces where the phone points: that world direction becomes "ahead".
    func setForward(_ forward: SIMD3<Float>) {
        headLock.withLock {
            baseForward = forward
            headReference = latestHead?.copy() as? CMAttitude
            applyHead()
        }
    }

    func beaconPing(at position: SIMD3<Float>) { play("beacon", from: beaconSource, at: position) }

    /// Hot/cold pulses come from the estimated target position, so the user hears where it is.
    /// Without a position they come from just in front of the listener.
    func pulse(at position: SIMD3<Float>?) { play("pulse", from: targetSource, at: position) }
    func confirm(at position: SIMD3<Float>?) { play("confirm", from: targetSource, at: position) }

    func cue(_ name: String) {
        switch name {
        case "stop": silence(); play(name, from: cueSource, at: nil)
        case "rescan": play(name, from: cueSource, at: nil)
        default: break
        }
    }

    private func play(_ name: String, from source: PHASESource, at position: SIMD3<Float>?) {
        ensureRunning()
        guard running, let mixerID = mixerIDs[name] else { return }
        let p = position ?? headLock.withLock { listenerPosition + simd_normalize(listenerForward) * 0.6 }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(p, 1)
        source.transform = transform
        let parameters = PHASEMixerParameters()
        parameters.addSpatialMixerParameters(identifier: mixerID, source: source, listener: listener)
        guard let event = try? PHASESoundEvent(engine: engine, assetIdentifier: "\(name)-event",
                                               mixerParameters: parameters) else { return }
        playing.removeAll { $0.renderingState == .stopped }
        playing.append(event)
        event.start(completion: nil)
    }

    // MARK: Sounds (mono, 44.1 kHz float)

    private static let rate = 44_100.0

    /// A rounded beep: fundamental plus decaying harmonics up to ~8 kHz, smooth attack and release.
    private static func beep(hz: Double, seconds: Double) -> [Float] {
        let n = Int(seconds * rate)
        let harmonics = (1...8).filter { Double($0) * hz < 8_000 }
        return (0..<n).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for k in harmonics { v += sin(2 * .pi * hz * Double(k) * t) / Double(k * k) * (k == 1 ? 1 : 1.6) }
            let envelope = min(1, t / 0.006, (seconds - t) / 0.025)
            return Float(0.4 * envelope * v)
        }
    }

    private static func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * rate)) }

    /// Tone sequence; a frequency of 0 is silence. `harmonic` adds a second partial for a softer timbre.
    private static func tone(_ segments: [(hz: Double, seconds: Double)], harmonic: Float) -> [Float] {
        segments.flatMap { hz, seconds -> [Float] in
            let n = Int(seconds * rate)
            return (0..<n).map { j in
                guard hz > 0 else { return 0 }
                let phase = 2 * Double.pi * hz * Double(j) / rate
                let envelope = Float(min(1, Double(j) / (0.004 * rate), Double(n - j) / (0.012 * rate)))
                let wave = Float(sin(phase)) + harmonic * Float(sin(2 * phase))
                return 0.5 * envelope * wave / (1 + harmonic)
            }
        }
    }
}
