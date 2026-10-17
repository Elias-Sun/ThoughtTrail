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

/// 讨论所需的依赖（由 AppInfrastructure 装配）。
public struct ReaderAgentDependencies: Sendable {
    public var books: BookRepository
    public var readStates: ReadingStateRepository
    public var annotations: AnnotationRepository
    public var reflections: ReflectionRepository
    public var conversations: ConversationRepository
    public var brain: BrainRepository
    public var retriever: HybridRetriever
    /// 回答生成模型；nil 表示未配置（讨论会以“失败：未配置”结束并保留问题）。
    public var generator: ChatModel?
    /// 语义规划模型；nil 时使用规则策略。
    public var planner: ChatModel?
    /// 复核模型；nil 时按 `fallbackJudge` 处理。
    public var verifier: ChatModel?
    /// 无复核模型时的确定性裁判（例如离线演示）；nil 则复核结果为“未能核查”。
    public var fallbackJudge: ClaimJudge?
    public var trace: TraceRecorder
    public var tasks: TaskRegistry
    public var clock: WallClock
    public var ids: IDGenerating
    public var sleeper: Sleeper
    public var limits: ExecutionLimits
    public var memoryLimits: ExecutionLimits

    public init(books: BookRepository, readStates: ReadingStateRepository, annotations: AnnotationRepository,
                reflections: ReflectionRepository, conversations: ConversationRepository, brain: BrainRepository,
                retriever: HybridRetriever, generator: ChatModel?, planner: ChatModel?, verifier: ChatModel?,
                fallbackJudge: ClaimJudge? = nil, trace: TraceRecorder, tasks: TaskRegistry, clock: WallClock,
                ids: IDGenerating, sleeper: Sleeper = TaskSleeper(), limits: ExecutionLimits = .discussion,
                memoryLimits: ExecutionLimits = .memoryProposal) {
        self.books = books; self.readStates = readStates; self.annotations = annotations; self.reflections = reflections
        self.conversations = conversations; self.brain = brain; self.retriever = retriever; self.generator = generator
        self.planner = planner; self.verifier = verifier; self.fallbackJudge = fallbackJudge; self.trace = trace
        self.tasks = tasks; self.clock = clock; self.ids = ids; self.sleeper = sleeper; self.limits = limits
        self.memoryLimits = memoryLimits
    }
}

/// 用户在阅读器中选中的文本（发起讨论的阅读现场）。
public struct SelectionContext: Sendable, Hashable {
    public var locator: Locator
    public var text: String

    public init(locator: Locator, text: String) { self.locator = locator; self.text = text }
}

public struct DiscussionRequest: Sendable {
    public var conversationID: String
    /// 已保存的用户消息（问题先持久化，失败/取消后仍保留，CHAT-04）。
    public var userMessageID: String
    public var selection: SelectionContext?

    public init(conversationID: String, userMessageID: String, selection: SelectionContext? = nil) {
        self.conversationID = conversationID; self.userMessageID = userMessageID; self.selection = selection
    }

    /// 幂等键：同一问题重复触发只执行一次。
    public var requestKey: String { "discussion:\(userMessageID)" }
}

/// 执行记录中可见的策略摘要（范围切换在界面与记录中可见）。
public struct PolicySummary: Sendable, Hashable {
    public var intent: DiscussionIntent
    public var scopeMode: ScopeMode
    public var bookIDs: [BookID]
    public var sources: [ContextSource]
    public var queries: [String]
    public var usedModelPlan: Bool
    public var notes: [RoutingNote]
}

public enum DiscussionEvent: Sendable {
    case started(assistantMessageID: String, traceID: String)
    case status(MessageStatus)
    case policy(PolicySummary)
    case evidence([Evidence])
    case delta(String)
    /// 修正后整体替换草稿。
    case revised(String)
    case verification(VerificationReport)
    case finished(Message)
}

public enum DiscussionError: Error, Equatable, Sendable {
    case conversationNotFound
    case userMessageNotFound
    case alreadyRunning
}

