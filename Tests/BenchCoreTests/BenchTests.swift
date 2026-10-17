import Testing
import Foundation
@testable import BenchCore
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import EvidenceVerificationCore
import LearningCore
import TestSupport

private let rel = [RelevantSpan(bookID: "b", chapterIndex: 0, start: 0, end: 100, grade: 3),
                   RelevantSpan(bookID: "b", chapterIndex: 1, start: 50, end: 80, grade: 1)]

private func ctx(_ sha: String = "sha") -> BenchContext {
    BenchContext(datasetName: "dev", datasetVersion: "1", datasetSHA256: sha, annotationStatus: .draftUnreviewed,
                 configuration: ["k": "v"], runID: "r1", now: Date(timeIntervalSince1970: 0))
}

@Suite("M16 指标")
struct MetricTests {
    @Test("9.2 Recall@K 按标注相关证据总数计算，不是命中任意一条")
    func recallDenominator() {
        let retrieved = [RetrievedSpan(bookID: "b", chapterIndex: 0, start: 10, end: 90)]
        #expect(RetrievalMetrics.recall(at: 5, retrieved: retrieved, relevant: rel) == 0.5)
        let both = retrieved + [RetrievedSpan(bookID: "b", chapterIndex: 1, start: 55, end: 75)]
        #expect(RetrievalMetrics.recall(at: 5, retrieved: both, relevant: rel) == 1)
        #expect(RetrievalMetrics.recall(at: 1, retrieved: both, relevant: rel) == 0.5)
    }

    @Test("9.2 命中需同书同章且重叠足够")
    func matchingRule() {
        #expect(!RetrievalMetrics.matches(RetrievedSpan(bookID: "b", chapterIndex: 0, start: 95, end: 200), rel[0]))
        #expect(!RetrievalMetrics.matches(RetrievedSpan(bookID: "x", chapterIndex: 0, start: 0, end: 100), rel[0]))
        #expect(RetrievalMetrics.matches(RetrievedSpan(bookID: "b", chapterIndex: 0, start: 40, end: 60), rel[0]))
    }

    @Test("9.2 nDCG@K：理想排序为 1，高等级证据靠后时降低")
    func ndcg() {
        let ideal = [RetrievedSpan(bookID: "b", chapterIndex: 0, start: 0, end: 100), RetrievedSpan(bookID: "b", chapterIndex: 1, start: 50, end: 80)]
        #expect(abs(RetrievalMetrics.ndcg(at: 5, retrieved: ideal, relevant: rel) - 1) < 1e-9)
        let swapped = Array(ideal.reversed())
        #expect(RetrievalMetrics.ndcg(at: 5, retrieved: swapped, relevant: rel) < 1)
        #expect(RetrievalMetrics.ndcg(at: 5, retrieved: [], relevant: rel) == 0)
    }

    @Test("9.2 nDCG 中同一相关证据只计一次")
    func ndcgNoDoubleCount() {
        let dup = [RetrievedSpan(bookID: "b", chapterIndex: 0, start: 0, end: 50), RetrievedSpan(bookID: "b", chapterIndex: 0, start: 40, end: 100)]
        let single = [RelevantSpan(bookID: "b", chapterIndex: 0, start: 0, end: 100, grade: 2)]
        #expect(RetrievalMetrics.ndcg(at: 5, retrieved: dup, relevant: single) <= 1)
    }

    @Test("9.2 问题类别 Precision/Recall：无法判断的正类计入未检出")
    func binaryMetrics() {
        var m = ConfusionMatrix(labels: Verdict.allCases.map(\.rawValue))
        m.add(gold: "contradicted", predicted: "contradicted")
        m.add(gold: "insufficient", predicted: "unknown")
        m.add(gold: "supported", predicted: "insufficient")
        m.add(gold: "supported", predicted: "supported")
        let pr = m.binary(positive: ["contradicted", "insufficient"])
        #expect(pr.precision.value == 0.5 && pr.precision.denominator == 2)
        #expect(pr.recall.value == 0.5 && pr.recall.denominator == 2)
        #expect(m.accuracy().value == 0.5 && m.total == 4)
    }

    @Test("9.2 指标同时给出分子与分母；空样本不除零")
    func metricValue() {
        #expect(MetricValue(numerator: 3, denominator: 4).value == 0.75)
        #expect(MetricValue(numerator: 0, denominator: 0).value == 0)
        #expect(MetricValue(mean: [1, 0, 0.5]).denominator == 3)
    }
}

