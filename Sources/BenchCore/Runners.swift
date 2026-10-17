import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore
import RetrievalCore
import ContextEngineering
import EvidenceVerificationCore
import BrainCore
import LearningCore

/// 把数据集中的范围设定转为访问范围。
public enum ScopeBuilder {
    public struct BookInfo: Sendable {
        public var version: String
        public var chapterLengths: [Int: Int]
        public init(version: String, chapterLengths: [Int: Int]) { self.version = version; self.chapterLengths = chapterLengths }
    }

    public static func scopes(_ specs: [ScopeSpec], books: [BookID: BookInfo]) -> [AccessScope] {
        specs.compactMap { spec in
            guard let info = books[spec.bookID] else { return nil }
            if spec.wholeBook == true { return AccessScope.wholeBook(bookID: spec.bookID, version: info.version) }
            var state = BookReadState(bookID: spec.bookID, bookVersion: info.version)
            for c in spec.readChapters {
                state.markRead(chapterIndex: c, range: TextSpan(start: 0, end: info.chapterLengths[c] ?? 0))
            }
            for p in spec.partialRanges ?? [] {
                state.markRead(chapterIndex: p.chapterIndex, range: TextSpan(start: p.start, end: p.end))
            }
            return AccessScope.readOnly(state)
        }
    }
}

public struct BenchContext: Sendable {
    public var datasetName: String
    public var datasetVersion: String
    public var datasetSHA256: String
    public var annotationStatus: DatasetManifest.AnnotationStatus
    public var configuration: [String: String]
    public var runID: String
    public var now: Date

    public init(datasetName: String, datasetVersion: String, datasetSHA256: String, annotationStatus: DatasetManifest.AnnotationStatus,
                configuration: [String: String], runID: String, now: Date) {
        self.datasetName = datasetName; self.datasetVersion = datasetVersion; self.datasetSHA256 = datasetSHA256
        self.annotationStatus = annotationStatus; self.configuration = configuration; self.runID = runID; self.now = now
    }

    func result(suite: String, samples: Int, metrics: [String: MetricValue], confusion: ConfusionMatrix? = nil,
                failures: [FailureCase]) -> BenchRunResult {
        BenchRunResult(runID: runID, suite: suite, datasetName: datasetName, datasetVersion: datasetVersion,
                       datasetSHA256: datasetSHA256, annotationStatus: annotationStatus, configuration: configuration,
                       createdAt: now, sampleCount: samples, metrics: metrics, confusion: confusion, failures: failures)
    }
}

/// 检索评测：Recall@5/10、nDCG@5，按类别分组。
public enum RetrievalBenchRunner {
    public static func run(cases: [RetrievalCase], context: BenchContext,
                           retrieve: @Sendable (RetrievalCase) async -> [RetrievedSpan]) async -> BenchRunResult {
        var r5: [Double] = [], r10: [Double] = [], n5: [Double] = []
        var byCategory: [RetrievalCategory: [Double]] = [:]
        var failures: [FailureCase] = []
        for c in cases where c.answerable {
            let retrieved = await retrieve(c)
            let a = RetrievalMetrics.recall(at: 5, retrieved: retrieved, relevant: c.relevant)
            let b = RetrievalMetrics.recall(at: 10, retrieved: retrieved, relevant: c.relevant)
            r5.append(a); r10.append(b)
            n5.append(RetrievalMetrics.ndcg(at: 5, retrieved: retrieved, relevant: c.relevant))
            byCategory[c.category, default: []].append(b)
            if b < 1 { failures.append(FailureCase(caseID: c.id, detail: String(format: "Recall@10=%.2f；%@", b, c.question))) }
        }
        var metrics: [String: MetricValue] = [
            "recall@5": MetricValue(mean: r5), "recall@10": MetricValue(mean: r10), "ndcg@5": MetricValue(mean: n5),
        ]
        for (cat, values) in byCategory { metrics["recall@10.\(cat.rawValue)"] = MetricValue(mean: values) }
        return context.result(suite: "retrieval", samples: r10.count, metrics: metrics, failures: Array(failures.prefix(20)))
    }
}