/// 阅读讨论编排（M11）。模型提出意图和候选内容，代码控制可访问数据、执行、预算与写入（3.2）。
public actor DiscussionOrchestrator {
    let deps: ReaderAgentDependencies
    let conversationService: ConversationService
    private var running: [String: Task<Message, Error>] = [:]
    private var gates: [String: CompletionGate<Message>] = [:]
    private var drafts: [String: String] = [:]
    private var assistantIDs: [String: String] = [:]

    public init(dependencies: ReaderAgentDependencies) {
        deps = dependencies
        conversationService = ConversationService(repository: dependencies.conversations, clock: dependencies.clock,
                                                  ids: dependencies.ids)
    }

    /// 执行讨论并返回最终的助手消息（任何结果都有明确状态）。
    public func run(_ request: DiscussionRequest, onEvent: @escaping @Sendable (DiscussionEvent) async -> Void = { _ in }) async throws -> Message {
        let key = request.requestKey
        switch try await deps.tasks.begin(kind: .discussion, idempotencyKey: key) {
        case .alreadySucceeded(let record):
            if let id = record.resultRef, let m = try await deps.conversations.message(id: id) { return m }
        case .alreadyRunning:
            if let id = assistantIDs[key], let m = try await deps.conversations.message(id: id) { return m }
            throw DiscussionError.alreadyRunning
        case .started(let record):
            return try await execute(request, traceID: record.traceID, onEvent: onEvent)
        }
        throw DiscussionError.alreadyRunning
    }

    /// 取消：立即把消息置为“已取消”并保留草稿；迟到的生成结果不会再改变状态（10.1）。
    @discardableResult
    public func cancel(requestKey: String) async -> Message? {
        guard let gate = gates[requestKey], await gate.cancel() else { return nil }
        running[requestKey]?.cancel()
        let draft = drafts[requestKey] ?? ""
        guard let id = assistantIDs[requestKey] else { return nil }
        let m = try? await conversationService.transition(messageID: id, to: .cancelled) { m in
            m.text = draft
            m.errorDescription = "用户已取消，草稿已保留，可重试。"
        }
        _ = try? await deps.tasks.finish(idempotencyKey: requestKey, status: .cancelled, resultRef: id, errorCode: "cancelled")
        return m
    }

    private func execute(_ request: DiscussionRequest, traceID: String,
                         onEvent: @escaping @Sendable (DiscussionEvent) async -> Void) async throws -> Message {
        let key = request.requestKey
        guard let conversation = try await deps.conversations.conversation(id: request.conversationID) else {
            _ = try? await deps.tasks.finish(idempotencyKey: key, status: .failed, errorCode: "conversation_not_found")
            throw DiscussionError.conversationNotFound
        }
        guard let userMessage = try await deps.conversations.message(id: request.userMessageID), userMessage.role == .user else {
            _ = try? await deps.tasks.finish(idempotencyKey: key, status: .failed, errorCode: "user_message_not_found")
            throw DiscussionError.userMessageNotFound
        }
        let now = deps.clock.now()
        let assistant = Message(id: deps.ids.make("msg"), conversationID: conversation.id, role: .assistant, text: "",
                                status: .preparing, requestKey: key, replyTo: userMessage.id, traceID: traceID,
                                scopeMode: conversation.scopeMode, createdAt: now, updatedAt: now)
        try await deps.conversations.save(assistant)
        let gate = CompletionGate<Message>()
        gates[key] = gate
        assistantIDs[key] = assistant.id
        drafts[key] = ""
        await onEvent(.started(assistantMessageID: assistant.id, traceID: traceID))
        await onEvent(.status(.preparing))

        let pipeline = DiscussionPipeline(deps: deps, conversation: conversation, question: userMessage.text,
                                          selection: request.selection, assistant: assistant, traceID: traceID,
                                          conversationService: conversationService)
        let task = Task<Message, Error> {
            try await pipeline.run(onDraft: { text in await self.setDraft(key, text) }, onEvent: onEvent)
        }
        running[key] = task
        let outcome = await task.result
        running[key] = nil
        defer { gates[key] = nil; drafts[key] = nil; assistantIDs[key] = nil }

        switch outcome {
        case .success(let final):
            guard await gate.complete(final) else {
                // 已被取消：返回取消后的记录，丢弃迟到结果
                return try await deps.conversations.message(id: assistant.id) ?? final
            }
            let saved = try await conversationService.transition(messageID: assistant.id, to: final.status) { m in
                m.text = final.text
                m.citations = final.citations
                m.claimChecks = final.claimChecks
                m.truncated = final.truncated
                m.errorDescription = final.errorDescription
                m.scopeMode = final.scopeMode
            }
            _ = try? await deps.tasks.finish(idempotencyKey: key, status: .succeeded, resultRef: saved.id)
            await deps.trace.record(TraceEvent(traceID: traceID, stage: "storage", name: "message_saved", startedAt: deps.clock.now(),
                                               outcome: .success, attributes: ["status": saved.status.rawValue,
                                                                               "citations": "\(saved.citations.count)"]))
            await onEvent(.finished(saved))
            return saved
        case .failure(let error):
            let draft = drafts[key] ?? ""
            if await gate.isCancelled || error is CancellationError || (error as? BudgetError) == .cancelled
                || (error as? ProviderError) == .cancelled {
                _ = await gate.cancel()
                let m = try? await conversationService.transition(messageID: assistant.id, to: .cancelled) { m in
                    m.text = draft
                    m.errorDescription = "用户已取消，草稿已保留，可重试。"
                }
                _ = try? await deps.tasks.finish(idempotencyKey: key, status: .cancelled, resultRef: assistant.id, errorCode: "cancelled")
                let final = try await deps.conversations.message(id: assistant.id) ?? m ?? assistant
                await onEvent(.finished(final))
                return final
            }
            _ = await gate.fail("\(error)")
            let description = Self.describe(error)
            let m = try? await conversationService.transition(messageID: assistant.id, to: .failed) { m in
                m.text = draft
                m.errorDescription = description
            }
            let code = (error as? ProviderError)?.code ?? String(describing: error)
            _ = try? await deps.tasks.finish(idempotencyKey: key, status: .failed, resultRef: assistant.id, errorCode: code)
            await deps.trace.record(TraceEvent(traceID: traceID, stage: "discussion", name: "failed", startedAt: deps.clock.now(),
                                               outcome: .failure, errorCode: code))
            let final = try await deps.conversations.message(id: assistant.id) ?? m ?? assistant
            await onEvent(.finished(final))
            return final
        }
    }

    private func setDraft(_ key: String, _ text: String) { drafts[key] = text }

    static func describe(_ error: Error) -> String {
        if let p = error as? ProviderError { return p.userMessage }
        if let b = error as? BudgetError {
            switch b {
            case .callLimitReached: return "已达到本次讨论的调用上限，问题已保留，可重试。"
            case .deadlineExceeded: return "本次讨论超过时限（60 秒），问题已保留，可重试。"
            case .cancelled: return "已取消。"
            }
        }
        if let c = error as? ConversationError, case .illegalTransition = c { return "状态已改变（可能已取消）。" }
        return "发生错误：\(Redactor.redact(String(describing: error)))"
    }

    // MARK: 异步记忆提议

    /// 讨论完成后异步生成记忆提议（独立预算：≤2 次请求、30 秒）。失败可重试，不影响已保存讨论。
    public func proposeMemories(messageID: String) async throws -> [MemoryProposal] {
        guard let generator = deps.planner ?? deps.generator else { throw ProviderError.notConfigured("对话模型") }
        guard let message = try await deps.conversations.message(id: messageID), message.role == .assistant,
              message.status.isTerminal, message.status != .failed, message.status != .cancelled else { return [] }
        let key = "memory:\(messageID)"
        let record: AgentTaskRecord
        switch try await deps.tasks.begin(kind: .memoryProposal, idempotencyKey: key) {
        case .alreadySucceeded, .alreadyRunning:
            return try await deps.brain.proposals(status: nil).filter { $0.messageID == messageID }
        case .started(let r): record = r
        }
        do {
            let budget = TaskBudget(limits: deps.memoryLimits, clock: deps.clock)
            let executor = BoundedExecutor(budget: budget, clock: deps.clock, sleeper: deps.sleeper, trace: deps.trace, traceID: record.traceID)
            let conversations = deps.conversations
            let userText = try await message.replyTo.asyncMap { try await conversations.message(id: $0)?.text } ?? ""
            let validCitations = message.citations.filter(\.structurallyValid)
            var evidenceByLabel: [String: EvidenceRef] = [:]
            for c in validCitations {
                switch c.kind {
                case .bookText, .annotation:
                    if let l = c.locator {
                        evidenceByLabel[c.label] = .book(l.bookID, version: l.bookVersion, chapter: l.chapterIndex, range: l.range, quote: c.quote)
                    }
                case .reflection:
                    evidenceByLabel[c.label] = .reflection(c.sourceRecordID ?? c.evidenceID, bookID: c.bookID, quote: c.quote)
                case .memory, .history:
                    continue
                }
            }
            let existing = try await deps.brain.items(kinds: nil, includeInactive: false)
            let prompt = ProposalParser.promptMessages(question: userText, answer: message.text,
                                                       evidence: validCitations.map { ($0.label, $0.quote) }, existing: existing)
            let request = ChatRequest(messages: prompt.map { ChatMessage(role: ChatRole(rawValue: $0.role) ?? .user, content: $0.content) },
                                      maxOutputTokens: deps.memoryLimits.maxOutputTokens, temperature: 0.2, jsonMode: true,
                                      stage: "memory_proposal")
            let response: ChatResponse = try await executor.run(stage: "memory_proposal", model: generator.modelID, retry: .standard,
                                                  timeout: 25, usage: { $0.usage }) {
                try await generator.complete(request)
            }
            let context = ProposalContext(conversationID: message.conversationID, messageID: messageID,
                                          evidenceByLabel: evidenceByLabel, scope: nil)
            let parsed = try ProposalParser.parse(response.text, context: context, existing: existing)
            let service = BrainService(repository: deps.brain, clock: deps.clock, ids: deps.ids)
            let proposals = try await service.submit(parsed.actions, context: context)
            _ = try await deps.tasks.finish(idempotencyKey: key, status: .succeeded, resultRef: messageID)
            return proposals
        } catch {
            _ = try? await deps.tasks.finish(idempotencyKey: key, status: .failed, errorCode: (error as? ProviderError)?.code ?? "\(error)")
            throw error
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let v = self else { return nil }
        return try await transform(v)
    }
}
