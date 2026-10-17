import Foundation
import LibraryCore

/// 复习结果对间隔的影响（LEARN-04）。
public enum ReviewOutcome: String, Codable, Sendable {
    /// 表现良好：前进到下一个间隔。
    case advance
    /// 部分掌握：保持当前间隔。
    case hold
    /// 遗忘或错误：回退一级。
    case regress

    /// 由评分与自评决定。自评可修正模型评分；评分不确定时只看自评。
    public static func from(grade: Grade, selfRating: SelfRating?) -> ReviewOutcome {
        if let rating = selfRating, rating == .forgot { return .regress }
        switch grade {
        case .scored(let s):
            if s >= 0.8 { return selfRating == .hard ? .hold : .advance }
            if s >= 0.5 { return .hold }
            return .regress
        case .uncertain:
            switch selfRating {
            case .easy?, .good?: return .advance
            case .hard?: return .hold
            case .forgot?, nil: return .hold
            }
        }
    }
}

public struct ReviewLogEntry: Codable, Hashable, Sendable {
    public var attemptKey: String
    public var reviewedAt: Date
    public var outcome: ReviewOutcome
    public var fromStep: Int
    public var toStep: Int
    public var dueDay: DayKey
}

/// 一道题的复习排期。到期日按用户时区的日历日计算。
public struct ReviewSchedule: Codable, Hashable, Sendable {
    public var itemID: String
    public var step: Int
    public var dueDay: DayKey
    public var timeZoneID: String
    public var lastReviewedAt: Date?
    public var history: [ReviewLogEntry]

    public init(itemID: String, step: Int, dueDay: DayKey, timeZoneID: String, lastReviewedAt: Date? = nil, history: [ReviewLogEntry] = []) {
        self.itemID = itemID; self.step = step; self.dueDay = dueDay; self.timeZoneID = timeZoneID
        self.lastReviewedAt = lastReviewedAt; self.history = history
    }
}

/// 文档化的间隔规则：1/3/7/14/30 天，前进/保持/回退（Docs/DataAndInterfaces.md 第 6 节）。
public struct ReviewScheduler: Sendable {
    public let intervals: [Int]

    public init(intervals: [Int] = [1, 3, 7, 14, 30]) {
        precondition(!intervals.isEmpty)
        self.intervals = intervals
    }

    public func initial(itemID: String, createdAt: Date, timeZone: TimeZone) -> ReviewSchedule {
        let today = DayKey(date: createdAt, timeZone: timeZone)
        return ReviewSchedule(itemID: itemID, step: 0, dueDay: today.adding(days: intervals[0]), timeZoneID: timeZone.identifier)
    }

    /// 应用一次复习。同一 attemptKey 重复提交不会重复排期（LEARN-05）。
    public func apply(_ outcome: ReviewOutcome, to schedule: ReviewSchedule, at date: Date, timeZone: TimeZone,
                      attemptKey: String) -> ReviewSchedule {
        if schedule.history.contains(where: { $0.attemptKey == attemptKey }) { return schedule }
        var s = schedule
        let from = s.step
        switch outcome {
        case .advance: s.step = min(intervals.count - 1, s.step + 1)
        case .hold: break
        case .regress: s.step = max(0, s.step - 1)
        }
        let today = DayKey(date: date, timeZone: timeZone)
        s.dueDay = today.adding(days: intervals[s.step])
        s.timeZoneID = timeZone.identifier
        s.lastReviewedAt = date
        s.history.append(ReviewLogEntry(attemptKey: attemptKey, reviewedAt: date, outcome: outcome, fromStep: from,
                                        toStep: s.step, dueDay: s.dueDay))
        return s
    }

    public func isDue(_ schedule: ReviewSchedule, now: Date, timeZone: TimeZone) -> Bool {
        schedule.dueDay <= DayKey(date: now, timeZone: timeZone)
    }

    /// 逾期天数（未到期为负）。
    public func overdueDays(_ schedule: ReviewSchedule, now: Date, timeZone: TimeZone) -> Int {
        schedule.dueDay.days(to: DayKey(date: now, timeZone: timeZone))
    }

    /// 到期列表（完整范围）：逾期最久的在前。
    public func dueList(_ schedules: [ReviewSchedule], now: Date, timeZone: TimeZone) -> [ReviewSchedule] {
        schedules.filter { isDue($0, now: now, timeZone: timeZone) }
            .sorted { $0.dueDay == $1.dueDay ? $0.itemID < $1.itemID : $0.dueDay < $1.dueDay }
    }
}
