import Foundation

@main
struct VoiceRequestEndpointTests {
    static func main() {
        var quiet = VoiceRequestEndpoint()
        for tick in 1...119 {
            precondition(!quiet.shouldFinish(at: Double(tick) * 0.05, power: -80, isRecording: true),
                         "Give the user time to start speaking")
        }
        precondition(quiet.shouldFinish(at: 6, power: -80, isRecording: true), "Silence must time out")

        var speech = VoiceRequestEndpoint()
        for tick in 1...20 {
            precondition(!speech.shouldFinish(at: Double(tick) * 0.05, power: -20, isRecording: true))
        }
        precondition(!speech.shouldFinish(at: 1.5, power: -80, isRecording: true), "Allow a short pause between words")
        precondition(!speech.shouldFinish(at: 1.6, power: -20, isRecording: true))
        precondition(!speech.shouldFinish(at: 2, power: -80, isRecording: true))
        precondition(speech.shouldFinish(at: 2.6, power: -80, isRecording: true), "Send after speech followed by silence")

        var click = VoiceRequestEndpoint()
        precondition(!click.shouldFinish(at: 0.05, power: -10, isRecording: true))
        precondition(!click.shouldFinish(at: 2, power: -80, isRecording: true), "A single handling click is not a request")

        var noise = VoiceRequestEndpoint()
        for tick in 1...119 {
            precondition(!noise.shouldFinish(at: Double(tick) * 0.05, power: -15, isRecording: true))
        }
        precondition(noise.shouldFinish(at: 6, power: -15, isRecording: true), "Never record indefinitely in noise")

        var stopped = VoiceRequestEndpoint()
        precondition(stopped.shouldFinish(at: 0.4, power: -80, isRecording: false), "Finish if the recorder stops early")
        var invalid = VoiceRequestEndpoint()
        precondition(!invalid.shouldFinish(at: 0.2, power: .nan, isRecording: true))
        precondition(!invalid.shouldFinish(at: 1.2, power: -.infinity, isRecording: true))
        precondition(invalid.shouldFinish(at: 6, power: .nan, isRecording: true))
        print("Action-button recording: silence, speech pauses, brief noise, continuous noise, early stop and invalid meter checks passed")
    }
}
