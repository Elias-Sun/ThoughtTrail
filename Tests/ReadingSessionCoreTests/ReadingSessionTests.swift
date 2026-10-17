import Testing
import Foundation
@testable import ReadingSessionCore
import LibraryCore
import Persistence
import TestSupport

@Suite("M03 已读区间")
struct ReadRangeTests {
    @Test("READ-04 相交与相接的区间合并")
    func mergeOverlapping() {
        var s = ReadRangeSet()
        s.insert(TextSpan(start: 10, end: 20))
        s.insert(TextSpan(start: 30, end: 40))
        s.insert(TextSpan(start: 20, end: 30))
        #expect(s.ranges == [TextSpan(start: 10, end: 40)])
    }

    @Test("READ-04 不相交区间保持有序且分离")
    func keepsDisjoint() {
        let s = ReadRangeSet([TextSpan(start: 50, end: 60), TextSpan(start: 0, end: 5), TextSpan(start: 20, end: 25)])
        #expect(s.ranges == [TextSpan(start: 0, end: 5), TextSpan(start: 20, end: 25), TextSpan(start: 50, end: 60)])
        #expect(s.coveredLength == 20)
    }

    @Test("READ-04 只有被完全覆盖的区间才算已读")
    func containsRequiresFullCoverage() {
        let s = ReadRangeSet([TextSpan(start: 0, end: 10), TextSpan(start: 20, end: 30)])
        #expect(s.contains(TextSpan(start: 2, end: 8)))
        #expect(!s.contains(TextSpan(start: 5, end: 25)))
        #expect(s.intersection(with: TextSpan(start: 5, end: 25)) == [TextSpan(start: 5, end: 10), TextSpan(start: 20, end: 25)])
    }

    @Test("READ-04 直接跳到后章不会自动放开中间未读章节")
    func skippingAheadDoesNotUnlockMiddle() {
        var state = BookReadState(bookID: "b", bookVersion: "v")
        state.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100))
        state.markRead(chapterIndex: 5, range: TextSpan(start: 0, end: 50))
        #expect(state.isRead(chapterIndex: 5, range: TextSpan(start: 0, end: 10)))
        #expect(!state.isRead(chapterIndex: 3, range: TextSpan(start: 0, end: 1)))
        let scope = AccessScope.readOnly(state)
        #expect(!scope.allows(bookID: "b", version: "v", chapterIndex: 2, range: TextSpan(start: 0, end: 5)))
    }

    @Test("READ-04 回看已读章节不丢失历史区间")
    func revisitingKeepsHistory() {
        var state = BookReadState(bookID: "b", bookVersion: "v")
        state.markRead(chapterIndex: 2, range: TextSpan(start: 0, end: 300))
        state.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 50))
        state.markRead(chapterIndex: 2, range: TextSpan(start: 100, end: 120))
        #expect(state.readRanges(chapterIndex: 2) == [TextSpan(start: 0, end: 300)])
    }

    @Test("READ-05 版本不同的访问一律拒绝")
    func versionMismatchDenied() {
        var state = BookReadState(bookID: "b", bookVersion: "v1")
        state.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100))
        let scope = AccessScope.readOnly(state)
        #expect(!scope.allows(bookID: "b", version: "v2", chapterIndex: 0, range: TextSpan(start: 0, end: 5)))
        #expect(scope.clip(bookID: "other", version: "v1", chapterIndex: 0, range: TextSpan(start: 0, end: 5)).isEmpty)
    }

    @Test("READ-05 全书范围需显式选择，且仍绑定版本")
    func wholeBookScope() {
        let s = AccessScope.wholeBook(bookID: "b", version: "v")
        #expect(s.allows(bookID: "b", version: "v", chapterIndex: 9, range: TextSpan(start: 0, end: 999)))
        #expect(!s.allows(bookID: "b", version: "x", chapterIndex: 9, range: TextSpan(start: 0, end: 1)))
        #expect(s.hasAccessibleContent)
        #expect(!AccessScope.readOnly(BookReadState(bookID: "b", bookVersion: "v")).hasAccessibleContent)
    }

    @Test("READ-04 展示进度只统计已读字符，不决定检索范围")
    func displayProgress() {
        var state = BookReadState(bookID: "b", bookVersion: "v")
        state.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100))
        state.markRead(chapterIndex: 1, range: TextSpan(start: 0, end: 50))
        let summary = ProgressSummary(state: state, chapterLengths: [0: 100, 1: 100, 2: 200])
        #expect(abs(summary.fraction - 0.375) < 1e-9)
        #expect(summary.completedChapters == [0])
        #expect(summary.furthestChapter == 1)
    }
}

