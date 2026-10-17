import Testing
import Foundation
@testable import LearningCore
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import ContextEngineering
import ContextRouting
import Persistence
import TestSupport

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_773_144_000)

@Suite("M18 边界情况")
struct LearningEdgeTests {
    @Test("LEARN-04 间隔规则可配置且文档化")
    func customIntervals() {
        let s = ReviewScheduler(intervals: [2, 5])
        var sched = s.initial(itemID: "q", createdAt: t0, timeZone: utc)
        #expect(DayKey(date: t0, timeZone: utc).days(to: sched.dueDay) == 2)
        sched = s.apply(.advance, to: sched, at: t0, timeZone: utc, attemptKey: "a")
        sched = s.apply(.advance, to: sched, at: t0, timeZone: utc, attemptKey: "b")
        #expect(sched.step == 1 && DayKey(date: t0, timeZone: utc).days(to: sched.dueDay) == 5)
    }

    @Test("LEARN-05 用户更换时区后按新时区计算下一次到期日")
    func timezoneChange() {
        let s = ReviewScheduler()
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let lateUTC = Date(timeIntervalSince1970: 1_773_183_600) // 2026-03-10 23:00 UTC = 3/11 08:00 东京
        let sched = s.apply(.hold, to: s.initial(itemID: "q", createdAt: t0, timeZone: utc), at: lateUTC, timeZone: tokyo, attemptKey: "k")
        #expect(sched.timeZoneID == "Asia/Tokyo")
        #expect(sched.dueDay == DayKey(year: 2026, month: 3, day: 12))
    }

    @Test("LEARN-01 一题多证据中任一越界则整题拒绝")
    func partialInvalidEvidence() throws {
        var state = BookReadState(bookID: "b1", bookVersion: "fp1")
        state.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100))
        let ev = ContextAssembler(budgetTokens: 1_000).assemble([
            Make.evidence("", "已读证据", range: TextSpan(start: 0, end: 10)),
            Make.evidence("", "未读证据", chapter: 4, range: TextSpan(start: 0, end: 10)),
        ], allowedSources: ContextSource.allCases).evidence
        let json = #"{"questions":[{"type":"comparison","prompt":"比较这两段的观点有何不同？","reference_points":["观点不同"],"evidence":["E1","E2"]}]}"#
        let r = try QuestionGenerator.parse(json, evidence: ev, scope: RetrievalScope([.readOnly(state)]), existing: [], bookID: "b1",
                                            ids: SequentialIDGenerator(), now: t0)
        #expect(r.items.isEmpty && r.rejections == ["invalid_evidence"])
    }

    @Test("LEARN-01 同一批次内重复的题目只保留一题")
    func dedupeWithinBatch() throws {
        let ev = ContextAssembler(budgetTokens: 1_000).assemble([Make.evidence("", "证据")], allowedSources: ContextSource.allCases).evidence
        let json = #"{"questions":[{"type":"comprehension","prompt":"作者如何看待复习？","reference_points":["按间隔"],"evidence":["E1"]},{"type":"comprehension","prompt":"作者如何看待复习?","reference_points":["按间隔"],"evidence":["E1"]}]}"#
        let r = try QuestionGenerator.parse(json, evidence: ev, scope: Make.wholeScope(), existing: [], bookID: "b1", ids: SequentialIDGenerator(), now: t0)
        #expect(r.items.count == 1 && r.rejections == ["duplicate"])
    }

    @Test("LEARN-01 展示视图的章节列表去重排序；去重键稳定")
    func presentationAndKey() {
        let ev = [3, 1, 3].map { LearningEvidence(bookID: "b", bookVersion: "v", chapterIndex: $0, range: TextSpan(start: 0, end: 1), quote: "") }
        let item = LearningItem(id: "q", bookID: "b", type: .explanation, prompt: "为什么？请解释", referencePoints: ["r"], rubric: "",
                                evidence: ev, knowledgePoint: "k", createdAt: t0)
        #expect(item.presentation.chapterIndices == [1, 3])
        var same = item; same.id = "other"; same.prompt = "为什么?请解释"
        #expect(item.dedupeKey == same.dedupeKey)
    }

    @Test("LEARN-05 已停用的题目不出现在到期列表")
    func retiredExcluded() async throws {
        let repo = SQLiteLearningRepository(try AppDatabase.inMemory())
        let clock = ManualClock(t0)
        let svc = LearningService(repository: repo, clock: clock, ids: SequentialIDGenerator())
        var item = LearningItem(id: "q", bookID: "b", type: .comprehension, prompt: "题目内容", referencePoints: ["r"], rubric: "",
                                evidence: [], knowledgePoint: "k", createdAt: t0)
        try await svc.addItem(item, timeZone: utc)
        item.status = .retired
        try await repo.save(item)
        clock.advance(by: 3 * 86_400)
        #expect(try await svc.dueItems(timeZone: utc).isEmpty)
    }

    @Test("LEARN-02 没有证据的题目不作确定评分")
    func itemWithoutEvidence() async throws {
        let repo = SQLiteLearningRepository(try AppDatabase.inMemory())
        let svc = LearningService(repository: repo, clock: ManualClock(t0), ids: SequentialIDGenerator())
        try await svc.addItem(LearningItem(id: "q", bookID: "b", type: .comprehension, prompt: "题目内容", referencePoints: ["r"], rubric: "",
                                           evidence: [], knowledgePoint: "k", createdAt: t0), timeZone: utc)
        let (_, fb, _) = try await svc.submit(itemID: "q", answer: "回答", selfRating: nil, idempotencyKey: "x", grader: HeuristicAnswerGrader(), timeZone: utc)
        if case .uncertain = fb.grade {} else { Issue.record("应为不确定") }
    }

    @Test("LEARN-03 掌握记录按书籍与知识点分开")
    func masteryPerBook() async throws {
        let repo = SQLiteLearningRepository(try AppDatabase.inMemory())
        let svc = LearningService(repository: repo, clock: ManualClock(t0), ids: SequentialIDGenerator())
        _ = try await svc.correctMastery(knowledgePoint: "k", bookID: "a", level: .mastered, note: nil)
        _ = try await svc.correctMastery(knowledgePoint: "k", bookID: "b", level: .learning, note: nil)
        #expect(try await repo.masteryRecords(bookID: "a").first?.level == .mastered)
        #expect(try await repo.masteryRecords(bookID: nil).count == 2)
    }

    @Test("LEARN-03 自评与等级有中文展示名")
    func displayNames() {
        #expect(SelfRating.allCases.map(\.displayName).count == 4)
        #expect(MasteryLevel.allCases.sorted() == [.new, .learning, .familiar, .mastered])
        #expect(QuestionType.allCases.map(\.displayName) == ["理解", "解释", "观点比较"])
    }

    @Test("LEARN-05 作答不存在的题目报错，不产生记录")
    func unknownItem() async throws {
        let repo = SQLiteLearningRepository(try AppDatabase.inMemory())
        let svc = LearningService(repository: repo, clock: ManualClock(t0), ids: SequentialIDGenerator())
        await #expect(throws: LearningError.itemNotFound) {
            try await svc.submit(itemID: "missing", answer: "a", selfRating: nil, idempotencyKey: "k", grader: HeuristicAnswerGrader(), timeZone: utc)
        }
        #expect(try await repo.attempt(idempotencyKey: "k") == nil)
    }
}
