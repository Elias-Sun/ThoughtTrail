import Foundation
import LibraryCore

public enum AnnotationKind: String, Codable, Sendable, CaseIterable {
    case highlight
    case note
}

public enum HighlightColor: String, Codable, Sendable, CaseIterable {
    case yellow, green, blue, pink, purple
}

/// 高亮/笔记（READ-02）。
public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var locator: Locator
    public var kind: AnnotationKind
    public var color: HighlightColor
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, bookID: BookID, locator: Locator, kind: AnnotationKind, color: HighlightColor,
                note: String?, createdAt: Date, updatedAt: Date) {
        self.id = id; self.bookID = bookID; self.locator = locator; self.kind = kind
        self.color = color; self.note = note; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var quote: String { locator.anchor.exact }
}

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var locator: Locator
    public var title: String
    public var createdAt: Date

    public init(id: String, bookID: BookID, locator: Locator, title: String, createdAt: Date) {
        self.id = id; self.bookID = bookID; self.locator = locator; self.title = title; self.createdAt = createdAt
    }
}

/// 批注、书签与阅读位置仓储接口。
public protocol AnnotationRepository: Sendable {
    func save(_ annotation: Annotation) async throws
    func delete(annotationID: String) async throws
    func annotation(id: String) async throws -> Annotation?
    func annotations(bookID: BookID) async throws -> [Annotation]
    func save(_ bookmark: Bookmark) async throws
    func delete(bookmarkID: String) async throws
    func bookmarks(bookID: BookID) async throws -> [Bookmark]
    func savePosition(_ position: ReadingPosition) async throws
    func position(bookID: BookID) async throws -> ReadingPosition?
}

public enum AnnotationError: Error, Equatable, Sendable {
    case emptySelection
    case notFound
    case selectionOutOfChapter
}

/// 批注服务：新增/修改/删除立即持久化；跳转时通过 LocatorResolver 回到原文。
public actor AnnotationService {
    private let repository: AnnotationRepository
    private let clock: WallClock
    private let ids: IDGenerating
    private let resolver = LocatorResolver()

    public init(repository: AnnotationRepository, clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator()) {
        self.repository = repository; self.clock = clock; self.ids = ids
    }

    public func addHighlight(book: Book, chapter: Chapter, range: TextSpan, color: HighlightColor = .yellow,
                             note: String? = nil) async throws -> Annotation {
        guard !range.isEmpty else { throw AnnotationError.emptySelection }
        guard range.end <= chapter.length else { throw AnnotationError.selectionOutOfChapter }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = clock.now()
        let a = Annotation(id: ids.make("ann"), bookID: book.id,
                           locator: Locator.make(book: book, chapter: chapter, range: range),
                           kind: (trimmedNote?.isEmpty == false) ? .note : .highlight,
                           color: color, note: (trimmedNote?.isEmpty == false) ? trimmedNote : nil,
                           createdAt: now, updatedAt: now)
        try await repository.save(a)
        return a
    }

    public func updateNote(annotationID: String, note: String?) async throws -> Annotation {
        guard var a = try await repository.annotation(id: annotationID) else { throw AnnotationError.notFound }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        a.note = (trimmed?.isEmpty == false) ? trimmed : nil
        a.kind = a.note == nil ? .highlight : .note
        a.updatedAt = clock.now()
        try await repository.save(a)
        return a
    }

    public func updateColor(annotationID: String, color: HighlightColor) async throws -> Annotation {
        guard var a = try await repository.annotation(id: annotationID) else { throw AnnotationError.notFound }
        a.color = color
        a.updatedAt = clock.now()
        try await repository.save(a)
        return a
    }

    public func delete(annotationID: String) async throws {
        try await repository.delete(annotationID: annotationID)
    }

    public func annotations(bookID: BookID) async throws -> [Annotation] {
        try await repository.annotations(bookID: bookID).sorted {
            ($0.locator.chapterIndex, $0.locator.range.start) < ($1.locator.chapterIndex, $1.locator.range.start)
        }
    }

    /// 切换书签：同章同页已有书签则移除，否则新增。
    public func toggleBookmark(book: Book, chapter: Chapter, page: TextSpan) async throws -> Bookmark? {
        let existing = try await repository.bookmarks(bookID: book.id).first {
            $0.locator.chapterIndex == chapter.index && page.contains($0.locator.range.start)
        }
        if let existing {
            try await repository.delete(bookmarkID: existing.id)
            return nil
        }
        let start = TextSpan(start: page.start, end: min(page.end, page.start + 24))
        let title = chapter.text.substring(utf16: start).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = Bookmark(id: ids.make("bm"), bookID: book.id, locator: Locator.make(book: book, chapter: chapter, range: start),
                         title: title.isEmpty ? chapter.title : title, createdAt: clock.now())
        try await repository.save(b)
        return b
    }

    public func savePosition(_ locator: Locator) async throws {
        try await repository.savePosition(ReadingPosition(bookID: locator.bookID, locator: locator, updatedAt: clock.now()))
    }

    public func lastPosition(bookID: BookID) async throws -> ReadingPosition? {
        try await repository.position(bookID: bookID)
    }

    /// 点击批注/引用后回到原文。
    public func resolve(_ locator: Locator, book: Book, chapters: [Chapter]) -> LocatorResolution {
        resolver.resolve(locator, currentVersion: book.fingerprint, chapters: chapters)
    }
}
