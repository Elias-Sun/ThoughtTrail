import Foundation
import LibraryCore
import ReadingSessionCore

/// 阅读统计（HABIT-01）。规则：会话的前台时长按其墙钟跨度在各日历日间按比例分配；
/// 当日累计 ≥ `minimumSecondsPerDay` 记为有效阅读日；连续天数按用户时区的日历日计算。
public struct ReadingStats: Sendable, Equatable {
    public var dailySeconds: [DayKey: Double]
    public var totalSeconds: Double
    public var sessionCount: Int
    public var qualifyingDays: [DayKey]
    public var currentStreak: Int
    public var longestStreak: Int
}

public enum HabitCalculator {
    public static let minimumSecondsPerDay: Double = 300

    public static func stats(sessions: [ReadingSession], timeZone: TimeZone, now: Date,
                             minimumSecondsPerDay: Double = minimumSecondsPerDay) -> ReadingStats {
        // 同一会话重复事件只计一次
        var unique: [String: ReadingSession] = [:]
        for s in sessions { unique[s.id] = s }
        var daily: [DayKey: Double] = [:]
        for s in unique.values where s.activeSeconds > 0 {
            for (day, secs) in distribute(session: s, timeZone: timeZone) { daily[day, default: 0] += secs }
        }
        let qualifying = daily.filter { $0.value >= minimumSecondsPerDay }.map(\.key).sorted()
        let qset = Set(qualifying)
        let today = DayKey(date: now, timeZone: timeZone)
        // 今天尚未达标时，从昨天开始计算当前连续（当天仍有机会）
        var cursor = qset.contains(today) ? today : today.adding(days: -1)
        var current = 0
        while qset.contains(cursor) { current += 1; cursor = cursor.adding(days: -1) }
        var longest = 0, run = 0
        var prev: DayKey?
        for d in qualifying {
            if let p = prev, p.adding(days: 1) == d { run += 1 } else { run = 1 }
            longest = max(longest, run)
            prev = d
        }
        return ReadingStats(dailySeconds: daily, totalSeconds: daily.values.reduce(0, +), sessionCount: unique.count,
                            qualifyingDays: qualifying, currentStreak: current, longestStreak: longest)
    }

    /// 把会话的前台时长按跨越的日历日比例分配（跨午夜、跨时区一致）。
    public static func distribute(session: ReadingSession, timeZone: TimeZone) -> [DayKey: Double] {
        let start = session.startedAt
        let end = max(session.endedAt ?? session.lastActivityAt, start)
        let span = end.timeIntervalSince(start)
        let startDay = DayKey(date: start, timeZone: timeZone)
        guard span > 0 else { return [startDay: session.activeSeconds] }
        var out: [DayKey: Double] = [:]
        var day = startDay
        while true {
            let dayStart = max(start, day.startDate(in: timeZone))
            let dayEnd = min(end, day.adding(days: 1).startDate(in: timeZone))
            if dayEnd > dayStart {
                out[day, default: 0] += session.activeSeconds * dayEnd.timeIntervalSince(dayStart) / span
            }
            if day.adding(days: 1).startDate(in: timeZone) >= end { break }
            day = day.adding(days: 1)
        }
        return out
    }
}

/// 计算成就所需的计数快照（均来自持久化记录，可解释）。
public struct HabitSnapshot: Sendable, Equatable {
    public var reflectionCount: Int
    public var annotationCount: Int
    public var attemptCount: Int
    public var completedBookCount: Int

    public init(reflectionCount: Int = 0, annotationCount: Int = 0, attemptCount: Int = 0, completedBookCount: Int = 0) {
        self.reflectionCount = reflectionCount; self.annotationCount = annotationCount
        self.attemptCount = attemptCount; self.completedBookCount = completedBookCount
    }
}

public struct UnlockedAchievement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var unlockedAt: Date
    /// 解锁原因（可从记录解释结果）。
    public var explanation: String

    public init(id: String, title: String, unlockedAt: Date, explanation: String) {
        self.id = id; self.title = title; self.unlockedAt = unlockedAt; self.explanation = explanation
    }
}

public struct AchievementDefinition: Sendable {
    public var id: String
    public var title: String
    public var rule: @Sendable (ReadingStats, HabitSnapshot) -> String?

