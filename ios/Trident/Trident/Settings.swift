import Foundation

enum GuidanceSoundStyle: String, CaseIterable, Identifiable {
    case chest, beeps
    var id: String { rawValue }
    var label: String { self == .chest ? "Chest" : "Beeps" }
}

enum Settings {
    static let guidanceSoundStyleKey = "guidanceSoundStyle"
    static var guidanceSoundStyle: GuidanceSoundStyle {
        GuidanceSoundStyle(rawValue: UserDefaults.standard.string(forKey: guidanceSoundStyleKey) ?? "") ?? .beeps
    }
    static let hostKey = "host"
    static let frameRateKey = "frameRate"
    static let defaultHost = "Malins-Macbook-Pro-3.local"
    static let reverseHeadTurnKey = "reverseHeadTurn"
    static let reverseHeadTiltKey = "reverseHeadTilt"
    static let soundHeightKey = "soundHeight"  // metres; positive raises sounds
    static let defaultFrameRate = 20.0  // preserve the current main default

    static var host: String { UserDefaults.standard.string(forKey: hostKey) ?? defaultHost }
    static var frameRate: Double {
        let value = UserDefaults.standard.double(forKey: frameRateKey)
        return value > 0 ? value : defaultFrameRate
    }
}
