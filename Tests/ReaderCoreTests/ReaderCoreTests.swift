import Testing
import Foundation
@testable import ReaderCore
import LibraryCore
import Persistence
import TestSupport

private let sampleText = "第一段：读书要带着问题。\n第二段：做批注能促进思考。\n第三段：读书要带着问题，这句话再次出现。\n第四段：结尾。"

@Suite("M02 稳定定位")
struct LocatorTests {
    let book = Make.book(fingerprint: "v1")
    var chapter: Chapter { Make.chapter(text: sampleText) }

    @Test("READ-03 定位包含书籍版本、章节资源、区间与前后文锚点")
    func locatorCapturesContext() {
        let range = sampleText.utf16Ranges(of: "做批注")[0]
        let l = Locator.make(book: book, chapter: chapter, range: range)
        #expect(l.bookVersion == "v1")
        #expect(l.chapterHref == "ch0.xhtml")
        #expect(l.anchor.exact == "做批注")
        #expect(l.anchor.prefix.hasSuffix("第二段："))
        #expect(l.anchor.suffix.hasPrefix("能促进思考"))
        #expect(l.progression > 0 && l.progression < 1)
    }

    @Test("READ-03 同版本且偏移文本一致时精确解析")
    func exactResolution() {
        let range = sampleText.utf16Ranges(of: "做批注")[0]
        let l = Locator.make(book: book, chapter: chapter, range: range)
        #expect(LocatorResolver().resolve(l, currentVersion: "v1", chapters: [chapter]) == .exact(range))
    }

    @Test("READ-03 重复出现的文本依靠前后文选中正确位置")
    func disambiguatesByContext() {
        let second = sampleText.utf16Ranges(of: "读书要带着问题")[1]
        let l = Locator.make(book: book, chapter: chapter, range: second)
        // 新版本在开头插入内容，偏移整体后移
        let shifted = Make.chapter(text: "序言新增。\n" + sampleText)
        let r = LocatorResolver().resolve(l, currentVersion: "v2", chapters: [shifted])
        let expected = shifted.text.utf16Ranges(of: "读书要带着问题")[1]
        #expect(r == .reanchored(expected, chapterIndex: 0))
    }

    @Test("READ-03 版本变化后不沿用旧偏移，找不到原文时报告失效")
    func versionChangeWithoutTextIsNotFound() {
        let range = sampleText.utf16Ranges(of: "做批注")[0]
        let l = Locator.make(book: book, chapter: chapter, range: range)
        let rewritten = Make.chapter(text: "完全不同的内容，长度相近，但是没有那三个字。。。。。。。。。。。。。。。。。")
        #expect(LocatorResolver().resolve(l, currentVersion: "v2", chapters: [rewritten]) == .notFound)
    }

    @Test("READ-03 章节顺序变化时跨章重新定位")
    func crossChapterReanchor() {
        let range = sampleText.utf16Ranges(of: "结尾")[0]
        let l = Locator.make(book: book, chapter: chapter, range: range)
        let moved = [Make.chapter(index: 0, text: "新增的第一章。"), Make.chapter(index: 1, text: sampleText)]
        let r = LocatorResolver().resolve(l, currentVersion: "v2", chapters: moved)
        #expect(r.range == range)
        if case .reanchored(_, let idx) = r { #expect(idx == 1) } else { Issue.record("应跨章重定位") }
    }

    @Test("READ-03 同版本但偏移被篡改时用锚点纠正")
    func tamperedOffsetSameVersion() {
        let range = sampleText.utf16Ranges(of: "做批注")[0]
        var l = Locator.make(book: book, chapter: chapter, range: range)
        l.range = TextSpan(start: 0, end: 3)
        #expect(LocatorResolver().resolve(l, currentVersion: "v1", chapters: [chapter]).range == range)
    }

    @Test("READ-03 越界区间在创建定位时被裁剪")
    func clampsOutOfBounds() {
        let l = Locator.make(book: book, chapter: chapter, range: TextSpan(start: 5, end: 10_000))
        #expect(l.range.end == chapter.length)
    }
}

@Suite("M02 分页与导航")
struct PaginationTests {
    let chapters = [
        Make.chapter(index: 0, text: String(repeating: "甲", count: 300) + "\n" + String(repeating: "乙", count: 300)),
        Make.chapter(index: 1, text: String(repeating: "丙", count: 500)),
    ]

