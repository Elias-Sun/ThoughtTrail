import Testing
import Foundation
@testable import LearningCore
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import ContextEngineering
import ContextRouting
import AgentRuntime
import Persistence
import TestSupport

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let utc = TimeZone(identifier: "UTC")!
/// 2026-03-10 12:00:00 UTC
private let noon = Date(timeIntervalSince1970: 1_773_144_000)

@Suite("M18 复习调度")
struct SchedulerTests {
    let s = ReviewScheduler()

    @Test("LEARN-04 新题第 1 天到期")
    func initialDue() {
        let sched = s.initial(itemID: "q", createdAt: noon, timeZone: utc)
        #expect(sched.step == 0 && sched.dueDay == DayKey(year: 2026, month: 3, day: 11))
    }

    @Test("LEARN-04 表现良好按 1/3/7/14/30 前进并在 30 天封顶")
    func advanceSequence() {
        var sched = s.initial(itemID: "q", createdAt: noon, timeZone: utc)
        var gaps: [Int] = []
        for i in 0..<6 {
            sched = s.apply(.advance, to: sched, at: noon, timeZone: utc, attemptKey: "a\(i)")
            gaps.append(DayKey(date: noon, timeZone: utc).days(to: sched.dueDay))
        }
        #expect(gaps == [3, 7, 14, 30, 30, 30])
    }

    @Test("LEARN-04 部分掌握保持间隔，遗忘回退一级且不低于第一级")
    func holdAndRegress() {
        var sched = s.initial(itemID: "q", createdAt: noon, timeZone: utc)
        sched = s.apply(.advance, to: sched, at: noon, timeZone: utc, attemptKey: "1")
        sched = s.apply(.advance, to: sched, at: noon, timeZone: utc, attemptKey: "2")
        #expect(sched.step == 2)
        sched = s.apply(.hold, to: sched, at: noon, timeZone: utc, attemptKey: "3")
        #expect(sched.step == 2)
        sched = s.apply(.regress, to: sched, at: noon, timeZone: utc, attemptKey: "4")
        sched = s.apply(.regress, to: sched, at: noon, timeZone: utc, attemptKey: "5")
        sched = s.apply(.regress, to: sched, at: noon, timeZone: utc, attemptKey: "6")
        #expect(sched.step == 0)
        #expect(sched.history.map(\.outcome) == [.advance, .advance, .hold, .regress, .regress, .regress])
    }

    @Test("LEARN-05 同一次作答重复提交不重复排期")
    func idempotentApply() {
        let base = s.initial(itemID: "q", createdAt: noon, timeZone: utc)
        let once = s.apply(.advance, to: base, at: noon, timeZone: utc, attemptKey: "same")
        let twice = s.apply(.advance, to: once, at: noon, timeZone: utc, attemptKey: "same")
        #expect(once == twice)
        #expect(twice.history.count == 1)
    }

    @Test("LEARN-05 到期按用户时区的日历日计算（固定时钟）")
    func timezoneDue() {
        // 上海 2026-03-10 23:30 = UTC 15:30
        let lateNight = Date(timeIntervalSince1970: 1_773_156_600)
        let sched = s.initial(itemID: "q", createdAt: lateNight, timeZone: shanghai)
        #expect(sched.dueDay == DayKey(year: 2026, month: 3, day: 11))
        // 上海次日 00:10 已到期；同一时刻在纽约仍是 3 月 10 日，未到期
        let justAfterMidnight = lateNight.addingTimeInterval(40 * 60)
        #expect(s.isDue(sched, now: justAfterMidnight, timeZone: shanghai))
        #expect(!s.isDue(sched, now: justAfterMidnight, timeZone: TimeZone(identifier: "America/New_York")!))
    }

    @Test("LEARN-05 到期列表包含逾期项，逾期最久的在前")
    func dueListIncludesOverdue() {
        let a = ReviewSchedule(itemID: "a", step: 0, dueDay: DayKey(year: 2026, month: 3, day: 1), timeZoneID: "UTC")
        let b = ReviewSchedule(itemID: "b", step: 0, dueDay: DayKey(year: 2026, month: 3, day: 9), timeZoneID: "UTC")
        let c = ReviewSchedule(itemID: "c", step: 0, dueDay: DayKey(year: 2026, month: 3, day: 20), timeZoneID: "UTC")
        #expect(s.dueList([c, b, a], now: noon, timeZone: utc).map(\.itemID) == ["a", "b"])
        #expect(s.overdueDays(a, now: noon, timeZone: utc) == 9)
        #expect(s.overdueDays(c, now: noon, timeZone: utc) < 0)
    }

