import Foundation
import LibraryCore

/// 有序、不重叠的区间集合。插入时合并重叠/相接区间（READ-04）。
public struct ReadRangeSet: Codable, Hashable, Sendable {
    public private(set) var ranges: [TextSpan]

    public init(_ ranges: [TextSpan] = []) {
        self.ranges = []
        for r in ranges { insert(r) }
    }

    public var isEmpty: Bool { ranges.isEmpty }
    public var coveredLength: Int { ranges.reduce(0) { $0 + $1.length } }

    public mutating func insert(_ range: TextSpan) {
        guard !range.isEmpty else { return }
        var merged = range
        var result: [TextSpan] = []
        result.reserveCapacity(ranges.count + 1)
        var inserted = false
        for r in ranges {
            if r.touches(merged) {
                merged = merged.union(r)
            } else if r.end < merged.start {
                result.append(r)
            } else {
                if !inserted { result.append(merged); inserted = true }
                result.append(r)
            }
        }
        if !inserted { result.append(merged) }
        ranges = result.sorted()
    }

    public mutating func formUnion(_ other: ReadRangeSet) {
        for r in other.ranges { insert(r) }
    }

    /// 区间是否被完全覆盖。
    public func contains(_ range: TextSpan) -> Bool {
        if range.isEmpty { return ranges.contains { $0.start <= range.start && range.start <= $0.end } }
        return ranges.contains { $0.contains(range) }
    }

    public func contains(offset: Int) -> Bool { ranges.contains { $0.contains(offset) } }

    /// 与给定区间的交集部分（用于裁剪父块）。
    public func intersection(with range: TextSpan) -> [TextSpan] {
        ranges.compactMap { $0.intersection(range) }
    }
}

/// 一本书（某个版本）的已读区间。权限依据文本区间，而非“最远页码”（统一规则 2）。
public struct BookReadState: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var bookVersion: String
    public private(set) var chapters: [Int: ReadRangeSet]

    public init(bookID: BookID, bookVersion: String, chapters: [Int: ReadRangeSet] = [:]) {
        self.bookID = bookID; self.bookVersion = bookVersion; self.chapters = chapters
    }

    public mutating func markRead(chapterIndex: Int, range: TextSpan) {
        var set = chapters[chapterIndex] ?? ReadRangeSet()
        set.insert(range)
        chapters[chapterIndex] = set
    }

    public func isRead(chapterIndex: Int, range: TextSpan) -> Bool {
        chapters[chapterIndex]?.contains(range) ?? false
    }

    public func readRanges(chapterIndex: Int) -> [TextSpan] {
        chapters[chapterIndex]?.ranges ?? []
    }

    /// 显示用进度：已读字符数 / 全书字符数。
    public func displayFraction(chapterLengths: [Int: Int]) -> Double {
        let total = chapterLengths.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let read = chapters.reduce(0) { acc, kv in
            let len = chapterLengths[kv.key] ?? 0
            return acc + kv.value.ranges.reduce(0) { $0 + ($1.intersection(TextSpan(start: 0, end: len))?.length ?? 0) }
        }
        return min(1, Double(read) / Double(total))
    }

    /// 完整读完的章节（展示用）。
    public func completedChapters(chapterLengths: [Int: Int]) -> [Int] {
        chapterLengths.filter { idx, len in len > 0 && isRead(chapterIndex: idx, range: TextSpan(start: 0, end: len)) }
            .map(\.key).sorted()
    }
}

/// 讨论/检索范围。默认为已读；全书范围需用户明确选择并记录（5.2）。
public enum ScopeMode: String, Codable, Sendable, CaseIterable {
    case readOnly
    case wholeBook
}

/// 对一本书的访问权限，由代码裁决，模型无法放开。
public struct AccessScope: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var bookVersion: String
    public var mode: ScopeMode
    public var readState: BookReadState

    public init(bookID: BookID, bookVersion: String, mode: ScopeMode, readState: BookReadState) {
        self.bookID = bookID; self.bookVersion = bookVersion; self.mode = mode; self.readState = readState
    }

    public static func readOnly(_ state: BookReadState) -> AccessScope {
        AccessScope(bookID: state.bookID, bookVersion: state.bookVersion, mode: .readOnly, readState: state)
    }

    public static func wholeBook(bookID: BookID, version: String) -> AccessScope {
        AccessScope(bookID: bookID, bookVersion: version, mode: .wholeBook,
                    readState: BookReadState(bookID: bookID, bookVersion: version))
    }

    /// 区间是否允许访问（版本必须一致）。
    public func allows(bookID: BookID, version: String, chapterIndex: Int, range: TextSpan) -> Bool {
        guard bookID == self.bookID, version == bookVersion else { return false }
        switch mode {
        case .wholeBook: return true
        case .readOnly: return readState.isRead(chapterIndex: chapterIndex, range: range)
        }
    }

    /// 把区间裁剪到允许部分。
    public func clip(bookID: BookID, version: String, chapterIndex: Int, range: TextSpan) -> [TextSpan] {
        guard bookID == self.bookID, version == bookVersion else { return [] }
        switch mode {
        case .wholeBook: return [range]
        case .readOnly: return readState.chapters[chapterIndex]?.intersection(with: range) ?? []
        }
    }

    /// 是否有任何可访问内容。
    public var hasAccessibleContent: Bool {
        mode == .wholeBook || readState.chapters.values.contains { !$0.isEmpty }
    }
}
