import SwiftUI

struct GuidanceSoundSettings: View {
    @AppStorage(Settings.guidanceSoundStyleKey) private var soundStyle = GuidanceSoundStyle.chest.rawValue

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
            Text("Chest plays continuously from the found object. Beeps use pulses. Pause or finish the search to stop the sound.")
        }
    }
}