@Suite("M03 阅读会话")
struct SessionTrackerTests {
    func make(dwell: TimeInterval = 4) throws -> (ReadingSessionTracker, SQLiteReadingRepository, ManualClock) {
        let repo = SQLiteReadingRepository(try AppDatabase.inMemory())
        let clock = ManualClock()
        return (ReadingSessionTracker(repository: repo, clock: clock, ids: SequentialIDGenerator(),
                                      rule: ReadMarkingRule(minimumDwell: dwell, idleTimeout: 60)), repo, clock)
    }

    @Test("READ-04 页面停留达到阈值才记为已读")
    func dwellThreshold() async throws {
        let (t, repo, clock) = try make()
        _ = try await t.start(bookID: "b", bookVersion: "v")
        try await t.handle(.pageShown(chapterIndex: 0, range: TextSpan(start: 0, end: 100)))
        clock.advance(by: 2)
        try await t.handle(.pageShown(chapterIndex: 0, range: TextSpan(start: 100, end: 200)))
        clock.advance(by: 6)
        try await t.handle(.pageShown(chapterIndex: 0, range: TextSpan(start: 200, end: 300)))
        let state = try await repo.readState(bookID: "b", version: "v")
        #expect(!state.isRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100)))
        #expect(state.isRead(chapterIndex: 0, range: TextSpan(start: 100, end: 200)))
    }

    @Test("READ-04 前台时长累计，空闲超过阈值只计到阈值")
    func activeTimeWithIdleCap() async throws {
        let (t, _, clock) = try make()
        _ = try await t.start(bookID: "b", bookVersion: "v")
        clock.advance(by: 30)
        try await t.handle(.interaction)
        clock.advance(by: 1_000)
        try await t.handle(.interaction)
        #expect(await t.session?.activeSeconds == 90)
    }

    @Test("READ-04 转入后台暂停计时并提交当前页，回到前台继续")
    func backgroundPauses() async throws {
        let (t, repo, clock) = try make()
        _ = try await t.start(bookID: "b", bookVersion: "v")
        try await t.handle(.pageShown(chapterIndex: 1, range: TextSpan(start: 0, end: 50)))
        clock.advance(by: 10)
        try await t.handle(.backgrounded)
        clock.advance(by: 500)
        try await t.handle(.foregrounded)
        clock.advance(by: 5)
        try await t.handle(.interaction)
        #expect(await t.session?.activeSeconds == 15)
        #expect(try await repo.readState(bookID: "b", version: "v").isRead(chapterIndex: 1, range: TextSpan(start: 0, end: 50)))
    }

    @Test("READ-04 显式标记已读立即写入")
    func explicitMarkRead() async throws {
        let (t, repo, _) = try make()
        _ = try await t.start(bookID: "b", bookVersion: "v")
        try await t.handle(.markRangeRead(chapterIndex: 3, range: TextSpan(start: 5, end: 25)))
        #expect(try await repo.readState(bookID: "b", version: "v").isRead(chapterIndex: 3, range: TextSpan(start: 5, end: 25)))
        #expect(await t.session?.pagesMarkedRead == 1)
    }

    @Test("READ-04 结束会话后保存结束时间，后续事件被忽略")
    func endSession() async throws {
        let (t, repo, clock) = try make()
        let s = try await t.start(bookID: "b", bookVersion: "v")
        clock.advance(by: 20)
        try await t.end()
        try await t.handle(.interaction)
        let saved = try await repo.sessions(bookID: "b").first { $0.id == s.id }
        #expect(saved?.status == .ended)
        #expect(saved?.endedAt != nil)
        #expect(await t.session == nil)
    }

    @Test("READ-04 中断恢复：进程被杀后遗留会话以最后活动时间结束")
    func recoverInterrupted() async throws {
        let (t, repo, clock) = try make()
        _ = try await t.start(bookID: "b", bookVersion: "v")
        clock.advance(by: 30)
        try await t.handle(.interaction)
        let recovered = try await ReadingSessionTracker.recoverInterrupted(repository: repo)
        #expect(recovered.count == 1)
        #expect(recovered[0].endedAt == recovered[0].lastActivityAt)
        #expect(try await repo.openSessions().isEmpty)
    }

    @Test("READ-04 打开另一本书会结束上一本书的会话")
    func switchingBooksEndsPrevious() async throws {
        let (t, repo, _) = try make()
        let first = try await t.start(bookID: "a", bookVersion: "v")
        let again = try await t.start(bookID: "a", bookVersion: "v")
        #expect(first.id == again.id)
        _ = try await t.start(bookID: "b", bookVersion: "v")
        #expect(try await repo.sessions(bookID: "a").first?.status == .ended)
    }

    @Test("READ-04 重复提交相同区间不会产生重复区间记录")
    func idempotentRanges() async throws {
        let (_, repo, _) = try make()
        for _ in 0..<3 { try await repo.addReadRange(bookID: "b", version: "v", chapterIndex: 0, range: TextSpan(start: 0, end: 10)) }
        #expect(try await repo.readState(bookID: "b", version: "v").readRanges(chapterIndex: 0) == [TextSpan(start: 0, end: 10)])
    }
}