@Suite("M16 数据集与结果")
struct DatasetAndRunTests {
    @Test("9.1 JSONL 载入：坏行记录行号，不静默丢弃")
    func jsonlLoading() {
        let text = """
        {"id":"v1","claim":"甲","evidence":["乙"],"label":"supported"}
        // 注释行
        {"id":"v2","claim":
        {"id":"v3","claim":"丙","evidence":[],"label":"insufficient","perturbation":"number"}
        """
        let r = DatasetLoader.loadJSONL(VerificationCase.self, data: Data(text.utf8))
        #expect(r.items.map(\.id) == ["v1", "v3"])
        #expect(r.errors.map(\.line) == [3])
    }

    @Test("9.1 验收集冻结：哈希变化则拒绝评测；开发集可不冻结")
    func frozenCheck() {
        let acc = DatasetManifest(name: "a", version: "1", split: .acceptance, annotationStatus: .humanReviewed, description: "", frozenSHA256: "abc")
        #expect(DatasetLoader.verifyFrozen(acc, actualSHA256: "abc"))
        #expect(!DatasetLoader.verifyFrozen(acc, actualSHA256: "changed"))
        var unfrozen = acc; unfrozen.frozenSHA256 = nil
        #expect(!DatasetLoader.verifyFrozen(unfrozen, actualSHA256: "x"))
        let dev = DatasetManifest(name: "d", version: "1", split: .dev, annotationStatus: .draftUnreviewed, description: "")
        #expect(DatasetLoader.verifyFrozen(dev, actualSHA256: "x"))
    }

    @Test("9.2 结果保存、读取与比较；数据版本不同拒绝比较")
    func runStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BenchRunStore(directory: dir)
        let base = ctx().result(suite: "retrieval", samples: 2, metrics: ["recall@10": MetricValue(numerator: 1, denominator: 2)], failures: [])
        var cand = base; cand.runID = "r2"; cand.metrics["recall@10"] = MetricValue(numerator: 2, denominator: 2)
        _ = try store.save(base); _ = try store.save(cand)
        #expect(try store.all(suite: "retrieval").count == 2)
        let deltas = try BenchRunStore.compare(baseline: base, candidate: cand)
        #expect(deltas.first?.delta == 0.5)
        var other = cand; other.datasetSHA256 = "different"
        #expect(throws: BenchCompareError.self) { try BenchRunStore.compare(baseline: base, candidate: other) }
    }

    @Test("9.2 重复运行保存为不同记录；配置哈希可复现")
    func repeatedRuns() throws {
        let a = ctx().result(suite: "s", samples: 1, metrics: [:], failures: [])
        var b = a; b.runID = "r9"
        #expect(a.configurationHash == b.configurationHash)
        var c = a; c.configuration["k"] = "other"
        #expect(a.configurationHash != c.configurationHash)
    }

    @Test("9.3 Markdown 报告包含数据版本、分母、混淆矩阵与失败样本")
    func report() {
        var m = ConfusionMatrix(labels: ["supported", "contradicted"])
        m.add(gold: "contradicted", predicted: "supported")
        let r = ctx().result(suite: "verification", samples: 1, metrics: ["flagged_recall": MetricValue(numerator: 0, denominator: 1)],
                             confusion: m, failures: [FailureCase(caseID: "v7", detail: "gold=contradicted pred=supported")])
        let md = BenchReportWriter.markdown([r])
        #expect(md.contains("draft_unreviewed") && md.contains("| flagged_recall | 0.0000 | 0.00 | 1 |"))
        #expect(md.contains("混淆矩阵") && md.contains("`v7`"))
    }
}

@Suite("M16 评测运行器")
struct RunnerTests {
    @Test("9.2 检索运行器按类别汇总并跳过不可回答问题")
    func retrievalRunner() async {
        let cases = [
            RetrievalCase(id: "q1", category: .local, question: "a", scopes: [], relevant: [rel[0]], note: nil),
            RetrievalCase(id: "q2", category: .crossChapter, question: "b", scopes: [], relevant: rel, note: nil),
            RetrievalCase(id: "q3", category: .unanswerable, question: "c", scopes: [], relevant: [], note: nil),
        ]
        let r = await RetrievalBenchRunner.run(cases: cases, context: ctx()) { _ in [RetrievedSpan(bookID: "b", chapterIndex: 0, start: 0, end: 100)] }
        #expect(r.sampleCount == 2)
        #expect(r.metrics["recall@10"]?.value == 0.75)
        #expect(r.metrics["recall@10.local"]?.value == 1)
        #expect(r.failures.map(\.caseID) == ["q2"])
    }

    @Test("9.2 复核运行器：裁判报错的样本计为无法判断")
    func verificationRunner() async {
        struct Throwing: ClaimJudge { let name = "t"; func judge(_ i: [ClaimJudgeInput]) async throws -> [ClaimJudgement] { throw CocoaError(.featureUnsupported) } }
        let cases = [VerificationCase(id: "v1", claim: "x", evidence: ["y"], label: "contradicted", perturbation: "number")]
        let r = await VerificationBenchRunner.run(cases: cases, judge: Throwing(), context: ctx())
        #expect(r.metrics["unknown"]?.numerator == 1)
        #expect(r.metrics["flagged_recall"]?.value == 0)
    }

