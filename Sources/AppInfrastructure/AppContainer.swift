import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import SpeechCore
import RetrievalCore
import ContextRouting
import ContextEngineering
import BrainCore
import AgentRuntime
import ReaderAgent
import ModelProviders
import Persistence
import AchievementCore
import EvidenceVerificationCore
import LearningCore

/// 应用运行环境（生产 / UI 自动化的确定性环境）。
public struct AppEnvironment: Sendable {
    public var databaseURL: URL?
    public var booksDirectory: URL?
    public var secrets: SecretStore
    public var transport: HTTPTransport
    public var clock: WallClock
    public var ids: IDGenerating
    public var timeZone: @Sendable () -> TimeZone
    /// 未配置复核模型时使用的确定性裁判（演示/测试）。生产默认 nil：复核不可用时如实显示“未能核查”。
    public var fallbackJudge: ClaimJudge?
    /// 覆盖 Provider（UI 自动化注入确定性模型）。
    public var overrides: ProviderOverrides?

    public init(databaseURL: URL?, booksDirectory: URL?, secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(),
                clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator(),
                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }, fallbackJudge: ClaimJudge? = nil,
                overrides: ProviderOverrides? = nil) {
        self.databaseURL = databaseURL; self.booksDirectory = booksDirectory; self.secrets = secrets; self.transport = transport
        self.clock = clock; self.ids = ids; self.timeZone = timeZone; self.fallbackJudge = fallbackJudge; self.overrides = overrides
    }

    /// 生产环境：Application Support 下的数据库与书籍目录，Keychain 保存密钥。
    public static func production() -> AppEnvironment {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThoughtTrail", isDirectory: true)
        return AppEnvironment(databaseURL: base.appendingPathComponent("thoughttrail.sqlite"),
                              booksDirectory: base.appendingPathComponent("Books", isDirectory: true),
                              secrets: KeychainSecretStore())
    }
}

/// 覆盖 Provider（UI 自动化与演示的确定性环境）。规划/复核模型可单独指定，nil 表示不用模型执行该角色。
public struct ProviderOverrides: Sendable {
    public var chat: ChatModel?
    public var planner: ChatModel?
    public var verifier: ChatModel?
    public var embedding: EmbeddingService?
    public var rerank: RerankService?

    public init(chat: ChatModel?, planner: ChatModel? = nil, verifier: ChatModel? = nil, embedding: EmbeddingService?, rerank: RerankService?) {
        self.chat = chat; self.planner = planner; self.verifier = verifier; self.embedding = embedding; self.rerank = rerank
    }
}

/// 依赖装配（M14）：数据库、仓储、领域服务、检索与讨论编排。
public final class AppContainer: Sendable {
    public let environment: AppEnvironment
    public let database: AppDatabase
    public let bookRepository: SQLiteBookRepository
    public let readingRepository: SQLiteReadingRepository
    public let reflectionRepository: SQLiteReflectionRepository
    public let retrievalStore: SQLiteRetrievalStore
    public let brainRepository: SQLiteBrainRepository
    public let learningRepository: SQLiteLearningRepository
    public let runtimeStore: SQLiteRuntimeStore
    public let files: BookFileStore

    public let library: LibraryService
    public let annotations: AnnotationService
    public let sessionTracker: ReadingSessionTracker
    public let reflections: ReflectionService
    public let conversations: ConversationService
    public let brain: BrainService
    public let learning: LearningService
    public let achievements: AchievementService
    public let backup: BackupService
    public let trace: TraceRecorder
    public let tasks: TaskRegistry
    public let providers: ProviderHub
    public let indexing: IndexingCoordinator