    public init(id: String, title: String, rule: @escaping @Sendable (ReadingStats, HabitSnapshot) -> String?) {
        self.id = id; self.title = title; self.rule = rule
    }
}

public enum AchievementCatalog {
    public static let all: [AchievementDefinition] = [
        AchievementDefinition(id: "first_day", title: "开卷有益") { s, _ in
            s.qualifyingDays.first.map { "\($0) 当日阅读满 5 分钟" }
        },
        AchievementDefinition(id: "streak_3", title: "三日不辍") { s, _ in
            s.longestStreak >= 3 ? "最长连续阅读 \(s.longestStreak) 天" : nil
        },
        AchievementDefinition(id: "streak_7", title: "一周坚持") { s, _ in
            s.longestStreak >= 7 ? "最长连续阅读 \(s.longestStreak) 天" : nil
        },
        AchievementDefinition(id: "streak_30", title: "月读不息") { s, _ in
            s.longestStreak >= 30 ? "最长连续阅读 \(s.longestStreak) 天" : nil
        },
        AchievementDefinition(id: "hours_10", title: "十小时") { s, _ in
            s.totalSeconds >= 36_000 ? String(format: "累计阅读 %.1f 小时", s.totalSeconds / 3600) : nil
        },
        AchievementDefinition(id: "reflection_1", title: "第一次反思") { _, h in
            h.reflectionCount >= 1 ? "已保存 \(h.reflectionCount) 条反思" : nil
        },
        AchievementDefinition(id: "reflection_10", title: "思有所迹") { _, h in
            h.reflectionCount >= 10 ? "已保存 \(h.reflectionCount) 条反思" : nil
        },
        AchievementDefinition(id: "annotation_10", title: "勤做批注") { _, h in
            h.annotationCount >= 10 ? "已做 \(h.annotationCount) 条批注" : nil
        },
        AchievementDefinition(id: "quiz_1", title: "初试自测") { _, h in
            h.attemptCount >= 1 ? "已完成 \(h.attemptCount) 次作答" : nil
        },
        AchievementDefinition(id: "book_finished", title: "读完一本书") { _, h in
            h.completedBookCount >= 1 ? "已读完 \(h.completedBookCount) 本书（已读区间覆盖全书）" : nil
        },
    ]
}

public protocol AchievementRepository: Sendable {
    func unlocked() async throws -> [UnlockedAchievement]
    /// 已存在的 id 不得重复插入（重复解锁）。
    func insertIfAbsent(_ achievements: [UnlockedAchievement]) async throws
}

/// 成就评估：只返回新解锁项，已解锁不会重复（HABIT-01）。
public struct AchievementEngine: Sendable {
    public let catalog: [AchievementDefinition]

    public init(catalog: [AchievementDefinition] = AchievementCatalog.all) { self.catalog = catalog }

    public func evaluate(stats: ReadingStats, snapshot: HabitSnapshot, alreadyUnlocked: Set<String>, now: Date) -> [UnlockedAchievement] {
        catalog.compactMap { def in
            guard !alreadyUnlocked.contains(def.id), let why = def.rule(stats, snapshot) else { return nil }
            return UnlockedAchievement(id: def.id, title: def.title, unlockedAt: now, explanation: why)
        }
    }
}

public actor AchievementService {
    private let repository: AchievementRepository
    private let engine: AchievementEngine
    private let clock: WallClock

    public init(repository: AchievementRepository, engine: AchievementEngine = AchievementEngine(), clock: WallClock = SystemClock()) {
        self.repository = repository; self.engine = engine; self.clock = clock
    }

    @discardableResult
    public func refresh(sessions: [ReadingSession], snapshot: HabitSnapshot, timeZone: TimeZone) async throws -> [UnlockedAchievement] {
        let stats = HabitCalculator.stats(sessions: sessions, timeZone: timeZone, now: clock.now())
        let already = Set(try await repository.unlocked().map(\.id))
        let new = engine.evaluate(stats: stats, snapshot: snapshot, alreadyUnlocked: already, now: clock.now())
        if !new.isEmpty { try await repository.insertIfAbsent(new) }
        return new
    }
}
