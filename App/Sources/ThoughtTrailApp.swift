import SwiftUI
import AppInfrastructure

@main
struct ThoughtTrailApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let launch = LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        _model = State(initialValue: AppModel.make(launch: launch))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.handleScenePhase(phase) }
        }
    }
}