    public init(environment: AppEnvironment) throws {
        self.environment = environment
        database = try environment.databaseURL.map { try AppDatabase.onDisk(at: $0) } ?? AppDatabase.inMemory()
        bookRepository = SQLiteBookRepository(database)
        readingRepository = SQLiteReadingRepository(database)
        reflectionRepository = SQLiteReflectionRepository(database)
        retrievalStore = SQLiteRetrievalStore(database)
        brainRepository = SQLiteBrainRepository(database)
        learningRepository = SQLiteLearningRepository(database)
        runtimeStore = SQLiteRuntimeStore(database)
        files = environment.booksDirectory.map { DiskBookFileStore(root: $0) as BookFileStore } ?? InMemoryBookFileStore()

        let clock = environment.clock, ids = environment.ids
        library = LibraryService(repository: bookRepository, files: files, clock: clock, ids: ids)
        annotations = AnnotationService(repository: readingRepository, clock: clock, ids: ids)
        sessionTracker = ReadingSessionTracker(repository: readingRepository, clock: clock, ids: ids)
        reflections = ReflectionService(repository: reflectionRepository, clock: clock, ids: ids)
        conversations = ConversationService(repository: reflectionRepository, clock: clock, ids: ids)
        brain = BrainService(repository: brainRepository, clock: clock, ids: ids)
        learning = LearningService(repository: learningRepository, clock: clock, ids: ids)
        achievements = AchievementService(repository: runtimeStore, clock: clock)
        backup = BackupService(db: database, files: files)
        trace = TraceRecorder(sink: runtimeStore)
        tasks = TaskRegistry(store: runtimeStore, clock: clock, ids: ids)
        indexing = IndexingCoordinator(books: bookRepository, store: retrievalStore, readStates: readingRepository, clock: clock)
        providers = ProviderHub(environment: environment, settings: runtimeStore)
    }

    /// 启动恢复（10.3 进程终止）：结束遗留会话、标记中断任务、把进行中的回答标记为失败（保留问题与草稿）。
    public func recoverOnLaunch() async throws -> LaunchRecovery {
        let sessions = try await ReadingSessionTracker.recoverInterrupted(repository: readingRepository)
        let interrupted = try await tasks.markInterruptedOnLaunch()
        let messages = try await reflectionRepository.failInterruptedMessages(reason: "应用在回答完成前被关闭，问题已保留，可重试。")
        return LaunchRecovery(endedSessions: sessions.count, interruptedTasks: interrupted.count, failedMessages: messages)
    }

    /// 构造当前配置下的讨论编排器。
    public func makeOrchestrator() async -> DiscussionOrchestrator {
        let models = await providers.current()
        let retriever = HybridRetriever(chunks: retrievalStore, lexical: retrievalStore, vectors: retrievalStore,
                                        embedder: models.embedding, reranker: models.rerank)
        let deps = ReaderAgentDependencies(
            books: bookRepository, readStates: readingRepository, annotations: readingRepository, reflections: reflectionRepository,
            conversations: reflectionRepository, brain: brainRepository, retriever: retriever,
            generator: models.chat, planner: models.planner, verifier: models.verifier,
            fallbackJudge: environment.fallbackJudge, trace: trace, tasks: tasks, clock: environment.clock, ids: environment.ids)
        return DiscussionOrchestrator(dependencies: deps)
    }

    /// 书库删除时同步记忆证据失效（统一规则 3）。
    public func registerLifecycleObservers() async {
        await library.addObserver(LibraryLifecycleBridge(brain: brain))
    }

    public func exportMarkdown() async throws -> String {
        MarkdownExporter.export(books: try await bookRepository.allBooks(),
                                annotations: try await allAnnotations(),
                                reflections: try await reflectionRepository.reflections(bookID: nil),
                                brainItems: try await brainRepository.items(kinds: nil, includeInactive: false),
                                conversations: try await reflectionRepository.conversations(bookID: nil),
                                messages: try await allMessages())
    }

    func allAnnotations() async throws -> [Annotation] {
        var out: [Annotation] = []
        for b in try await bookRepository.allBooks() { out += try await readingRepository.annotations(bookID: b.id) }
        return out
    }

    func allMessages() async throws -> [Message] {
        var out: [Message] = []
        for c in try await reflectionRepository.conversations(bookID: nil) { out += try await reflectionRepository.messages(conversationID: c.id) }
        return out
    }
}

public struct LaunchRecovery: Sendable, Equatable {
    public var endedSessions: Int
    public var interruptedTasks: Int
    public var failedMessages: Int
}

/// 删除书籍后：记忆中的原文证据标记失效，而不是静默保留（LIB-04、统一规则 3）。
public struct LibraryLifecycleBridge: BookLifecycleObserver {
    let brain: BrainService
    public init(brain: BrainService) { self.brain = brain }

    public func bookSourceDetached(_ bookID: BookID) async {
        _ = try? await brain.invalidateBookSources(bookID: bookID, reason: "阅读文件已删除")
    }

    public func bookPurged(_ bookID: BookID) async {
        _ = try? await brain.invalidateBookSources(bookID: bookID, reason: "书籍已彻底删除")
    }
}

