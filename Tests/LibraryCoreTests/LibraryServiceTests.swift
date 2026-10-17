import Testing
import Foundation
@testable import LibraryCore
import Persistence
import TestSupport

actor ObserverSpy: BookLifecycleObserver {
    var detached: [BookID] = []
    var purged: [BookID] = []
    func bookSourceDetached(_ bookID: BookID) async { detached.append(bookID) }
    func bookPurged(_ bookID: BookID) async { purged.append(bookID) }
}

@Suite("M01 书库服务")
struct LibraryServiceTests {
    @Test("LIB-01 导入有效 EPUB 后书籍、章节、目录与文件均已保存")
    func importStoresEverything() async throws {
        let env = try TestEnvironment()
        let data = try Fixtures.zhBook()
        let outcome = try await env.library.importBook(data: data, fileName: "zh.epub")
        guard case .imported(let book) = outcome else { Issue.record("应为新导入"); return }
        #expect(book.fingerprint == Fingerprint.sha256(data))
        #expect(book.hasCover)
        #expect(try await env.books.chapters(bookID: book.id).count == 4)
        #expect(try await env.books.toc(bookID: book.id).isEmpty == false)
        #expect(await env.files.exists(for: book.id))
    }

    @Test("LIB-02 相同文件再次导入识别为重复，不产生第二本书")
    func duplicateImport() async throws {
        let env = try TestEnvironment()
        let data = try Fixtures.zhBook()
        let first = try await env.library.importBook(data: data, fileName: "a.epub")
        let second = try await env.library.importBook(data: data, fileName: "b.epub")
        #expect(second == .duplicate(existing: first.book))
        #expect(try await env.books.allBooks().count == 1)
    }

    @Test("LIB-02 损坏文件导入失败且不残留书籍或文件")
    func corruptLeavesNothing() async throws {
        let env = try TestEnvironment()
        await #expect(throws: ImportError.invalidEPUB(.notZipArchive)) {
            try await env.library.importBook(data: Data("broken".utf8), fileName: "bad.epub")
        }
        #expect(try await env.books.allBooks().isEmpty)
        #expect(await env.files.storedCount == 0)
    }

    @Test("LIB-02 存储失败时清理已写入部分，不留下半成品")
    func storageFailureCleansUp() async throws {
        let env = try TestEnvironment()
        await env.files.setFailNextSave(true)
        await #expect(throws: ImportError.self) {
            try await env.library.importBook(data: try Fixtures.enBook(), fileName: "en.epub")
        }
        #expect(try await env.books.allBooks().isEmpty)
        #expect(await env.files.storedCount == 0)
    }

    @Test("LIB-02 空文件导入给出明确错误")
    func emptyImport() async throws {
        let env = try TestEnvironment()
        await #expect(throws: ImportError.invalidEPUB(.emptyFile)) {
            try await env.library.importBook(data: Data(), fileName: "e.epub")
        }
    }

    @Test("LIB-04 删除阅读文件保留笔记：书籍标记来源不可访问并通知观察者")
    func deleteKeepNotes() async throws {
        let env = try TestEnvironment()
        let spy = ObserverSpy()
        await env.library.addObserver(spy)
        let book = try await env.library.importBook(data: Fixtures.zhBook(), fileName: "a.epub").book
        try await env.library.delete(bookID: book.id, policy: .removeFileKeepNotes)
        let after = try #require(try await env.books.book(id: book.id))
        #expect(after.status == .sourceUnavailable)
        #expect(try await env.books.chapters(bookID: book.id).isEmpty)
        #expect(await env.files.exists(for: book.id) == false)
        #expect(await spy.detached == [book.id])
    }

    @Test("LIB-04 彻底删除移除书籍并通知观察者")
    func purgeEverything() async throws {
        let env = try TestEnvironment()
        let spy = ObserverSpy()
        await env.library.addObserver(spy)
        let book = try await env.library.importBook(data: Fixtures.zhBook(), fileName: "a.epub").book
        try await env.library.delete(bookID: book.id, policy: .purgeEverything)
        #expect(try await env.books.book(id: book.id) == nil)
        #expect(await spy.purged == [book.id])
    }

    @Test("LIB-04 仅删除文件后重新导入同一 EPUB 恢复来源并沿用原 ID")
    func reimportRestoresSource() async throws {
        let env = try TestEnvironment()
        let data = try Fixtures.zhBook()
        let book = try await env.library.importBook(data: data, fileName: "a.epub").book
        try await env.library.delete(bookID: book.id, policy: .removeFileKeepNotes)
        let outcome = try await env.library.importBook(data: data, fileName: "a.epub")
        guard case .restoredSource(let restored) = outcome else { Issue.record("应恢复来源"); return }
        #expect(restored.id == book.id)
        #expect(restored.status == .active)
        #expect(try await env.books.chapters(bookID: book.id).count == 4)
    }

    @Test("LIB-03 并发导入同一文件只产生一本书")
    func concurrentDuplicateImports() async throws {
        let env = try TestEnvironment()
        let data = try Fixtures.enBook()
        async let a = env.library.importBook(data: data, fileName: "a.epub")
        async let b = env.library.importBook(data: data, fileName: "b.epub")
        let results = try await [a, b]
        #expect(Set(results.map(\.book.id)).count == 1)
        #expect(try await env.books.allBooks().count == 1)
    }

    @Test("LIB-03 书籍被删除后，迟到的索引状态更新不会复活记录")
    func indexStateAfterDeletion() async throws {
        let env = try TestEnvironment()
        let book = try await env.library.importBook(data: Fixtures.enBook(), fileName: "a.epub").book
        try await env.library.delete(bookID: book.id, policy: .purgeEverything)
        try await env.library.setIndexState(bookID: book.id, state: .ready)
        #expect(try await env.books.book(id: book.id) == nil)
    }

    @Test("LIB-03 进度更新被限制在 0...1")
    func progressClamped() async throws {
        let env = try TestEnvironment()
        let book = try await env.library.importBook(data: Fixtures.enBook(), fileName: "a.epub").book
        try await env.library.updateProgress(bookID: book.id, progress: 1.7)
        #expect(try await env.books.book(id: book.id)?.displayProgress == 1)
    }

    @Test("LIB-03 打开书籍更新最近打开时间并影响默认排序")
    func markOpenedAffectsSort() async throws {
        let env = try TestEnvironment()
        let zh = try await env.library.importBook(data: Fixtures.zhBook(), fileName: "zh.epub").book
        env.clock.advance(by: 10)
        _ = try await env.library.importBook(data: Fixtures.enBook(), fileName: "en.epub").book
        env.clock.advance(by: 10)
        try await env.library.markOpened(bookID: zh.id)
        #expect(try await env.library.books().first?.id == zh.id)
    }
}

