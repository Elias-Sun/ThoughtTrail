import Testing
import Foundation
@testable import EvidenceVerificationCore
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import ContextEngineering
import AgentRuntime
import TestSupport

private func pkg(_ items: [Evidence]) -> ContextPackage {
    ContextAssembler(budgetTokens: 10_000).assemble(items, allowedSources: ContextRouting.ContextSource.allCases)
}

import ContextRouting

/// 固定裁判：按陈述 ID 返回预设结论。
struct FixedJudge: ClaimJudge {
    let name = "fixed"
    let verdicts: [String: Verdict]
    var error: Error?
    func judge(_ inputs: [ClaimJudgeInput]) async throws -> [ClaimJudgement] {
        if let error { throw error }
        return inputs.compactMap { i in verdicts[i.claimID].map { ClaimJudgement(claimID: i.claimID, verdict: $0, reason: "fixed") } }
    }
}

@Suite("M17 陈述拆分")
struct ClaimExtractionTests {
    @Test("EVID-02 按句拆分并提取每句引用")
    func splitsSentences() {
        let claims = ClaimExtractor.extract("作者认为复习要按间隔进行[E1]。自测比重读更有效[E2, E3]。")
        #expect(claims.count == 2)
        #expect(claims[0].labels == ["E1"] && claims[1].labels == ["E2", "E3"])
        #expect(claims[0].text == "作者认为复习要按间隔进行。")
        #expect(claims[0].assertsBookContent)
    }

    @Test("CHAT-03 【一般知识】句不要求书内引用")
    func generalKnowledge() {
        let claims = ClaimExtractor.extract("【一般知识】艾宾浩斯在 1885 年发表了遗忘研究。")
        #expect(claims.count == 1 && claims[0].isGeneralKnowledge && !claims[0].requiresVerification)
    }

    @Test("EVID-02 说明限制的元陈述与反问不作为事实核查对象")
    func metaStatements() {
        let claims = ClaimExtractor.extract("在已读范围内没有找到足够依据。你想继续读下去吗？")
        #expect(claims.allSatisfy { $0.isMeta })
    }

    @Test("EVID-02 列表符号与标题符号被去除，过短片段忽略")
    func listMarkers() {
        let claims = ClaimExtractor.extract("- 第一点：批注促进思考[E1]。\n## 好\n1. 第二点：精读奠基[E2]。")
        #expect(claims.map(\.labels) == [["E1"], ["E2"]])
        #expect(claims[0].text.hasPrefix("第一点"))
    }

    @Test("EVID-02 句末标点之后的引用（……。[E1]）归入前一条陈述")
    func trailingCitationAfterPunctuation() {
        let claims = ClaimExtractor.extract("第一章 读书的方法。[E1] 精读用于奠基之作。[E2, E3]")
        #expect(claims.map(\.labels) == [["E1"], ["E2", "E3"]])
        #expect(claims.allSatisfy { !$0.isMeta })
    }

    @Test("EVID-02 英文回答同样拆分")
    func english() {
        let claims = ClaimExtractor.extract("The author says the storm damaged three bridges [E1]. The fishermen stayed home [E2].")
        #expect(claims.count == 2 && claims[0].assertsBookContent)
    }
}

