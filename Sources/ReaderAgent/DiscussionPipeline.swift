import Foundation
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

/// 一次讨论的执行流程（3.2 流程图 A→K）。返回最终消息内容，由编排器在完成门之后持久化。
struct DiscussionPipeline: Sendable {
    let deps: ReaderAgentDependencies
    let conversation: Conversation
    let question: String
    let selection: SelectionContext?
    let assistant: Message
    let traceID: String
    let conversationService: ConversationService

    func run(onDraft: @escaping @Sendable (String) async -> Void,
             onEvent: @escaping @Sendable (DiscussionEvent) async -> Void) async throws -> Message {
        let clock = deps.clock
        let budget = TaskBudget(limits: deps.limits, clock: clock)
        let executor = BoundedExecutor(budget: budget, clock: clock, sleeper: deps.sleeper, trace: deps.trace, traceID: traceID)
        guard let generator = deps.generator else { throw ProviderError.notConfigured("对话模型") }

        // A. 阅读状态：选段视为用户正在阅读的内容，记为已读
        var books: [BookID: Book] = [:]
        var readStates: [BookID: BookReadState] = [:]
        for id in conversation.allBookIDs {
            guard let book = try await deps.books.book(id: id), book.status == .active else { continue }
            books[id] = book
            if let sel = selection, sel.locator.bookID == id, sel.locator.bookVersion == book.fingerprint, !sel.locator.range.isEmpty {
                try await deps.readStates.addReadRange(bookID: id, version: book.fingerprint,
                                                       chapterIndex: sel.locator.chapterIndex, range: sel.locator.range)
            }
            readStates[id] = try await deps.readStates.readState(bookID: id, version: book.fingerprint)
        }
        let routingRequest = RoutingRequest(question: question, primaryBookID: conversation.primaryBookID,
                                            selectionText: selection?.text, userScope: conversation.scopeMode,
                                            permittedBookIDs: conversation.allBookIDs, readStates: readStates,
                                            hasHistory: try await !history().isEmpty)

        // B/C. 语义规划 → 规则校验与策略编译
        var plan: SemanticPlan?
        var planFailure: String?
        if let planner = deps.planner {
            let messages = PlanPromptBuilder.messages(for: routingRequest, bookTitles: books.mapValues(\.title))
            do {
                let response: ChatResponse = try await executor.run(stage: "planning", model: planner.modelID, timeout: 15, usage: { $0.usage }) {
                    try await planner.complete(ChatRequest(messages: messages, maxOutputTokens: 300, temperature: 0, jsonMode: true, stage: "planning"))
                }
                plan = try SemanticPlanParser.parse(response.text)
            } catch let e as BudgetError where e == .cancelled {
                throw e
            } catch {
                planFailure = "规划失败：\(error)"
            }
        } else {
            planFailure = "未配置规划模型"
        }
        try Task.checkCancellation()
        let policy = PolicyCompiler(limits: deps.limits).compile(plan: plan, request: routingRequest, planFailure: planFailure)
        let summary = PolicySummary(intent: policy.intent, scopeMode: policy.scopeMode, bookIDs: policy.scopes.map(\.bookID),
                                    sources: policy.sources, queries: policy.queries, usedModelPlan: policy.usedModelPlan,
                                    notes: policy.notes)
        await onEvent(.policy(summary))
        await deps.trace.record(TraceEvent(traceID: traceID, stage: "routing", name: "policy_compiled", startedAt: clock.now(),
                                           outcome: policy.usedModelPlan ? .success : .degraded,
                                           degradation: policy.usedModelPlan ? nil : planFailure,
                                           attributes: ["scope": policy.scopeMode.rawValue, "books": "\(policy.scopes.count)",
                                                        "notes": policy.notes.map(\.code).joined(separator: ",")]))

        // D/E. 检索（外部请求计入同一预算）
        let scope = policy.retrievalScope
        let retriever = HybridRetriever(
            chunks: deps.retriever.chunks, lexical: deps.retriever.lexical, vectors: deps.retriever.vectors,
            embedder: deps.retriever.embedder.map { BudgetedEmbeddingService(inner: $0, executor: executor) },
            reranker: deps.retriever.reranker.map { BudgetedRerankService(inner: $0, executor: executor) },
            config: policy.retrieval)
        let retrievalStart = clock.now()
        let retrieval = policy.sources.contains(.bookText) ? await retriever.retrieve(queries: policy.queries, scope: scope)
            : RetrievalResult(units: [], diagnostics: RetrievalDiagnostics())
        await deps.trace.record(TraceEvent(traceID: traceID, stage: "retrieval", name: "hybrid_retrieve", startedAt: retrievalStart,
                                           duration: clock.now().timeIntervalSince(retrievalStart),
                                           outcome: retrieval.diagnostics.degradations.isEmpty ? .success : .degraded,
                                           degradation: retrieval.diagnostics.degradations.joined(separator: ","),
                                           attributes: ["units": "\(retrieval.units.count)", "lexical": "\(retrieval.diagnostics.lexicalHits)",
                                                        "vector": "\(retrieval.diagnostics.vectorHits)",
                                                        "reranked": "\(retrieval.diagnostics.reranked)"]))
        try Task.checkCancellation()

        // F. 多来源候选 → 去重、预算裁剪
        let candidates = try await gatherCandidates(policy: policy, scope: scope, books: books, retrieval: retrieval)
        let package = ContextAssembler(budgetTokens: deps.limits.contextTokenBudget).assemble(candidates, allowedSources: policy.sources)
        await onEvent(.evidence(package.evidence))
        await deps.trace.record(TraceEvent(traceID: traceID, stage: "context", name: "assembled", startedAt: clock.now(),
                                           outcome: package.dropped.isEmpty ? .success : .degraded,
                                           attributes: ["evidence": "\(package.evidence.count)", "dropped": "\(package.dropped.count)",
                                                        "estimated_tokens": "\(package.estimatedTokens)"]))

        // 证据不足：说明限制并给出补充方式，不伪造引用（CHAT-03）
        let hasPersonalEvidence = package.evidence.contains { (e: Evidence) -> Bool in e.kind == .reflection || e.kind == .memory }
        guard package.hasBookEvidence || hasPersonalEvidence else {
            var m = assistant
            m.status = .insufficientEvidence
            let hasRead = policy.scopes.contains { (s: AccessScope) -> Bool in s.hasAccessibleContent }
            m.text = InsufficientEvidenceResponder.text(scopeMode: policy.scopeMode, hasReadContent: hasRead)
            m.scopeMode = policy.scopeMode
            return m
        }

        // G. 生成带引用的回答草稿（流式）
        _ = try await conversationService.transition(messageID: assistant.id, to: .drafting)
        await onEvent(.status(.drafting))
        let historyMessages = try await history()
        let messages = PromptComposer.generationMessages(question: question, package: package, intent: policy.intent,
                                                         history: historyMessages, scopeMode: policy.scopeMode.rawValue)
        let request = ChatRequest(messages: messages, maxOutputTokens: deps.limits.maxOutputTokens, temperature: 0.3, stage: "generation")
        let accumulator = DraftAccumulator()
        let response: ChatResponse = try await executor.run(stage: "generation", model: generator.modelID, usage: { $0.usage }) {
            try await generator.collectStream(request) { delta in
                let text = await accumulator.append(delta)
                await onDraft(text)
                await onEvent(.delta(delta))
            }
        }
        var answer = response.text
        let truncated = response.finishReason == .length

        // H. 引用与范围校验：伪造标签被移除并记录
        let stripped = CitationExtractor.stripUnknown(answer, known: package.labels)
        if !stripped.removed.isEmpty {
            answer = stripped.text
            await deps.trace.record(TraceEvent(traceID: traceID, stage: "citation", name: "unknown_labels_removed", startedAt: clock.now(),
                                               outcome: .degraded, attributes: ["labels": stripped.removed.joined(separator: ",")]))
            await onEvent(.revised(answer))
        }

        // I. 关键陈述与证据一致性复核
        let draftAnswer = answer
        _ = try await conversationService.transition(messageID: assistant.id, to: .verifying) { $0.text = draftAnswer }
        await onEvent(.status(.verifying))
        let judge: ClaimJudge? = deps.verifier.map { LLMClaimJudge(model: $0, executor: executor) } ?? deps.fallbackJudge
        let validator = RepositoryEvidenceValidator(books: deps.books, reflections: deps.reflections, brain: deps.brain)
        let verifier = EvidenceVerifier(judge: judge, checker: StructuralChecker(scope: scope, validator: validator))
        var report = await verifier.verify(answer: answer, package: package)

        // EVID-03：剩余预算内至多修正一轮
        if CorrectionPolicy.shouldRevise(report, roundsUsed: 0, remainingCalls: await budget.remainingCalls) {
            do {
                let revisionRequest = ChatRequest(messages: CorrectionPolicy.revisionMessages(answer: answer, report: report,
                                                                                               package: package, question: question),
                                                  maxOutputTokens: deps.limits.maxOutputTokens, temperature: 0.2, stage: "revision")
                let revised: ChatResponse = try await executor.run(stage: "revision", model: generator.modelID, usage: { $0.usage }) {
                    try await generator.complete(revisionRequest)
                }
                let cleaned = CitationExtractor.stripUnknown(revised.text, known: package.labels).text
                let newReport: VerificationReport = await verifier.verify(answer: cleaned, package: package)
                if newReport.flaggedClaims.count < report.flaggedClaims.count && newReport.overall != .unavailable {
                    answer = cleaned
                    report = newReport
                    await onEvent(.revised(answer))
                }
            } catch let e as BudgetError where e == .cancelled {
                throw e
            } catch {
                await deps.trace.record(TraceEvent(traceID: traceID, stage: "revision", name: "revision_skipped", startedAt: clock.now(),
                                                   outcome: .degraded, errorCode: "\(error)"))
            }
        }
        await onEvent(.verification(report))
        await deps.trace.record(TraceEvent(traceID: traceID, stage: "verification", name: "verified", startedAt: clock.now(),
                                           outcome: report.overall == .unavailable ? .failure : .success,
                                           errorCode: report.failureReason,
                                           attributes: ["overall": report.overall.rawValue,
                                                        "supported": "\(report.count(.supported))",
                                                        "insufficient": "\(report.count(.insufficient))",
                                                        "contradicted": "\(report.count(.contradicted))",
                                                        "unknown": "\(report.count(.unknown))"]))

        // J/K. 最终状态与证据快照
        var final = assistant
        final.text = answer
        final.truncated = truncated
        final.scopeMode = policy.scopeMode
        final.status = Self.status(for: report, truncated: truncated)
        if truncated { final.errorDescription = "回答达到长度上限，内容可能不完整。" }
        if report.overall == .unavailable { final.errorDescription = "证据复核未完成（\(report.failureReason ?? "未知原因")），回答未经核查。" }
        let usedLabels = Set(CitationExtractor.labels(in: answer))
        final.citations = package.evidence.filter { usedLabels.contains($0.label) }.map { e in
            Self.snapshot(e, valid: report.citationChecks[e.label]?.isValid ?? false, books: books)
        }
        final.claimChecks = report.claims.map {
            ClaimCheckSnapshot(claim: $0.claim.text, labels: $0.claim.labels, verdict: ClaimVerdictLabel(rawValue: $0.verdict.rawValue) ?? .unknown,
                               reason: $0.reason, isGeneralKnowledge: $0.claim.isGeneralKnowledge)
        }
        return final
    }

