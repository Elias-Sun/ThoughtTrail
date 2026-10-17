import SwiftUI
import Observation
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import ReaderAgent

/// 阅读器状态：章节、定位、阅读偏好、批注与已读记录。
@MainActor
@Observable
final class ReaderModel {
    let book: Book
    let app: AppModel
    var chapters: [Chapter] = []
    var toc: [TOCEntry] = []
    var chapterIndex = 0
    var preferences: ReaderPreferences
    var annotations: [Annotation] = []
    var bookmarks: [Bookmark] = []
    var selection: TextSpan?
    var visibleRange = TextSpan(start: 0, end: 0)
    var jump: JumpRequest?
    var pageCommand: PageCommand?
    var loaded = false
    var errorMessage: String?

    struct JumpRequest: Equatable { let id = UUID(); var range: TextSpan; var select: Bool }
    struct PageCommand: Equatable { let id = UUID(); var forward: Bool }

    private var lastSavedPosition = Date.distantPast
    private var lastSavedChapter: Int?
    /// 可见区间所属章节：换章后即使偏移相同也要上报（否则不会保存位置、不会记录已读）
    private var visibleChapter: Int?

    init(book: Book, app: AppModel) {
        self.book = book
        self.app = app
        preferences = ReaderModel.loadPreferences()
    }

    var currentChapter: Chapter? { chapters.first { $0.index == chapterIndex } }

    var highlights: [Annotation] { annotations.filter { $0.locator.chapterIndex == chapterIndex && $0.locator.bookVersion == book.fingerprint } }

    var isBookmarked: Bool {
        bookmarks.contains { $0.locator.chapterIndex == chapterIndex && visibleRange.contains($0.locator.range.start) }
    }

    func load(initial: Locator?) async {
        guard !loaded else { if let initial { await open(initial) }; return }
        let c = app.container
        // 先读取上次位置，再填充章节：首次渲染即为正确章节，避免首屏上报的可见区间覆盖已保存的位置
        let saved = initial == nil ? try? await c.annotations.lastPosition(bookID: book.id) : nil
        var loadedChapters: [Chapter] = []
        do {
            loadedChapters = try await c.bookRepository.chapters(bookID: book.id)
            toc = try await c.bookRepository.toc(bookID: book.id)
            annotations = try await c.annotations.annotations(bookID: book.id)
            bookmarks = try await c.readingRepository.bookmarks(bookID: book.id)
        } catch {
            errorMessage = "无法打开书籍：\(error.localizedDescription)"
        }
        guard !loadedChapters.isEmpty else {
            errorMessage = book.status == .sourceUnavailable ? "阅读文件已删除。笔记仍在“思考与记忆”中；重新导入同一文件即可恢复。" : "这本书没有可显示的正文。"
            loaded = true
            return
        }
        let target = initial ?? saved?.locator
        var startJump: JumpRequest?
        if let target {
            switch LocatorResolver().resolve(target, currentVersion: book.fingerprint, chapters: loadedChapters) {
            case .exact(let r): chapterIndex = target.chapterIndex; startJump = JumpRequest(range: r, select: initial != nil)
            case .reanchored(let r, let idx): chapterIndex = idx; startJump = JumpRequest(range: r, select: initial != nil)
            case .notFound: chapterIndex = loadedChapters.first { $0.isLinear && $0.length > 0 }?.index ?? 0
            }
        } else {
            chapterIndex = loadedChapters.first { $0.isLinear && $0.length > 0 }?.index ?? 0
        }
        chapters = loadedChapters
        jump = startJump
        loaded = true
        try? await c.library.markOpened(bookID: book.id)
        _ = try? await c.sessionTracker.start(bookID: book.id, bookVersion: book.fingerprint)
    }

    /// 打开定位：版本变化时通过锚点重新定位；找不到时提示来源失效。
    func open(_ locator: Locator, select: Bool = true) async {
        switch LocatorResolver().resolve(locator, currentVersion: book.fingerprint, chapters: chapters) {
        case .exact(let r):
            chapterIndex = locator.chapterIndex
            jump = JumpRequest(range: r, select: select)
        case .reanchored(let r, let idx):
            chapterIndex = idx
            jump = JumpRequest(range: r, select: select)
        case .notFound:
            app.banner = .init(message: "在当前版本中找不到这段原文，引用来源可能已失效。", isError: true)
        }
    }

    func goTo(chapter: Int, offset: Int) {
        chapterIndex = chapter
        selection = nil
        jump = JumpRequest(range: TextSpan(start: offset, end: offset), select: false)
    }

    func go(to entry: TOCEntry) {
        guard let idx = entry.chapterIndex else { return }
        goTo(chapter: idx, offset: entry.offset)
    }

    func nextChapter() { if let next = chapters.first(where: { $0.index > chapterIndex }) { goTo(chapter: next.index, offset: 0) } }
    func previousChapter() { if let prev = chapters.last(where: { $0.index < chapterIndex }) { goTo(chapter: prev.index, offset: 0) } }

