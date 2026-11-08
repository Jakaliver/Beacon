import SwiftUI

struct GuidanceSoundSettings: View {
    @AppStorage(Settings.guidanceSoundStyleKey) private var soundStyle = GuidanceSoundStyle.beeps.rawValue

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
    }
}
