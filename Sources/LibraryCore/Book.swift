import Foundation

public typealias BookID = String

/// 书籍状态。`sourceUnavailable` 表示阅读文件已删除但保留个人笔记（LIB-04）。
public enum BookStatus: String, Codable, Sendable, CaseIterable {
    case active
    case sourceUnavailable
}

/// 后台索引状态，仅用于书库展示。
public enum IndexState: String, Codable, Sendable {
    case notIndexed, lexicalReady, indexing, ready, paused, failed
}

public struct Book: Codable, Hashable, Sendable, Identifiable {
    public var id: BookID
    public var title: String
    public var authors: [String]
    public var language: String
    public var identifier: String?
    /// 文件内容 SHA-256，作为书籍版本。证据与定位绑定此版本。
    public var fingerprint: String
    public var fileName: String
    public var fileSize: Int
    public var chapterCount: Int
    public var hasCover: Bool
    public var status: BookStatus
    public var indexState: IndexState
    public var importedAt: Date
    public var lastOpenedAt: Date?
    /// 仅用于展示的进度（0...1），不决定可检索范围。
    public var displayProgress: Double

    public init(id: BookID, title: String, authors: [String], language: String, identifier: String?,
                fingerprint: String, fileName: String, fileSize: Int, chapterCount: Int, hasCover: Bool,
                status: BookStatus = .active, indexState: IndexState = .notIndexed, importedAt: Date,
                lastOpenedAt: Date? = nil, displayProgress: Double = 0) {
        self.id = id; self.title = title; self.authors = authors; self.language = language
        self.identifier = identifier; self.fingerprint = fingerprint; self.fileName = fileName
        self.fileSize = fileSize; self.chapterCount = chapterCount; self.hasCover = hasCover
        self.status = status; self.indexState = indexState; self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt; self.displayProgress = displayProgress
    }

    public var authorLine: String { authors.isEmpty ? Book.unknownAuthor : authors.joined(separator: "、") }

    public static let unknownAuthor = "佚名"
    public static let untitled = "未命名书籍"
}

/// 书籍章节（spine 中的一项）。`text` 为规范化正文，所有定位使用其 UTF-16 偏移。
public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public var bookID: BookID
    public var index: Int
    public var href: String
    public var title: String
    public var text: String
    /// 片段 id → 正文偏移，用于目录锚点跳转。
    public var anchors: [String: Int]
    public var isLinear: Bool

    public var id: String { "\(bookID)#\(index)" }
    public var length: Int { text.utf16Length }

    public init(bookID: BookID, index: Int, href: String, title: String, text: String,
                anchors: [String: Int] = [:], isLinear: Bool = true) {
        self.bookID = bookID; self.index = index; self.href = href; self.title = title
        self.text = text; self.anchors = anchors; self.isLinear = isLinear
    }

    /// 段落区间（以换行分隔）。
    public var paragraphRanges: [TextSpan] {
        var result: [TextSpan] = []
        var start = 0
        var offset = 0
        for unit in text.utf16 {
            if unit == 0x0A { // \n
                if offset > start { result.append(TextSpan(start: start, end: offset)) }
                start = offset + 1
            }
            offset += 1
        }
        if offset > start { result.append(TextSpan(start: start, end: offset)) }
        return result
    }
}

public struct TOCEntry: Codable, Hashable, Sendable {
    public var title: String
    public var level: Int
    public var chapterIndex: Int?
    public var offset: Int
    public var href: String

    public init(title: String, level: Int, chapterIndex: Int?, offset: Int, href: String) {
        self.title = title; self.level = level; self.chapterIndex = chapterIndex
        self.offset = offset; self.href = href
    }
}
