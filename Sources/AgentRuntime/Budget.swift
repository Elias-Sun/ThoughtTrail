import Foundation
import LibraryCore

/// 任务执行上限（RUN-01、10.2）。所有子调用（含重试、修正、备用请求）共享同一预算。
public struct ExecutionLimits: Codable, Hashable, Sendable {
    public var maxModelCalls: Int
    public var maxDuration: TimeInterval
    public var maxOutputTokens: Int
    public var contextTokenBudget: Int

    public init(maxModelCalls: Int, maxDuration: TimeInterval, maxOutputTokens: Int, contextTokenBudget: Int) {
        self.maxModelCalls = max(0, maxModelCalls); self.maxDuration = max(0, maxDuration)
        self.maxOutputTokens = max(1, maxOutputTokens); self.contextTokenBudget = max(0, contextTokenBudget)
    }

    /// 一次前台阅读讨论：≤6 次外部请求，60 秒，回答 1500 Token，证据/历史 6000 Token。
    public static let discussion = ExecutionLimits(maxModelCalls: 6, maxDuration: 60, maxOutputTokens: 1_500, contextTokenBudget: 6_000)
    /// 异步记忆提议：≤2 次请求，30 秒。
    public static let memoryProposal = ExecutionLimits(maxModelCalls: 2, maxDuration: 30, maxOutputTokens: 800, contextTokenBudget: 3_000)
    /// 一次出题或作答反馈：≤6 次请求，60 秒。
    public static let learning = ExecutionLimits(maxModelCalls: 6, maxDuration: 60, maxOutputTokens: 1_500, contextTokenBudget: 6_000)
}

public enum BudgetError: Error, Equatable, Sendable {
    case callLimitReached(stage: String, limit: Int)
    case deadlineExceeded
    case cancelled
}

public struct BudgetSnapshot: Codable, Hashable, Sendable {
    public var limits: ExecutionLimits
    public var callsUsed: Int
    public var callsByStage: [String: Int]
    public var elapsed: TimeInterval
    public var reportedPromptTokens: Int
    public var reportedCompletionTokens: Int
    public var estimatedTokens: Int
    /// 未返回用量的调用次数（成本报告标记“未知”）。
    public var unknownUsageCalls: Int
}

/// 共享预算（actor 隔离）。
public actor TaskBudget {
    public let limits: ExecutionLimits
    private let clock: WallClock
    private let startedAt: Date
    private var callsUsed = 0
    private var callsByStage: [String: Int] = [:]
    private var reportedPrompt = 0
    private var reportedCompletion = 0
    private var estimated = 0
    private var unknownUsage = 0

    public init(limits: ExecutionLimits, clock: WallClock) {
        self.limits = limits; self.clock = clock; self.startedAt = clock.now()
    }

    public var remainingCalls: Int { max(0, limits.maxModelCalls - callsUsed) }

    public func remainingTime() -> TimeInterval {
        max(0, limits.maxDuration - clock.now().timeIntervalSince(startedAt))
    }

    public func checkDeadline() throws {
        if remainingTime() <= 0 { throw BudgetError.deadlineExceeded }
    }

    /// 预留一次外部调用；超过上限或超时抛错。
    @discardableResult
    public func reserveCall(stage: String) throws -> Int {
        try checkDeadline()
        guard callsUsed < limits.maxModelCalls else {
            throw BudgetError.callLimitReached(stage: stage, limit: limits.maxModelCalls)
        }
        callsUsed += 1
        callsByStage[stage, default: 0] += 1
        return callsUsed
    }

    public func canAfford(calls: Int) -> Bool {
        remainingCalls >= calls && remainingTime() > 0
    }

    public func record(usage: TokenUsage?) {
        guard let usage else { unknownUsage += 1; return }
        switch usage.source {
        case .reported:
            reportedPrompt += usage.promptTokens; reportedCompletion += usage.completionTokens
        case .estimated:
            estimated += usage.totalTokens
        }
    }

    public func snapshot() -> BudgetSnapshot {
        BudgetSnapshot(limits: limits, callsUsed: callsUsed, callsByStage: callsByStage,
                       elapsed: clock.now().timeIntervalSince(startedAt), reportedPromptTokens: reportedPrompt,
                       reportedCompletionTokens: reportedCompletion, estimatedTokens: estimated,
                       unknownUsageCalls: unknownUsage)
    }
}

