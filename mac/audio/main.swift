import Foundation
import AVFoundation

// Independent Mac output. Consumes a copy of server events; never controls the phone.
final class LaptopAudio {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: GuidanceSounds.sampleRate, channels: 1)!
    var buffers: [String: AVAudioPCMBuffer] = [:]
    var speech: Process?
    var words: [String] = []
    var guidance: [String: Any] = [:]
    var received = -Double.infinity
    var lastPulse = -Double.infinity
    var busyUntil = 0.0

    init() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for (name, samples) in [("pulse", GuidanceSounds.pulse), ("confirm", GuidanceSounds.onObject)] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            buffers[name] = buffer
        }
        try engine.start()
        player.play()
    }

    func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "say":
            if let text = message["text"] as? String, !text.isEmpty {
                words.append(text)
                words = Array(words.suffix(8))
                player.stop()
                player.play()
            }
        case "guidance":
            guidance = message
            received = ProcessInfo.processInfo.systemUptime
            if !["hotcold", "probe", "walking"].contains(message["mode"] as? String ?? "") {
                player.stop()
                player.play()
                lastPulse = -.infinity
            }
        case "cue":
            if message["name"] as? String == "stop" {
                words.removeAll()
                if speech?.isRunning == true { speech?.terminate() }
                player.stop()
                player.play()
                guidance = [:]
            }
        default: break
        }
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if speech?.isRunning == true { return }
        if !words.isEmpty {
            let text = words.removeFirst()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-f", "-"]
            let input = Pipe()
            process.standardInput = input
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(text.utf8))
                try? input.fileHandleForWriting.close()
                speech = process
            } catch { fputs("Mac speech failed: \(error)\n", stderr) }
            return
        }
        guard now - received < 1, now >= busyUntil,
              guidance["stop_reason"] == nil || guidance["stop_reason"] is NSNull,
              let target = guidance["target"] as? [String: Any], target["valid"] as? Bool == true else { return }
        let mode = guidance["mode"] as? String
        let proximity = guidance["proximity"] as? [String: Any]
        let confirming = proximity?["confirm"] as? Bool == true
        let interval: Double
        if mode == "walking" {
            guard guidance["waypoint"] is [String: Any] else { return }
            interval = 0.6
        } else if mode == "probe" || mode == "hotcold" {
            guard let value = proximity?["pulse_interval"] as? Double, value.isFinite else { return }
            interval = confirming ? 0.8 : max(0.08, value)
        } else { return }
        guard now - lastPulse >= interval else { return }
        play(confirming && mode != "walking" ? "confirm" : "pulse", now: now)
    }

    func play(_ name: String, now: Double) {
        guard let buffer = buffers[name] else { return }
        player.scheduleBuffer(buffer)
        lastPulse = now
        busyUntil = now + Double(buffer.frameLength) / format.sampleRate + 0.02
    }

    func shutdown() {
        if speech?.isRunning == true { speech?.terminate() }
        player.stop()
        engine.stop()
    }
}

@main struct Main {
    static func main() throws {
        let audio = try LaptopAudio()
        if CommandLine.arguments.contains("--self-test") {
            audio.play("pulse", now: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                audio.receive(["type": "say", "text": "Beacon laptop audio is ready."])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { audio.shutdown(); exit(0) }
        } else {
            DispatchQueue.global().async {
                while let line = readLine() {
                    guard let data = line.data(using: .utf8),
                          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    DispatchQueue.main.async { audio.receive(message) }
                }
                DispatchQueue.main.async { audio.shutdown(); exit(0) }
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in audio.tick() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }
}