/// 当前模型配置及派生的 Provider（配置变更后重建；向量模型变化触发索引失效）。
public actor ProviderHub {
    public struct Models: Sendable {
        public var chat: ChatModel?
        public var planner: ChatModel?
        public var verifier: ChatModel?
        public var embedding: EmbeddingService?
        public var rerank: RerankService?
    }

    let environment: AppEnvironment
    let settings: SQLiteRuntimeStore
    static let configKey = "provider_config"

    public init(environment: AppEnvironment, settings: SQLiteRuntimeStore) {
        self.environment = environment; self.settings = settings
    }

    public func configuration() async -> ProviderConfiguration {
        guard let raw = try? await settings.setting(Self.configKey), let data = raw.data(using: .utf8),
              let config = try? JSONDecoder().decode(ProviderConfiguration.self, from: data) else {
            return ProviderConfiguration()
        }
        return config
    }

    /// 保存配置（不含密钥）。返回是否需要重建向量索引。
    @discardableResult
    public func save(_ config: ProviderConfiguration) async throws -> Bool {
        let issues = config.validate()
        guard issues.isEmpty else { throw ConfigurationError.invalid(issues) }
        let old = await configuration()
        let data = try JSONEncoder().encode(config)
        try await settings.setSetting(Self.configKey, String(decoding: data, as: UTF8.self))
        return config.embeddingProfileChanged(from: old)
    }

    public func current() async -> Models {
        if let o = environment.overrides {
            return Models(chat: o.chat, planner: o.planner, verifier: o.verifier, embedding: o.embedding, rerank: o.rerank)
        }
        let config = await configuration()
        let factory = ProviderFactory(secrets: environment.secrets, transport: environment.transport)
        return Models(chat: factory.chatModel(config), planner: factory.chatModel(config, role: .planner),
                      verifier: factory.chatModel(config, role: .verifier), embedding: factory.embeddingService(config),
                      rerank: factory.rerankService(config))
    }

    public func checkConnections() async -> [ConnectionCheckResult] {
        if let o = environment.overrides {
            var out: [ConnectionCheckResult] = []
            if let c = o.chat { out.append(await ConnectionChecker.checkChat(c)) }
            if let e = o.embedding { out.append(await ConnectionChecker.checkEmbedding(e)) }
            if let r = o.rerank { out.append(await ConnectionChecker.checkRerank(r)) }
            return out
        }
        return await ProviderFactory(secrets: environment.secrets, transport: environment.transport).checkAll(await configuration())
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case invalid([ProviderConfiguration.ValidationIssue])
}

/// 后台索引协调：导入后建立词法索引；按已读范围增量向量化；模型变化时失效重建。
public actor IndexingCoordinator {
    let books: BookRepository
    let store: SQLiteRetrievalStore
    let readStates: ReadingStateRepository
    let clock: WallClock
    private var running: Set<BookID> = []

    public init(books: BookRepository, store: SQLiteRetrievalStore, readStates: ReadingStateRepository, clock: WallClock) {
        self.books = books; self.store = store; self.readStates = readStates; self.clock = clock
    }

    @discardableResult
    public func ensureLexical(bookID: BookID, profile: EmbeddingProfile?) async throws -> IndexCompatibility? {
        guard let book = try await books.book(id: bookID), book.status == .active else { return nil }
        let chapters = try await books.chapters(bookID: bookID)
        return try await BookIndexer(store: store, embeddings: store, clock: clock).ensureLexicalIndex(book: book, chapters: chapters, profile: profile)
    }

    /// 只对已读范围内的子块生成云向量（7.3）。同一本书并发触发只执行一次。
    public func embedReadContent(bookID: BookID, service: EmbeddingService, budget: IndexingBudget = IndexingBudget(),
                                 onProgress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> IndexingReport? {
        guard !running.contains(bookID) else { return nil }
        running.insert(bookID)
        defer { running.remove(bookID) }
        guard let book = try await books.book(id: bookID), book.status == .active else { return nil }
        try await ensureLexical(bookID: bookID, profile: service.profile)
        let state = try await readStates.readState(bookID: bookID, version: book.fingerprint)
        return await BookIndexer(store: store, embeddings: store, clock: clock)
            .embed(bookID: bookID, scope: AccessScope.readOnly(state), service: service, budget: budget, onProgress: onProgress)
    }
}
