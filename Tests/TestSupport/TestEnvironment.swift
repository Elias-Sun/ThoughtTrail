import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import RetrievalCore
import ContextEngineering
import BrainCore
import AgentRuntime
import ReaderAgent
import Persistence
import EvidenceVerificationCore
import LearningCore

/// 基于内存 SQLite 的完整测试环境（跨模块集成测试使用真实仓储与检索实现）。
public struct TestEnvironment: Sendable {
    public let db: AppDatabase
    public let books: SQLiteBookRepository
    public let reading: SQLiteReadingRepository
    public let reflections: SQLiteReflectionRepository
    public let retrieval: SQLiteRetrievalStore
    public let brain: SQLiteBrainRepository
    public let learning: SQLiteLearningRepository
    public let runtime: SQLiteRuntimeStore
    public let files: InMemoryBookFileStore
    public let clock: ManualClock
    public let ids: SequentialIDGenerator
    public let library: LibraryService

    public init() throws {
        db = try AppDatabase.inMemory()
        books = SQLiteBookRepository(db)
        reading = SQLiteReadingRepository(db)
        reflections = SQLiteReflectionRepository(db)
        retrieval = SQLiteRetrievalStore(db)
        brain = SQLiteBrainRepository(db)
        learning = SQLiteLearningRepository(db)
        runtime = SQLiteRuntimeStore(db)
        files = InMemoryBookFileStore()
        clock = ManualClock()
        ids = SequentialIDGenerator()
        library = LibraryService(repository: books, files: files, clock: clock, ids: ids)
    }

    /// 导入并建立词法索引。
    public func importBook(_ data: Data, name: String = "book.epub", profile: EmbeddingProfile? = nil) async throws -> (Book, [Chapter]) {
        let outcome = try await library.importBook(data: data, fileName: name)
        let book = outcome.book
        let chapters = try await books.chapters(bookID: book.id)
        try await BookIndexer(store: retrieval, embeddings: retrieval, clock: clock).ensureLexicalIndex(book: book, chapters: chapters, profile: profile)
        return (book, chapters)
    }

    /// 把若干章节整章标记为已读。
    public func markRead(_ book: Book, chapters: [Chapter], indices: [Int]) async throws {
        for c in chapters where indices.contains(c.index) {
            try await reading.addReadRange(bookID: book.id, version: book.fingerprint, chapterIndex: c.index, range: TextSpan(start: 0, end: c.length))
        }
    }

    public func scope(_ book: Book, mode: ScopeMode = .readOnly) async throws -> AccessScope {
        let state = try await reading.readState(bookID: book.id, version: book.fingerprint)
        return mode == .readOnly ? .readOnly(state) : .wholeBook(bookID: book.id, version: book.fingerprint)
    }

    public func retriever(embedder: EmbeddingService? = nil, reranker: RerankService? = nil, config: RetrievalConfig = .default) -> HybridRetriever {
        HybridRetriever(chunks: retrieval, lexical: retrieval, vectors: retrieval, embedder: embedder, reranker: reranker, config: config)
    }

    public func orchestrator(generator: ChatModel?, planner: ChatModel? = nil, verifier: ChatModel? = nil,
                             fallbackJudge: ClaimJudge? = HeuristicClaimJudge(), embedder: EmbeddingService? = nil,
                             reranker: RerankService? = nil, limits: ExecutionLimits = .discussion,
                             trace: TraceRecorder = TraceRecorder()) -> DiscussionOrchestrator {
        DiscussionOrchestrator(dependencies: ReaderAgentDependencies(
            books: books, readStates: reading, annotations: reading, reflections: reflections, conversations: reflections,
            brain: brain, retriever: retriever(embedder: embedder, reranker: reranker), generator: generator, planner: planner,
            verifier: verifier, fallbackJudge: fallbackJudge, trace: trace,
            tasks: TaskRegistry(store: runtime, clock: clock, ids: ids), clock: clock, ids: ids, sleeper: ImmediateSleeper(),
            limits: limits))
    }

    public func conversationService() -> ConversationService {
        ConversationService(repository: reflections, clock: clock, ids: ids)
    }

    /// 创建讨论并保存用户问题。
    public func startDiscussion(book: Book, question: String, selection: String? = nil, scope: ScopeMode = .readOnly,
                                extraBooks: [BookID] = []) async throws -> (Conversation, Message) {
        let svc = conversationService()
        let ctx = ReadingContextSnapshot(bookID: book.id, bookVersion: book.fingerprint, bookTitle: book.title, chapterIndex: 0,
                                         chapterTitle: nil, locator: nil, selectedText: selection, sessionID: nil, capturedAt: clock.now())
        let conv = try await svc.startConversation(context: ctx, scopeMode: scope, additionalBookIDs: extraBooks)
        let msg = try await svc.addUserMessage(conversationID: conv.id, text: question)
        return (conv, msg)
    }
}

/// 常用构造器。
public enum Make {
    public static func book(id: BookID = "b1", fingerprint: String = "fp1", title: String = "书", status: BookStatus = .active,
                            importedAt: Date = Date(timeIntervalSince1970: 1_000), progress: Double = 0, authors: [String] = ["作者"]) -> Book {
        Book(id: id, title: title, authors: authors, language: "zh", identifier: nil, fingerprint: fingerprint, fileName: "\(id).epub",
             fileSize: 100, chapterCount: 1, hasCover: false, status: status, importedAt: importedAt, displayProgress: progress)
    }

    public static func chapter(bookID: BookID = "b1", index: Int = 0, text: String, title: String = "章") -> Chapter {
        Chapter(bookID: bookID, index: index, href: "ch\(index).xhtml", title: title, text: text)
    }

    public static func evidence(_ label: String, _ text: String, kind: EvidenceKind = .bookText, bookID: BookID = "b1", version: String = "fp1",
                                chapter: Int = 0, range: TextSpan? = nil) -> Evidence {
        Evidence(id: "ev-\(label.isEmpty ? Fingerprint.short(text + kind.rawValue) : label)", label: label, kind: kind, bookID: kind.isBookEvidence ? bookID : nil,
                 bookVersion: kind.isBookEvidence ? version : nil, chapterIndex: kind.isBookEvidence ? chapter : nil,
                 range: kind.isBookEvidence ? (range ?? TextSpan(start: 0, end: text.utf16Length)) : nil, text: text)
    }

    public static func wholeScope(bookID: BookID = "b1", version: String = "fp1") -> RetrievalScope {
        RetrievalScope([AccessScope.wholeBook(bookID: bookID, version: version)])
    }
}
