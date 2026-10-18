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
                    let args = ProcessInfo.processInfo.arguments
                    PerfProbe.prepare(arguments: args)
                    await model.start()
                    await PerfProbe.markLaunchReady(arguments: args, books: model.books.count)
                    await PerfProbe.importIfRequested(app: model, arguments: args)
                    if args.contains("-perf-suite") { await PerfProbe.runSuite(app: model) }
                    if let i = args.firstIndex(of: "-perf-soak"), i + 1 < args.count, let minutes = Double(args[i + 1]) {
                        await PerfProbe.runSoak(app: model, minutes: minutes)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.handleScenePhase(phase) }
        }
    }
}