@Suite("M17 结构检查")
struct StructuralTests {
    var scope: RetrievalScope {
        var s = BookReadState(bookID: "b1", bookVersion: "fp1")
        s.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100))
        return RetrievalScope([.readOnly(s)])
    }

    @Test("EVID-01 未知标签判为无效")
    func unknownLabel() async {
        let checks = await StructuralChecker(scope: scope).check(labels: ["E5"], package: pkg([]))
        #expect(checks["E5"]?.issue == .unknownLabel)
    }

    @Test("EVID-01 超出阅读范围的原文证据判为无效")
    func outOfScope() async {
        let p = pkg([Make.evidence("", "未读内容", range: TextSpan(start: 150, end: 160))])
        #expect(await StructuralChecker(scope: scope).check(labels: ["E1"], package: p)["E1"]?.issue == .outOfScope)
    }

    @Test("EVID-01 书籍版本不符或书籍不在范围内判为无效")
    func versionAndBook() async {
        let p = pkg([Make.evidence("", "旧版本内容", version: "old", range: TextSpan(start: 0, end: 5)),
                     Make.evidence("", "别的书", bookID: "b9", range: TextSpan(start: 0, end: 5))])
        let checks = await StructuralChecker(scope: scope).check(labels: ["E1", "E2"], package: p)
        #expect(checks["E1"]?.issue == .versionMismatch)
        #expect(checks["E2"]?.issue == .bookMismatch)
    }

    @Test("EVID-01 缺少定位信息的原文证据判为无效")
    func missingLocator() async {
        var e = Make.evidence("", "没有定位")
        e.range = nil
        #expect(await StructuralChecker(scope: scope).check(labels: ["E1"], package: pkg([e]))["E1"]?.issue == .invalidLocator)
    }

    @Test("EVID-01 外部校验发现来源已删除")
    func deletedSource() async {
        struct Deleted: EvidenceSourceValidating { func issue(for evidence: Evidence) async -> StructuralIssue? { .sourceDeleted } }
        let p = pkg([Make.evidence("", "内容", range: TextSpan(start: 0, end: 5))])
        #expect(await StructuralChecker(scope: scope, validator: Deleted()).check(labels: ["E1"], package: p)["E1"]?.issue == .sourceDeleted)
    }

    @Test("EVID-01 范围内的有效原文与个人反思通过结构检查")
    func validEvidence() async {
        let p = pkg([Make.evidence("", "范围内", range: TextSpan(start: 0, end: 5)), Make.evidence("", "反思", kind: .reflection)])
        let checks = await StructuralChecker(scope: scope).check(labels: ["E1", "E2"], package: p)
        #expect(checks.values.allSatisfy { $0.isValid })
    }
}

@Suite("M17 语义复核")
struct VerifierTests {
    let scope = Make.wholeScope()
    let evidence = pkg([Make.evidence("", "复习应当按照第1天、第3天、第7天的间隔进行。"), Make.evidence("", "我觉得复习很枯燥。", kind: .reflection)])

