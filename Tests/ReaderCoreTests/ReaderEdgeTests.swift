import Testing
import Foundation
@testable import ReaderCore
import LibraryCore
import TestSupport

@Suite("M02 边界情况")
struct ReaderEdgeTests {
    @Test("READ-03 章首/章尾的锚点前后文为空，不越界")
    func anchorAtEdges() {
        let text = "开头的句子。结尾"
        let start = TextAnchor.make(text: text, range: TextSpan(start: 0, end: 2))
        #expect(start.prefix.isEmpty && start.exact == "开头")
        let len = text.utf16Length
        let end = TextAnchor.make(text: text, range: TextSpan(start: len - 2, end: len))
        #expect(end.suffix.isEmpty && end.exact == "结尾")
    }

    @Test("READ-03 锚点文本为空的定位无法重新定位，报告失效")
    func emptyAnchorNotFound() {
        let ch = Make.chapter(text: "一些正文")
        let l = Locator(bookID: "b1", bookVersion: "old", chapterIndex: 0, chapterHref: "x", range: TextSpan(start: 0, end: 0),
                        anchor: TextAnchor(prefix: "", exact: "", suffix: ""), progression: 0)
        #expect(LocatorResolver().resolve(l, currentVersion: "new", chapters: [ch]) == .notFound)
    }

    @Test("READ-01 超出章节末尾的偏移落在最后一页")
    func offsetBeyondEnd() {
        let ch = Make.chapter(text: String(repeating: "字", count: 200))
        let p = Paginator(metrics: PageMetrics(charactersPerLine: 10, linesPerPage: 5))
        let pages = p.pages(for: ch)
        #expect(p.pageIndex(containing: 10_000, in: pages) == pages.count - 1)
        #expect(p.pageIndex(containing: -5, in: pages) == 0)
    }

}
