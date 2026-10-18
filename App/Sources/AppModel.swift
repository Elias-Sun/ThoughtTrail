import SwiftUI
import Observation
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import RetrievalCore
import BrainCore
import AgentRuntime
import ReaderAgent
import ModelProviders
import Persistence
import AppInfrastructure
import AchievementCore
import EvidenceVerificationCore
import LearningCore

/// 启动参数（UI 自动化使用确定性环境）。
struct LaunchConfiguration {
    /// UI 自动化/演示：确定性模型响应，独立数据目录。
    var deterministic: Bool
    /// 启动前清空数据（UI 自动化每个用例从干净状态开始）。
    var reset: Bool
    /// 启动后自动导入的内置示例书。
    var preloadBooks: [String]
    /// 时钟偏移天数（仅确定性模式）。
    var clockOffsetDays: Int

    init(arguments: [String]) {
        deterministic = arguments.contains("-uitest") || arguments.contains("-demo")
        reset = arguments.contains("-uitest-reset")
        preloadBooks = arguments.enumerated().compactMap { i, a in
            a == "-uitest-import" && i + 1 < arguments.count ? arguments[i + 1] : nil
        }
        clockOffsetDays = arguments.firstIndex(of: "-uitest-clock-offset-days").flatMap { i in
            i + 1 < arguments.count ? Int(arguments[i + 1]) : nil
        } ?? 0
    }
}

/// 应用级状态：书库、网络、全局提示。各页面的业务状态在各自的模型中。
@MainActor
@Observable
final class AppModel {
    let container: AppContainer
    let launch: LaunchConfiguration
    var books: [Book] = []
    var librarySearch = ""
    var librarySort: LibrarySort = .recentlyOpened
    var banner: Banner?
    var isOnline = true
    var recovery: LaunchRecovery?
    var indexing: [BookID: String] = [:]
    /// 跨页面的“打开原文”请求（引用跳转、记忆来源跳转）。
    var openRequest: OpenRequest?
    /// 最近一次导出的备份文件（确定性模式下用于恢复验证）。
    var lastBackupURL: URL?
    /// 关闭阅读器回到书库（性能采样用于重复“打开书籍”）。
    var closeReaderRequest: UUID?
    private let network = NetworkMonitor()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    struct OpenRequest: Identifiable, Equatable {
        let id = UUID()
        var bookID: BookID
        var locator: Locator?
    }

    init(container: AppContainer, launch: LaunchConfiguration) {
        self.container = container
        self.launch = launch
    }

    static func make(launch: LaunchConfiguration) -> AppModel {
        do {
            let env = launch.deterministic ? DeterministicEnvironment.make(reset: launch.reset, clockOffsetDays: launch.clockOffsetDays)
                : AppEnvironment.production()
            return AppModel(container: try AppContainer(environment: env), launch: launch)
        } catch {
            // 数据库无法打开时退回内存库，界面提示，不崩溃
            let fallback = AppEnvironment(databaseURL: nil, booksDirectory: nil, secrets: KeychainSecretStore())
            let model = AppModel(container: try! AppContainer(environment: fallback), launch: launch)
            model.banner = Banner(message: "数据库无法打开，已使用临时存储：\(error.localizedDescription)", isError: true)
            return model
        }
    }

    var timeZone: TimeZone { container.environment.timeZone() }

