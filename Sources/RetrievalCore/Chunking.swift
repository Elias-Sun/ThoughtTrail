import Foundation
import LibraryCore

/// 父块：上下文扩展单位（Small-to-Big）。
public struct ParentChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var bookVersion: String
    public var chapterIndex: Int
    public var range: TextSpan
    public var text: String
    public var fingerprint: String

    public init(id: String, bookID: BookID, bookVersion: String, chapterIndex: Int, range: TextSpan, text: String, fingerprint: String) {
        self.id = id; self.bookID = bookID; self.bookVersion = bookVersion; self.chapterIndex = chapterIndex
        self.range = range; self.text = text; self.fingerprint = fingerprint
    }
}

/// 子块：召回单位。每个子块都可回查到阅读器（RAG-01）。
public struct ChildChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var parentID: String
    public var bookID: BookID
    public var bookVersion: String
    public var chapterIndex: Int
    public var range: TextSpan
    public var text: String
    public var fingerprint: String

    public init(id: String, parentID: String, bookID: BookID, bookVersion: String, chapterIndex: Int, range: TextSpan,
                text: String, fingerprint: String) {
        self.id = id; self.parentID = parentID; self.bookID = bookID; self.bookVersion = bookVersion
        self.chapterIndex = chapterIndex; self.range = range; self.text = text; self.fingerprint = fingerprint
    }
}

public struct ChunkingConfig: Codable, Hashable, Sendable {
    public var parentMaxChars: Int
    public var childMaxChars: Int
    public var childMinChars: Int

    public init(parentMaxChars: Int = 1_200, childMaxChars: Int = 320, childMinChars: Int = 24) {
        self.parentMaxChars = max(childMaxChars, parentMaxChars)
        self.childMaxChars = max(16, childMaxChars)
        self.childMinChars = max(1, min(childMinChars, childMaxChars))
    }

    /// 切块策略版本：变化时触发重建（RAG-05）。
    public var version: String { "pc1-p\(parentMaxChars)-c\(childMaxChars)-m\(childMinChars)-\(TextSegmenter.version)" }
}

public struct ChunkSet: Sendable, Hashable {
    public var parents: [ParentChunk]
    public var children: [ChildChunk]

    public init(parents: [ParentChunk], children: [ChildChunk]) {
        self.parents = parents; self.children = children
    }
}

/// 父子切块：按段落聚合为父块，父块内按句聚合为子块。区间为章节内绝对 UTF-16 偏移。
public struct Chunker: Sendable {
    public let config: ChunkingConfig

    public init(config: ChunkingConfig = ChunkingConfig()) { self.config = config }

    public func chunk(chapter: Chapter, bookVersion: String) -> ChunkSet {
        let text = chapter.text
        var parents: [ParentChunk] = []
        var children: [ChildChunk] = []
        let versionTag = String(bookVersion.prefix(12))

        for parentRange in parentRanges(text: text, paragraphs: chapter.paragraphRanges) {
            let parentText = text.substring(utf16: parentRange)
            guard !parentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let pid = "\(chapter.bookID)/\(versionTag):\(chapter.index):p\(parents.count)"
            parents.append(ParentChunk(id: pid, bookID: chapter.bookID, bookVersion: bookVersion,
                                       chapterIndex: chapter.index, range: parentRange, text: parentText,
                                       fingerprint: Fingerprint.short(parentText, length: 16)))
            for childRange in childRanges(text: text, parent: parentRange) {
                let childText = text.substring(utf16: childRange)
                let trimmed = childText.trimmingCharacters(in: .whitespacesAndNewlines)
                // 空文本不进入有效索引（RAG-02）
                guard !trimmed.isEmpty, !TextSegmenter().tokens(trimmed).isEmpty else { continue }
                let cid = "\(pid):c\(children.count)"
                children.append(ChildChunk(id: cid, parentID: pid, bookID: chapter.bookID, bookVersion: bookVersion,
                                           chapterIndex: chapter.index, range: childRange, text: childText,
                                           fingerprint: Fingerprint.short(childText, length: 16)))
            }
        }
        return ChunkSet(parents: parents, children: children)
    }

    public func chunk(chapters: [Chapter], bookVersion: String) -> ChunkSet {
        var all = ChunkSet(parents: [], children: [])
        for c in chapters {
            let s = chunk(chapter: c, bookVersion: bookVersion)
            all.parents += s.parents
            all.children += s.children
        }
        return all
    }

    /// 段落聚合为父块；超长段落按句切分。
    func parentRanges(text: String, paragraphs: [TextSpan]) -> [TextSpan] {
        var units: [TextSpan] = []
        for p in paragraphs {
            if p.length <= config.parentMaxChars { units.append(p); continue }
            units += pack(SentenceSplitter.sentences(in: text, range: p), max: config.parentMaxChars)
        }
        return pack(units, max: config.parentMaxChars)
    }

    /// 父块内按句聚合为子块；过短的尾块并入前一块。
    func childRanges(text: String, parent: TextSpan) -> [TextSpan] {
        let sentences = SentenceSplitter.sentences(in: text, range: parent).flatMap { s -> [TextSpan] in
            guard s.length > config.childMaxChars else { return [s] }
            // 极长句：硬切
            var out: [TextSpan] = []
            var start = s.start
            while start < s.end {
                let end = min(s.end, start + config.childMaxChars)
                out.append(TextSpan(start: start, end: end))
                start = end
            }
            return out
        }
        var packed = pack(sentences, max: config.childMaxChars)
        if packed.count >= 2, let last = packed.last, last.length < config.childMinChars {
            packed.removeLast()
            packed[packed.count - 1] = packed[packed.count - 1].union(last)
        }
        return packed
    }

    /// 相邻区间贪心合并，不超过 max（单个超长单元保持原样）。合并后区间覆盖中间的分隔符。
    func pack(_ units: [TextSpan], max: Int) -> [TextSpan] {
        var out: [TextSpan] = []
        var current: TextSpan?
        for u in units {
            if let c = current {
                if u.end - c.start <= max { current = c.union(u) } else { out.append(c); current = u }
            } else {
                current = u
            }
        }
        if let c = current { out.append(c) }
        return out
    }
}