    @Test("READ-01 分页区间首尾相接且覆盖整章")
    func pagesCoverChapter() {
        let pages = Paginator(metrics: PageMetrics(charactersPerLine: 20, linesPerPage: 10)).pages(for: chapters[0])
        #expect(pages.first?.start == 0)
        #expect(pages.last?.end == chapters[0].length)
        for (a, b) in zip(pages, pages.dropFirst()) { #expect(a.end == b.start) }
        #expect(pages.count > 2)
    }

    @Test("READ-03 字号变化后同一偏移仍能定位到包含它的页")
    func fontChangeKeepsOffsetVisible() {
        var nav = ReaderNavigator(chapters: chapters, metrics: PageMetrics(charactersPerLine: 20, linesPerPage: 10))
        nav.jump(chapterIndex: 0, offset: 450)
        let before = nav.currentPage!
        #expect(before.contains(450))
        let start = before.start
        nav.updateMetrics(PageMetrics(charactersPerLine: 12, linesPerPage: 8))
        #expect(nav.currentPage!.contains(start))
    }

    @Test("READ-01 翻页在章末跨入下一章，首页不能再向前")
    func pageTurningAcrossChapters() {
        var nav = ReaderNavigator(chapters: chapters, metrics: PageMetrics(charactersPerLine: 50, linesPerPage: 20))
        let movedBack = nav.previousPage()
        #expect(movedBack == false)
        var turns = 0
        while nav.currentChapter?.index == 0 {
            let moved = nav.nextPage()
            #expect(moved)
            turns += 1
        }
        #expect(nav.currentChapter?.index == 1)
        #expect(nav.pageIndex == 0)
        let back = nav.previousPage()
        #expect(back)
        #expect(nav.currentChapter?.index == 0)
        #expect(turns >= 1)
    }

    @Test("READ-01 目录跳转到锚点所在页")
    func tocJump() {
        var nav = ReaderNavigator(chapters: chapters, metrics: PageMetrics(charactersPerLine: 20, linesPerPage: 10))
        let jumped = nav.jump(to: TOCEntry(title: "乙", level: 0, chapterIndex: 0, offset: 301, href: "ch0.xhtml#b"))
        #expect(jumped)
        #expect(nav.currentPage!.contains(301))
        let external = nav.jump(to: TOCEntry(title: "外部", level: 0, chapterIndex: nil, offset: 0, href: "x"))
        #expect(!external)
    }

    @Test("READ-01 以保存的定位重新打开时恢复到对应页")
    func restoreFromLocator() {
        let book = Make.book(fingerprint: "v")
        let l = Locator.make(book: book, chapter: chapters[1], range: TextSpan(start: 420, end: 421))
        let nav = ReaderNavigator(chapters: chapters, metrics: PageMetrics(charactersPerLine: 20, linesPerPage: 10), start: l)
        #expect(nav.currentChapter?.index == 1)
        #expect(nav.currentPage!.contains(420))
        #expect(nav.currentLocator(bookID: book.id, bookVersion: "v")?.chapterIndex == 1)
    }

    @Test("READ-01 字号有上下限，主题可切换")
    func preferencesBounds() {
        var p = ReaderPreferences(fontSize: 100, theme: .dark)
        #expect(p.fontSize == ReaderPreferences.fontSizeRange.upperBound)
        for _ in 0..<30 { p.decreaseFont() }
        #expect(p.fontSize == ReaderPreferences.fontSizeRange.lowerBound)
        p.increaseFont()
        #expect(p.fontSize == ReaderPreferences.fontSizeRange.lowerBound + 2)
        #expect(p.theme == .dark)
    }

    @Test("READ-01 视口与字号推导每页行数与字数")
    func metricsFromViewport() {
        let small = PageMetrics(viewportWidth: 360, viewportHeight: 600, preferences: ReaderPreferences(fontSize: 18))
        let large = PageMetrics(viewportWidth: 360, viewportHeight: 600, preferences: ReaderPreferences(fontSize: 30))
        #expect(small.charactersPerLine > large.charactersPerLine)
        #expect(small.linesPerPage > large.linesPerPage)
    }

    @Test("READ-01 空章节也有一页，不崩溃")
    func emptyChapter() {
        #expect(Paginator(metrics: PageMetrics(charactersPerLine: 10, linesPerPage: 5)).pages(for: Make.chapter(text: "")) == [TextSpan(start: 0, end: 0)])
    }
}

@Suite("M02 批注与书签")
struct AnnotationServiceTests {
    func setup() throws -> (AnnotationService, SQLiteReadingRepository, Book, Chapter, ManualClock) {
        let db = try AppDatabase.inMemory()
        let repo = SQLiteReadingRepository(db)
        let clock = ManualClock()
        return (AnnotationService(repository: repo, clock: clock, ids: SequentialIDGenerator()), repo, Make.book(fingerprint: "v1"),
                Make.chapter(text: sampleText), clock)
    }