    @Test("LEARN-04 评分与自评决定前进、保持或回退")
    func outcomeMapping() {
        #expect(ReviewOutcome.from(grade: .scored(0.9), selfRating: nil) == .advance)
        #expect(ReviewOutcome.from(grade: .scored(0.9), selfRating: .hard) == .hold)
        #expect(ReviewOutcome.from(grade: .scored(0.6), selfRating: .easy) == .hold)
        #expect(ReviewOutcome.from(grade: .scored(0.2), selfRating: nil) == .regress)
        #expect(ReviewOutcome.from(grade: .scored(1), selfRating: .forgot) == .regress)
        #expect(ReviewOutcome.from(grade: .uncertain("x"), selfRating: .good) == .advance)
        #expect(ReviewOutcome.from(grade: .uncertain("x"), selfRating: nil) == .hold)
    }
}

@Suite("M18 掌握记录")
struct MasteryTests {
    @Test("LEARN-03 一次高分不算永久掌握，需要连续两次通过")
    func notMasteredAfterOne() {
        var m = MasteryRecord(knowledgePoint: "间隔复习", bookID: "b", updatedAt: noon)
        m.record(score: 1, selfRating: nil, at: noon)
        #expect(m.level == .familiar)
        m.record(score: 0.9, selfRating: nil, at: noon)
        #expect(m.level == .mastered)
        m.record(score: 0.1, selfRating: nil, at: noon)
        #expect(m.level == .learning)
        #expect(m.attempts == 3 && m.errors == 1)
    }

    @Test("LEARN-03 人工修正优先，下一次作答后恢复按记录计算")
    func manualOverride() {
        var m = MasteryRecord(knowledgePoint: "k", bookID: "b", updatedAt: noon)
        m.manualLevel = .mastered
        #expect(m.level == .mastered)
        m.record(score: 0.2, selfRating: nil, at: noon)
        #expect(m.manualLevel == nil && m.level == .learning)
    }

    @Test("LEARN-03 只保留最近窗口内的作答事件")
    func recentWindow() {
        var m = MasteryRecord(knowledgePoint: "k", bookID: "b", updatedAt: noon)
        for _ in 0..<9 { m.record(score: 0.5, selfRating: nil, at: noon) }
        #expect(m.recent.count == MasteryRecord.recentWindow && m.attempts == 9)
    }

    @Test("LEARN-03 评分不确定时按自评计算错误")
    func uncertainUsesSelfRating() {
        var m = MasteryRecord(knowledgePoint: "k", bookID: "b", updatedAt: noon)
        m.record(score: nil, selfRating: .forgot, at: noon)
        #expect(m.errors == 1 && m.level == .learning)
        m.record(score: nil, selfRating: .good, at: noon)
        #expect(m.level == .familiar)
    }
}

private func readScope(_ chapters: [Int] = [0]) -> RetrievalScope {
    var s = BookReadState(bookID: "b1", bookVersion: "fp1")
    for c in chapters { s.markRead(chapterIndex: c, range: TextSpan(start: 0, end: 200)) }
    return RetrievalScope([.readOnly(s)])
}

private func evidencePkg() -> [Evidence] {
    ContextAssembler(budgetTokens: 5_000).assemble([
        Make.evidence("", "复习应当按照逐渐拉长的间隔进行，例如第1天、第3天、第7天。", range: TextSpan(start: 0, end: 30)),
        Make.evidence("", "自测比重读更有效，因为提取会强化记忆。", chapter: 3, range: TextSpan(start: 0, end: 20)),
        Make.evidence("", "我觉得复习很枯燥", kind: .reflection),
    ], allowedSources: ContextSource.allCases).evidence
}

