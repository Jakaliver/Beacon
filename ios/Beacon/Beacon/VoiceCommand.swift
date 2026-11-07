import Foundation

enum VoiceSide: String {
    case left, right
}

/// A deliberately small grammar for spoken actions, independent of speech recognition and the app.
enum VoiceCommand: Equatable {
    case find(String)
    case calibrate
    case pause
    case resume
    case startOver
    case finish
    case repeatLast
    case help
    case status
    case inspect
    case choose(Int)
    case chooseSide(VoiceSide)
    case disableVoice

    /// These actions may interrupt an utterance; other commands should wait for settled speech.
    var isImmediate: Bool {
        switch self {
        case .pause, .startOver, .finish, .disableVoice: return true
        default: return false
        }
    }

    /// Normalizes transcription punctuation and spacing without dropping descriptive target words.
    static func normalized(_ text: String) -> String {
        let text = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let separated = text.unicodeScalars.map { scalar -> String in
            if CharacterSet.punctuationCharacters.contains(scalar), scalar != "'", scalar != "-" {
                return " "
            }
            return String(scalar)
        }.joined()
        return separated.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func parse(_ text: String) -> VoiceCommand? {
        var utterance = normalized(text)
        // Permit "Please, Beacon, stop" and "Hey Beacon, please stop" without matching
        // commands buried in conversation, such as "I told Beacon to stop".
        utterance = removingPrefix("please ", from: utterance)
        for prefix in ["hey beacon ", "beacon "] where utterance.hasPrefix(prefix) {
            utterance = String(utterance.dropFirst(prefix.count))
            break
        }
        utterance = removingPrefix("please ", from: utterance)
        if utterance.hasSuffix(" please") {
            utterance = String(utterance.dropLast(" please".count))
        }

        // Parse the target before control aliases: "find the stop sign" must never stop guidance.
        // Keep the whole phrase, including colour, ownership, and words such as "reset".
        for prefix in ["find ", "locate ", "where is ", "where are ", "where's ", "search for ", "look for ", "get "] {
            if utterance.hasPrefix(prefix) {
                let target = String(utterance.dropFirst(prefix.count))
                return target.isEmpty ? nil : .find(target)
            }
        }

        if let side = parseSide(utterance) { return .chooseSide(side) }

        switch utterance {
        case "calibrate", "recalibrate": return .calibrate
        case "pause", "stop", "hold on", "pause guidance", "stop guidance": return .pause
        case "resume", "continue", "resume guidance", "continue guidance": return .resume
        case "start over", "start again", "reset", "reset search", "cancel", "cancel search": return .startOver
        case "found it", "i found it", "i have it", "done", "finish", "finished", "i'm done", "i am done": return .finish
        case "repeat", "repeat that", "repeat last instruction", "say that again": return .repeatLast
        case "help", "what can i say", "what are the commands": return .help
        case "status", "what is my status", "what's my status", "what is the status", "what's the status": return .status
        case "inspect", "inspect target", "describe target", "describe the target": return .inspect
        case "turn off voice mode", "turn voice mode off", "disable voice mode", "voice mode off", "stop listening":
            return .disableVoice
        default: return parseChoice(utterance)
        }
    }

    private static func removingPrefix(_ prefix: String, from text: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// A side describes the requested match, not its position in a numbered options array.
    private static func parseSide(_ text: String) -> VoiceSide? {
        var phrase = text
        for prefix in ["choose ", "pick ", "take ", "select ", "i'll take ", "i will take ", "i want "]
            where phrase.hasPrefix(prefix) {
            phrase = String(phrase.dropFirst(prefix.count))
            break
        }
        for side in [VoiceSide.left, .right] {
            let direction = side.rawValue
            let forms = [
                direction, "the \(direction)", "\(direction) one", "the \(direction) one",
                "on the \(direction)", "on my \(direction)", "to the \(direction)", "to my \(direction)",
                "one on the \(direction)", "the one on the \(direction)",
                "one on my \(direction)", "the one on my \(direction)",
                "one to the \(direction)", "the one to the \(direction)",
                "one to my \(direction)", "the one to my \(direction)",
                "the \(direction) option", "the \(direction) match",
            ]
            if forms.contains(phrase) { return side }
        }
        return nil
    }

    private static func parseChoice(_ text: String) -> VoiceCommand? {
        let ordinals = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
            "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        ]
        if let number = ordinals[text] { return .choose(number) }
        if text.hasPrefix("the "), text.hasSuffix(" one"),
           let number = ordinals[String(text.dropFirst(4).dropLast(4))] {
            return .choose(number)
        }
        var words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if first == "choose" || first == "pick" {
            words.removeFirst()
            if words.first == "option" || words.first == "number" { words.removeFirst() }
        } else if first == "option" || first == "number" {
            words.removeFirst()
        } else if words.count == 1, text.hasPrefix("option") {
            // Recognizers sometimes join the numeral to the noun: "option2".
            let digits = String(text.dropFirst("option".count))
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            words = [digits]
        } else {
            return nil
        }
        guard words.count == 1 else { return nil }
        let numbers = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        let token = words[0]
        let number = numbers[token] ?? ordinals[token]
            ?? (token.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(token) : nil)
        guard let number, number > 0 else { return nil }
        return .choose(number)
    }
}
