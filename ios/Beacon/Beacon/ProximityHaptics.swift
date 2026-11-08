import AVFoundation
import CoreHaptics
import UIKit

@MainActor
final class ProximityHaptics {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var running = false
    private var smoothedDistance: Float?
    private var lastPulse = -Double.infinity
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)

    func update(distance: Float?) {
        guard let distance, distance.isFinite, distance >= 0 else { stop(); return }
        let smoothed = smoothedDistance.map { $0 + 0.25 * (distance - $0) } ?? distance
        smoothedDistance = smoothed
        guard let pulse = TargetProximity.hapticPulse(forDistance: smoothed) else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPulse >= pulse.interval else { return }
        lastPulse = now
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            fallback.impactOccurred(intensity: CGFloat(pulse.intensity))
            return
        }
        do {
            if engine == nil {
                let engine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = true
                engine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.running = false }
                }
                engine.resetHandler = { [weak self] in
                    Task { @MainActor in
                        self?.running = false
                        self?.player = nil
                    }
                }
                self.engine = engine
            }
            guard let engine else { return }
            if !running { try engine.start(); running = true }
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
                CHHapticEventParameter(parameterID: .attackTime, value: 0.004),
                CHHapticEventParameter(parameterID: .releaseTime, value: 0.01),
            ], relativeTime: 0, duration: pulse.duration)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            player = try engine.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            running = false
            fallback.impactOccurred(intensity: CGFloat(pulse.intensity))
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        lastPulse = -Double.infinity
        smoothedDistance = nil
    }
}
