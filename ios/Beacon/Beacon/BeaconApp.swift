import SwiftUI

@main
struct BeaconApp: App {
    @StateObject private var model = AppModel()
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
