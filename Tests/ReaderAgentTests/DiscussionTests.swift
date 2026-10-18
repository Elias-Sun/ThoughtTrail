import Testing
import Foundation
@testable import ReaderAgent
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import RetrievalCore
import ContextRouting
import ContextEngineering
import BrainCore
import AgentRuntime
import EvidenceVerificationCore
import Persistence
import TestSupport

actor EventLog {
    var events: [DiscussionEvent] = []
    func add(_ e: DiscussionEvent) { events.append(e) }
    var statuses: [MessageStatus] { events.compactMap { if case .status(let s) = $0 { return s } else { return nil } } }
    var deltas: String { events.compactMap { if case .delta(let d) = $0 { return d } else { return nil } }.joined() }
    var policy: PolicySummary? { events.compactMap { if case .policy(let p) = $0 { return p } else { return nil } }.first }
    var evidence: [Evidence] { events.compactMap { if case .evidence(let e) = $0 { return e } else { return nil } }.first ?? [] }
    var revised: [String] { events.compactMap { if case .revised(let t) = $0 { return t } else { return nil } } }
}

/// 已导入中文书并读完前三章（第四章“结局”未读）。
struct Rig {
    let env: TestEnvironment
    let book: Book
    let chapters: [Chapter]

    static func make(readChapters: [Int] = [0, 1, 2]) async throws -> Rig {
        let env = try TestEnvironment()
        let (book, chapters) = try await env.importBook(Fixtures.zhBook())
        try await env.markRead(book, chapters: chapters, indices: readChapters)
        return Rig(env: env, book: book, chapters: chapters)
    }

    func ask(_ question: String, model: ChatModel?, scope: ScopeMode = .readOnly, selection: SelectionContext? = nil,
             planner: ChatModel? = nil, verifier: ChatModel? = nil, judge: ClaimJudge? = HeuristicClaimJudge(),
             limits: ExecutionLimits = .discussion, trace: TraceRecorder = TraceRecorder(), log: EventLog = EventLog(),
             extraBooks: [BookID] = []) async throws -> (Message, DiscussionOrchestrator, DiscussionRequest) {
        let (conv, user) = try await env.startDiscussion(book: book, question: question, selection: selection?.text, scope: scope, extraBooks: extraBooks)
        let orch = env.orchestrator(generator: model, planner: planner, verifier: verifier, fallbackJudge: judge, limits: limits, trace: trace)
        let req = DiscussionRequest(conversationID: conv.id, userMessageID: user.id, selection: selection)
        let m = try await orch.run(req) { await log.add($0) }
        return (m, orch, req)
    }
}

private let allLabels = "[E1, E2, E3, E4, E5, E6, E7, E8]"

