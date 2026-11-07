import SwiftUI

@main
struct VoiceLabApp: App {
    @StateObject private var model = VoiceLabModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            VoiceLabView(model: model)
                .task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    if !ProcessInfo.processInfo.arguments.contains("--manual-voice-test") {
                        await model.voice.enable()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                UIApplication.shared.isIdleTimerDisabled = false
                model.enteredBackground()
            } else if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                model.voice.becameActive()
            }
        }
    }
}
