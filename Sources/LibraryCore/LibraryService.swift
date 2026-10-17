import Foundation

/// 书籍仓储接口（由 Persistence 实现）。
public protocol BookRepository: Sendable {
    /// 原子写入书籍、章节与目录；失败时不得留下可见书籍。
    func insert(_ book: Book, chapters: [Chapter], toc: [TOCEntry]) async throws
    func book(id: BookID) async throws -> Book?
    func book(fingerprint: String) async throws -> Book?
    func allBooks() async throws -> [Book]
    func chapters(bookID: BookID) async throws -> [Chapter]
    func chapter(bookID: BookID, index: Int) async throws -> Chapter?
    func toc(bookID: BookID) async throws -> [TOCEntry]
    func update(_ book: Book) async throws
    /// 保留个人笔记，仅移除阅读文件相关的正文、索引；书籍标记为 sourceUnavailable。
    func detachSource(bookID: BookID) async throws
    /// 彻底删除：书籍、章节、索引、批注、会话、反思、讨论等全部关联。
    func purge(bookID: BookID) async throws
    /// 对来源已失效的书重新挂接正文（同一指纹重新导入）。
    func reattach(bookID: BookID, chapters: [Chapter], toc: [TOCEntry], fileName: String, fileSize: Int) async throws
}

/// 书籍文件与封面存储（App 使用沙盒目录，测试使用内存实现）。
public protocol BookFileStore: Sendable {
    func save(_ data: Data, for bookID: BookID, fileName: String) async throws
    func saveCover(_ data: Data, for bookID: BookID) async throws
    func loadFile(for bookID: BookID) async throws -> Data?
    func loadCover(for bookID: BookID) async throws -> Data?
    func removeAll(for bookID: BookID) async throws
    func exists(for bookID: BookID) async -> Bool
}

/// 导入结果。
public enum ImportOutcome: Sendable, Equatable {
    case imported(Book)
    /// 相同内容已在书库中（LIB-02）。
    case duplicate(existing: Book)
    /// 之前仅删除了阅读文件，重新导入相同内容后恢复。
    case restoredSource(Book)

    public var book: Book {
        switch self {
        case .imported(let b), .duplicate(let b), .restoredSource(let b): return b
        }
    }
}

public enum ImportError: Error, Equatable, Sendable {
    case invalidEPUB(EPUBError)
    case storageFailed(String)
    case unreadableFile(String)

    public var userMessage: String {
        switch self {
        case .invalidEPUB(let e): return e.userMessage
        case .storageFailed(let r): return "保存书籍失败：\(r)"
        case .unreadableFile(let r): return "无法读取文件：\(r)"
        }
    }
}

/// 删除策略（LIB-04）。
public enum BookDeletionPolicy: String, Sendable, Codable, CaseIterable {
    /// 删除阅读文件，保留批注、反思和记忆；来源标记为不可访问。
    case removeFileKeepNotes
    /// 彻底删除书籍及所有相关内容、索引与关联。
    case purgeEverything
}

/// 删除后通知其他领域（例如记忆证据失效、索引清理）。
public protocol BookLifecycleObserver: Sendable {
    func bookSourceDetached(_ bookID: BookID) async
    func bookPurged(_ bookID: BookID) async
}

public enum LibrarySort: String, Sendable, CaseIterable, Codable {
    case recentlyOpened, title, author, progress, importedAt
}