    static func status(for report: VerificationReport, truncated: Bool) -> MessageStatus {
        switch report.overall {
        case .passed: return truncated ? .needsAttention : .verified
        case .issuesFound: return .needsAttention
        case .unavailable: return .verificationUnavailable
        case .noFactualClaims: return .insufficientEvidence
        }
    }

    static func snapshot(_ e: Evidence, valid: Bool, books: [BookID: Book]) -> CitationSnapshot {
        var locator: Locator?
        if let b = e.bookID, let v = e.bookVersion, let c = e.chapterIndex, let r = e.range {
            locator = Locator(bookID: b, bookVersion: v, chapterIndex: c, chapterHref: "", range: r,
                              anchor: TextAnchor(prefix: "", exact: e.text, suffix: ""), progression: 0)
        }
        return CitationSnapshot(label: e.label, evidenceID: e.id, kind: EvidenceSourceKind(rawValue: e.kind.rawValue) ?? .bookText,
                                bookID: e.bookID, bookVersion: e.bookVersion, locator: locator, sourceRecordID: e.sourceRecordID,
                                quote: e.text, structurallyValid: valid)
    }

    /// 历史快照：按状态筛选，并排除从全书切回已读后的全书轮次；不重新校验引用来源、版本与区间（已知限制 R-01）。
    func history() async throws -> [ChatMessage] {
        let messages = try await deps.conversations.messages(conversationID: conversation.id)
            .filter { $0.id != assistant.id }
            .sorted { $0.createdAt < $1.createdAt }
        var out: [ChatMessage] = []
        var pendingUser: Message?
        for m in messages {
            if m.role == .user { pendingUser = m; continue }
            guard let u = pendingUser, m.replyTo == u.id else { continue }
            pendingUser = nil
            guard [.verified, .needsAttention].contains(m.status) else { continue }
            if m.scopeMode == .wholeBook && conversation.scopeMode == .readOnly { continue }
            out.append(.user(u.text))
            out.append(.assistant(TokenEstimator.truncate(m.text, toTokens: 400)))
        }
        return Array(out.suffix(8))
    }

