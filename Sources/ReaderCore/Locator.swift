import Foundation
import LibraryCore

/// 文本锚点：被选中文字及其前后文，用于版本或分页变化后重新定位（READ-03）。
public struct TextAnchor: Codable, Hashable, Sendable {
    public var prefix: String
    public var exact: String
    public var suffix: String

    public init(prefix: String, exact: String, suffix: String) {
        self.prefix = prefix; self.exact = exact; self.suffix = suffix
    }

    public static let contextLength = 32

    public static func make(text: String, range: TextSpan, context: Int = contextLength) -> TextAnchor {
        let len = text.utf16Length
        let r = range.clamped(toLength: len)
        return TextAnchor(
            prefix: text.substring(utf16: TextSpan(start: max(0, r.start - context), end: r.start)),
            exact: text.substring(utf16: r),
            suffix: text.substring(utf16: TextSpan(start: r.end, end: min(len, r.end + context)))
        )
    }
}

/// 稳定定位：书籍版本 + 章节资源 + UTF-16 区间 + 文本锚点。
public struct Locator: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var bookVersion: String
    public var chapterIndex: Int
    public var chapterHref: String
    public var range: TextSpan
    public var anchor: TextAnchor
    /// 章节内进度（0...1），仅用于展示。
    public var progression: Double

    public init(bookID: BookID, bookVersion: String, chapterIndex: Int, chapterHref: String,
                range: TextSpan, anchor: TextAnchor, progression: Double) {
        self.bookID = bookID; self.bookVersion = bookVersion; self.chapterIndex = chapterIndex
        self.chapterHref = chapterHref; self.range = range; self.anchor = anchor; self.progression = progression
    }

    /// 从章节与区间创建定位。
    public static func make(book: Book, chapter: Chapter, range: TextSpan) -> Locator {
        let len = chapter.length
        let r = range.clamped(toLength: len)
        return Locator(bookID: book.id, bookVersion: book.fingerprint, chapterIndex: chapter.index,
                       chapterHref: chapter.href, range: r, anchor: TextAnchor.make(text: chapter.text, range: r),
                       progression: len == 0 ? 0 : Double(r.start) / Double(len))
    }

    public static func make(bookID: BookID, bookVersion: String, chapter: Chapter, range: TextSpan) -> Locator {
        let len = chapter.length
        let r = range.clamped(toLength: len)
        return Locator(bookID: bookID, bookVersion: bookVersion, chapterIndex: chapter.index,
                       chapterHref: chapter.href, range: r, anchor: TextAnchor.make(text: chapter.text, range: r),
                       progression: len == 0 ? 0 : Double(r.start) / Double(len))
    }
}

/// 定位解析结果。
public enum LocatorResolution: Equatable, Sendable {
    /// 版本一致且偏移处文本与锚点一致。
    case exact(TextSpan)
    /// 通过锚点文本重新找到（版本变化或偏移漂移）。
    case reanchored(TextSpan, chapterIndex: Int)
    /// 找不到对应原文：来源失效，不得静默沿用旧偏移。
    case notFound

    public var range: TextSpan? {
        switch self {
        case .exact(let r), .reanchored(let r, _): return r
        case .notFound: return nil
        }
    }
}

/// 将 Locator 解析到当前书籍内容。版本不同则只依赖锚点文本，不沿用旧偏移（统一规则 1）。
public struct LocatorResolver: Sendable {
    public init() {}

    public func resolve(_ locator: Locator, currentVersion: String, chapters: [Chapter]) -> LocatorResolution {
        let sameVersion = locator.bookVersion == currentVersion
        if sameVersion, let chapter = chapters.first(where: { $0.index == locator.chapterIndex }) {
            let r = locator.range
            if r.end <= chapter.length && chapter.text.substring(utf16: r) == locator.anchor.exact {
                return .exact(r)
            }
        }
        guard !locator.anchor.exact.isEmpty else { return .notFound }
        // 优先在同 href 或同序号章节中查找，其次全书
        let ordered = chapters.sorted { a, b in
            score(a, locator) > score(b, locator)
        }
        for chapter in ordered {
            if let r = bestMatch(locator.anchor, in: chapter.text, near: locator.range.start) {
                if sameVersion && chapter.index == locator.chapterIndex && r == locator.range { return .exact(r) }
                return .reanchored(r, chapterIndex: chapter.index)
            }
        }
        return .notFound
    }

    private func score(_ c: Chapter, _ l: Locator) -> Int {
        (c.href == l.chapterHref ? 2 : 0) + (c.index == l.chapterIndex ? 1 : 0)
    }

    /// 在文本中寻找锚点：优先前后文都匹配的出现位置，其次距离原偏移最近者。
    func bestMatch(_ anchor: TextAnchor, in text: String, near hint: Int) -> TextSpan? {
        let candidates = text.utf16Ranges(of: anchor.exact)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        let len = text.utf16Length
        func contextScore(_ r: TextSpan) -> Int {
            let pre = text.substring(utf16: TextSpan(start: max(0, r.start - anchor.prefix.utf16Length), end: r.start))
            let suf = text.substring(utf16: TextSpan(start: r.end, end: min(len, r.end + anchor.suffix.utf16Length)))
            return commonSuffix(pre, anchor.prefix) + commonPrefix(suf, anchor.suffix)
        }
        return candidates.max { a, b in
            let sa = contextScore(a), sb = contextScore(b)
            if sa != sb { return sa < sb }
            return abs(a.start - hint) > abs(b.start - hint)
        }
    }

    private func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    private func commonSuffix(_ a: String, _ b: String) -> Int {
        zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
    }
}
