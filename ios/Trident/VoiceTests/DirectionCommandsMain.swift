import Foundation

/// Standalone parser regression checks; kept outside the offloaded iCloud checkout.
@main
struct DirectionCommandsTests {
    static func main() {
        let cases: [(String, VoiceCommand?)] = [
            ("left", .chooseSide(.left)),
            ("right", .chooseSide(.right)),
            ("left one", .chooseSide(.left)),
            ("right one", .chooseSide(.right)),
            ("the left one", .chooseSide(.left)),
            ("the right one", .chooseSide(.right)),
            ("the one on the left", .chooseSide(.left)),
            ("the one on the right", .chooseSide(.right)),
            ("on my left", .chooseSide(.left)),
            ("on my right", .chooseSide(.right)),
            ("on the left", .chooseSide(.left)),
            ("on the right", .chooseSide(.right)),
            ("the one to my left", .chooseSide(.left)),
            ("the one to my right", .chooseSide(.right)),
            ("choose the left one", .chooseSide(.left)),
            ("pick the right one", .chooseSide(.right)),
            ("take the left one", .chooseSide(.left)),
            ("choose right", .chooseSide(.right)),
            ("pick left one", .chooseSide(.left)),
            ("take the one on my right", .chooseSide(.right)),
            ("select the left match", .chooseSide(.left)),
            ("I'll take the right one", .chooseSide(.right)),
            ("I want the one on the left", .chooseSide(.left)),
            ("Hey Trident, please pick the right one!", .chooseSide(.right)),
            ("Please, Trident, take the one on my left.", .chooseSide(.left)),
            ("  THE\n ONE ON THE RIGHT, please! ", .chooseSide(.right)),
            ("find the left shoe", .find("the left shoe")),
            ("find the right shoe", .find("the right shoe")),
            ("find the one on the left", .find("the one on the left")),
            ("where is the right glove", .find("the right glove")),
            ("look for the left boot", .find("the left boot")),
            ("get the right headphone", .find("the right headphone")),
            ("search for the stop sign on the left", .find("the stop sign on the left")),
            ("locate my red wallet", .find("my red wallet")),
            ("don't choose left", nil),
            ("do not pick the right one", nil),
            ("not the left one", nil),
            ("never take the one on my right", nil),
            ("I don't want the left one", nil),
            ("I said the right one earlier", nil),
            ("the one on the left is broken", nil),
            ("is it on my right", nil),
            ("turn left", nil),
            ("turn right", nil),
            ("left or right", nil),
            ("choose the left one or the right one", nil),
            ("right now", nil),
            ("I want the right one later", nil),
            ("there is one on the left", nil),
            ("choose left if it is blue", nil),
            ("left shoe", nil),
            ("rightward", nil),
            ("leftover", nil),
            ("choose", nil),
            ("find", nil),
            ("", nil),
            ("choose one", .choose(1)),
            ("option2", .choose(2)),
            ("the first one", .choose(1)),
            ("second", .choose(2)),
            ("choose 0", nil),
            ("choose -1", nil),
            ("choose 1.5", nil),
            ("pause", .pause),
            ("stop", .pause),
            ("continue", .resume),
            ("start over", .startOver),
            ("calibrate", .calibrate),
            ("found it", .finish),
            ("repeat", .repeatLast),
            ("help", .help),
            ("status", .status),
            ("inspect", .inspect),
            ("turn off voice mode", .disableVoice),
        ]
        var failures = 0
        for (utterance, expected) in cases {
            let actual = VoiceCommand.parse(utterance)
            if actual != expected {
                failures += 1
                print("FAIL \(String(reflecting: utterance)): expected \(String(describing: expected)), got \(String(describing: actual))")
            }
        }
        let checks: [(String, Bool)] = [
            ("left choice settles", !VoiceCommand.chooseSide(.left).isImmediate),
            ("right choice settles", !VoiceCommand.chooseSide(.right).isImmediate),
            ("left remains a semantic side", VoiceCommand.parse("left") != .choose(1)),
            ("right remains a semantic side", VoiceCommand.parse("right") != .choose(2)),
        ]
        for (description, passed) in checks where !passed {
            failures += 1
            print("FAIL: \(description)")
        }
        guard failures == 0 else { exit(EXIT_FAILURE) }
        print("Voice directions: \(cases.count) utterances and \(checks.count) semantic checks passed")
    }
}
