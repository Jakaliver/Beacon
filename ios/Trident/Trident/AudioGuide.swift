import AVFoundation
import simd

/// Spatial guidance sounds. Positions are ARKit world coordinates; both frames are right-handed, +Y up, −Z forward.
///
/// The headphones' own orientation is NOT assumed to be in ARKit coordinates. The system head tracking
/// (`isListenerHeadTrackingEnabled`) rotates the listener relative to the user's calibrated forward, so on
/// Calibrate we set the listener's base orientation to the phone's horizontal forward in the AR world.
/// We never rotate the listener by head motion ourselves.
final class AudioGuide {
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
        environment.isListenerHeadTrackingEnabled = true
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.rolloffFactor = 0.5
    }

    func start() {
        guard !engine.isRunning else { return }
        try? engine.start()
        beacon.play()
        probe.play()
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

    /// Sets the listener's base yaw so that audio forward equals the given world direction.
    func setForward(_ forward: SIMD3<Float>) {
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: 0, z: forward.z),
            up: AVAudio3DVector(x: 0, y: 1, z: 0))
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