    @Test("EVID-02 全部陈述获支持时总体为通过")
    func passes() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .supported]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习按第1、3、7天的间隔进行[E1]。", package: evidence)
        #expect(r.overall == .passed)
        #expect(r.count(.supported) == 1)
    }

    @Test("EVID-02 存在矛盾或证据不足时总体为需处理，并给出理由")
    func issues() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .supported, "C2": .contradicted]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习按间隔进行[E1]。复习间隔是第2天[E1]。", package: evidence)
        #expect(r.overall == .issuesFound)
        #expect(r.flaggedClaims.map(\.claim.id) == ["C2"])
        #expect(r.flaggedClaims[0].reason == "fixed")
    }

    @Test("EVID-02 没有引用的事实陈述判为证据不足（不调用裁判）")
    func uncitedClaim() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: [:]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "书中说复习一年一次就够了。", package: evidence)
        #expect(r.claims[0].verdict == .insufficient)
        #expect(r.claims[0].reason.contains("没有引用"))
    }

    @Test("EVID-01 引用了无效证据的陈述不能显示为已核查")
    func invalidCitation() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .supported]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习按间隔进行[E7]。", package: evidence)
        #expect(r.claims[0].verdict == .insufficient)
        #expect(r.claims[0].invalidLabels == ["E7"])
        #expect(r.invalidLabels == ["E7"])
        #expect(r.overall == .issuesFound)
    }

    @Test("5.6 只引用个人反思却断言书中内容：判为证据不足")
    func personalEvidenceCannotProveBook() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .supported]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "作者认为复习很枯燥[E2]。", package: evidence)
        #expect(r.claims[0].verdict == .insufficient)
    }

    @Test("5.6 个人看法引用反思可以获支持（不涉及书中内容）")
    func personalViewSupported() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .supported]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "你此前觉得复习很枯燥[E2]。", package: evidence)
        #expect(r.overall == .passed)
    }

    @Test("EVID-04 复核超时/失败不能显示为通过")
    func judgeFailure() async {
        var j = FixedJudge(verdicts: [:]); j.error = ProviderError.timeout
        let v = EvidenceVerifier(judge: j, checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习按间隔进行[E1]。", package: evidence)
        #expect(r.overall == .unavailable)
        #expect(r.failureReason == "timeout")
        #expect(r.claims[0].verdict == .unknown)
    }

    @Test("EVID-04 未配置复核器时报告不可用")
    func noJudge() async {
        let r = await EvidenceVerifier(judge: nil, checker: StructuralChecker(scope: scope)).verify(answer: "复习按间隔进行[E1]。", package: evidence)
        #expect(r.overall == .unavailable)
    }

    @Test("EVID-04 裁判漏掉某条陈述时记为无法判断")
    func missingJudgement() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .supported]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习按间隔进行[E1]。自测更有效[E1]。", package: evidence)
        #expect(r.claims[1].verdict == .unknown)
        #expect(r.overall == .issuesFound)
    }

    @Test("EVID-02 只有一般知识与说明时总体为“无事实陈述”")
    func noFactualClaims() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: [:]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "【一般知识】间隔重复是常见学习方法。在已读范围内没有找到更多依据。", package: evidence)
        #expect(r.overall == .noFactualClaims)
    }

    @Test("EVID-03 修正策略：剩余预算≥2 且存在问题时至多修正一轮")
    func correctionPolicy() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .contradicted]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习间隔是第2天[E1]。", package: evidence)
        #expect(CorrectionPolicy.shouldRevise(r, roundsUsed: 0, remainingCalls: 2))
        #expect(!CorrectionPolicy.shouldRevise(r, roundsUsed: 1, remainingCalls: 5))
        #expect(!CorrectionPolicy.shouldRevise(r, roundsUsed: 0, remainingCalls: 1))
        let msgs = CorrectionPolicy.revisionMessages(answer: "复习间隔是第2天[E1]。", report: r, package: evidence, question: "间隔？")
        #expect(msgs.last!.content.contains("contradicted"))
    }

    @Test("EVID-03 只有“无法判断”时不触发修正")
    func noCorrectionForUnknownOnly() async {
        let v = EvidenceVerifier(judge: FixedJudge(verdicts: ["C1": .unknown]), checker: StructuralChecker(scope: scope))
        let r = await v.verify(answer: "复习按间隔进行[E1]。", package: evidence)
        #expect(!CorrectionPolicy.shouldRevise(r, roundsUsed: 0, remainingCalls: 6))
    }
}

@Suite("M17 裁判实现")
struct JudgeTests {
    let judge = HeuristicClaimJudge()
    func input(_ claim: String, _ evidence: String) -> ClaimJudgeInput {
        ClaimJudgeInput(claimID: "C1", claim: claim, evidence: [.init(label: "E1", kind: .bookText, text: evidence)])
    }

    @Test("EVID-02 启发式：高覆盖判为支持")
    func supported() {
        #expect(judge.judgeOne(input("风暴毁坏了三座桥", "十月的风暴毁坏了三座桥。")).verdict == .supported)
    }

    @Test("EVID-02 启发式：数字不一致判为矛盾")
    func numberContradiction() {
        let j = judge.judgeOne(input("渔民 15 天没有出海", "渔民 12 天没有出海。"))
        #expect(j.verdict == .contradicted)
        #expect(j.reason.contains("15"))
    }

