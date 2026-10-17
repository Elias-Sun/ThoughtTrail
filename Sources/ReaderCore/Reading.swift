import Foundation
import LibraryCore

public enum ReaderTheme: String, Codable, Sendable, CaseIterable {
    case light, sepia, dark
}

/// 阅读偏好（READ-01）。字号有界，修改不影响 Locator（定位独立于分页）。
public struct ReaderPreferences: Codable, Hashable, Sendable {
    public static let fontSizeRange: ClosedRange<Double> = 12...34
    public private(set) var fontSize: Double
    public var theme: ReaderTheme
    public var lineSpacing: Double

    public init(fontSize: Double = 18, theme: ReaderTheme = .light, lineSpacing: Double = 1.5) {
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.theme = theme
        self.lineSpacing = min(max(lineSpacing, 1.0), 2.4)
    }

    public mutating func setFontSize(_ size: Double) {
        fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    public mutating func increaseFont() { setFontSize(fontSize + 2) }
    public mutating func decreaseFont() { setFontSize(fontSize - 2) }
}

/// 视口与字号推导出的排版度量。真实排版由 UITextView 负责；此模型用于页码与定位稳定性推导。
public struct PageMetrics: Hashable, Sendable {
    public var charactersPerLine: Int
    public var linesPerPage: Int

    public init(charactersPerLine: Int, linesPerPage: Int) {
        self.charactersPerLine = max(4, charactersPerLine)
        self.linesPerPage = max(3, linesPerPage)
    }

    public init(viewportWidth: Double, viewportHeight: Double, preferences: ReaderPreferences) {
        let charWidth = preferences.fontSize * 1.0
        let lineHeight = preferences.fontSize * preferences.lineSpacing
        self.init(charactersPerLine: Int(viewportWidth / charWidth), linesPerPage: Int(viewportHeight / lineHeight))
    }
}

/// 简化分页：按段落与每行字符数切页，页区间首尾相接覆盖整章。
public struct Paginator: Sendable {
    public let metrics: PageMetrics

    public init(metrics: PageMetrics) { self.metrics = metrics }

    public func pages(for chapter: Chapter) -> [TextSpan] {
        let total = chapter.length
        guard total > 0 else { return [TextSpan(start: 0, end: 0)] }
        var pages: [TextSpan] = []
        var pageStart = 0
        var linesUsed = 0
        for para in chapter.paragraphRanges {
            var cursor = para.start
            while cursor < para.end {
                let remainingLines = metrics.linesPerPage - linesUsed
                let charsFit = remainingLines * metrics.charactersPerLine
                let left = para.end - cursor
                if left <= charsFit {
                    linesUsed += Int((Double(left) / Double(metrics.charactersPerLine)).rounded(.up)) + 1
                    cursor = para.end
                } else {
                    cursor += charsFit
                    pages.append(TextSpan(start: pageStart, end: cursor))
                    pageStart = cursor
                    linesUsed = 0
                }
                if linesUsed >= metrics.linesPerPage {
                    let end = min(total, cursor + 1) // 包含段落换行
                    pages.append(TextSpan(start: pageStart, end: end))
                    pageStart = end
                    linesUsed = 0
                }
            }
        }
        if pageStart < total { pages.append(TextSpan(start: pageStart, end: total)) }
        return pages.isEmpty ? [TextSpan(start: 0, end: total)] : pages
    }

    /// 偏移所在页码（0 基）。
    public func pageIndex(containing offset: Int, in pages: [TextSpan]) -> Int {
        if let i = pages.firstIndex(where: { $0.contains(offset) }) { return i }
        return offset <= 0 ? 0 : max(0, pages.count - 1)
    }
}

/// 阅读位置（重新打开时恢复）。
public struct ReadingPosition: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var locator: Locator
    public var updatedAt: Date

    public init(bookID: BookID, locator: Locator, updatedAt: Date) {
        self.bookID = bookID; self.locator = locator; self.updatedAt = updatedAt
    }
}

/// 阅读器导航状态（章节与页），与具体渲染解耦。
public struct ReaderNavigator: Sendable {
    public private(set) var chapters: [Chapter]
    public private(set) var chapterIndex: Int
    public private(set) var pageIndex: Int
    public private(set) var pages: [TextSpan]
    public private(set) var metrics: PageMetrics

    public init(chapters: [Chapter], metrics: PageMetrics, start: Locator? = nil) {
        self.chapters = chapters.sorted { $0.index < $1.index }
        self.metrics = metrics
        self.chapterIndex = 0
        self.pageIndex = 0
        self.pages = []
        if let start, let pos = self.chapters.firstIndex(where: { $0.index == start.chapterIndex }) {
            chapterIndex = pos
            repaginate()
            pageIndex = Paginator(metrics: metrics).pageIndex(containing: start.range.start, in: pages)
        } else {
            chapterIndex = self.chapters.firstIndex(where: { $0.isLinear && $0.length > 0 }) ?? 0
            repaginate()
        }
    }

    public var currentChapter: Chapter? { chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil }
    public var currentPage: TextSpan? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    private mutating func repaginate() {
        guard let c = currentChapter else { pages = []; return }
        pages = Paginator(metrics: metrics).pages(for: c)
    }

    /// 下一页；章末跨入下一章。返回是否移动。
    @discardableResult
    public mutating func nextPage() -> Bool {
        if pageIndex + 1 < pages.count { pageIndex += 1; return true }
        guard chapterIndex + 1 < chapters.count else { return false }
        chapterIndex += 1; repaginate(); pageIndex = 0
        return true
    }

    @discardableResult
    public mutating func previousPage() -> Bool {
        if pageIndex > 0 { pageIndex -= 1; return true }
        guard chapterIndex > 0 else { return false }
        chapterIndex -= 1; repaginate(); pageIndex = max(0, pages.count - 1)
        return true
    }

    /// 跳转到章节内偏移（目录、批注、引用跳转）。
    @discardableResult
    public mutating func jump(chapterIndex target: Int, offset: Int) -> Bool {
        guard let pos = chapters.firstIndex(where: { $0.index == target }) else { return false }
        chapterIndex = pos; repaginate()
        pageIndex = Paginator(metrics: metrics).pageIndex(containing: offset, in: pages)
        return true
    }

    public mutating func jump(to entry: TOCEntry) -> Bool {
        guard let idx = entry.chapterIndex else { return false }
        return jump(chapterIndex: idx, offset: entry.offset)
    }

    /// 改变字号/视口后保持当前页首字符可见（READ-03）。
    public mutating func updateMetrics(_ newMetrics: PageMetrics) {
        let anchorOffset = currentPage?.start ?? 0
        metrics = newMetrics
        repaginate()
        pageIndex = Paginator(metrics: metrics).pageIndex(containing: anchorOffset, in: pages)
    }

    /// 当前页的定位。
    public func currentLocator(bookID: BookID, bookVersion: String) -> Locator? {
        guard let c = currentChapter, let p = currentPage else { return nil }
        let range = TextSpan(start: p.start, end: min(p.end, p.start + 1))
        return Locator.make(bookID: bookID, bookVersion: bookVersion, chapter: c, range: range)
    }
}
