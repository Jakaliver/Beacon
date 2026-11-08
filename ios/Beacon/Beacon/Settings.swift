import Foundation

enum GuidanceSoundStyle: String, CaseIterable, Identifiable {
    case chest, beeps
    var id: String { rawValue }
    var label: String { self == .chest ? "Chest" : "Beeps" }
}

enum GuidanceRoomSize: String, CaseIterable, Identifiable {
    case large, meeting
    var id: String { rawValue }
    var label: String { self == .large ? "Large room" : "Meeting room" }
    // Width, ceiling height, depth in metres. Meeting room seats about four.
    var dimensions: SIMD3<Float> {
        self == .large ? SIMD3(7, 3, 9) : SIMD3(3.2, 2.6, 4)
    }
}

enum Settings {
    static let guidanceRoomSizeKey = "guidanceRoomSize"
    static var guidanceRoomSize: GuidanceRoomSize {
        GuidanceRoomSize(rawValue: UserDefaults.standard.string(forKey: guidanceRoomSizeKey) ?? "") ?? .large
    }
    static let guidanceSoundStyleKey = "guidanceSoundStyle"
    static var guidanceSoundStyle: GuidanceSoundStyle {
        get {
            GuidanceSoundStyle(rawValue: UserDefaults.standard.string(forKey: guidanceSoundStyleKey) ?? "") ?? .beeps
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: guidanceSoundStyleKey) }
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