    @Test("READ-02 新增高亮立即保存，可在重新读取后找到")
    func addHighlightPersists() async throws {
        let (svc, repo, book, chapter, _) = try setup()
        let range = sampleText.utf16Ranges(of: "做批注能促进思考")[0]
        let a = try await svc.addHighlight(book: book, chapter: chapter, range: range)
        let reloaded = try await repo.annotation(id: a.id)
        #expect(reloaded?.quote == "做批注能促进思考")
        #expect(reloaded?.kind == .highlight)
    }

    @Test("READ-02 带笔记的高亮记为笔记；修改与清空笔记切换类型")
    func noteEditing() async throws {
        let (svc, _, book, chapter, clock) = try setup()
        let a = try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 0, end: 3), note: " 想法 ")
        #expect(a.kind == .note && a.note == "想法")
        clock.advance(by: 5)
        let edited = try await svc.updateNote(annotationID: a.id, note: "新的想法")
        #expect(edited.note == "新的想法" && edited.updatedAt > a.updatedAt)
        let cleared = try await svc.updateNote(annotationID: a.id, note: "   ")
        #expect(cleared.kind == .highlight && cleared.note == nil)
    }

    @Test("READ-02 删除批注后列表同步")
    func deleteAnnotation() async throws {
        let (svc, _, book, chapter, _) = try setup()
        let a = try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 0, end: 3))
        _ = try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 5, end: 8))
        try await svc.delete(annotationID: a.id)
        #expect(try await svc.annotations(bookID: book.id).count == 1)
    }

    @Test("READ-02 空选择与越界选择被拒绝")
    func invalidSelections() async throws {
        let (svc, _, book, chapter, _) = try setup()
        await #expect(throws: AnnotationError.emptySelection) {
            try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 3, end: 3))
        }
        await #expect(throws: AnnotationError.selectionOutOfChapter) {
            try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 3, end: 9_999))
        }
        await #expect(throws: AnnotationError.notFound) { try await svc.updateNote(annotationID: "none", note: "x") }
    }

    @Test("READ-02 批注列表按章节与位置排序")
    func annotationsOrdered() async throws {
        let (svc, _, book, chapter, _) = try setup()
        let later = Make.chapter(index: 1, text: "第二章内容")
        _ = try await svc.addHighlight(book: book, chapter: later, range: TextSpan(start: 0, end: 2))
        _ = try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 10, end: 12))
        _ = try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 0, end: 2))
        let list = try await svc.annotations(bookID: book.id)
        #expect(list.map { [$0.locator.chapterIndex, $0.locator.range.start] } == [[0, 0], [0, 10], [1, 0]])
    }

    @Test("READ-02 点击批注通过定位回到原文")
    func annotationJumpsBack() async throws {
        let (svc, _, book, chapter, _) = try setup()
        let range = sampleText.utf16Ranges(of: "结尾")[0]
        let a = try await svc.addHighlight(book: book, chapter: chapter, range: range)
        let resolution = await svc.resolve(a.locator, book: book, chapters: [chapter])
        #expect(resolution == .exact(range))
    }

    @Test("READ-01 书签在同一页切换：再次点击移除")
    func bookmarkToggle() async throws {
        let (svc, repo, book, chapter, _) = try setup()
        let page = TextSpan(start: 0, end: 20)
        let added = try await svc.toggleBookmark(book: book, chapter: chapter, page: page)
        #expect(added != nil)
        #expect(try await repo.bookmarks(bookID: book.id).count == 1)
        #expect(try await svc.toggleBookmark(book: book, chapter: chapter, page: page) == nil)
        #expect(try await repo.bookmarks(bookID: book.id).isEmpty)
    }

    @Test("READ-01 阅读位置保存后重新打开可恢复")
    func positionRestore() async throws {
        let (svc, _, book, chapter, _) = try setup()
        let l = Locator.make(book: book, chapter: chapter, range: TextSpan(start: 12, end: 13))
        try await svc.savePosition(l)
        #expect(try await svc.lastPosition(bookID: book.id)?.locator == l)
    }

    @Test("READ-02 修改颜色立即保存")
    func colorUpdate() async throws {
        let (svc, repo, book, chapter, _) = try setup()
        let a = try await svc.addHighlight(book: book, chapter: chapter, range: TextSpan(start: 0, end: 3))
        _ = try await svc.updateColor(annotationID: a.id, color: .blue)
        #expect(try await repo.annotation(id: a.id)?.color == .blue)
    }
}
