import Testing
import Foundation
@testable import AgentRuntime
import LibraryCore
import TestSupport

private func executor(limits: ExecutionLimits = ExecutionLimits(maxModelCalls: 3, maxDuration: 60, maxOutputTokens: 100, contextTokenBudget: 100),
                      clock: ManualClock = ManualClock(), trace: TraceRecorder? = nil) -> (BoundedExecutor, TaskBudget) {
    let budget = TaskBudget(limits: limits, clock: clock)
    return (BoundedExecutor(budget: budget, clock: clock, sleeper: ImmediateSleeper(), trace: trace, traceID: "t1"), budget)
}

actor Attempts {
    var n = 0
    func next() -> Int { n += 1; return n }
}

@Suite("M10 预算")
struct BudgetTests {
    @Test("RUN-01 调用次数达到上限后拒绝")
    func callLimit() async throws {
        let budget = TaskBudget(limits: ExecutionLimits(maxModelCalls: 2, maxDuration: 60, maxOutputTokens: 1, contextTokenBudget: 1), clock: ManualClock())
        try await budget.reserveCall(stage: "a")
        try await budget.reserveCall(stage: "b")
        await #expect(throws: BudgetError.callLimitReached(stage: "c", limit: 2)) { try await budget.reserveCall(stage: "c") }
        #expect(await budget.remainingCalls == 0)
        #expect(await budget.snapshot().callsByStage == ["a": 1, "b": 1])
    }

    @Test("RUN-01 超过总时限后拒绝新调用")
    func deadline() async throws {
        let clock = ManualClock()
        let budget = TaskBudget(limits: .discussion, clock: clock)
        clock.advance(by: 61)
        await #expect(throws: BudgetError.deadlineExceeded) { try await budget.reserveCall(stage: "x") }
        #expect(await budget.remainingTime() == 0)
    }

    @Test("10.2 初始执行预算：讨论 6 次/60 秒，记忆 2 次/30 秒，学习 6 次/60 秒")
    func presets() {
        #expect(ExecutionLimits.discussion.maxModelCalls == 6 && ExecutionLimits.discussion.maxDuration == 60)
        #expect(ExecutionLimits.discussion.maxOutputTokens == 1_500 && ExecutionLimits.discussion.contextTokenBudget == 6_000)
        #expect(ExecutionLimits.memoryProposal.maxModelCalls == 2 && ExecutionLimits.memoryProposal.maxDuration == 30)
        #expect(ExecutionLimits.learning.maxModelCalls == 6)
    }

    @Test("RUN-03 区分服务端实际用量、估算用量与未知用量")
    func usageAccounting() async {
        let budget = TaskBudget(limits: .discussion, clock: ManualClock())
        await budget.record(usage: TokenUsage(promptTokens: 100, completionTokens: 20, source: .reported))
        await budget.record(usage: TokenUsage(promptTokens: 50, completionTokens: 0, source: .estimated))
        await budget.record(usage: nil)
        let s = await budget.snapshot()
        #expect(s.reportedPromptTokens == 100 && s.reportedCompletionTokens == 20)
        #expect(s.estimatedTokens == 50)
        #expect(s.unknownUsageCalls == 1)
    }

    @Test("RUN-01 负数配置被规整为 0")
    func normalizesLimits() {
        let l = ExecutionLimits(maxModelCalls: -1, maxDuration: -5, maxOutputTokens: 0, contextTokenBudget: -1)
        #expect(l.maxModelCalls == 0 && l.maxDuration == 0 && l.maxOutputTokens == 1 && l.contextTokenBudget == 0)
    }
}