    /// 文本视图报告的可见区间：驱动已读记录（停留阈值）与阅读位置保存。
    func visibleRangeChanged(_ range: TextSpan) {
        guard let chapter = currentChapter, range != visibleRange || chapter.index != visibleChapter else { return }
        visibleRange = range
        visibleChapter = chapter.index
        let tracker = app.container.sessionTracker
        let chapterIndex = chapter.index
        Task { try? await tracker.handle(.pageShown(chapterIndex: chapterIndex, range: range)) }
        // 换章时立即保存；同章内节流 1 秒
        if lastSavedChapter != chapter.index || Date().timeIntervalSince(lastSavedPosition) > 1 {
            lastSavedPosition = Date()
            lastSavedChapter = chapter.index
            let locator = Locator.make(book: book, chapter: chapter, range: TextSpan(start: range.start, end: min(range.end, range.start + 1)))
            let c = app.container
            let book = self.book
            let chapters = self.chapters
            Task {
                try? await c.annotations.savePosition(locator)
                let state = try? await c.readingRepository.readState(bookID: book.id, version: book.fingerprint)
                if let state {
                    let lengths = Dictionary(uniqueKeysWithValues: chapters.map { ($0.index, $0.length) })
                    try? await c.library.updateProgress(bookID: book.id, progress: state.displayFraction(chapterLengths: lengths))
                }
            }
        }
    }

    /// 显式标记当前页已读（不等停留阈值）。
    func markPageRead() async {
        guard let chapter = currentChapter else { return }
        guard !visibleRange.isEmpty else {
            app.banner = .init(message: "页面尚未完成排版，请稍后再试", isError: true)
            return
        }
        try? await app.container.sessionTracker.handle(.markRangeRead(chapterIndex: chapter.index, range: visibleRange))
        app.banner = .init(message: "已将本页记为已读", isError: false)
    }

    func close() async {
        if let chapter = currentChapter {
            let locator = Locator.make(book: book, chapter: chapter, range: TextSpan(start: visibleRange.start, end: min(chapter.length, visibleRange.start + 1)))
            try? await app.container.annotations.savePosition(locator)
        }
        try? await app.container.sessionTracker.end()
        await app.reloadBooks()
    }

    // MARK: 偏好

    static func loadPreferences() -> ReaderPreferences {
        guard let data = UserDefaults.standard.data(forKey: "reader.preferences"),
              let p = try? JSONDecoder().decode(ReaderPreferences.self, from: data) else { return ReaderPreferences() }
        return p
    }

    func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "reader.preferences") }
    }

    // MARK: 批注与书签

    func selectFirstParagraphOnPage() {
        guard let chapter = currentChapter else { return }
        let paragraphs = chapter.paragraphRanges
        if let p = paragraphs.first(where: { $0.end > visibleRange.start + 1 }) ?? paragraphs.first {
            selection = p
            jump = JumpRequest(range: p, select: true)
        }
    }

    func addHighlight(color: HighlightColor = .yellow, note: String? = nil) async {
        guard let range = selection, let chapter = currentChapter else { return }
        do {
            let a = try await app.container.annotations.addHighlight(book: book, chapter: chapter, range: range, color: color, note: note)
            annotations.append(a)
            selection = nil
            try? await app.container.sessionTracker.handle(.markRangeRead(chapterIndex: chapter.index, range: range))
        } catch {
            app.banner = .init(message: "无法保存批注：\(error.localizedDescription)", isError: true)
        }
    }

    func updateNote(_ annotation: Annotation, note: String) async {
        if let updated = try? await app.container.annotations.updateNote(annotationID: annotation.id, note: note),
           let i = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[i] = updated
        }
    }

    func deleteAnnotation(_ annotation: Annotation) async {
        try? await app.container.annotations.delete(annotationID: annotation.id)
        annotations.removeAll { $0.id == annotation.id }
    }

    func toggleBookmark() async {
        guard let chapter = currentChapter else { return }
        _ = try? await app.container.annotations.toggleBookmark(book: book, chapter: chapter, page: visibleRange.isEmpty ? TextSpan(start: 0, end: 1) : visibleRange)
        bookmarks = (try? await app.container.readingRepository.bookmarks(bookID: book.id)) ?? []
    }

    /// 当前阅读现场快照（发起讨论/反思时冻结）。
    func contextSnapshot() async -> ReadingContextSnapshot {
        let chapter = currentChapter
        var locator: Locator?
        var selected: String?
        if let chapter, let sel = selection, !sel.isEmpty {
            locator = Locator.make(book: book, chapter: chapter, range: sel)
            selected = chapter.text.substring(utf16: sel)
        } else if let chapter {
            locator = Locator.make(book: book, chapter: chapter, range: TextSpan(start: visibleRange.start, end: min(chapter.length, visibleRange.start + 1)))
        }
        return ReadingContextSnapshot(bookID: book.id, bookVersion: book.fingerprint, bookTitle: book.title, chapterIndex: chapter?.index,
                                      chapterTitle: chapter?.title, locator: locator, selectedText: selected,
                                      sessionID: await app.container.sessionTracker.session?.id, capturedAt: Date())
    }

    func selectionContext() -> SelectionContext? {
        guard let chapter = currentChapter, let sel = selection, !sel.isEmpty else { return nil }
        return SelectionContext(locator: Locator.make(book: book, chapter: chapter, range: sel), text: chapter.text.substring(utf16: sel))
    }
}
