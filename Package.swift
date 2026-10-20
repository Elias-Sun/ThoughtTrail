// swift-tools-version: 6.0
// ThoughtTrail（思迹）核心 Swift 包：18 个库模块 + 测试 + 评测/联调命令行工具。
// iOS 应用工程见 App/ 与 project.yml（XcodeGen），它通过本地包引用这些库。
import PackageDescription

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let zip: Target.Dependency = .product(name: "ZIPFoundation", package: "ZIPFoundation")

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

/// 18 个库模块（M01–M18），依赖关系见 Docs/Architecture.md。
let modules: [(name: String, deps: [Target.Dependency])] = [
    ("LibraryCore", [zip]),                                                            // M01
    ("ReaderCore", ["LibraryCore"]),                                                   // M02
    ("ReadingSessionCore", ["LibraryCore", "ReaderCore"]),                             // M03
    ("ReflectionCore", ["LibraryCore", "ReaderCore", "ReadingSessionCore"]),           // M04
    ("SpeechCore", ["LibraryCore"]),                                                   // M05
    ("RetrievalCore", ["LibraryCore", "ReaderCore", "ReadingSessionCore"]),            // M06
    ("ContextRouting", ["LibraryCore", "ReadingSessionCore", "RetrievalCore", "AgentRuntime"]), // M07
    ("ContextEngineering", ["LibraryCore", "ReaderCore", "RetrievalCore", "ContextRouting", "AgentRuntime"]), // M08
    ("BrainCore", ["LibraryCore", "ReaderCore", "ReadingSessionCore", "RetrievalCore"]), // M09
    ("AgentRuntime", ["LibraryCore"]),                                                 // M10
    ("ReaderAgent", ["LibraryCore", "ReaderCore", "ReadingSessionCore", "ReflectionCore", "RetrievalCore",
                     "ContextRouting", "ContextEngineering", "BrainCore", "AgentRuntime",
                     "EvidenceVerificationCore"]),                                     // M11
    ("ModelProviders", ["LibraryCore", "AgentRuntime", "RetrievalCore"]),              // M12
    ("Persistence", [grdb, "LibraryCore", "ReaderCore", "ReadingSessionCore", "ReflectionCore",
                     "RetrievalCore", "BrainCore", "LearningCore", "AchievementCore", "AgentRuntime",
                     "ContextEngineering"]),                                           // M13
    ("AppInfrastructure", ["LibraryCore", "ReaderCore", "ReadingSessionCore", "ReflectionCore", "SpeechCore",
                           "RetrievalCore", "ContextRouting", "ContextEngineering", "BrainCore",
                           "AgentRuntime", "ReaderAgent", "ModelProviders", "Persistence",
                           "AchievementCore", "EvidenceVerificationCore", "LearningCore"]), // M14
    ("AchievementCore", ["LibraryCore", "ReadingSessionCore"]),                        // M15
    ("BenchCore", ["LibraryCore", "ReaderCore", "ReadingSessionCore", "RetrievalCore",
                   "ContextEngineering", "EvidenceVerificationCore", "BrainCore", "LearningCore"]), // M16
    ("EvidenceVerificationCore", ["LibraryCore", "ReaderCore", "ReadingSessionCore", "RetrievalCore",
                                  "ContextEngineering", "AgentRuntime"]),              // M17
    ("LearningCore", ["LibraryCore", "ReaderCore", "ReadingSessionCore", "RetrievalCore",
                      "ContextEngineering", "AgentRuntime", "EvidenceVerificationCore"]), // M18
]

var targets: [Target] = modules.map {
    .target(name: $0.name, dependencies: $0.deps, swiftSettings: swiftSettings)
}

// 测试辅助（确定性桩、EPUB 夹具生成器）。不属于 18 个库模块，仅供测试与工具使用。
targets.append(.target(
    name: "TestSupport",
    dependencies: modules.map { .byName(name: $0.name) } + [zip, grdb],
    path: "Tests/TestSupport",
    swiftSettings: swiftSettings
))

// 每个模块一个单元测试 target，另加跨模块集成测试 target。
targets += modules.map {
    .testTarget(
        name: "\($0.name)Tests",
        dependencies: modules.map { .byName(name: $0.name) } + ["TestSupport"],
        swiftSettings: swiftSettings
    )
}
targets.append(.testTarget(
    name: "IntegrationTests",
    dependencies: modules.map { .byName(name: $0.name) } + ["TestSupport", grdb],
    swiftSettings: swiftSettings
))

// 命令行工具：固定评测、夹具生成、真实接口联调（需显式触发）。
targets.append(.executableTarget(
    name: "tt-bench",
    dependencies: modules.map { .byName(name: $0.name) } + ["TestSupport"],
    path: "Benchmarks/tt-bench",
    swiftSettings: swiftSettings
))
targets.append(.executableTarget(
    name: "tt-live-check",
    dependencies: ["AppInfrastructure", "ModelProviders", "AgentRuntime", "RetrievalCore", "LibraryCore"],
    path: "Benchmarks/tt-live-check",
    swiftSettings: swiftSettings
))

let package = Package(
    name: "ThoughtTrail",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: modules.map { .library(name: $0.name, targets: [$0.name]) },
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: targets
)