@Suite("M10 有界执行")
struct ExecutorTests {
    @Test("RUN-01 重试计入同一预算：预算耗尽后停止重试")
    func retriesConsumeBudget() async throws {
        let (exec, budget) = executor()
        let attempts = Attempts()
        await #expect(throws: ProviderError.server(status: 503)) {
            _ = try await exec.run(stage: "gen", retry: RetryPolicy(maxAttempts: 10)) { () async throws -> Int in
                _ = await attempts.next()
                throw ProviderError.server(status: 503)
            }
        }
        #expect(await attempts.n == 3)
        #expect(await budget.remainingCalls == 0)
    }

    @Test("RUN-01 可重试错误重试后成功")
    func retryThenSucceed() async throws {
        let (exec, budget) = executor()
        let attempts = Attempts()
        let v = try await exec.run(stage: "gen", retry: .standard) { () async throws -> String in
            if await attempts.next() == 1 { throw ProviderError.rateLimited(retryAfter: 1) }
            return "ok"
        }
        #expect(v == "ok")
        #expect(await budget.snapshot().callsUsed == 2)
    }

    @Test("10.3 401/403/请求错误不重试")
    func nonRetryable() async throws {
        for error in [ProviderError.unauthorized, .forbidden, .badRequest("x"), .contextTooLong, .invalidResponse("x")] {
            let (exec, budget) = executor()
            await #expect(throws: error) { _ = try await exec.run(stage: "g", retry: RetryPolicy(maxAttempts: 3)) { () async throws -> Int in throw error } }
            #expect(await budget.snapshot().callsUsed == 1)
        }
    }

    @Test("10.3 超时返回 timeout 错误")
    func timeout() async throws {
        let (exec, _) = executor()
        await #expect(throws: ProviderError.timeout) {
            _ = try await exec.run(stage: "g", timeout: 0.05) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
        }
    }

    @Test("10.3 取消后不再发起调用，错误为 cancelled")
    func cancellation() async throws {
        let (exec, budget) = executor()
        let task = Task { try await exec.run(stage: "g") { () async throws -> Int in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        } }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await #expect(throws: BudgetError.cancelled) { _ = try await task.value }
        #expect(await budget.snapshot().callsUsed == 1)
    }

    @Test("RUN-03 每次调用记录追踪事件：阶段、模型、用量、结果与错误码")
    func tracesEachCall() async throws {
        let trace = TraceRecorder()
        let (exec, _) = executor(trace: trace)
        _ = try await exec.run(stage: "gen", model: "qwen", retry: .standard, usage: { _ in TokenUsage(promptTokens: 1, completionTokens: 1, source: .reported) }) {
            () async throws -> Int in 7
        }
        _ = try? await exec.run(stage: "verify", model: "qwen") { () async throws -> Int in throw ProviderError.unauthorized }
        let events = await trace.events(traceID: "t1")
        #expect(events.count == 2)
        #expect(events[0].stage == "gen" && events[0].outcome == .success && events[0].usage != nil)
        #expect(events[1].errorCode == "unauthorized" && events[1].outcome == .failure && events[1].usageUnknown)
    }

    @Test("RUN-01 退避：限流使用 Retry-After，其余指数增长且有上限")
    func backoff() {
        let p = RetryPolicy(maxAttempts: 5, baseDelay: 0.5, maxDelay: 3)
        #expect(p.delay(afterAttempt: 1, error: ProviderError.server(status: 500)) == 0.5)
        #expect(p.delay(afterAttempt: 3, error: ProviderError.server(status: 500)) == 2)
        #expect(p.delay(afterAttempt: 9, error: ProviderError.server(status: 500)) == 3)
        #expect(p.delay(afterAttempt: 1, error: ProviderError.rateLimited(retryAfter: 2.5)) == 2.5)
        #expect(!p.shouldRetry(ProviderError.server(status: 500), attempt: 5))
        #expect(!p.shouldRetry(CocoaError(.fileNoSuchFile), attempt: 1))
    }
}

