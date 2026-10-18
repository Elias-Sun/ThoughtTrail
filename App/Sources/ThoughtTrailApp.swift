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
                .task {
                    await model.start()
                    let args = ProcessInfo.processInfo.arguments
                    await PerfProbe.markLaunchReady(arguments: args, books: model.books.count)
                    if args.contains("-perf-suite") { await PerfProbe.runSuite(app: model) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.handleScenePhase(phase) }
        }
    }
}