@Suite("M01 书库查询")
struct LibraryQueryTests {
    let books = [
        Make.book(id: "a", title: "论语", importedAt: Date(timeIntervalSince1970: 1), progress: 0.2, authors: ["孔子弟子"]),
        Make.book(id: "b", title: "Walden", importedAt: Date(timeIntervalSince1970: 3), progress: 0.9, authors: ["Thoreau"]),
        Make.book(id: "c", title: "道德经", importedAt: Date(timeIntervalSince1970: 2), progress: 0.5, authors: ["老子"]),
    ]

    @Test("LIB-03 按标题或作者搜索（不区分大小写）")
    func search() {
        #expect(LibraryQuery.filter(books, query: "walden", sort: .title).map(\.id) == ["b"])
        #expect(LibraryQuery.filter(books, query: "老子", sort: .title).map(\.id) == ["c"])
        #expect(LibraryQuery.filter(books, query: "  ", sort: .title).count == 3)
    }

    @Test("LIB-03 按进度与导入时间排序")
    func sorting() {
        #expect(LibraryQuery.filter(books, query: "", sort: .progress).map(\.id) == ["b", "c", "a"])
        #expect(LibraryQuery.filter(books, query: "", sort: .importedAt).map(\.id) == ["b", "c", "a"])
    }
}

@Suite("M01 基础类型")
struct KernelTests {
    @Test("READ-03 TextSpan 交集、并集与裁剪")
    func spanOps() {
        let a = TextSpan(start: 5, end: 10), b = TextSpan(start: 8, end: 20)
        #expect(a.intersection(b) == TextSpan(start: 8, end: 10))
        #expect(a.union(b) == TextSpan(start: 5, end: 20))
        #expect(TextSpan(start: 10, end: 5) == TextSpan(start: 5, end: 10))
        #expect(b.clamped(toLength: 12) == TextSpan(start: 8, end: 12))
        #expect(a.intersection(TextSpan(start: 10, end: 11)) == nil)
        #expect(a.touches(TextSpan(start: 10, end: 11)))
    }

    @Test("READ-03 UTF-16 截取正确处理中文与表情")
    func utf16Substring() {
        let s = "读书😀思考"
        #expect(s.utf16Length == 6)
        #expect(s.substring(utf16: TextSpan(start: 2, end: 4)) == "😀")
        #expect(s.substring(utf16: TextSpan(start: 4, end: 99)) == "思考")
        #expect(s.utf16Ranges(of: "思考") == [TextSpan(start: 4, end: 6)])
    }

    @Test("LEARN-05 DayKey 按时区计算日历日并支持跨月加减")
    func dayKeys() {
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        #expect(DayKey(date: date, timeZone: TimeZone(identifier: "Asia/Shanghai")!).description == "2026-01-01")
        #expect(DayKey(date: date, timeZone: TimeZone(identifier: "America/New_York")!).description == "2025-12-31")
        #expect(DayKey(year: 2026, month: 1, day: 31).adding(days: 1) == DayKey(year: 2026, month: 2, day: 1))
        #expect(DayKey(year: 2026, month: 3, day: 1).days(to: DayKey(year: 2026, month: 3, day: 31)) == 30)
    }
}