@Suite("M10 完成门与任务登记")
struct GateAndRegistryTests {
    @Test("RUN-02 完成后取消无效；取消后迟到的完成被丢弃")
    func gateRaces() async {
        let g1 = CompletionGate<Int>()
        #expect(await g1.complete(1))
        #expect(await g1.cancel() == false)
        let g2 = CompletionGate<Int>()
        #expect(await g2.cancel())
        #expect(await g2.complete(2) == false)
        #expect(await g2.isCancelled)
        #expect(await g2.fail("x") == false)
    }

    @Test("RUN-02 并发完成只有一个生效")
    func concurrentCompletion() async {
        let g = CompletionGate<Int>()
        let results = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 { group.addTask { await g.complete(i) } }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }
        #expect(results.filter { $0 }.count == 1)
    }

    func registry() -> (TaskRegistry, InMemoryAgentTaskStore) {
        let store = InMemoryAgentTaskStore()
        return (TaskRegistry(store: store, clock: ManualClock(), ids: SequentialIDGenerator()), store)
    }

    @Test("RUN-02 重复触发：进行中返回 alreadyRunning，成功后返回 alreadySucceeded")
    func duplicateTriggers() async throws {
        let (r, _) = registry()
        guard case .started = try await r.begin(kind: .discussion, idempotencyKey: "k") else { Issue.record("应开始"); return }
        guard case .alreadyRunning = try await r.begin(kind: .discussion, idempotencyKey: "k") else { Issue.record("应在运行"); return }
        #expect(try await r.finish(idempotencyKey: "k", status: .succeeded, resultRef: "msg1"))
        guard case .alreadySucceeded(let rec) = try await r.begin(kind: .discussion, idempotencyKey: "k") else { Issue.record("应已成功"); return }
        #expect(rec.resultRef == "msg1")
    }

    @Test("CHAT-04 失败后可重试：尝试次数递增并换新 traceID")
    func retryAfterFailure() async throws {
        let (r, _) = registry()
        guard case .started(let first) = try await r.begin(kind: .discussion, idempotencyKey: "k") else { return }
        try await r.finish(idempotencyKey: "k", status: .failed, errorCode: "offline")
        guard case .started(let second) = try await r.begin(kind: .discussion, idempotencyKey: "k") else { Issue.record("应可重试"); return }
        #expect(second.attempts == 2)
        #expect(second.traceID != first.traceID)
        #expect(second.errorCode == nil)
    }

    @Test("RUN-02 迟到的第二次结束被忽略")
    func finishOnce() async throws {
        let (r, store) = registry()
        _ = try await r.begin(kind: .discussion, idempotencyKey: "k")
        #expect(try await r.finish(idempotencyKey: "k", status: .cancelled))
        #expect(try await r.finish(idempotencyKey: "k", status: .succeeded) == false)
        #expect(try await store.task(idempotencyKey: "k")?.status == .cancelled)
    }

    @Test("10.3 进程终止后启动时把运行中的任务标记为中断")
    func interruptedOnLaunch() async throws {
        let (r, store) = registry()
        _ = try await r.begin(kind: .discussion, idempotencyKey: "a")
        _ = try await r.begin(kind: .indexing, idempotencyKey: "b")
        try await r.finish(idempotencyKey: "b", status: .succeeded)
        let marked = try await r.markInterruptedOnLaunch()
        #expect(marked.map(\.idempotencyKey) == ["a"])
        #expect(try await store.tasks(status: .running).isEmpty)
    }
}

@Suite("M10 脱敏、估算与结构化输出")
struct UtilityTests {
    @Test("DATA-03 日志中的密钥与授权头被脱敏")
    func redaction() {
        let s = Redactor.redact("key sk-abcdef1234567890 header Bearer abc.def-ghi12345 api_key=\"zzzzzzzz\"")
        #expect(!s.contains("sk-abcdef1234567890"))
        #expect(!s.contains("abc.def-ghi12345"))
        #expect(!s.contains("zzzzzzzz"))
        #expect(s.contains("[REDACTED]"))
    }

