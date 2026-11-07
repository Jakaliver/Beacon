import SwiftUI
import AppIntents

@main
struct TridentApp: App {
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
    static var title: LocalizedStringResource = "Push to Talk"
    static var description = IntentDescription("Open Trident and speak a navigation request. Pause to send, or run again to send early.")
    static var openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.actionButtonPushToTalk()
        return .result()
    }
}

struct TridentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PushToTalkIntent(),
                    phrases: ["Push to talk with \(.applicationName)"],
                    shortTitle: "Push to Talk", systemImageName: "mic.fill")
    }
}