@Suite("M11 阅读讨论链路")
struct DiscussionTests {
    @Test("CHAT-01/02 完整链路：检索→流式草稿→核查→已核查，并保存证据快照")
    func happyPath() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .chunks(["复习应当按照逐渐", "拉长的间隔进行\(allLabels)。"]))
        let log = EventLog()
        let (m, _, _) = try await rig.ask("为什么复习要按间隔进行？", model: model, log: log)
        #expect(m.status == .verified)
        #expect(!m.citations.isEmpty && m.citations.allSatisfy(\.structurallyValid))
        #expect(m.citations.contains { $0.quote.contains("间隔") && $0.locator?.chapterIndex == 1 })
        #expect(await log.statuses == [.preparing, .drafting, .verifying])
        #expect(await log.deltas.hasPrefix("复习应当按照逐渐拉长"))
        let saved = try await rig.env.reflections.message(id: m.id)
        #expect(saved?.status == .verified && saved?.claimChecks.first?.verdict == .supported)
    }

    @Test("CHAT-02 引用写在句末标点之后（……。[E1]）也能完成核查并通过结构校验")
    func citationAfterPunctuation() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行。\(allLabels)"))
        let (m, _, _) = try await rig.ask("复习间隔？", model: model)
        #expect(m.status == .verified)
        #expect(m.citations.allSatisfy { $0.structurallyValid })
    }

    @Test("READ-05 未读章节不进入检索与上下文：证据不足且不调用模型")
    func unreadNotRetrieved() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        let log = EventLog()
        let (m, _, _) = try await rig.ask("灯塔管理员其实是谁？失踪多年的船长？", model: model, log: log)
        #expect(await log.evidence.allSatisfy { $0.chapterIndex != 3 })
        #expect(m.status == .insufficientEvidence || !m.text.contains("船长"))
        #expect(model.requests(stage: "generation").allSatisfy { req in !req.messages.contains { $0.content.contains("灯塔管理员其实就是") } })
    }

    @Test("CHAT-03 范围内没有任何依据时说明限制并给出补充方式，不伪造引用")
    func insufficientEvidence() async throws {
        let rig = try await Rig.make(readChapters: [])
        let model = ScriptedChatModel()
        let (m, _, _) = try await rig.ask("结局是什么？", model: model)
        #expect(m.status == .insufficientEvidence)
        #expect(m.text.contains("没有找到") && m.text.contains("切换到全书范围"))
        #expect(m.citations.isEmpty)
        #expect(model.requestCount == 0)
    }

    @Test("5.2 用户切换全书范围后可检索未读章节，且范围在执行记录中可见")
    func wholeBookScope() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("灯塔管理员其实就是失踪多年的船长\(allLabels)。"))
        let log = EventLog()
        let (m, _, _) = try await rig.ask("灯塔管理员是谁？", model: model, scope: .wholeBook, log: log)
        #expect(await log.policy?.scopeMode == .wholeBook)
        #expect(await log.evidence.contains { $0.chapterIndex == 3 })
        #expect(m.scopeMode == .wholeBook)
        #expect(m.status == .verified)
    }

    @Test("CHAT-03 回答中伪造的引用标签被移除并记录")
    func fabricatedCitationRemoved() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行[E1, E42]。"))
        let trace = TraceRecorder()
        let log = EventLog()
        let (m, _, _) = try await rig.ask("复习间隔？", model: model, trace: trace, log: log)
        #expect(!m.text.contains("E42"))
        #expect(await trace.allEvents().contains { $0.name == "unknown_labels_removed" && $0.attributes["labels"] == "E42" })
        #expect(await log.revised.count == 1)
    }

    @Test("EVID-02 与证据矛盾的陈述被识别：状态为需处理")
    func contradictionDetected() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行，例如第2天和第5天\(allLabels)。"))
        let (m, _, _) = try await rig.ask("复习间隔具体是哪几天？", model: model)
        #expect(m.status == .needsAttention)
        #expect(m.claimChecks.contains { $0.verdict == .contradicted })
    }

    @Test("EVID-04 复核模型失败时显示“未能核查”，不是“已核查”")
    func verifierFailure() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let verifier = ScriptedChatModel(fallback: .fail(.timeout))
        let (m, _, _) = try await rig.ask("复习间隔？", model: model, verifier: verifier)
        #expect(m.status == .verificationUnavailable)
        #expect(m.errorDescription?.contains("未经核查") == true)
        #expect(!m.status.isVerifiedSuccess)
    }

    @Test("EVID-03 证据不足/矛盾时在预算内修正一轮，修正后通过")
    func correctionRound() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行，例如第2天\(allLabels)。"))
        model.enqueue("revision", .text("复习应当按照逐渐拉长的间隔进行，例如第1天、第3天、第7天\(allLabels)。"))
        let log = EventLog()
        let (m, _, _) = try await rig.ask("复习间隔？", model: model, log: log)
        #expect(m.status == .verified)
        #expect(m.text.contains("第3天"))
        #expect(model.requests(stage: "revision").count == 1)
        #expect(await log.revised.last?.contains("第7天") == true)
    }

    @Test("10.2 回答达到长度上限：标记不完整，不显示为完整成功")
    func truncatedAnswer() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。", .length))
        let (m, _, _) = try await rig.ask("复习间隔？", model: model)
        #expect(m.truncated)
        #expect(m.status == .needsAttention)
    }

    @Test("CHAT-01 选段作为当前阅读现场进入证据，并记为已读")
    func selectionEvidence() async throws {
        let rig = try await Rig.make(readChapters: [0])
        let ch = rig.chapters[1]
        let range = ch.text.utf16Ranges(of: "自测比重读更有效")[0]
        let sel = SelectionContext(locator: Locator.make(book: rig.book, chapter: ch, range: range), text: "自测比重读更有效")
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("自测比重读更有效[E1]。"))
        let log = EventLog()
        let (m, _, _) = try await rig.ask("这句话什么意思？", model: model, selection: sel, log: log)
        #expect(await log.evidence.first?.isSelection == true)
        #expect(m.citations.first?.label == "E1")
        let state = try await rig.env.reading.readState(bookID: rig.book.id, version: rig.book.fingerprint)
        #expect(state.isRead(chapterIndex: 1, range: range))
    }

    @Test("CHAT-04 断网失败：保留用户问题与草稿，可用同一请求重试并成功")
    func failureThenRetry() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .partialThenFail(["复习应当"], .offline), .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let (failed, orch, req) = try await rig.ask("复习间隔？", model: model)
        #expect(failed.status == .failed)
        #expect(failed.text == "复习应当")
        #expect(failed.errorDescription?.contains("网络") == true)
        #expect(try await rig.env.reflections.message(id: req.userMessageID)?.text == "复习间隔？")
        let retried = try await orch.run(req)
        #expect(retried.status == .verified)
        #expect(retried.id != failed.id)
    }

    @Test("RUN-02 同一请求重复触发不产生重复回答，也不重复调用模型")
    func idempotentRun() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let (first, orch, req) = try await rig.ask("复习间隔？", model: model)
        let second = try await orch.run(req)
        #expect(first.id == second.id)
        #expect(model.requests(stage: "generation").count == 1)
        let assistants = try await rig.env.reflections.messages(conversationID: req.conversationID).filter { $0.role == .assistant }
        #expect(assistants.count == 1)
    }

    @Test("CHAT-04/10.1 取消立即生效并保留草稿；迟到的生成结果不会改变已取消状态")
    func cancellation() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .delayed(0.3, "复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let (conv, user) = try await rig.env.startDiscussion(book: rig.book, question: "复习间隔？")
        let orch = rig.env.orchestrator(generator: model)
        let req = DiscussionRequest(conversationID: conv.id, userMessageID: user.id)
        let running = Task { try await orch.run(req) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        let cancelled = await orch.cancel(requestKey: req.requestKey)
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(cancelled?.status == .cancelled)
        #expect(cancelled?.text == "复习应当")
        let final = try await running.value
        #expect(final.status == .cancelled)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await rig.env.reflections.message(id: final.id)?.status == .cancelled)
    }

    @Test("RUN-01 规划、生成等共享 6 次调用预算；预算耗尽以明确状态结束")
    func sharedBudget() async throws {
        let rig = try await Rig.make()
        let planner = ScriptedChatModel(fallback: .text(#"{"intent":"general","queries":["复习"]}"#))
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let limits = ExecutionLimits(maxModelCalls: 1, maxDuration: 60, maxOutputTokens: 100, contextTokenBudget: 3_000)
        let (m, _, _) = try await rig.ask("复习间隔？", model: model, planner: planner, limits: limits)
        #expect(m.status == .failed)
        #expect(m.errorDescription?.contains("调用上限") == true)
        #expect(model.requestCount == 0)
    }

    @Test("CTX-04 规划输出畸形时使用规则策略并在记录中说明")
    func plannerFallback() async throws {
        let rig = try await Rig.make()
        let planner = ScriptedChatModel(fallback: .text("我不会输出 JSON"))
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let log = EventLog()
        let (m, _, _) = try await rig.ask("复习间隔？", model: model, planner: planner, log: log)
        let policy = try #require(await log.policy)
        #expect(!policy.usedModelPlan)
        #expect(policy.notes.contains { $0.code == "rule_fallback" })
        #expect(m.status == .verified)
    }

    @Test("CTX-02 规划要求放开到全书范围被拒绝，证据仍限于已读")
    func plannerCannotWiden() async throws {
        let rig = try await Rig.make()
        let planner = ScriptedChatModel(fallback: .text(#"{"intent":"general","queries":["灯塔管理员 船长"],"scope":"wholeBook","target_book_ids":["b-other"]}"#))
        let model = ScriptedChatModel(fallback: .text("目前没有找到依据。"))
        let log = EventLog()
        _ = try await rig.ask("灯塔管理员是谁？", model: model, planner: planner, log: log)
        let policy = try #require(await log.policy)
        #expect(policy.scopeMode == .readOnly)
        #expect(policy.notes.contains { $0.code == "scope_widen_rejected" })
        #expect(policy.notes.contains { $0.code == "book_rejected" })
        #expect(await log.evidence.allSatisfy { $0.chapterIndex != 3 })
    }

    @Test("CHAT-04 未配置对话模型时以明确失败结束并保留问题")
    func notConfigured() async throws {
        let rig = try await Rig.make()
        let (m, _, req) = try await rig.ask("复习间隔？", model: nil)
        #expect(m.status == .failed)
        #expect(m.errorDescription?.contains("尚未配置") == true)
        #expect(try await rig.env.reflections.message(id: req.userMessageID) != nil)
    }

    @Test("RUN-03 同一 traceID 关联规划、检索、上下文、核查与存储")
    func traceCorrelation() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let trace = TraceRecorder()
        let (m, _, _) = try await rig.ask("复习间隔？", model: model, trace: trace)
        let stages = Set(await trace.events(traceID: m.traceID!).map(\.stage))
        #expect(stages.isSuperset(of: ["routing", "retrieval", "context", "generation", "verification", "storage"]))
        #expect(await trace.events(traceID: m.traceID!).allSatisfy { $0.attributes["question"] == nil })
    }
}

@Suite("M11 多来源与多轮")
struct MultiSourceTests {
    @Test("CHAT-01 追问时历史问答进入生成请求")
    func followUpHistory() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let (conv, u1) = try await rig.env.startDiscussion(book: rig.book, question: "复习间隔？")
        let orch = rig.env.orchestrator(generator: model)
        _ = try await orch.run(DiscussionRequest(conversationID: conv.id, userMessageID: u1.id))
        let u2 = try await rig.env.conversationService().addUserMessage(conversationID: conv.id, text: "那为什么要逐渐拉长？")
        _ = try await orch.run(DiscussionRequest(conversationID: conv.id, userMessageID: u2.id))
        let last = try #require(model.requests(stage: "generation").last)
        #expect(last.messages.contains { $0.role == .user && $0.content == "复习间隔？" })
        #expect(last.messages.contains { $0.role == .assistant })
    }

    @Test("READ-05 全书范围下的历史回答不会进入之后的已读范围讨论")
    func wholeBookHistoryExcluded() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel(fallback: .text("灯塔管理员其实就是失踪多年的船长\(allLabels)。"))
        let svc = rig.env.conversationService()
        let (conv, u1) = try await rig.env.startDiscussion(book: rig.book, question: "灯塔管理员是谁？", scope: .wholeBook)
        let orch = rig.env.orchestrator(generator: model)
        _ = try await orch.run(DiscussionRequest(conversationID: conv.id, userMessageID: u1.id))
        _ = try await svc.setScope(conversationID: conv.id, mode: .readOnly)
        let u2 = try await svc.addUserMessage(conversationID: conv.id, text: "复习要怎么安排？")
        _ = try await orch.run(DiscussionRequest(conversationID: conv.id, userMessageID: u2.id))
        let last = try #require(model.requests(stage: "generation").last)
        #expect(!last.messages.contains { $0.content.contains("船长") })
    }

    @Test("CHAT-01 相关的批注与反思作为单独来源进入证据")
    func annotationsAndReflections() async throws {
        let rig = try await Rig.make()
        let ch = rig.chapters[1]
        let ann = AnnotationService(repository: rig.env.reading, clock: rig.env.clock, ids: rig.env.ids)
        _ = try await ann.addHighlight(book: rig.book, chapter: ch, range: ch.text.utf16Ranges(of: "自测比重读更有效")[0], note: "自测很关键")
        let refl = ReflectionService(repository: rig.env.reflections, clock: rig.env.clock, ids: rig.env.ids)
        let ctx = ReadingContextSnapshot(bookID: rig.book.id, bookVersion: rig.book.fingerprint, bookTitle: rig.book.title, chapterIndex: 1,
                                         chapterTitle: nil, locator: nil, selectedText: nil, sessionID: nil, capturedAt: rig.env.clock.now())
        let d = try await refl.startDraft(context: ctx, text: "我觉得自测比重读更累，但更有效")
        _ = try await refl.commit(id: d.id, commitKey: "c")
        let model = ScriptedChatModel(fallback: .text("自测比重读更有效\(allLabels)。"))
        let log = EventLog()
        _ = try await rig.ask("自测为什么比重读有效？", model: model, log: log)
        let kinds = Set(await log.evidence.map(\.kind))
        #expect(kinds.contains(.annotation) && kinds.contains(.reflection))
    }

    @Test("MEM-05 越界来源的记忆不进入讨论上下文")
    func outOfScopeMemoryExcluded() async throws {
        let rig = try await Rig.make()
        let brain = BrainService(repository: rig.env.brain, clock: rig.env.clock, ids: rig.env.ids)
        let ending = rig.chapters[3]
        _ = try await brain.create(kind: .memory, content: "灯塔管理员就是船长（复习时记下）",
                                   evidence: [.book(rig.book.id, version: rig.book.fingerprint, chapter: 3, range: TextSpan(start: 0, end: ending.length), quote: "结局")])
        _ = try await brain.create(kind: .memory, content: "复习要按间隔安排",
                                   evidence: [.book(rig.book.id, version: rig.book.fingerprint, chapter: 1, range: TextSpan(start: 0, end: 10), quote: "复习")])
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let log = EventLog()
        _ = try await rig.ask("复习怎么安排？比较一下我的记忆", model: model, log: log)
        let memories = await log.evidence.filter { $0.kind == .memory }.map(\.text)
        #expect(memories.contains("复习要按间隔安排"))
        #expect(!memories.contains { $0.contains("船长") })
    }

    @Test("READ-05 跨书讨论逐本遵守各自的已读边界")
    func crossBook() async throws {
        let rig = try await Rig.make()
        let (en, enChapters) = try await rig.env.importBook(Fixtures.enBook(), name: "en.epub")
        try await rig.env.markRead(en, chapters: enChapters, indices: [1])
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行\(allLabels)。"))
        let log = EventLog()
        _ = try await rig.ask("storm bridges 复习 captain", model: model, log: log, extraBooks: [en.id])
        let ev = await log.evidence
        #expect(ev.contains { $0.bookID == en.id && $0.chapterIndex == 1 })
        #expect(!ev.contains { $0.bookID == en.id && $0.chapterIndex == 2 })
        #expect(!ev.contains { $0.bookID == rig.book.id && $0.chapterIndex == 3 })
    }
}

@Suite("M11 异步记忆提议")
struct MemoryProposalFlowTests {
    @Test("MEM-02 讨论完成后生成待确认提议，引用映射到回答中的有效证据")
    func proposals() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行[E1]。"))
        model.enqueue("memory_proposal", .text(#"{"proposals":[{"action":"create","kind":"memory","content":"复习按逐渐拉长的间隔进行","evidence":["E1"],"rationale":"讨论结论"}]}"#))
        let (m, orch, _) = try await rig.ask("复习间隔？", model: model)
        let props = try await orch.proposeMemories(messageID: m.id)
        #expect(props.count == 1 && props[0].status == .pending)
        if case .create(_, _, let ev) = props[0].action { #expect(ev.first?.kind == .bookText) } else { Issue.record("应为 create") }
        #expect(try await rig.env.brain.items(kinds: nil, includeInactive: true).isEmpty)
        let again = try await orch.proposeMemories(messageID: m.id)
        #expect(again.map(\.id) == props.map(\.id))
        #expect(model.requests(stage: "memory_proposal").count == 1)
    }

    @Test("MEM-02 提议失败可重试，不影响已保存讨论")
    func proposalFailureRetry() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .text("复习应当按照逐渐拉长的间隔进行[E1]。"))
        model.enqueue("memory_proposal", .fail(.unauthorized), .text(#"{"proposals":[]}"#))
        let (m, orch, _) = try await rig.ask("复习间隔？", model: model)
        await #expect(throws: ProviderError.unauthorized) { try await orch.proposeMemories(messageID: m.id) }
        #expect(try await rig.env.reflections.message(id: m.id)?.status == .verified)
        #expect(try await orch.proposeMemories(messageID: m.id).isEmpty)
    }

    @Test("MEM-02 失败或取消的回答不生成提议")
    func noProposalForFailed() async throws {
        let rig = try await Rig.make()
        let model = ScriptedChatModel()
        model.enqueue("generation", .fail(.offline))
        let (m, orch, _) = try await rig.ask("复习间隔？", model: model)
        #expect(try await orch.proposeMemories(messageID: m.id).isEmpty)
        #expect(model.requests(stage: "memory_proposal").isEmpty)
    }
}

@Suite("M11 补充")
struct DiscussionEdgeTests {
    @Test("READ-05 未读章节上的批注不进入讨论证据")
    func unreadAnnotationExcluded() async throws {
        let rig = try await Rig.make(readChapters: [0, 1])
        let ending = rig.chapters[3]
        _ = try await AnnotationService(repository: rig.env.reading, clock: rig.env.clock, ids: rig.env.ids)
            .addHighlight(book: rig.book, chapter: ending, range: ending.text.utf16Ranges(of: "灯塔管理员")[0], note: "复习时看到的灯塔秘密")
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行[E1, E2, E3, E4]。"))
        let log = EventLog()
        _ = try await rig.ask("复习和灯塔管理员", model: model, log: log)
        #expect(await log.evidence.allSatisfy { $0.kind != .annotation })
    }

    @Test("READ-05 阅读现场位于未读区间的反思不进入讨论证据")
    func unreadReflectionExcluded() async throws {
        let rig = try await Rig.make(readChapters: [0, 1])
        let ending = rig.chapters[3]
        let refl = ReflectionService(repository: rig.env.reflections, clock: rig.env.clock, ids: rig.env.ids)
        let ctx = ReadingContextSnapshot(bookID: rig.book.id, bookVersion: rig.book.fingerprint, bookTitle: rig.book.title, chapterIndex: 3,
                                         chapterTitle: nil, locator: Locator.make(book: rig.book, chapter: ending, range: TextSpan(start: 0, end: 5)),
                                         selectedText: nil, sessionID: nil, capturedAt: rig.env.clock.now())
        let d = try await refl.startDraft(context: ctx, text: "复习时我想到灯塔管理员就是船长")
        _ = try await refl.commit(id: d.id, commitKey: "x")
        let model = ScriptedChatModel(fallback: .text("复习应当按照逐渐拉长的间隔进行[E1, E2, E3]。"))
        let log = EventLog()
        _ = try await rig.ask("复习时想到了什么？", model: model, log: log)
        #expect(await log.evidence.allSatisfy { $0.kind != .reflection })
    }
}