    @Test("9.2 记忆运行器：来源、重复与冲突规则判定")
    func memoryRunner() {
        let cases = [
            MemoryCase(id: "m1", kind: "new", existing: [], action: "create", content: "新的记忆", targetID: nil, linkToID: nil, baseRevision: nil,
                       evidenceAllowed: true, evidenceInScope: nil, expectedStatus: "pending", expectedIssuePrefix: nil),
            MemoryCase(id: "m2", kind: "duplicate", existing: [.init(id: "e1", kind: "memory", content: "新的记忆", revision: 1)], action: "create",
                       content: "新的记忆。", targetID: nil, linkToID: nil, baseRevision: nil, evidenceAllowed: true, evidenceInScope: nil,
                       expectedStatus: "invalid", expectedIssuePrefix: "duplicate_of"),
            MemoryCase(id: "m3", kind: "conflict", existing: [.init(id: "e1", kind: "thought", content: "旧", revision: 3)], action: "revise",
                       content: "新", targetID: "e1", linkToID: nil, baseRevision: 2, evidenceAllowed: true, evidenceInScope: nil,
                       expectedStatus: "invalid", expectedIssuePrefix: "revision_conflict"),
        ]
        let r = MemoryBenchRunner.run(cases: cases, context: ctx(), now: Date())
        #expect(r.metrics["rule_conformance"]?.value == 1)
        #expect(r.metrics["unconfirmed_writes"]?.numerator == 0)
    }

    @Test("9.2 自测运行器：越界证据判为不可作答，反馈与参考分比较")
    func learningRunner() async {
        let books = ["b": ScopeBuilder.BookInfo(version: "v", chapterLengths: [0: 100, 1: 100])]
        let scope = [ScopeSpec(bookID: "b", readChapters: [0])]
        let cases = [
            LearningCase(id: "l1", bookID: "b", prompt: "作者的主要观点是什么？", referencePoints: ["带着问题读书"],
                         evidence: [RelevantSpan(bookID: "b", chapterIndex: 0, start: 0, end: 20)], scopes: scope, answer: "要带着问题读书",
                         expectedAnswerable: true, expectedScore: 1),
            LearningCase(id: "l2", bookID: "b", prompt: "第二章讲了什么内容？", referencePoints: ["复习"],
                         evidence: [RelevantSpan(bookID: "b", chapterIndex: 1, start: 0, end: 20)], scopes: scope, answer: "复习",
                         expectedAnswerable: false, expectedScore: nil),
        ]
        let r = await LearningBenchRunner.run(cases: cases, books: books, grader: HeuristicAnswerGrader(), context: ctx(), now: Date())
        #expect(r.metrics["answerable_accuracy"]?.value == 1)
        #expect(r.metrics["feedback_agreement"]?.value == 1)
    }

    @Test("9.1 范围设定：整章、章内区间与全书")
    func scopeBuilder() {
        let books = ["b": ScopeBuilder.BookInfo(version: "v", chapterLengths: [0: 100, 1: 200])]
        let s = ScopeBuilder.scopes([ScopeSpec(bookID: "b", readChapters: [0], partialRanges: [.init(chapterIndex: 1, start: 0, end: 50)])], books: books)[0]
        #expect(s.allows(bookID: "b", version: "v", chapterIndex: 1, range: TextSpan(start: 10, end: 40)))
        #expect(!s.allows(bookID: "b", version: "v", chapterIndex: 1, range: TextSpan(start: 60, end: 70)))
        let w = ScopeBuilder.scopes([ScopeSpec(bookID: "b", readChapters: [], wholeBook: true)], books: books)[0]
        #expect(w.mode == .wholeBook)
        #expect(ScopeBuilder.scopes([ScopeSpec(bookID: "missing", readChapters: [0])], books: books).isEmpty)
    }

    @Test("9.2 边界运行器：违规计数与样本")
    func boundaryRunner() async {
        let cases = [BoundaryCase(id: "b1", kind: "skip", query: "q", scopes: [], note: nil),
                     BoundaryCase(id: "b2", kind: "parent", query: "q", scopes: [], note: nil)]
        let r = await BoundaryBenchRunner.run(cases: cases, context: ctx()) { c in c.id == "b2" ? (3, ["越界 ch2"]) : (2, []) }
        #expect(r.metrics["violation_count"]?.numerator == 1)
        #expect(r.failures.map(\.caseID) == ["b2"])
    }
}