    func gatherCandidates(policy: ExecutionPolicy, scope: RetrievalScope, books: [BookID: Book],
                          retrieval: RetrievalResult) async throws -> [Evidence] {
        var out: [Evidence] = []
        var chapterTitles: [String: String] = [:]
        for (id, _) in books {
            for c in try await deps.books.chapters(bookID: id) { chapterTitles["\(id)#\(c.index)"] = c.title }
        }
        let segmenter = TextSegmenter()
        let qTokens = Set(segmenter.tokens(question + " " + (selection?.text ?? "")))
        func relevance(_ text: String) -> Double {
            guard !qTokens.isEmpty else { return 0 }
            return Double(Set(segmenter.tokens(text)).intersection(qTokens).count) / Double(qTokens.count)
        }

        if let sel = selection, policy.sources.contains(.selection),
           scope.allows(bookID: sel.locator.bookID, version: sel.locator.bookVersion, chapterIndex: sel.locator.chapterIndex, range: sel.locator.range) {
            out.append(Evidence(id: "sel:\(sel.locator.bookID):\(sel.locator.chapterIndex):\(sel.locator.range.start)-\(sel.locator.range.end)",
                                kind: .bookText, bookID: sel.locator.bookID, bookVersion: sel.locator.bookVersion,
                                chapterIndex: sel.locator.chapterIndex, chapterTitle: chapterTitles["\(sel.locator.bookID)#\(sel.locator.chapterIndex)"],
                                range: sel.locator.range, text: sel.text, score: 10, isSelection: true))
        }
        for u in retrieval.units {
            out.append(Evidence.fromRetrieval(u, chapterTitle: chapterTitles["\(u.bookID)#\(u.chapterIndex)"]))
        }
        if policy.sources.contains(.annotations) {
            for id in scope.bookIDs {
                let anns = try await deps.annotations.annotations(bookID: id).filter {
                    scope.allows(bookID: $0.bookID, version: $0.locator.bookVersion, chapterIndex: $0.locator.chapterIndex, range: $0.locator.range)
                }
                for a in anns.map({ ($0, relevance($0.quote + " " + ($0.note ?? ""))) }).filter({ $0.1 > 0 }).sorted(by: { $0.1 > $1.1 }).prefix(3) {
                    let text = a.0.note.map { "「\(a.0.quote)」批注：\($0)" } ?? "「\(a.0.quote)」"
                    out.append(Evidence(id: "ann:\(a.0.id)", kind: .annotation, bookID: a.0.bookID, bookVersion: a.0.locator.bookVersion,
                                        chapterIndex: a.0.locator.chapterIndex, chapterTitle: chapterTitles["\(a.0.bookID)#\(a.0.locator.chapterIndex)"],
                                        range: a.0.locator.range, text: text, sourceRecordID: a.0.id, score: a.1))
                }
            }
        }
        if policy.sources.contains(.reflections) {
            var refls: [(Reflection, Double)] = []
            for id in scope.bookIDs {
                for r in try await deps.reflections.reflections(bookID: id) where r.state == .saved && !r.sourceUnavailable {
                    // 反思的阅读现场若在当前范围之外，不纳入（避免借反思泄露未读内容）
                    if let l = r.context.locator, !scope.allows(bookID: l.bookID, version: l.bookVersion, chapterIndex: l.chapterIndex, range: l.range) { continue }
                    let score = relevance(r.text + " " + (r.context.selectedText ?? ""))
                    if score > 0 { refls.append((r, score)) }
                }
            }
            for (r, score) in refls.sorted(by: { $0.1 > $1.1 }).prefix(3) {
                out.append(Evidence(id: "refl:\(r.id)", kind: .reflection, bookID: r.bookID, text: r.text, sourceRecordID: r.id, score: score))
            }
        }
        if policy.sources.contains(.memories) {
            let items = try await deps.brain.items(kinds: [.thought, .memory], includeInactive: false)
            let recall = MemoryRecall().recall(query: question, items: items, scope: scope, limit: 3)
            for r in recall.recalled {
                out.append(Evidence(id: "mem:\(r.item.id)", kind: .memory, text: r.item.content, sourceRecordID: r.item.id, score: r.score))
            }
            if recall.excludedOutOfScope > 0 {
                await deps.trace.record(TraceEvent(traceID: traceID, stage: "context", name: "memories_excluded", startedAt: deps.clock.now(),
                                                   outcome: .success, attributes: ["out_of_scope": "\(recall.excludedOutOfScope)",
                                                                                   "invalid_source": "\(recall.excludedInvalidSource)"]))
            }
        }
        return out
    }
}