    func start() async {
        await container.registerLifecycleObservers()
        recovery = try? await container.recoverOnLaunch()
        network.start { [weak self] online in Task { @MainActor in self?.isOnline = online } }
        for name in launch.preloadBooks { await importBundled(name) }
        await reloadBooks()
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background: try? await container.sessionTracker.handle(.backgrounded)
        case .active: try? await container.sessionTracker.handle(.foregrounded)
        default: break
        }
    }

    func reloadBooks() async {
        books = (try? await container.library.books(matching: librarySearch, sort: librarySort)) ?? []
    }

    // MARK: 导入

    func importEPUB(at url: URL) async {
        do {
            let outcome = try await container.library.importBook(from: url)
            await handleImport(outcome)
        } catch let e as ImportError {
            banner = Banner(message: e.userMessage, isError: true)
        } catch {
            banner = Banner(message: "导入失败：\(error.localizedDescription)", isError: true)
        }
        await reloadBooks()
    }

    func importData(_ data: Data, fileName: String) async {
        do {
            await handleImport(try await container.library.importBook(data: data, fileName: fileName))
        } catch let e as ImportError {
            banner = Banner(message: e.userMessage, isError: true)
        } catch {
            banner = Banner(message: "导入失败：\(error.localizedDescription)", isError: true)
        }
        await reloadBooks()
    }

    func importBundled(_ name: String) async {
        guard let url = Bundle.main.url(forResource: name, withExtension: "epub"), let data = try? Data(contentsOf: url) else {
            banner = Banner(message: "找不到内置示例：\(name)", isError: true)
            return
        }
        await importData(data, fileName: "\(name).epub")
    }

    private func handleImport(_ outcome: ImportOutcome) async {
        switch outcome {
        case .imported(let b):
            banner = Banner(message: "已导入《\(b.title)》", isError: false)
            await buildIndex(b)
        case .duplicate(let b):
            banner = Banner(message: "《\(b.title)》已在书库中（重复文件未再次导入）", isError: false)
        case .restoredSource(let b):
            banner = Banner(message: "已恢复《\(b.title)》的阅读文件，笔记保持不变", isError: false)
            await buildIndex(b)
        }
    }

    /// 导入后建立本地词法索引（全书结构本地解析；云向量只对已读范围增量生成）。
    func buildIndex(_ book: Book) async {
        indexing[book.id] = "建立索引中…"
        try? await container.library.setIndexState(bookID: book.id, state: .indexing)
        let models = await container.providers.current()
        do {
            try await container.indexing.ensureLexical(bookID: book.id, profile: models.embedding?.profile)
            try await container.library.setIndexState(bookID: book.id, state: .lexicalReady)
            indexing[book.id] = nil
        } catch {
            try? await container.library.setIndexState(bookID: book.id, state: .failed)
            indexing[book.id] = "索引失败，可稍后重试"
        }
        await reloadBooks()
    }

    /// 已读内容的向量化（需要在线且配置了向量模型）。
    func embedReadContent(_ book: Book) async {
        let models = await container.providers.current()
        guard let embedding = models.embedding else { return }
        guard isOnline else { indexing[book.id] = "离线：联网后继续向量化"; return }
        indexing[book.id] = "向量化已读内容…"
        let report = try? await container.indexing.embedReadContent(bookID: book.id, service: embedding) { done, total in
            await MainActor.run { self.indexing[book.id] = "向量化 \(done)/\(total)" }
        }
        if let r = report, r.completed {
            indexing[book.id] = nil
            try? await container.library.setIndexState(bookID: book.id, state: .ready)
        } else if let r = report, r.paused {
            indexing[book.id] = "已暂停（\(r.lastError ?? "预算或网络")），可继续"
            try? await container.library.setIndexState(bookID: book.id, state: .paused)
        } else {
            indexing[book.id] = nil
        }
        await reloadBooks()
    }

    func delete(_ book: Book, policy: BookDeletionPolicy) async {
        do {
            try await container.library.delete(bookID: book.id, policy: policy)
            banner = Banner(message: policy == .purgeEverything ? "已彻底删除《\(book.title)》及相关内容" : "已删除阅读文件，笔记保留", isError: false)
        } catch {
            banner = Banner(message: "删除失败：\(error.localizedDescription)", isError: true)
        }
        await reloadBooks()
    }

    func availability(_ op: OperationKind) async -> Availability {
        let models = await container.providers.current()
        return OfflinePolicy.availability(of: op, online: isOnline, chatConfigured: models.chat != nil,
                                          embeddingConfigured: models.embedding != nil)
    }
}
