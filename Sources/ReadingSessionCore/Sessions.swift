import Foundation
import LibraryCore

public enum SessionStatus: String, Codable, Sendable {
    case active, paused, ended
}

/// 一次阅读会话。`activeSeconds` 只累计前台可见时长。
public struct ReadingSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var startedAt: Date
    public var lastActivityAt: Date
    public var endedAt: Date?
    public var activeSeconds: Double
    public var status: SessionStatus
    public var pagesMarkedRead: Int

    public init(id: String, bookID: BookID, startedAt: Date) {
        self.id = id; self.bookID = bookID; self.startedAt = startedAt; self.lastActivityAt = startedAt
        self.endedAt = nil; self.activeSeconds = 0; self.status = .active; self.pagesMarkedRead = 0
    }
}

/// 会话与已读区间的持久化接口。
public protocol ReadingStateRepository: Sendable {
    func readState(bookID: BookID, version: String) async throws -> BookReadState
    /// 追加已读区间（合并由实现保证幂等）。
    func addReadRange(bookID: BookID, version: String, chapterIndex: Int, range: TextSpan) async throws
    func saveSession(_ session: ReadingSession) async throws
    func sessions(bookID: BookID?) async throws -> [ReadingSession]
    func openSessions() async throws -> [ReadingSession]
}

/// “标记已读”的记录规则：页面在前台可见至少 `minimumDwell` 秒才记为已读。
/// 这仅是应用的记录规则，不代表用户真正理解（5.2）。
public struct ReadMarkingRule: Codable, Hashable, Sendable {
    public var minimumDwell: TimeInterval
    /// 超过该时长无操作视为离开，不再累计时长。
    public var idleTimeout: TimeInterval

    public init(minimumDwell: TimeInterval = 4, idleTimeout: TimeInterval = 300) {
        self.minimumDwell = minimumDwell; self.idleTimeout = idleTimeout
    }
}

public enum SessionEvent: Sendable, Equatable {
    case pageShown(chapterIndex: Int, range: TextSpan)
    case markRangeRead(chapterIndex: Int, range: TextSpan)
    case backgrounded
    case foregrounded
    case interaction
    case close
}

/// 阅读会话追踪器：处理页面停留、前后台、空闲与中断恢复（READ-04、M03）。
public actor ReadingSessionTracker {
    private let repository: ReadingStateRepository
    private let clock: WallClock
    private let ids: IDGenerating
    public let rule: ReadMarkingRule

    public private(set) var session: ReadingSession?
    private var bookVersion: String = ""
    private var visiblePage: (chapter: Int, range: TextSpan, since: Date)?
    private var lastTick: Date?

    public init(repository: ReadingStateRepository, clock: WallClock = SystemClock(),
                ids: IDGenerating = UUIDGenerator(), rule: ReadMarkingRule = ReadMarkingRule()) {
        self.repository = repository; self.clock = clock; self.ids = ids; self.rule = rule
    }

    /// 启动时把上次异常中断（进程被杀）留下的会话以最后活动时间结束。
    public static func recoverInterrupted(repository: ReadingStateRepository) async throws -> [ReadingSession] {
        var recovered: [ReadingSession] = []
        for var s in try await repository.openSessions() {
            s.status = .ended
            s.endedAt = s.lastActivityAt
            try await repository.saveSession(s)
            recovered.append(s)
        }
        return recovered
    }

    public func start(bookID: BookID, bookVersion: String) async throws -> ReadingSession {
        if let current = session, current.status != .ended {
            if current.bookID == bookID { return current }
            try await end()
        }
        let now = clock.now()
        let s = ReadingSession(id: ids.make("sess"), bookID: bookID, startedAt: now)
        session = s
        self.bookVersion = bookVersion
        lastTick = now
        visiblePage = nil
        try await repository.saveSession(s)
        return s
    }

    public func handle(_ event: SessionEvent) async throws {
        guard var s = session, s.status != .ended else { return }
        let now = clock.now()
        switch event {
        case .pageShown(let chapter, let range):
            accumulate(&s, now: now)
            try await commitVisiblePage(&s, now: now)
            visiblePage = (chapter, range, now)
        case .markRangeRead(let chapter, let range):
            accumulate(&s, now: now)
            try await repository.addReadRange(bookID: s.bookID, version: bookVersion, chapterIndex: chapter, range: range)
            s.pagesMarkedRead += 1
        case .interaction:
            accumulate(&s, now: now)
        case .backgrounded:
            accumulate(&s, now: now)
            try await commitVisiblePage(&s, now: now)
            visiblePage = nil
            s.status = .paused
            lastTick = nil
        case .foregrounded:
            if s.status == .paused { s.status = .active }
            lastTick = now
        case .close:
            accumulate(&s, now: now)
            try await commitVisiblePage(&s, now: now)
            visiblePage = nil
            s.status = .ended
            s.endedAt = now
            lastTick = nil
        }
        s.lastActivityAt = now
        session = s
        try await repository.saveSession(s)
        if s.status == .ended { session = nil }
    }

    public func end() async throws {
        try await handle(.close)
    }

    /// 累计前台活动时长；超过空闲阈值的间隔只计到阈值。
    private func accumulate(_ s: inout ReadingSession, now: Date) {
        guard s.status == .active, let last = lastTick else { lastTick = now; return }
        let delta = max(0, now.timeIntervalSince(last))
        s.activeSeconds += min(delta, rule.idleTimeout)
        lastTick = now
    }

    /// 页面停留达到阈值才记为已读。
    private func commitVisiblePage(_ s: inout ReadingSession, now: Date) async throws {
        guard let page = visiblePage, s.status == .active else { return }
        let dwell = min(now.timeIntervalSince(page.since), rule.idleTimeout)
        guard dwell >= rule.minimumDwell, !page.range.isEmpty else { return }
        try await repository.addReadRange(bookID: s.bookID, version: bookVersion, chapterIndex: page.chapter, range: page.range)
        s.pagesMarkedRead += 1
    }
}

/// 阅读进度摘要，仅用于展示。
public struct ProgressSummary: Sendable, Equatable {
    public var fraction: Double
    public var completedChapters: [Int]
    public var furthestChapter: Int?

    public init(state: BookReadState, chapterLengths: [Int: Int]) {
        fraction = state.displayFraction(chapterLengths: chapterLengths)
        completedChapters = state.completedChapters(chapterLengths: chapterLengths)
        furthestChapter = state.chapters.filter { !$0.value.isEmpty }.keys.max()
    }
}