actor DraftAccumulator {
    private var text = ""
    func append(_ s: String) -> String { text += s; return text }
}

/// 证据不足时的说明（不调用模型，不伪造引用）。
public enum InsufficientEvidenceResponder {
    public static func text(scopeMode: ScopeMode, hasReadContent: Bool) -> String {
        var lines = ["在\(scopeMode == .readOnly ? "你已读的范围" : "本书")内，我没有找到足以回答这个问题的依据，因此不作推测。"]
        if !hasReadContent {
            lines.append("目前还没有记录到已读内容：继续阅读后，相关段落会进入讨论范围。")
        }
        lines.append("你可以：选中相关段落再提问；补充一条自己的反思；或在确认不介意剧透时切换到全书范围。")
        return lines.joined(separator: "\n")
    }
}

/// 用仓储校验证据来源仍然有效（定位存在、来源未删除）。
struct RepositoryEvidenceValidator: EvidenceSourceValidating {
    let books: BookRepository
    let reflections: ReflectionRepository
    let brain: BrainRepository

    func issue(for evidence: Evidence) async -> StructuralIssue? {
        switch evidence.kind {
        case .bookText, .annotation:
            guard let bookID = evidence.bookID, let idx = evidence.chapterIndex, let range = evidence.range else { return .invalidLocator }
            guard let book = try? await books.book(id: bookID) else { return .sourceDeleted }
            if book.status != .active { return .sourceDeleted }
            if book.fingerprint != evidence.bookVersion { return .versionMismatch }
            guard let chapter = try? await books.chapter(bookID: bookID, index: idx) else { return .invalidLocator }
            if range.end > chapter.length || range.isEmpty { return .invalidLocator }
            if evidence.kind == .bookText && chapter.text.substring(utf16: range) != evidence.text { return .invalidLocator }
            return nil
        case .reflection:
            guard let id = evidence.sourceRecordID, let r = try? await reflections.reflection(id: id) else { return .sourceDeleted }
            return r.sourceUnavailable ? .sourceDeleted : nil
        case .memory:
            guard let id = evidence.sourceRecordID, let item = try? await brain.item(id: id), item.status == .active else { return .sourceDeleted }
            return nil
        case .history:
            return nil
        }
    }
}