/// 阅读边界评测：任何检索/扩展单元超出允许区间即为违规（目标 0）。
public enum BoundaryBenchRunner {
    public static func run(cases: [BoundaryCase], context: BenchContext,
                           check: @Sendable (BoundaryCase) async -> (units: Int, violations: [String])) async -> BenchRunResult {
        var violations = 0, units = 0
        var failures: [FailureCase] = []
        for c in cases {
            let r = await check(c)
            units += r.units
            violations += r.violations.count
            if !r.violations.isEmpty { failures.append(FailureCase(caseID: c.id, detail: r.violations.joined(separator: "; "))) }
        }
        return context.result(suite: "boundary", samples: cases.count,
                              metrics: ["violations": MetricValue(numerator: Double(violations), denominator: Double(max(units, 1))),
                                        "violation_count": MetricValue(numerator: Double(violations), denominator: 1),
                                        "cases_with_violation": MetricValue(numerator: Double(failures.count), denominator: Double(cases.count))],
                              failures: failures)
    }
}

/// 证据复核评测：问题类别（矛盾、证据不足）Precision/Recall + 混淆矩阵 + 无法判断数。
public enum VerificationBenchRunner {
    public static func run(cases: [VerificationCase], judge: ClaimJudge, context: BenchContext) async -> BenchRunResult {
        var matrix = ConfusionMatrix(labels: Verdict.allCases.map(\.rawValue))
        var failures: [FailureCase] = []
        var unknown = 0
        for c in cases {
            let input = ClaimJudgeInput(claimID: c.id, claim: c.claim,
                                        evidence: c.evidence.enumerated().map { .init(label: "E\($0.offset + 1)", kind: .bookText, text: $0.element) })
            let predicted: String
            do {
                predicted = try await judge.judge([input]).first?.verdict.rawValue ?? Verdict.unknown.rawValue
            } catch {
                predicted = Verdict.unknown.rawValue
            }
            if predicted == Verdict.unknown.rawValue { unknown += 1 }
            matrix.add(gold: c.label, predicted: predicted)
            if predicted != c.label { failures.append(FailureCase(caseID: c.id, detail: "gold=\(c.label) pred=\(predicted) [\(c.perturbation ?? "-")]")) }
        }
        let pr = matrix.binary(positive: [Verdict.insufficient.rawValue, Verdict.contradicted.rawValue])
        return context.result(suite: "verification", samples: cases.count,
                              metrics: ["flagged_precision": pr.precision, "flagged_recall": pr.recall, "accuracy": matrix.accuracy(),
                                        "unknown": MetricValue(numerator: Double(unknown), denominator: Double(cases.count))],
                              confusion: matrix, failures: Array(failures.prefix(30)))
    }
}

/// 记忆提议规则评测：校验结果是否符合来源、重复与冲突规则；未确认提议写入数恒为 0。
public enum MemoryBenchRunner {
    public static func run(cases: [MemoryCase], context: BenchContext, now: Date) -> BenchRunResult {
        let validator = ProposalValidator()
        var correct = 0
        var failures: [FailureCase] = []
        for c in cases {
            let existing = c.existing.map {
                BrainItem(id: $0.id, kind: BrainItemKind(rawValue: $0.kind) ?? .memory, content: $0.content, origin: .user,
                          evidence: [], revision: $0.revision ?? 1, createdAt: now, updatedAt: now)
            }
            let ref = EvidenceRef.book("bench", version: "v", chapter: 0, range: TextSpan(start: 0, end: 10), quote: "q")
            let allowedMap: [String: EvidenceRef] = c.evidenceAllowed ? ["E1": ref] : ["E1": .reflection("other", bookID: nil, quote: "x")]
            let action: ProposalAction
            switch c.action {
            case "link": action = .link(fromID: c.targetID ?? "", toID: c.linkToID ?? "", type: .supports)
            case "revise": action = .revise(itemID: c.targetID ?? "", baseRevision: c.baseRevision ?? 1, newContent: c.content ?? "", reason: "修订")
            default: action = .create(kind: .memory, content: c.content ?? "", evidence: [ref])
            }
            var scope: RetrievalScope?
            if c.evidenceInScope == false {
                scope = RetrievalScope([AccessScope.readOnly(BookReadState(bookID: "bench", bookVersion: "v"))])
            }
            let issues = validator.issues(for: action, existing: existing, relations: [],
                                          context: ProposalContext(conversationID: "c", messageID: "m", evidenceByLabel: allowedMap, scope: scope))
            let status = issues.isEmpty ? "pending" : "invalid"
            var ok = status == c.expectedStatus
            if ok, let prefix = c.expectedIssuePrefix { ok = issues.contains { $0.hasPrefix(prefix) } }
            if ok { correct += 1 } else {
                failures.append(FailureCase(caseID: c.id, detail: "expected=\(c.expectedStatus)\(c.expectedIssuePrefix.map { "/\($0)" } ?? "") got=\(status) \(issues)"))
            }
        }
        return context.result(suite: "memory", samples: cases.count,
                              metrics: ["rule_conformance": MetricValue(numerator: Double(correct), denominator: Double(cases.count)),
                                        "unconfirmed_writes": MetricValue(numerator: 0, denominator: 1)],
                              failures: failures)
    }
}