    @Test("EVID-02 数字抽取统一阿拉伯数字、中文数字与英文数字词")
    func numberExtraction() {
        #expect(NumberExtractor.numbers(in: "港口一连四十天被浓雾笼罩").contains("40"))
        #expect(NumberExtractor.numbers(in: "二十三名学生，三百本书，一六一〇年") == ["23", "300", "1610"])
        #expect(NumberExtractor.numbers(in: "with forty camels and twelve drivers") == ["40", "12"])
        #expect(NumberExtractor.numbers(in: "up to two thousand eggs, thirty-five degrees") == ["2000", "35"])
        #expect(NumberExtractor.numbers(in: "一些人一起读书") == [])
        #expect(NumberExtractor.numbers(in: "第二章 记忆与复习；Chapter 3. The Return") == [])
    }

    @Test("EVID-02 启发式：中文数字改写判为矛盾")
    func chineseNumberContradiction() {
        #expect(judge.judgeOne(input("港口一连二十天被浓雾笼罩", "每到冬季，港口一连四十天被浓雾笼罩。")).verdict == .contradicted)
    }

    @Test("EVID-02 启发式：否定极性相反判为矛盾")
    func negationContradiction() {
        #expect(judge.judgeOne(input("自测比重读更有效", "自测并不比重读更有效。")).verdict == .contradicted)
        #expect(judge.judgeOne(input("The keeper did not light the lamp", "The keeper lit the lamp every evening.")).verdict != .supported)
    }

    @Test("EVID-02 启发式：低覆盖判为证据不足")
    func insufficient() {
        #expect(judge.judgeOne(input("灯塔管理员是船长", "复习应当按照间隔进行。")).verdict == .insufficient)
    }

    @Test("EVID-02 启发式：证据未提及陈述中的数字判为证据不足")
    func missingNumber() {
        #expect(judge.judgeOne(input("复习间隔共有 5 档", "复习应当按照逐渐拉长的间隔进行，间隔共有若干档。")).verdict == .insufficient)
    }

    @Test("EVID-02 模型裁判：解析 JSON 并忽略未请求的陈述 ID")
    func llmParse() throws {
        let inputs = [input("a", "b")]
        let out = try LLMClaimJudge.parse(#"{"results":[{"claim_id":"C1","verdict":"Contradicted","reason":"数字不符"},{"claim_id":"C9","verdict":"supported"}]}"#, expected: inputs)
        #expect(out == [ClaimJudgement(claimID: "C1", verdict: .contradicted, reason: "数字不符")])
        let unknownVerdict = try LLMClaimJudge.parse(#"{"results":[{"claim_id":"C1","verdict":"maybe"}]}"#, expected: inputs)
        #expect(unknownVerdict.first?.verdict == .unknown)
    }

    @Test("EVID-04 模型裁判：解析失败与空响应抛错，并计入预算")
    func llmFailures() async throws {
        let model = ScriptedChatModel()
        model.enqueue("verification", .text("不是 JSON"), .text("   "))
        let budget = TaskBudget(limits: .discussion, clock: ManualClock())
        let j = LLMClaimJudge(model: model, executor: BoundedExecutor(budget: budget, clock: ManualClock(), sleeper: ImmediateSleeper(), traceID: "t"))
        await #expect(throws: ProviderError.self) { try await j.judge([input("a", "b")]) }
        await #expect(throws: ProviderError.emptyResponse) { try await j.judge([input("a", "b")]) }
        #expect(await budget.snapshot().callsByStage["verification"] == 2)
    }

    @Test("EVID-02 模型裁判提示词把陈述与证据放在数据块中")
    func llmPrompt() {
        let msgs = LLMClaimJudge.messages(for: [input("陈述", "证据")])
        #expect(msgs[1].content.contains("<data>") && msgs[1].content.contains("陈述 C1：陈述") && msgs[1].content.contains("[E1] (原文) 证据"))
        #expect(msgs[0].content.contains("contradicted"))
    }
}
