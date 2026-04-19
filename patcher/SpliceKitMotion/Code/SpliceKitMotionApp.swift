import SwiftUI

@main
struct SpliceKitMotionApp: App {
    @StateObject private var model = PatcherModel()

    var body: some Scene {
        WindowGroup {
            WizardView(model: model)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        Window("Logs", id: "log-panel") {
            LogPanelView(model: model)
        }
        .defaultSize(width: 600, height: 400)
    }
}
