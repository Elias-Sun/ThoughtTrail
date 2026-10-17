import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore

/// 阅读现场快照：保存时冻结，后续更换阅读位置不会覆盖（REF-01）。
public struct ReadingContextSnapshot: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var bookVersion: String
    public var bookTitle: String
    public var chapterIndex: Int?
    public var chapterTitle: String?
    public var locator: Locator?
    public var selectedText: String?
    public var sessionID: String?
    public var capturedAt: Date

    public init(bookID: BookID, bookVersion: String, bookTitle: String, chapterIndex: Int?, chapterTitle: String?,
                locator: Locator?, selectedText: String?, sessionID: String?, capturedAt: Date) {
        self.bookID = bookID; self.bookVersion = bookVersion; self.bookTitle = bookTitle
        self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle; self.locator = locator
        self.selectedText = selectedText; self.sessionID = sessionID; self.capturedAt = capturedAt
    }
}

public enum ReflectionSource: String, Codable, Sendable {
    case typed
    case voice
}

public enum ReflectionState: String, Codable, Sendable {
    case draft
    case saved
}

/// 一条反思。草稿与已保存共用实体，通过 `state` 区分。
public struct Reflection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var context: ReadingContextSnapshot
    public var text: String
    public var source: ReflectionSource
    /// 语音转写原文（人工修改前），便于追溯。
    public var originalTranscript: String?
    public var audioFileName: String?
    public var state: ReflectionState
    public var createdAt: Date
    public var updatedAt: Date
    /// 提交幂等键：连续点击保存不会产生重复记录（REF-02）。
    public var commitKey: String?
    /// 来源书籍已删除时为 true（笔记保留，但不再作为可访问书籍证据）。
    public var sourceUnavailable: Bool

    public init(id: String, context: ReadingContextSnapshot, text: String, source: ReflectionSource,
                originalTranscript: String? = nil, audioFileName: String? = nil, state: ReflectionState,
                createdAt: Date, updatedAt: Date, commitKey: String? = nil, sourceUnavailable: Bool = false) {
        self.id = id; self.context = context; self.text = text; self.source = source
        self.originalTranscript = originalTranscript; self.audioFileName = audioFileName; self.state = state
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.commitKey = commitKey
        self.sourceUnavailable = sourceUnavailable
    }

    public var bookID: BookID { context.bookID }
}

/// 已保存反思的修改记录。
public struct ReflectionEdit: Codable, Hashable, Sendable {
    public var reflectionID: String
    public var before: String
    public var after: String
    public var editedAt: Date

    public init(reflectionID: String, before: String, after: String, editedAt: Date) {
        self.reflectionID = reflectionID; self.before = before; self.after = after; self.editedAt = editedAt
    }
}

public protocol ReflectionRepository: Sendable {
    func save(_ reflection: Reflection) async throws
    func reflection(id: String) async throws -> Reflection?
    func reflection(commitKey: String) async throws -> Reflection?
    func reflections(bookID: BookID?) async throws -> [Reflection]
    func drafts() async throws -> [Reflection]
    func delete(id: String) async throws
    func appendEdit(_ edit: ReflectionEdit) async throws
    func edits(reflectionID: String) async throws -> [ReflectionEdit]
}

public enum ReflectionError: Error, Equatable, Sendable {
    case emptyText
    case notFound
    case alreadySaved
}

/// 反思服务：草稿自动保存、提交幂等、修改留痕。
public actor ReflectionService {
    private let repository: ReflectionRepository
    private let clock: WallClock
    private let ids: IDGenerating
    public static let maxLength = 20_000

    public init(repository: ReflectionRepository, clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator()) {
        self.repository = repository; self.clock = clock; self.ids = ids
    }

    /// 新建草稿（快照立即冻结）。
    public func startDraft(context: ReadingContextSnapshot, text: String = "", source: ReflectionSource = .typed) async throws -> Reflection {
        let now = clock.now()
        let r = Reflection(id: ids.make("refl"), context: context, text: String(text.prefix(Self.maxLength)),
                           source: source, state: .draft, createdAt: now, updatedAt: now)
        try await repository.save(r)
        return r
    }

    /// 更新草稿内容（自动保存）。已保存的反思应使用 `edit`。
    public func updateDraft(id: String, text: String, transcript: String? = nil, audioFileName: String? = nil) async throws -> Reflection {
        guard var r = try await repository.reflection(id: id) else { throw ReflectionError.notFound }
        guard r.state == .draft else { throw ReflectionError.alreadySaved }
        r.text = String(text.prefix(Self.maxLength))
        if let transcript { r.originalTranscript = transcript; r.source = .voice }
        if let audioFileName { r.audioFileName = audioFileName }
        r.updatedAt = clock.now()
        try await repository.save(r)
        return r
    }

    /// 提交草稿。同一 commitKey 重复提交返回同一记录。
    public func commit(id: String, commitKey: String) async throws -> Reflection {
        if let existing = try await repository.reflection(commitKey: commitKey) { return existing }
        guard var r = try await repository.reflection(id: id) else { throw ReflectionError.notFound }
        if r.state == .saved { return r }
        guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReflectionError.emptyText }
        r.state = .saved
        r.commitKey = commitKey
        r.updatedAt = clock.now()
        try await repository.save(r)
        return r
    }

    /// 修改已保存的反思，保留前后内容。
    public func edit(id: String, newText: String) async throws -> Reflection {
        guard var r = try await repository.reflection(id: id) else { throw ReflectionError.notFound }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReflectionError.emptyText }
        guard trimmed != r.text else { return r }
        let now = clock.now()
        try await repository.appendEdit(ReflectionEdit(reflectionID: id, before: r.text, after: trimmed, editedAt: now))
        r.text = trimmed
        r.updatedAt = now
        try await repository.save(r)
        return r
    }

    public func discardDraft(id: String) async throws {
        guard let r = try await repository.reflection(id: id) else { return }
        guard r.state == .draft else { throw ReflectionError.alreadySaved }
        try await repository.delete(id: id)
    }

    /// 应用重启后恢复的草稿（按更新时间倒序）。
    public func pendingDrafts() async throws -> [Reflection] {
        try await repository.drafts().sorted { $0.updatedAt > $1.updatedAt }
    }

    public func reflections(bookID: BookID?) async throws -> [Reflection] {
        try await repository.reflections(bookID: bookID).filter { $0.state == .saved }.sorted { $0.createdAt > $1.createdAt }
    }
}
