import SwiftUI

@main
struct TridentApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enteredBackground()
            case .active: model.becameActive()
            default: break
            }
        }
    }
}
