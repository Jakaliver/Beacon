import AVFoundation
import CoreMotion
import PHASE
import simd

/// Spatial guidance sounds, rendered with PHASE (Apple's Physical Audio Spatialization Engine): each sound
/// has a direct path and a short diffuse reverb tail, plus geometric distance
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

    /// For the status line: whether AirPods head motion arrived in the last second.
    var headTrackingLive: Bool {
        headLock.withLock { ProcessInfo.processInfo.systemUptime - lastHeadSample < 1 }
    }

    private let engine = PHASEEngine(updateMode: .automatic)
    private let listener: PHASEListener
    private let targetSource: PHASESource
    private let targetLoopSource: PHASESource
    // Natural spreading for the continuous source: about 6 dB per distance doubling.
    private static let rolloff = 1.0
    private let beaconSource: PHASESource
    private let cueSource: PHASESource
    // Events are asynchronous: .stopped also describes an event still preparing.
    // Keep each one alive until its completion callback, never prune by renderingState.
    private var playing: [UUID: PHASESoundEvent] = [:]
    private var prepared: [String: [(UUID, PHASESoundEvent)]] = [:]
    private var preparing: [UUID: (String, PHASESoundEvent)] = [:]
    private var generation = 0
    private var completedSounds = 0
    private var playbackCheckGeneration = 0
    // Continuous guidance has one event, including while it prepares. It never enters the one-shot pools.
    private var targetLoopEvent: PHASESoundEvent?
    private var targetLoopGeneration = 0
    private var targetLoopMixerID: String?
    private var targetLoopAssetIssue: String?
    private var reportedTargetLoopAssetIssue = false
    private var guidanceDucked = false
    private static let targetLoopAsset = "chest_loop"
    private static let targetLoopGain = "chest-loop-gain"
    private var alignment = TargetAlignment()
    var onDiagnostic: ((String) -> Void)?
    private var mixerIDs: [String: String] = [:]
    private var clipDurations: [String: Double] = [:]
    private var cueTiming = GuidanceCueTiming()
    private var lastRecovery = -Double.infinity
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
    private var lastHeadSample = -TimeInterval.infinity
    private var baseForward = SIMD3<Float>(0, 0, -1)
    private var listenerPosition = SIMD3<Float>(0, 0, 0)
    private var listenerTarget: SIMD3<Float>?
    private var listenerMotion = GuidanceListenerMotion()
    private var phonePose: simd_float4x4?
    private var phoneEpoch: Int?
    private var targetPosition: SIMD3<Float>?
    private var waypointPosition: SIMD3<Float>?
    private var targetMotion = GuidanceListenerMotion()
    private var waypointMotion = GuidanceListenerMotion()
    private var listenerForward = SIMD3<Float>(0, 0, -1)
    private var listenerHeading = SIMD3<Float>(0, 0, -1)
    private var listenerUp = SIMD3<Float>(0, 1, 0)

    init() {
        // Explicitly use PHASE's externalizing renderer, including on headphones
        // whose route might otherwise be treated as a conventional stereo output.
        engine.outputSpatializationMode = .alwaysUseBinaural
        engine.defaultReverbPreset = .smallRoom
        listener = PHASEListener(engine: engine)
        targetSource = PHASESource(engine: engine)
        targetLoopSource = PHASESource(engine: engine)
        beaconSource = PHASESource(engine: engine)
        cueSource = PHASESource(engine: engine)
        for object in [listener, targetSource, targetLoopSource, beaconSource, cueSource] as [PHASEObject] {
            do { try engine.rootObject.addChild(object) }
            catch { diagnostic("scene setup failed: \(error)") }
        }
        if Self.automaticHeadTracking, #available(iOS 18.0, *) {
            listener.automaticHeadTrackingFlags = .orientation
        }
        register("pulse", GuidanceSounds.pulse)
        register("confirm", GuidanceSounds.onObject, gain: 0.8)
        register("beacon", GuidanceSounds.waypoint)
        register("stop", GuidanceSounds.stop)
        register("rescan", GuidanceSounds.rescan)
        registerTargetLoop()
        headLock.withLock { updateListener() }
    }

    /// Keep the target's direct direction clear, with only a quiet diffuse tail.
    /// No early-reflection paths or occluders compete with the actual source.
    private func guidancePipeline() -> PHASESpatialPipeline? {
        guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission, .lateReverb]) else { return nil }
        pipeline.entries[PHASESpatialCategory.directPathTransmission]?.sendLevel = 1.0
        pipeline.entries[PHASESpatialCategory.lateReverb]?.sendLevel = GuidanceSounds.lateReverb
        return pipeline
    }

    /// One PHASE event per sound: sampler → spatial mixer with direct sound and reverb.
    private func register(_ name: String, _ samples: [Float], gain: Double = 1) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            _ = try engine.assetRegistry.registerSoundAsset(data: data, identifier: name, format: format,
                                                            normalizationMode: .none)
            guard let pipeline = guidancePipeline() else { return }
            let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline, identifier: "\(name)-mixer")
            let points = GuidanceSounds.distanceGains
            guard let envelope = PHASEEnvelope(startPoint: points[0], segments: points.dropFirst().map {
                PHASEEnvelopeSegment(endPoint: $0, curveType: .linear)
            }) else { return }
            let distance = PHASEEnvelopeDistanceModelParameters(envelope: envelope)
            distance.fadeOutParameters = PHASEDistanceModelFadeOutParameters(cullDistance: 20)
            mixer.distanceModelParameters = distance
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: name, mixerDefinition: mixer)
            sampler.playbackMode = .oneShot
            // The generated PCM is already peak-normalized with headroom. Keep linear
            // gain so loudness normalization/calibration cannot boost it back up.
            sampler.setCalibrationMode(calibrationMode: .none, level: gain)
            _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: "\(name)-event")
            mixerIDs[name] = mixer.identifier
            clipDurations[name] = Double(samples.count) / GuidanceSounds.sampleRate
        } catch { diagnostic("register \(name) failed: \(error)") }
    }

    private func registerTargetLoop() {
        guard let url = Bundle.main.url(forResource: Self.targetLoopAsset, withExtension: "wav") else {
            targetLoopAssetIssue = "chest loop unavailable: bundled chest_loop.wav is missing"
            diagnostic(targetLoopAssetIssue!)
            return
        }
        do {
            _ = try engine.assetRegistry.registerSoundAsset(url: url, identifier: Self.targetLoopAsset,
                                                            assetType: .resident, channelLayout: nil,
                                                            normalizationMode: .dynamic)
            guard let pipeline = guidancePipeline() else {
                targetLoopAssetIssue = "chest loop unavailable: spatial pipeline creation failed"
                diagnostic(targetLoopAssetIssue!)
                return
            }
            let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline, identifier: "chest-loop-mixer")
            let distance = PHASEGeometricSpreadingDistanceModelParameters()
            distance.rolloffFactor = Self.rolloff
            distance.fadeOutParameters = PHASEDistanceModelFadeOutParameters(cullDistance: 20)
            mixer.distanceModelParameters = distance
            mixer.gainMetaParameterDefinition = PHASENumberMetaParameterDefinition(value: 0.30,
                minimum: 0, maximum: 1, identifier: Self.targetLoopGain)
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: Self.targetLoopAsset, mixerDefinition: mixer)
            sampler.playbackMode = .looping
            // An out-of-range target may return; preserve its timeline instead of terminating the event.
            sampler.cullOption = .sleepWakeAtRealtimeOffset
            sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
            _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: "chest-loop-event")
            targetLoopMixerID = mixer.identifier
        } catch {
            targetLoopAssetIssue = "chest loop unavailable: asset registration failed: \(error)"
            diagnostic(targetLoopAssetIssue!)
        }
    }

    /// Keep one continuous sound at the target's world position. Call lifecycle methods on the main thread.
    /// Updating the position while preparation or playback is in progress does not restart the sound.
    func startOrUpdateTargetLoop(at position: SIMD3<Float>) {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            stopTargetLoop()
            diagnostic("chest loop stopped: target position is not finite")
            return
        }
        guard let mixerID = targetLoopMixerID else {
            if !reportedTargetLoopAssetIssue {
                reportedTargetLoopAssetIssue = true
                diagnostic(targetLoopAssetIssue ?? "chest loop unavailable: sound event was not registered")
            }
            return
        }
        updateTargetPosition(position)
        updateSources()
        guard ensureRunning() else {
            stopTargetLoop()
            return
        }
        guard targetLoopEvent == nil else { return }
        let parameters = PHASEMixerParameters()
        parameters.addSpatialMixerParameters(identifier: mixerID, source: targetLoopSource, listener: listener)
        do {
            let event = try PHASESoundEvent(engine: engine, assetIdentifier: "chest-loop-event", mixerParameters: parameters)
            targetLoopGeneration += 1
            let currentGeneration = targetLoopGeneration
            targetLoopEvent = event
            applyTargetLoopGain(animated: false)
            event.prepare { [weak self, weak event] reason in
                DispatchQueue.main.async {
                    guard let event else { return }
                    guard let self, self.targetLoopGeneration == currentGeneration,
                          self.targetLoopEvent === event else {
                        event.stopAndInvalidate()
                        return
                    }
                    guard reason == .prepared else {
                        self.stopTargetLoop()
                        self.diagnostic("chest loop preparation failed: \(reason.rawValue)")
                        return
                    }
                    self.applyTargetLoopGain(animated: false)
                    event.start { [weak self, weak event] reason in
                        DispatchQueue.main.async {
                            guard let self, let event, self.targetLoopGeneration == currentGeneration,
                                  self.targetLoopEvent === event else { return }
                            self.stopTargetLoop()
                            self.diagnostic("chest loop ended: \(reason.rawValue)")
                        }
                    }
                }
            }
        } catch {
            diagnostic("chest loop creation failed: \(error)")
        }
    }

    /// Also cancels an event still preparing; late callbacks cannot bring a stopped target back.
    func stopTargetLoop() {
        targetLoopGeneration += 1
        let event = targetLoopEvent
        targetLoopEvent = nil
        event?.stopAndInvalidate()
    }

    /// Lower the continuous sound beneath speech without restarting its playback or moving its anchor.
    func setGuidanceDucked(_ ducked: Bool) {
        guard guidanceDucked != ducked else { return }
        guidanceDucked = ducked
        applyTargetLoopGain(animated: true)
    }

    private func applyTargetLoopGain(animated: Bool) {
        guard let gain = targetLoopEvent?.metaParameters[Self.targetLoopGain] as? PHASENumberMetaParameter else { return }
        let value = guidanceDucked ? 0.08 : 0.30
        if animated {
            gain.fade(value: value, duration: guidanceDucked ? 0.08 : 0.25)
        } else {
            gain.value = NSNumber(value: value)
        }
    }

    /// Vibration uses live AirPods heading before pitch is applied. Head tilt still
    /// positions spatial audio normally, but never controls this tactile cue.
    @discardableResult
    func updateTargetAlignment(at target: SIMD3<Float>?) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let head = headLock.withLock { () -> (SIMD3<Float>, SIMD3<Float>)? in
            guard now - lastHeadSample < 1 else { return nil }
            return (listenerPosition, listenerHeading)
        }
        if let target, let head {
            return alignment.update(origin: head.0, forward: head.1, target: target, at: now)
        } else {
            alignment.reset()
            return false
        }
    }

    func start() {
        guard ensureRunning() else { return }
        for name in mixerIDs.keys { replenish(name) }
        if !Self.automaticHeadTracking { startHeadTracking() }
    }

    func restart() {
        generation += 1
        silence()
        let pending = Array(preparing.values.map { $0.1 }) + prepared.values.flatMap { $0.map { $0.1 } }
        preparing.removeAll()
        prepared.removeAll()
        pending.forEach { $0.stopAndInvalidate() }
        engine.stop()
        start()
    }

    /// The engine can fail to start (app launched in the background) or stop (route or interruption
    /// changes). Recover before playing, or every guidance sound is silently lost while speech still works.
    private func ensureRunning() -> Bool {
        guard engine.renderingState != .started else { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            diagnostic("engine started; route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
            return true
        } catch {
            diagnostic("engine start failed: \(error)")
            return false
        }
    }

    func silence() {
        alignment.reset()
        playbackCheckGeneration += 1
        cueTiming.reset()
        stopTargetLoop()
        let active = Array(playing.values)
        playing.removeAll()
        active.forEach { $0.stopAndInvalidate() }
        targetPosition = nil
        waypointPosition = nil
        targetMotion = GuidanceListenerMotion()
        waypointMotion = GuidanceListenerMotion()
    }

    func reportStatus() {
        diagnostic("state=\(engine.renderingState.rawValue); spatializer=binaural; effects=direct+reverb; listener=\(headLock.withLock { phonePose == nil ? "preview" : "local AR" }); headTracking=\(headTrackingLive); assets=\(mixerIDs.count); prepared=\(prepared.values.reduce(0) { $0 + $1.count }); active=\(playing.count); chestRegistered=\(targetLoopMixerID != nil); chestEvent=\(targetLoopEvent != nil); ducked=\(guidanceDucked)")
    }

    #if DEBUG
    /// A device-only regression check, invoked explicitly with --audio-self-test.
    /// No target or camera inference is needed, and Stop cancels the remaining sounds.
    func runPlaybackCheck() {
        let check = playbackCheckGeneration
        diagnostic("playback check: five beeps, then five double-beeps at 10 cm; peak=\(GuidanceSounds.peak), normalization=off")
        for index in 0..<10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) { [weak self] in
                guard let self, check == self.playbackCheckGeneration else { return }
                let near = self.headLock.withLock { self.listenerPosition + simd_normalize(self.listenerForward) * 0.1 }
                if index < 5 { self.pulse(at: near) }
                else { self.confirm(at: near) }
            }
        }
    }
    #endif

    private func startHeadTracking() {
        guard headMotion.isDeviceMotionAvailable, !headMotion.isDeviceMotionActive else { return }
        headMotion.startDeviceMotionUpdates(to: headQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let attitude = motion.attitude
            self.headLock.withLock {
                self.latestHead = attitude
                self.lastHeadSample = motion.timestamp
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
        listenerHeading = flat
        // Tilt: a positive pitch (look up) lifts forward towards +Y and tips "up" backwards.
        let worldUp = SIMD3<Float>(0, 1, 0)
        listenerForward = flat * cos(pitch) + worldUp * sin(pitch)
        listenerUp = worldUp * cos(pitch) - flat * sin(pitch)
        updateListener()
    }

    /// Call with `headLock` held.
    private func updateListener() {
        if let target = listenerTarget,
           let position = listenerMotion.update(towards: target, at: ProcessInfo.processInfo.systemUptime) {
            listenerPosition = position
        }
        let f = simd_normalize(listenerForward)
        let right = simd_normalize(simd_cross(f, listenerUp))
        let up = simd_cross(right, f)
        listener.transform = simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(-f, 0),
                                                     SIMD4(listenerPosition, 1)))
    }

    /// `position` is the body estimate at phone height. The phone is held at the chest and the ears are about
    /// 0.45 m higher, so a table-top target sounds below. The user's "Sound height" setting shifts this, also to
    /// offset the common perception of frontal headphone sources as higher than they are.
    func setListener(_ position: SIMD3<Float>) {
        let adjust = Float(UserDefaults.standard.double(forKey: Settings.soundHeightKey))
        headLock.withLock {
            phonePose = nil
            phoneEpoch = nil
            listenerTarget = position + SIMD3<Float>(0, 0.45 - adjust, 0)
            updateListener()
        }
    }

    /// Use local AR translation in every guidance mode, including the final
    /// approach. Network listener anchors must not pin the sound as the user moves.
    func setPhonePose(_ camera: simd_float4x4, epoch: Int) {
        headLock.withLock {
            phonePose = camera
            if phoneEpoch != epoch { listenerMotion = GuidanceListenerMotion() }
            phoneEpoch = epoch
            updatePhoneListener()
            updateListener()
        }
    }

    /// Call with headLock held. Head turns affect orientation, never this offset.
    private func updatePhoneListener() {
        guard let phonePose else { return }
        let height = Float(UserDefaults.standard.double(forKey: Settings.soundHeightKey))
        if let position = GuidanceListenerGeometry.position(camera: phonePose,
                                                            calibratedForward: baseForward, soundHeight: height) {
            listenerTarget = position
        }
    }

    /// Advance listener and source positions between incoming estimates. A source
    /// stays fixed in world space as the listener moves; corrections ease in.
    func updateSpatialAudio() {
        headLock.withLock { updateListener() }
        updateSources()
    }

    func updateTargetPosition(_ position: SIMD3<Float>) {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
        targetPosition = position
    }

    func updateWaypointPosition(_ position: SIMD3<Float>) {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
        waypointPosition = position
    }

    private func updateSources() {
        let now = ProcessInfo.processInfo.systemUptime
        if let targetPosition, let p = targetMotion.update(towards: targetPosition, at: now) {
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(p, 1)
            targetSource.transform = transform
            targetLoopSource.transform = transform
        }
        if let waypointPosition, let p = waypointMotion.update(towards: waypointPosition, at: now) {
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(p, 1)
            beaconSource.transform = transform
        }
    }

    /// Call while the user faces where the phone points: that world direction becomes "ahead".
    func setForward(_ forward: SIMD3<Float>) {
        headLock.withLock {
            baseForward = forward
            updatePhoneListener()
            headReference = latestHead?.copy() as? CMAttitude
            applyHead()
        }
    }

    @discardableResult
    func beaconPing(at position: SIMD3<Float>) -> Bool { play("beacon", from: beaconSource, at: position) }

    /// Hot/cold pulses come from the estimated target position, so the user hears where it is.
    /// Without a position they come from just in front of the listener.
    @discardableResult
    func pulse(at position: SIMD3<Float>?) -> Bool { play("pulse", from: targetSource, at: position) }
    @discardableResult
    func confirm(at position: SIMD3<Float>?) -> Bool { play("confirm", from: targetSource, at: position) }

    func cue(_ name: String) {
        switch name {
        case "stop": silence(); play(name, from: cueSource, at: nil)
        case "rescan": play(name, from: cueSource, at: nil)
        default: break
        }
    }

    @discardableResult
    private func play(_ name: String, from source: PHASESource, at position: SIMD3<Float>?) -> Bool {
        // Speech has its own output path. Avoid adding new guidance notes over it.
        if guidanceDucked, ["pulse", "confirm", "beacon"].contains(name) { return false }
        guard ensureRunning(), let duration = clipDurations[name],
              cueTiming.start(at: ProcessInfo.processInfo.systemUptime, duration: duration) else { return false }
        let p = position ?? headLock.withLock { listenerPosition + simd_normalize(listenerForward) * 0.6 }
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return false }
        if source === targetSource { updateTargetPosition(p); updateSources() }
        else if source === beaconSource { updateWaypointPosition(p); updateSources() }
        else {
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(p, 1)
            source.transform = transform
        }
        let next: (UUID, PHASESoundEvent)?
        if var ready = prepared[name], !ready.isEmpty {
            next = ready.removeFirst()
            prepared[name] = ready
        } else {
            next = makeEvent(name)
        }
        guard let (id, event) = next else { return false }
        playing[id] = event
        let currentGeneration = generation
        event.start { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration,
                      self.playing.removeValue(forKey: id) != nil else { return }
                if reason == .failure {
                    self.diagnostic("\(name) playback failed; restarting engine")
                    self.restart()
                } else if reason == .finishedPlaying {
                    self.completedSounds += 1
                    if self.completedSounds == 1 || self.completedSounds % 10 == 0 {
                        self.diagnostic("playback finished: \(self.completedSounds) sounds; last=\(name)")
                    }
                } else {
                    self.diagnostic("\(name) playback terminated")
                }
            }
        }
        replenish(name)
        return true
    }

    private func source(for name: String) -> PHASESource {
        name == "beacon" ? beaconSource : ["pulse", "confirm"].contains(name) ? targetSource : cueSource
    }

    private func makeEvent(_ name: String) -> (UUID, PHASESoundEvent)? {
        guard let mixerID = mixerIDs[name] else {
            diagnostic("missing sound asset: \(name)")
            return nil
        }
        let parameters = PHASEMixerParameters()
        parameters.addSpatialMixerParameters(identifier: mixerID, source: source(for: name), listener: listener)
        do {
            return (UUID(), try PHASESoundEvent(engine: engine, assetIdentifier: "\(name)-event", mixerParameters: parameters))
        } catch {
            diagnostic("create \(name) failed: \(error)")
            return nil
        }
    }

    /// Keep the next two one-shot events ready, so asset preparation cannot jitter the pulse rhythm.
    private func replenish(_ name: String) {
        let waiting = preparing.values.filter { $0.0 == name }.count
        let missing = max(0, 2 - (prepared[name]?.count ?? 0) - waiting)
        for _ in 0..<missing {
            guard let (id, event) = makeEvent(name) else { return }
            preparing[id] = (name, event)
            let currentGeneration = generation
            event.prepare { [weak self] reason in
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGeneration,
                          let (_, event) = self.preparing.removeValue(forKey: id) else { return }
                    if reason == .prepared {
                        self.prepared[name, default: []].append((id, event))
                    } else {
                        self.diagnostic("prepare \(name) failed: \(reason.rawValue)")
                        self.recoverFromPrepareFailure()
                    }
                }
            }
        }
    }

    /// A failed preparation means PHASE has lost its output although it still reports running (seen after
    /// audio session and route changes). Nothing would play again, so restart it, at most every 2 s.
    private func recoverFromPrepareFailure() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecovery > 2 else { return }
        lastRecovery = now
        diagnostic("restarting audio engine after a failed preparation")
        restart()
    }

    private func diagnostic(_ message: String) {
        NSLog("Beacon audio: %@", message)
        onDiagnostic?(message)
    }

}
