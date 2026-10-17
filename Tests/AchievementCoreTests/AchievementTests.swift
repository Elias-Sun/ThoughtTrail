import Testing
import Foundation
@testable import AchievementCore
import LibraryCore
import ReadingSessionCore
import Persistence

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let utc = TimeZone(identifier: "UTC")!

/// 在指定 UTC 日期的某时刻开始、持续 seconds 秒的会话。
private func session(_ id: String, day: Int, hourUTC: Double = 2, seconds: Double = 600, month: Int = 3) -> ReadingSession {
    let start = DayKey(year: 2026, month: month, day: day).startDate(in: utc).addingTimeInterval(hourUTC * 3600)
    var s = ReadingSession(id: id, bookID: "b", startedAt: start)
    s.activeSeconds = seconds
    s.endedAt = start.addingTimeInterval(seconds)
    s.lastActivityAt = s.endedAt!
    s.status = .ended
    return s
}

private func now(day: Int, hour: Double = 12) -> Date {
    DayKey(year: 2026, month: 3, day: day).startDate(in: utc).addingTimeInterval(hour * 3600)
}

@Suite("M15 阅读习惯统计")
struct HabitTests {
    @Test("HABIT-01 连续阅读按日历日计算；当天未达标时从昨天起算")
    func streaks() {
        let sessions = [session("a", day: 1), session("b", day: 2), session("c", day: 3), session("d", day: 5)]
        let s = HabitCalculator.stats(sessions: sessions, timeZone: utc, now: now(day: 6))
        #expect(s.currentStreak == 1)
        #expect(s.longestStreak == 3)
        let s2 = HabitCalculator.stats(sessions: sessions, timeZone: utc, now: now(day: 7))
        #expect(s2.currentStreak == 0)
    }

    @Test("HABIT-01 当天不足 5 分钟不计为有效阅读日")
    func minimumMinutes() {
        let s = HabitCalculator.stats(sessions: [session("a", day: 1, seconds: 120)], timeZone: utc, now: now(day: 1))
        #expect(s.qualifyingDays.isEmpty && s.totalSeconds == 120)
    }

    @Test("HABIT-01 重复事件（同一会话 ID）不重复累计")
    func dedupeSessions() {
        let s = HabitCalculator.stats(sessions: [session("a", day: 1), session("a", day: 1)], timeZone: utc, now: now(day: 1))
        #expect(s.totalSeconds == 600 && s.sessionCount == 1)
    }

    @Test("HABIT-01 跨午夜会话按墙钟跨度在两天间按比例分配")
    func crossMidnight() {
        // UTC 23:50 开始，持续 20 分钟
        let s = HabitCalculator.distribute(session: session("x", day: 1, hourUTC: 23 + 50.0 / 60, seconds: 1200), timeZone: utc)
        #expect(abs(s[DayKey(year: 2026, month: 3, day: 1)]! - 600) < 0.001)
        #expect(abs(s[DayKey(year: 2026, month: 3, day: 2)]! - 600) < 0.001)
    }

    @Test("HABIT-01 跨时区：同一会话在不同时区归属不同日历日")
    func timezones() {
        let late = session("x", day: 1, hourUTC: 20)   // 上海时间 3/2 04:00
        #expect(HabitCalculator.distribute(session: late, timeZone: utc).keys.first == DayKey(year: 2026, month: 3, day: 1))
        #expect(HabitCalculator.distribute(session: late, timeZone: shanghai).keys.first == DayKey(year: 2026, month: 3, day: 2))
    }

    @Test("HABIT-01 跨月份的连续天数正确")
    func monthBoundary() {
        let sessions = [session("a", day: 31, month: 1), session("b", day: 1, month: 2), session("c", day: 2, month: 2)]
        #expect(HabitCalculator.stats(sessions: sessions, timeZone: utc, now: now(day: 1)).longestStreak == 3)
    }
}

@Suite("M15 成就")
struct AchievementTests {
    @Test("HABIT-01 规则可解释：返回解锁原因")
    func explanations() {
        let stats = HabitCalculator.stats(sessions: (1...3).map { session("s\($0)", day: $0) }, timeZone: utc, now: now(day: 3))
        let unlocked = AchievementEngine().evaluate(stats: stats, snapshot: HabitSnapshot(reflectionCount: 1), alreadyUnlocked: [], now: now(day: 3))
        let ids = Set(unlocked.map(\.id))
        #expect(ids == ["first_day", "streak_3", "reflection_1"])
        #expect(unlocked.first { $0.id == "streak_3" }?.explanation == "最长连续阅读 3 天")
    }

    @Test("HABIT-01 已解锁的成就不会重复解锁")
    func noDuplicates() {
        let stats = HabitCalculator.stats(sessions: [session("a", day: 1)], timeZone: utc, now: now(day: 1))
        let again = AchievementEngine().evaluate(stats: stats, snapshot: HabitSnapshot(), alreadyUnlocked: ["first_day"], now: now(day: 1))
        #expect(again.isEmpty)
    }

    @Test("HABIT-01 计数类成就与读完一本书")
    func countAchievements() {
        let empty = HabitCalculator.stats(sessions: [], timeZone: utc, now: now(day: 1))
        let ids = Set(AchievementEngine().evaluate(stats: empty, snapshot: HabitSnapshot(reflectionCount: 10, annotationCount: 10, attemptCount: 1, completedBookCount: 1),
                                                   alreadyUnlocked: [], now: now(day: 1)).map(\.id))
        #expect(ids == ["reflection_1", "reflection_10", "annotation_10", "quiz_1", "book_finished"])
    }

    @Test("HABIT-01 服务刷新：持久化且重复刷新不重复插入")
    func serviceRefresh() async throws {
        let store = SQLiteRuntimeStore(try AppDatabase.inMemory())
        let clock = ManualClock(now(day: 3))
        let svc = AchievementService(repository: store, clock: clock)
        let sessions = (1...3).map { session("s\($0)", day: $0) }
        let first = try await svc.refresh(sessions: sessions, snapshot: HabitSnapshot(), timeZone: utc)
        let second = try await svc.refresh(sessions: sessions, snapshot: HabitSnapshot(), timeZone: utc)
        #expect(first.count == 2 && second.isEmpty)
        #expect(try await store.unlocked().count == 2)
    }

    @Test("HABIT-01 统计与成就一致：十小时成就基于累计时长")
    func hoursConsistency() {
        let sessions = (1...10).map { session("s\($0)", day: $0, seconds: 3600) }
        let stats = HabitCalculator.stats(sessions: sessions, timeZone: utc, now: now(day: 10))
        #expect(stats.totalSeconds == 36_000)
        #expect(AchievementEngine().evaluate(stats: stats, snapshot: HabitSnapshot(), alreadyUnlocked: [], now: now(day: 10)).contains { $0.id == "hours_10" })
    }

    @Test("HABIT-01 没有活动时长的会话不计入")
    func zeroActive() {
        let s = HabitCalculator.stats(sessions: [session("a", day: 1, seconds: 0)], timeZone: utc, now: now(day: 1))
        #expect(s.dailySeconds.isEmpty && s.sessionCount == 1)
    }
}