    @Test("RUN-03 追踪属性默认不记录敏感正文")
    func safeAttributes() {
        let a = Redactor.safeAttributes(["api_key": "x", "question": "我的问题", "stage": "gen", "Authorization": "Bearer x"])
        #expect(a["api_key"] == "[REDACTED]" && a["Authorization"] == "[REDACTED]")
        #expect(a["question"] == "[omitted 4 chars]")
        #expect(a["stage"] == "gen")
        let e = TraceEvent(traceID: "t", stage: "s", name: "n", startedAt: Date(), outcome: .success, attributes: ["text": "原文内容"])
        #expect(e.attributes["text"]?.hasPrefix("[omitted") == true)
    }

    @Test("DATA-03 设置页密钥只显示掩码")
    func mask() {
        #expect(Redactor.mask("sk-1234567890abcd") == "••••••••abcd")
        #expect(Redactor.mask("abc") == "•••")
    }

    @Test("5.5 保守 Token 估算：中文按字、其他字符按 3 字符 1 token")
    func tokenEstimate() {
        #expect(TokenEstimator.estimate("读书方法") == 4)
        #expect(TokenEstimator.estimate("abcdef") == 2)
        #expect(TokenEstimator.estimate("abcd") == 2)
        #expect(TokenEstimator.estimate([.user("读书"), .assistant("ab")]) == (2 + 4) + (1 + 4) + 2)
    }

    @Test("CTX-03 按估算截断不超过预算")
    func truncate() {
        let s = String(repeating: "字", count: 100)
        let t = TokenEstimator.truncate(s, toTokens: 30)
        #expect(TokenEstimator.estimate(t) <= 30 && t.count == 30)
        #expect(TokenEstimator.truncate("短", toTokens: 30) == "短")
    }

    @Test("CTX-01 从模型输出中提取 JSON：围栏、前置说明与字符串中的括号")
    func jsonExtraction() throws {
        struct T: Decodable { var a: String }
        #expect(try JSONExtraction.decode(T.self, from: "结果如下：{\"a\":\"x}y\"} 完毕").a == "x}y")
        #expect(try JSONExtraction.decode(T.self, from: "```json\n{\"a\":\"fenced\"}\n```").a == "fenced")
        #expect(JSONExtraction.extractObject("没有 json") == nil)
        #expect(throws: ProviderError.self) { try JSONExtraction.decode(T.self, from: "{\"b\":1}") }
        #expect(JSONExtraction.extractObject("{\"a\": {\"b\": [1, 2]}") == nil)
    }

    @Test("CHAT-02 流式消费逐段回调；缺少结束帧视为截断")
    func collectStream() async throws {
        let model = ScriptedChatModel()
        model.enqueue("generation", .chunks(["一", "二", "三"]))
        actor Sink { var parts: [String] = []; func add(_ s: String) { parts.append(s) } }
        let sink = Sink()
        let r = try await model.collectStream(ChatRequest(messages: [.user("q")])) { await sink.add($0) }
        #expect(r.text == "一二三" && r.finishReason == .stop)
        #expect(await sink.parts == ["一", "二", "三"])
        model.enqueue("generation", .partialThenFail(["半"], .streamTruncated))
        await #expect(throws: ProviderError.streamTruncated) { _ = try await model.collectStream(ChatRequest(messages: [.user("q")])) { _ in } }
    }

    @Test("10.3 错误语义：可重试分类与用户提示")
    func errorSemantics() {
        #expect(ProviderError.offline.isRetryable && ProviderError.server(status: 502).isRetryable && ProviderError.streamTruncated.isRetryable)
        #expect(!ProviderError.unauthorized.isRetryable && !ProviderError.dimensionMismatch(expected: 1, actual: 2).isRetryable)
        #expect(ProviderError.unauthorized.userMessage.contains("401"))
        #expect(ProviderError.forbidden.userMessage.contains("403"))
        #expect(!ProviderError.badRequest("sk-abcdefghijklmnop").userMessage.contains("sk-abcdefghijklmnop"))
    }
}
