import SwiftUI
import AppIntents

@main
struct BeaconApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    model.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                model.enteredBackground()
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                model.becameActive()
            default: break
            }
        }
    }
}

struct PushToTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Beacon"
    static var description = IntentDescription("Open Beacon and speak a navigation request. Pause to send, or run again to send early.")
    static var openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.talkToBeacon()
        return .result()
    }
}

struct BeaconShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PushToTalkIntent(),
                    phrases: ["Talk to \(.applicationName)"],
                    shortTitle: "Talk to Beacon", systemImageName: "mic.fill")
    }
}