private let goodQuestionJSON = #"""
{"questions":[
 {"type":"comprehension","prompt":"作者建议复习的间隔应当如何安排？","reference_points":["逐渐拉长间隔","第1天、第3天、第7天"],"rubric":"答出逐渐拉长","evidence":["E1"],"knowledge_point":"间隔复习"},
 {"type":"explanation","prompt":"为什么自测比重读更有效？","reference_points":["提取会强化记忆"],"evidence":["E2"]},
 {"type":"comparison","prompt":"你的看法与作者有何不同？","reference_points":["个人看法"],"evidence":["E3"]},
 {"type":"essay","prompt":"写一篇读后感吧，越长越好","reference_points":["x"],"evidence":["E1"]}
]}
"""#

@Suite("M18 出题与校验")
struct QuestionGenerationTests {
    @Test("LEARN-01 合法题目带证据与参考要点；越界证据、非原文证据与未知题型被拒绝")
    func parseAndValidate() throws {
        let r = try QuestionGenerator.parse(goodQuestionJSON, evidence: evidencePkg(), scope: readScope([0]), existing: [], bookID: "b1",
                                            ids: SequentialIDGenerator(), now: noon)
        #expect(r.items.count == 1)
        #expect(r.items[0].evidence.first?.chapterIndex == 0)
        #expect(r.items[0].knowledgePoint == "间隔复习")
        #expect(r.rejections.filter { $0 == "invalid_evidence" }.count == 2)
        #expect(r.rejections.contains("unknown_type:essay"))
    }

    @Test("LEARN-01 作答前的展示视图不包含参考答案与评分依据")
    func presentationHidesAnswers() throws {
        let r = try QuestionGenerator.parse(goodQuestionJSON, evidence: evidencePkg(), scope: readScope([0, 3]), existing: [], bookID: "b1",
                                            ids: SequentialIDGenerator(), now: noon)
        let json = String(decoding: try JSONEncoder().encode(r.items[0].presentation), as: UTF8.self)
        #expect(!json.contains("逐渐拉长间隔"))
        #expect(!json.contains("rubric") && !json.contains("referencePoints"))
        #expect(json.contains("作者建议复习的间隔"))
    }

    @Test("LEARN-01 题干泄露参考答案的题目被拒绝")
    func answerLeakRejected() throws {
        let leak = #"{"questions":[{"type":"comprehension","prompt":"复习应当按照逐渐拉长的间隔进行，对吗？","reference_points":["复习应当按照逐渐拉长的间隔进行"],"evidence":["E1"]}]}"#
        let r = try QuestionGenerator.parse(leak, evidence: evidencePkg(), scope: readScope(), existing: [], bookID: "b1", ids: SequentialIDGenerator(), now: noon)
        #expect(r.items.isEmpty && r.rejections == ["answer_leak"])
        #expect(QuestionGenerator.leaksAnswer(prompt: "什么是间隔复习？", referencePoints: ["逐渐拉长间隔进行复习"]) == false)
    }

    @Test("LEARN-01 与已有题目重复的题被拒绝")
    func duplicateRejected() throws {
        let first = try QuestionGenerator.parse(goodQuestionJSON, evidence: evidencePkg(), scope: readScope(), existing: [], bookID: "b1",
                                                ids: SequentialIDGenerator(), now: noon).items
        let again = try QuestionGenerator.parse(goodQuestionJSON, evidence: evidencePkg(), scope: readScope(), existing: first, bookID: "b1",
                                                ids: SequentialIDGenerator(start: 50), now: noon)
        #expect(again.items.isEmpty)
        #expect(again.rejections.contains("duplicate"))
    }

    @Test("LEARN-01 缺少参考要点或题干过短被拒绝；畸形输出抛错")
    func structuralRejections() throws {
        let bad = #"{"questions":[{"type":"comprehension","prompt":"为什么？","reference_points":["x"],"evidence":["E1"]},{"type":"comprehension","prompt":"作者如何看待复习的间隔？","reference_points":[" "],"evidence":["E1"]}]}"#
        let r = try QuestionGenerator.parse(bad, evidence: evidencePkg(), scope: readScope(), existing: [], bookID: "b1", ids: SequentialIDGenerator(), now: noon)
        #expect(r.rejections == ["prompt_too_short", "missing_reference_points"])
        #expect(throws: ProviderError.self) {
            try QuestionGenerator.parse("不是 JSON", evidence: [], scope: readScope(), existing: [], bookID: "b1", ids: SequentialIDGenerator(), now: noon)
        }
    }

    @Test("LEARN-01 出题提示词只包含书内证据并列出已有题目")
    func generationPrompt() {
        let msgs = QuestionGenerator.messages(evidence: evidencePkg().filter { $0.kind.isBookEvidence }, count: 2, existingPrompts: ["旧题"])
        #expect(msgs[1].content.contains("[E1]") && msgs[1].content.contains("请出 2 道题") && msgs[1].content.contains("- 旧题"))
        #expect(!msgs[1].content.contains("我觉得复习很枯燥"))
    }
}

@Suite("M18 作答与反馈")
struct LearningServiceTests {
    func setup() throws -> (LearningService, SQLiteLearningRepository, ManualClock) {
        let repo = SQLiteLearningRepository(try AppDatabase.inMemory())
        let clock = ManualClock(noon)
        return (LearningService(repository: repo, clock: clock, ids: SequentialIDGenerator()), repo, clock)
    }

    func executor(_ clock: ManualClock) -> BoundedExecutor {
        BoundedExecutor(budget: TaskBudget(limits: .learning, clock: clock), clock: clock, sleeper: ImmediateSleeper(), traceID: "t")
    }

    func addItem(_ svc: LearningService, _ clock: ManualClock) async throws -> LearningItem {
        let model = ScriptedChatModel()
        model.enqueue("quiz_generation", .text(goodQuestionJSON))
        return try await svc.generate(bookID: "b1", evidence: evidencePkg(), scope: readScope(), count: 1, model: model,
                                      executor: executor(clock), timeZone: utc).items[0]
    }

    @Test("LEARN-01 生成的题目与初始排期一起保存")
    func generateSaves() async throws {
        let (svc, repo, clock) = try setup()
        let item = try await addItem(svc, clock)
        #expect(try await repo.item(id: item.id) != nil)
        #expect(try await repo.schedule(itemID: item.id)?.step == 0)
    }

    @Test("10.2 输出被截断时不保存不完整的题目")
    func truncatedNotSaved() async throws {
        let (svc, repo, clock) = try setup()
        let model = ScriptedChatModel()
        model.enqueue("quiz_generation", .text(goodQuestionJSON, .length))
        await #expect(throws: LearningError.generationFailed("输出被截断")) {
            try await svc.generate(bookID: "b1", evidence: evidencePkg(), scope: readScope(), count: 1, model: model, executor: executor(clock), timeZone: utc)
        }
        #expect(try await repo.items(bookID: nil).isEmpty)
    }

    @Test("LEARN-01 没有已读原文证据时不出题")
    func noEvidence() async throws {
        let (svc, _, clock) = try setup()
        await #expect(throws: LearningError.noReadContent) {
            try await svc.generate(bookID: "b1", evidence: evidencePkg().filter { !$0.kind.isBookEvidence }, scope: readScope(), count: 1,
                                   model: ScriptedChatModel(), executor: executor(clock), timeZone: utc)
        }
    }

    @Test("LEARN-02 保存原始答案；反馈包含正确点、遗漏点与证据")
    func submitFeedback() async throws {
        let (svc, repo, clock) = try setup()
        let item = try await addItem(svc, clock)
        let (attempt, feedback, schedule) = try await svc.submit(itemID: item.id, answer: "  要逐渐拉长间隔复习  ", selfRating: .good,
                                                                 idempotencyKey: "k1", grader: HeuristicAnswerGrader(), timeZone: utc)
        #expect(attempt.answer == "  要逐渐拉长间隔复习  ")
        #expect(feedback.correctPoints == ["逐渐拉长间隔"])
        #expect(feedback.missingPoints == ["第1天、第3天、第7天"])
        #expect(feedback.evidence == item.evidence)
        #expect(schedule.history.count == 1)
        #expect(try await repo.feedback(attemptID: attempt.id) == feedback)
    }

    @Test("LEARN-05 重复提交同一答案不产生重复作答与复习记录")
    func submitIdempotent() async throws {
        let (svc, repo, clock) = try setup()
        let item = try await addItem(svc, clock)
        let a = try await svc.submit(itemID: item.id, answer: "逐渐拉长", selfRating: nil, idempotencyKey: "k", grader: HeuristicAnswerGrader(), timeZone: utc)
        let b = try await svc.submit(itemID: item.id, answer: "逐渐拉长", selfRating: nil, idempotencyKey: "k", grader: HeuristicAnswerGrader(), timeZone: utc)
        #expect(a.0.id == b.0.id)
        #expect(try await repo.attempts(itemID: item.id).count == 1)
        #expect(try await repo.schedule(itemID: item.id)?.history.count == 1)
        #expect(try await repo.mastery(knowledgePoint: item.knowledgePoint, bookID: "b1")?.attempts == 1)
    }

    @Test("LEARN-02 依据不足时不作确定评分")
    func uncertainGrading() async throws {
        let (svc, _, clock) = try setup()
        let item = try await addItem(svc, clock)
        struct Unsure: AnswerGrading {
            let name = "unsure"
            func grade(item: LearningItem, answer: String) async throws -> (correct: [String], missing: [String], grade: Grade, rationale: String) {
                ([], [], .uncertain("证据不足以判断"), "证据不足以判断")
            }
        }
        let (_, fb, sched) = try await svc.submit(itemID: item.id, answer: "某个答案", selfRating: nil, idempotencyKey: "u", grader: Unsure(), timeZone: utc)
        #expect(fb.grade == .uncertain("证据不足以判断"))
        #expect(sched.step == 0)
    }

    @Test("LEARN-02 空答案不调用评分器，记为 0 分且列出全部遗漏点")
    func emptyAnswer() async throws {
        let (svc, _, clock) = try setup()
        let item = try await addItem(svc, clock)
        let (_, fb, _) = try await svc.submit(itemID: item.id, answer: "   ", selfRating: nil, idempotencyKey: "e", grader: HeuristicAnswerGrader(), timeZone: utc)
        #expect(fb.grade == .scored(0) && fb.missingPoints == item.referencePoints && fb.graderName == "rule")
    }

    @Test("DATA-01 评分失败时不写入作答、掌握或排期（事务完整）")
    func graderFailureWritesNothing() async throws {
        let (svc, repo, clock) = try setup()
        let item = try await addItem(svc, clock)
        struct Failing: AnswerGrading {
            let name = "fail"
            func grade(item: LearningItem, answer: String) async throws -> (correct: [String], missing: [String], grade: Grade, rationale: String) {
                throw ProviderError.offline
            }
        }
        await #expect(throws: ProviderError.offline) {
            try await svc.submit(itemID: item.id, answer: "答案", selfRating: nil, idempotencyKey: "f", grader: Failing(), timeZone: utc)
        }
        #expect(try await repo.attempts(itemID: item.id).isEmpty)
        #expect(try await repo.schedule(itemID: item.id)?.history.isEmpty == true)
        #expect(try await repo.mastery(knowledgePoint: item.knowledgePoint, bookID: "b1") == nil)
    }

    @Test("LEARN-03 人工修正掌握等级")
    func manualCorrection() async throws {
        let (svc, repo, _) = try setup()
        let r = try await svc.correctMastery(knowledgePoint: "间隔复习", bookID: "b1", level: .mastered, note: "我确定掌握了")
        #expect(r.level == .mastered)
        #expect(try await repo.mastery(knowledgePoint: "间隔复习", bookID: "b1")?.manualNote == "我确定掌握了")
    }

    @Test("LEARN-05 时间推进后题目出现在到期列表，完成后移出")
    func dueFlow() async throws {
        let (svc, _, clock) = try setup()
        let item = try await addItem(svc, clock)
        #expect(try await svc.dueItems(timeZone: utc).isEmpty)
        clock.advance(by: 86_400)
        let due = try await svc.dueItems(timeZone: utc)
        #expect(due.map(\.0.id) == [item.id])
        _ = try await svc.submit(itemID: item.id, answer: "逐渐拉长间隔，第1天、第3天、第7天", selfRating: .good, idempotencyKey: "d",
                                 grader: HeuristicAnswerGrader(), timeZone: utc)
        #expect(try await svc.dueItems(timeZone: utc).isEmpty)
    }

    @Test("LEARN-02 模型评分解析：分数裁剪到 0–1，缺分或 uncertain 视为不确定")
    func llmGradeParse() throws {
        #expect(try LLMAnswerGrader.parse(#"{"correct_points":["a"],"missing_points":[],"score":1.7,"rationale":"r"}"#).grade == .scored(1))
        #expect(try LLMAnswerGrader.parse(#"{"score":null,"rationale":"不确定"}"#).grade == .uncertain("不确定"))
        if case .uncertain = try LLMAnswerGrader.parse(#"{"score":0.8,"uncertain":true}"#).grade {} else { Issue.record("应为不确定") }
        #expect(throws: ProviderError.self) { try LLMAnswerGrader.parse("oops") }
    }

    @Test("LEARN-02 模型评分提示词包含参考要点、证据与答案")
    func llmGradePrompt() {
        let item = LearningItem(id: "q", bookID: "b", type: .comprehension, prompt: "题目", referencePoints: ["要点一"], rubric: "依据",
                                evidence: [LearningEvidence(bookID: "b", bookVersion: "v", chapterIndex: 0, range: TextSpan(start: 0, end: 2), quote: "原文")],
                                knowledgePoint: "k", createdAt: noon)
        let user = LLMAnswerGrader.messages(item: item, answer: "我的答案")[1].content
        #expect(user.contains("要点一") && user.contains("原文") && user.contains("我的答案"))
    }
}
