import SwiftUI

struct GuidanceSoundSettings: View {
    @AppStorage(Settings.guidanceSoundStyleKey) private var soundStyle = GuidanceSoundStyle.beeps.rawValue
    @AppStorage(Settings.guidanceRoomSizeKey) private var roomSize = GuidanceRoomSize.large.rawValue

    var body: some View {
        Section {
            Picker("Object sound", selection: $soundStyle) {
                ForEach(GuidanceSoundStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("object-sound-style")
        } header: {
            Text("Object sound")
        } footer: {
            Text("Chest plays continuously from the object. Beeps use clean beeps as you approach, then a quick double beep when the phone is close. Pause or finish to stop the sound.")
        }
        Section {
            Picker("Room size", selection: $roomSize) {
                ForEach(GuidanceRoomSize.allCases) { room in
                    Text(room.label).tag(room.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("guidance-room-size")
        } header: {
            Text("Room size")
        } footer: {
            Text("Choose a larger space or a small meeting room for about four people.")
        }
    }
}