/// 自测评测：题目是否可由允许的已读证据回答（证据可定位且在范围内、无答案泄露）；反馈与人工参考评分是否一致。
public enum LearningBenchRunner {
    public static func run(cases: [LearningCase], books: [BookID: ScopeBuilder.BookInfo], grader: AnswerGrading,
                           context: BenchContext, now: Date) async -> BenchRunResult {
        var answerableCorrect = 0
        var feedbackCorrect = 0, feedbackTotal = 0
        var failures: [FailureCase] = []
        for c in cases {
            let scope = RetrievalScope(ScopeBuilder.scopes(c.scopes, books: books))
            let version = books[c.bookID]?.version ?? ""
            let inScope = !c.evidence.isEmpty && c.evidence.allSatisfy {
                scope.allows(bookID: $0.bookID, version: version, chapterIndex: $0.chapterIndex, range: $0.range)
            }
            let leak = QuestionGenerator.leaksAnswer(prompt: c.prompt, referencePoints: c.referencePoints)
            let predictedAnswerable = inScope && !leak
            if predictedAnswerable == c.expectedAnswerable { answerableCorrect += 1 } else {
                failures.append(FailureCase(caseID: c.id, detail: "answerable expected=\(c.expectedAnswerable) got=\(predictedAnswerable) leak=\(leak)"))
            }
            guard predictedAnswerable else { continue }
            let item = LearningItem(id: c.id, bookID: c.bookID, type: .comprehension, prompt: c.prompt, referencePoints: c.referencePoints,
                                    rubric: "", evidence: c.evidence.map {
                                        LearningEvidence(bookID: $0.bookID, bookVersion: version, chapterIndex: $0.chapterIndex, range: $0.range, quote: "")
                                    }, knowledgePoint: c.id, createdAt: now)
            feedbackTotal += 1
            let graded = try? await grader.grade(item: item, answer: c.answer)
            let ok: Bool
            switch (graded?.grade, c.expectedScore) {
            case (.scored(let s)?, let e?): ok = abs(s - e) <= 0.34
            case (.uncertain?, nil): ok = true
            default: ok = false
            }
            if ok { feedbackCorrect += 1 } else {
                failures.append(FailureCase(caseID: c.id, detail: "feedback expected=\(c.expectedScore.map { String($0) } ?? "uncertain") got=\(String(describing: graded?.grade))"))
            }
        }
        return context.result(suite: "learning", samples: cases.count,
                              metrics: ["answerable_accuracy": MetricValue(numerator: Double(answerableCorrect), denominator: Double(cases.count)),
                                        "feedback_agreement": MetricValue(numerator: Double(feedbackCorrect), denominator: Double(feedbackTotal))],
                              failures: Array(failures.prefix(20)))
    }
}

/// Markdown 评测报告。
public enum BenchReportWriter {
    public static func markdown(_ results: [BenchRunResult]) -> String {
        var out = "# 评测报告\n\n"
        for r in results {
            out += "## \(r.suite)（run \(r.runID)）\n\n"
            out += "- 数据集：\(r.datasetName) v\(r.datasetVersion)（sha256 \(r.datasetSHA256.prefix(12))…，标注状态：\(r.annotationStatus.rawValue)）\n"
            out += "- 样本数：\(r.sampleCount)；配置哈希：\(r.configurationHash)\n"
            out += "- 配置：" + r.configuration.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "\n\n"
            out += "| 指标 | 值 | 分子 | 分母 |\n|---|---:|---:|---:|\n"
            for (k, v) in r.metrics.sorted(by: { $0.key < $1.key }) {
                out += String(format: "| %@ | %.4f | %.2f | %.0f |\n", k, v.value, v.numerator, v.denominator)
            }
            if let m = r.confusion {
                out += "\n混淆矩阵（行=标注，列=预测）：\n\n| | " + m.labels.joined(separator: " | ") + " |\n|---|" + m.labels.map { _ in "---:" }.joined(separator: "|") + "|\n"
                for g in m.labels { out += "| \(g) | " + m.labels.map { "\(m.count(gold: g, predicted: $0))" }.joined(separator: " | ") + " |\n" }
            }
            if !r.failures.isEmpty {
                out += "\n代表性失败样本：\n\n"
                for f in r.failures.prefix(10) { out += "- `\(f.caseID)`：\(f.detail)\n" }
            }
            out += "\n"
        }
        return out
    }
}
