import Testing
import Foundation
@testable import AgentRuntime
import LibraryCore
import TestSupport

actor SinkSpy: TraceSink {
    var count = 0
    func persist(_ event: TraceEvent) async { count += 1 }
}

@Suite("M10 边界情况")
struct RuntimeEdgeTests {
    @Test("RUN-01 剩余时间不足时单次调用的超时以剩余时间为准")
    func timeoutBoundedByRemaining() async throws {
        let clock = ManualClock()
        let budget = TaskBudget(limits: ExecutionLimits(maxModelCalls: 5, maxDuration: 60, maxOutputTokens: 1, contextTokenBudget: 1), clock: clock)
        clock.advance(by: 59.95)
        let exec = BoundedExecutor(budget: budget, clock: clock, sleeper: ImmediateSleeper(), traceID: "t")
        let start = Date()
        await #expect(throws: ProviderError.timeout) {
            _ = try await exec.run(stage: "g", timeout: 30) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 3_000_000_000); return 1
            }
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test("RUN-01 canAfford 同时检查次数与时间")
    func canAfford() async {
        let clock = ManualClock()
        let budget = TaskBudget(limits: ExecutionLimits(maxModelCalls: 2, maxDuration: 10, maxOutputTokens: 1, contextTokenBudget: 1), clock: clock)
        #expect(await budget.canAfford(calls: 2))
        #expect(await !budget.canAfford(calls: 3))
        clock.advance(by: 11)
        #expect(await !budget.canAfford(calls: 1))
    }

    @Test("RUN-03 预算快照记录耗时与分阶段次数")
    func snapshotElapsed() async throws {
        let clock = ManualClock()
        let budget = TaskBudget(limits: .discussion, clock: clock)
        try await budget.reserveCall(stage: "planning")
        try await budget.reserveCall(stage: "generation")
        try await budget.reserveCall(stage: "generation")
        clock.advance(by: 12)
        let s = await budget.snapshot()
        #expect(s.elapsed == 12 && s.callsUsed == 3 && s.callsByStage["generation"] == 2)
    }

    @Test("RUN-03 追踪记录器容量受限并转发到持久化接收端")
    func traceCapacityAndSink() async {
        let sink = SinkSpy()
        let rec = TraceRecorder(sink: sink, capacity: 3)
        for i in 0..<5 { await rec.record(TraceEvent(traceID: "t\(i)", stage: "s", name: "n", startedAt: Date(), outcome: .success)) }
        #expect(await rec.allEvents().map(\.traceID) == ["t2", "t3", "t4"])
        #expect(await sink.count == 5)
    }

    @Test("RUN-02 同一幂等键并发开始只有一个获得执行权")
    func concurrentBegin() async throws {
        let reg = TaskRegistry(store: InMemoryAgentTaskStore(), clock: ManualClock(), ids: SequentialIDGenerator())
        let results = try await withThrowingTaskGroup(of: TaskBeginResult.self) { group in
            for _ in 0..<10 { group.addTask { try await reg.begin(kind: .discussion, idempotencyKey: "same") } }
            var out: [TaskBeginResult] = []
            for try await r in group { out.append(r) }
            return out
        }
        #expect(results.filter { if case .started = $0 { return true } else { return false } }.count == 1)
    }

    /// 每次读写都让出执行权的存储：把“查到无记录 → 保存”之间的 await 交错稳定地暴露出来（真实 SQLite 存储同样是异步的）。
    actor YieldingTaskStore: AgentTaskStore {
        private var byKey: [String: AgentTaskRecord] = [:]
        func save(_ record: AgentTaskRecord) async throws { await Task.yield(); byKey[record.idempotencyKey] = record }
        func task(idempotencyKey: String) async throws -> AgentTaskRecord? { await Task.yield(); return byKey[idempotencyKey] }
        func tasks(status: AgentTaskStatus) async throws -> [AgentTaskRecord] { byKey.values.filter { $0.status == status } }
    }

    @Test("RUN-02 存储读写会挂起时，同一键并发开始仍只有一个获得执行权，其余报告正在执行")
    func concurrentBeginWithSuspendingStore() async throws {
        for round in 0..<20 {
            let store = YieldingTaskStore()
            let reg = TaskRegistry(store: store, clock: ManualClock(), ids: SequentialIDGenerator())
            let results = try await withThrowingTaskGroup(of: TaskBeginResult.self) { group in
                for _ in 0..<10 { group.addTask { try await reg.begin(kind: .discussion, idempotencyKey: "k\(round)") } }
                var out: [TaskBeginResult] = []
                for try await r in group { out.append(r) }
                return out
            }
            let started = results.compactMap { if case .started(let r) = $0 { return r } else { return nil } }
            let running = results.compactMap { if case .alreadyRunning(let r) = $0 { return r } else { return nil } }
            #expect(started.count == 1, "第 \(round) 轮")
            #expect(running.count == 9 && running.allSatisfy { $0.id == started.first?.id }, "第 \(round) 轮")
        }
    }

    @Test("10.3 重试等待期间被取消：停止重试并报告取消")
    func cancelDuringBackoff() async throws {
        struct SlowSleeper: Sleeper { func sleep(seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: 2_000_000_000) } }
        let clock = ManualClock()
        let budget = TaskBudget(limits: .discussion, clock: clock)
        let exec = BoundedExecutor(budget: budget, clock: clock, sleeper: SlowSleeper(), traceID: "t")
        let task = Task { try await exec.run(stage: "g", retry: RetryPolicy(maxAttempts: 5)) { () async throws -> Int in throw ProviderError.server(status: 502) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: BudgetError.cancelled) { _ = try await task.value }
        #expect(await budget.snapshot().callsUsed == 1)
    }

    @Test("CTX-01 从模型输出中提取 JSON 数组")
    func jsonArray() {
        let d = JSONExtraction.extractObject("结果：[{\"a\":1},{\"a\":2}] 结束")
        #expect(d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Int]] }?.count == 2)
    }

    @Test("RUN-03 错误码彼此唯一，便于统计")
    func uniqueCodes() {
        let all: [ProviderError] = [.offline, .timeout, .unauthorized, .forbidden, .rateLimited(retryAfter: nil), .server(status: 500),
                                    .badRequest(""), .contextTooLong, .emptyResponse, .invalidResponse(""), .streamTruncated,
                                    .dimensionMismatch(expected: 1, actual: 2), .invalidRerankIndex, .notConfigured(""), .cancelled]
        #expect(Set(all.map(\.code)).count == all.count)
        #expect(all.allSatisfy { !$0.userMessage.isEmpty })
    }
}