/// 书库服务：导入、查询、删除。串行化导入/删除，避免与后台索引竞争产生不一致（LIB-03）。
public actor LibraryService {
    private let repository: BookRepository
    private let files: BookFileStore
    private let parser: EPUBParser
    private let clock: WallClock
    private let ids: IDGenerating
    private var observers: [BookLifecycleObserver] = []
    /// 正在导入的指纹，防止并发重复导入同一文件。
    private var importing: Set<String> = []

    public init(repository: BookRepository, files: BookFileStore, parser: EPUBParser = EPUBParser(),
                clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator()) {
        self.repository = repository; self.files = files; self.parser = parser
        self.clock = clock; self.ids = ids
    }

    public func addObserver(_ observer: BookLifecycleObserver) { observers.append(observer) }

    public func importBook(from url: URL) async throws -> ImportOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ImportError.unreadableFile(error.localizedDescription)
        }
        return try await importBook(data: data, fileName: url.lastPathComponent)
    }

    public func importBook(data: Data, fileName: String) async throws -> ImportOutcome {
        guard !data.isEmpty else { throw ImportError.invalidEPUB(.emptyFile) }
        let fingerprint = Fingerprint.sha256(data)
        if let existing = try await repository.book(fingerprint: fingerprint) {
            if existing.status == .active { return .duplicate(existing: existing) }
        }
        guard !importing.contains(fingerprint) else {
            // 同一文件并发导入：等待第一次完成后按重复处理
            while importing.contains(fingerprint) { await Task.yield() }
            if let existing = try await repository.book(fingerprint: fingerprint) { return .duplicate(existing: existing) }
            throw ImportError.storageFailed("并发导入失败")
        }
        importing.insert(fingerprint)
        defer { importing.remove(fingerprint) }

        let publication: ParsedPublication
        do { publication = try parser.parse(data: data, fileName: fileName) } catch let e as EPUBError {
            throw ImportError.invalidEPUB(e)
        }

        // 来源曾被删除但保留笔记：重新挂接正文
        if let existing = try await repository.book(fingerprint: fingerprint), existing.status == .sourceUnavailable {
            let chapters = Self.makeChapters(publication, bookID: existing.id)
            do {
                try await files.save(data, for: existing.id, fileName: fileName)
                if let cover = publication.cover { try await files.saveCover(cover, for: existing.id) }
                try await repository.reattach(bookID: existing.id, chapters: chapters, toc: publication.toc,
                                              fileName: fileName, fileSize: data.count)
            } catch {
                try? await files.removeAll(for: existing.id)
                throw ImportError.storageFailed("\(error)")
            }
            guard let restored = try await repository.book(id: existing.id) else {
                throw ImportError.storageFailed("恢复后无法读取书籍")
            }
            return .restoredSource(restored)
        }

        let bookID = ids.make("book")
        let book = Book(id: bookID, title: publication.title, authors: publication.authors,
                        language: publication.language, identifier: publication.identifier,
                        fingerprint: fingerprint, fileName: fileName, fileSize: data.count,
                        chapterCount: publication.chapters.count, hasCover: publication.cover != nil,
                        importedAt: clock.now())
        let chapters = Self.makeChapters(publication, bookID: bookID)
        do {
            try await files.save(data, for: bookID, fileName: fileName)
            if let cover = publication.cover { try await files.saveCover(cover, for: bookID) }
            try await repository.insert(book, chapters: chapters, toc: publication.toc)
        } catch {
            // 失败不残留半成品：清理文件；仓储写入本身是事务性的
            try? await files.removeAll(for: bookID)
            throw ImportError.storageFailed("\(error)")
        }
        return .imported(book)
    }

    static func makeChapters(_ p: ParsedPublication, bookID: BookID) -> [Chapter] {
        p.chapters.map {
            Chapter(bookID: bookID, index: $0.index, href: $0.href, title: $0.title, text: $0.text,
                    anchors: $0.anchors, isLinear: $0.isLinear)
        }
    }

    public func books(matching query: String = "", sort: LibrarySort = .recentlyOpened) async throws -> [Book] {
        let all = try await repository.allBooks()
        return LibraryQuery.filter(all, query: query, sort: sort)
    }

    public func delete(bookID: BookID, policy: BookDeletionPolicy) async throws {
        guard try await repository.book(id: bookID) != nil else { return }
        switch policy {
        case .removeFileKeepNotes:
            try await repository.detachSource(bookID: bookID)
            try await files.removeAll(for: bookID)
            for o in observers { await o.bookSourceDetached(bookID) }
        case .purgeEverything:
            try await repository.purge(bookID: bookID)
            try await files.removeAll(for: bookID)
            for o in observers { await o.bookPurged(bookID) }
        }
    }

    public func markOpened(bookID: BookID) async throws {
        guard var book = try await repository.book(id: bookID) else { return }
        book.lastOpenedAt = clock.now()
        try await repository.update(book)
    }

    public func updateProgress(bookID: BookID, progress: Double) async throws {
        guard var book = try await repository.book(id: bookID) else { return }
        book.displayProgress = min(1, max(0, progress))
        try await repository.update(book)
    }

    public func setIndexState(bookID: BookID, state: IndexState) async throws {
        // 书籍在索引过程中被删除时静默忽略，避免复活已删除记录（LIB-03）
        guard var book = try await repository.book(id: bookID), book.status == .active else { return }
        book.indexState = state
        try await repository.update(book)
    }
}

/// 书库搜索与排序（纯函数，便于测试）。
public enum LibraryQuery {
    public static func filter(_ books: [Book], query: String, sort: LibrarySort) -> [Book] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? books : books.filter {
            $0.title.lowercased().contains(q) || $0.authors.contains { $0.lowercased().contains(q) }
        }
        return filtered.sorted { a, b in
            switch sort {
            case .title:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .author:
                return a.authorLine.localizedStandardCompare(b.authorLine) == .orderedAscending
            case .progress:
                return a.displayProgress == b.displayProgress ? a.id < b.id : a.displayProgress > b.displayProgress
            case .importedAt:
                return a.importedAt == b.importedAt ? a.id < b.id : a.importedAt > b.importedAt
            case .recentlyOpened:
                let da = a.lastOpenedAt ?? a.importedAt, db = b.lastOpenedAt ?? b.importedAt
                return da == db ? a.id < b.id : da > db
            }
        }
    }
}