/// 可注入的等待（重试退避、超时）。测试使用立即返回的实现。
public protocol Sleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// 重试策略。重试同样计入预算，避免多组件各自重试导致请求失控（10.2）。
public struct RetryPolicy: Sendable, Hashable {
    /// 总尝试次数（含首次）。
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 4) {
        self.maxAttempts = max(1, maxAttempts); self.baseDelay = baseDelay; self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)
    public static let standard = RetryPolicy(maxAttempts: 2)

    public func delay(afterAttempt attempt: Int, error: Error) -> TimeInterval {
        if case ProviderError.rateLimited(let retryAfter?) = error { return min(retryAfter, maxDelay) }
        return min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
    }

    public func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        if let p = error as? ProviderError { return p.isRetryable }
        return false
    }
}

/// 有界执行器：检查取消 → 预留预算 → 超时竞争 → 按策略重试 → 记录追踪。
public struct BoundedExecutor: Sendable {
    public let budget: TaskBudget
    public let sleeper: Sleeper
    public let trace: TraceRecorder?
    public let traceID: String
    public let clock: WallClock

    public init(budget: TaskBudget, clock: WallClock, sleeper: Sleeper = TaskSleeper(), trace: TraceRecorder? = nil,
                traceID: String) {
        self.budget = budget; self.clock = clock; self.sleeper = sleeper; self.trace = trace; self.traceID = traceID
    }

    public func run<T: Sendable>(stage: String, model: String? = nil, retry: RetryPolicy = .none,
                                 timeout: TimeInterval? = nil,
                                 usage: @Sendable (T) -> TokenUsage? = { _ in nil },
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            if Task.isCancelled { throw BudgetError.cancelled }
            try await budget.reserveCall(stage: stage)
            let started = clock.now()
            let remaining = await budget.remainingTime()
            let limit = min(timeout ?? remaining, remaining)
            do {
                let value = try await Self.withTimeout(limit, operation)
                let u = usage(value)
                await budget.record(usage: u)
                await trace?.record(TraceEvent(traceID: traceID, stage: stage, name: "model_call", startedAt: started,
                                               duration: clock.now().timeIntervalSince(started), model: model,
                                               usage: u, outcome: .success, attributes: ["attempt": "\(attempt)"]))
                return value
            } catch {
                let mapped: Error = (error is CancellationError) ? BudgetError.cancelled : error
                await budget.record(usage: nil)
                await trace?.record(TraceEvent(traceID: traceID, stage: stage, name: "model_call", startedAt: started,
                                               duration: clock.now().timeIntervalSince(started), model: model,
                                               usage: nil, outcome: Self.outcome(for: mapped),
                                               errorCode: Self.code(for: mapped), attributes: ["attempt": "\(attempt)"]))
                if case BudgetError.cancelled = mapped { throw mapped }
                guard retry.shouldRetry(mapped, attempt: attempt), await budget.canAfford(calls: 1) else { throw mapped }
                try? await sleeper.sleep(seconds: retry.delay(afterAttempt: attempt, error: mapped))
                if Task.isCancelled { throw BudgetError.cancelled }
            }
        }
    }

    static func outcome(for error: Error) -> TraceEvent.Outcome {
        if case BudgetError.cancelled = error { return .cancelled }
        return .failure
    }

    static func code(for error: Error) -> String {
        if let p = error as? ProviderError { return p.code }
        if let b = error as? BudgetError {
            switch b {
            case .callLimitReached: return "budget_calls"
            case .deadlineExceeded: return "budget_deadline"
            case .cancelled: return "cancelled"
            }
        }
        return String(describing: type(of: error))
    }

    /// 超时竞争：先完成者胜，另一方被取消。
    /// 超时使用真实时间（`Task.sleep`），重试退避使用可注入的 `Sleeper`。
    public static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let sleeper = TaskSleeper()
        guard seconds > 0 else { throw ProviderError.timeout }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await sleeper.sleep(seconds: seconds)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let value = result { return value }
                throw ProviderError.timeout
            }
            throw ProviderError.timeout
        }
    }
}
