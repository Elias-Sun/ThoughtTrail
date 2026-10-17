import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore

/// 证据来源类别：回答可说明依据来自原文、批注、反思、长期记忆还是一般知识（CHAT-01/03）。
public enum EvidenceSourceKind: String, Codable, Sendable, CaseIterable {
    case bookText
    case annotation
    case reflection
    case memory
    case history
}

/// 单条引用的核查结论。
public enum ClaimVerdictLabel: String, Codable, Sendable, CaseIterable {
    case supported
    case insufficient
    case contradicted
    case unknown
}

/// 消息中保存的证据快照：回答保存时冻结来源文本与定位（统一规则 1、REF-01）。
public struct CitationSnapshot: Codable, Hashable, Sendable {
    public var label: String
    public var evidenceID: String
    public var kind: EvidenceSourceKind
    public var bookID: BookID?
    public var bookVersion: String?
    public var locator: Locator?
    public var sourceRecordID: String?
    public var quote: String
    /// 结构校验是否通过（EVID-01）。未通过的引用不会作为“已核查依据”展示。
    public var structurallyValid: Bool

    public init(label: String, evidenceID: String, kind: EvidenceSourceKind, bookID: BookID?, bookVersion: String?,
                locator: Locator?, sourceRecordID: String?, quote: String, structurallyValid: Bool) {
        self.label = label; self.evidenceID = evidenceID; self.kind = kind; self.bookID = bookID
        self.bookVersion = bookVersion; self.locator = locator; self.sourceRecordID = sourceRecordID
        self.quote = quote; self.structurallyValid = structurallyValid
    }
}

/// 回答中关键陈述的核查结果快照。
public struct ClaimCheckSnapshot: Codable, Hashable, Sendable {
    public var claim: String
    public var labels: [String]
    public var verdict: ClaimVerdictLabel
    public var reason: String
    public var isGeneralKnowledge: Bool

    public init(claim: String, labels: [String], verdict: ClaimVerdictLabel, reason: String, isGeneralKnowledge: Bool) {
        self.claim = claim; self.labels = labels; self.verdict = verdict; self.reason = reason
        self.isGeneralKnowledge = isGeneralKnowledge
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user, assistant
}

/// 消息生成与核查状态（CHAT-02/04）。生成完成 ≠ 核查通过。
public enum MessageStatus: String, Codable, Sendable, CaseIterable {
    /// 用户消息已保存。
    case sent
    /// 正在检索/规划。
    case preparing
    /// 正在流式生成草稿。
    case drafting
    /// 草稿已生成，正在核查。
    case verifying
    /// 所有关键陈述均获证据支持。
    case verified
    /// 部分陈述证据不足或存在矛盾。
    case needsAttention
    /// 没有找到足够依据。
    case insufficientEvidence
    /// 核查失败（超时/解析失败），回答可展示但不是“已核查”。
    case verificationUnavailable
    /// 用户取消。草稿保留，可重试。
    case cancelled
    /// 生成失败（网络、鉴权、超时等）。用户问题保留，可重试。
    case failed

    public var isTerminal: Bool {
        switch self {
        case .sent, .preparing, .drafting, .verifying: return false
        default: return true
        }
    }

    /// 只有该状态允许界面显示“已核查”。
    public var isVerifiedSuccess: Bool { self == .verified }

    /// 允许的状态迁移；终态不能被迟到响应改写。
    public func canTransition(to next: MessageStatus) -> Bool {
        if isTerminal { return false }
        switch (self, next) {
        case (.preparing, .drafting), (.preparing, .insufficientEvidence), (.preparing, .failed), (.preparing, .cancelled):
            return true
        case (.drafting, .drafting), (.drafting, .verifying), (.drafting, .failed), (.drafting, .cancelled),
             (.drafting, .insufficientEvidence), (.drafting, .verificationUnavailable):
            return true
        case (.verifying, .verified), (.verifying, .needsAttention), (.verifying, .insufficientEvidence),
             (.verifying, .verificationUnavailable), (.verifying, .cancelled), (.verifying, .failed):
            return true
        default:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .sent: return "已发送"
        case .preparing: return "准备中"
        case .drafting: return "草稿"
        case .verifying: return "核查中"
        case .verified: return "已核查"
        case .needsAttention: return "存在未获支持的陈述"
        case .insufficientEvidence: return "证据不足"
        case .verificationUnavailable: return "未能核查"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        }
    }
}

public struct Message: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var conversationID: String
    public var role: MessageRole
    public var text: String
    public var status: MessageStatus
    public var citations: [CitationSnapshot]
    public var claimChecks: [ClaimCheckSnapshot]
    /// 由请求派生的幂等键：同一请求重复触发不会产生重复回答（RUN-02）。
    public var requestKey: String?
    public var replyTo: String?
    public var errorDescription: String?
    public var traceID: String?
    public var scopeMode: ScopeMode
    public var truncated: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, conversationID: String, role: MessageRole, text: String, status: MessageStatus,
                citations: [CitationSnapshot] = [], claimChecks: [ClaimCheckSnapshot] = [], requestKey: String? = nil,
                replyTo: String? = nil, errorDescription: String? = nil, traceID: String? = nil,
                scopeMode: ScopeMode = .readOnly, truncated: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.conversationID = conversationID; self.role = role; self.text = text; self.status = status
        self.citations = citations; self.claimChecks = claimChecks; self.requestKey = requestKey
        self.replyTo = replyTo; self.errorDescription = errorDescription; self.traceID = traceID
        self.scopeMode = scopeMode; self.truncated = truncated; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct Conversation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var primaryBookID: BookID
    /// 跨书讨论时用户明确允许的其他书。
    public var additionalBookIDs: [BookID]
    public var scopeMode: ScopeMode
    public var context: ReadingContextSnapshot
    public var reflectionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, title: String, primaryBookID: BookID, additionalBookIDs: [BookID] = [],
                scopeMode: ScopeMode = .readOnly, context: ReadingContextSnapshot, reflectionID: String? = nil,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.title = title; self.primaryBookID = primaryBookID; self.additionalBookIDs = additionalBookIDs
        self.scopeMode = scopeMode; self.context = context; self.reflectionID = reflectionID
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var allBookIDs: [BookID] { [primaryBookID] + additionalBookIDs.filter { $0 != primaryBookID } }
}

public protocol ConversationRepository: Sendable {
    func save(_ conversation: Conversation) async throws
    func conversation(id: String) async throws -> Conversation?
    func conversations(bookID: BookID?) async throws -> [Conversation]
    func save(_ message: Message) async throws
    func message(id: String) async throws -> Message?
    func message(requestKey: String) async throws -> Message?
    func messages(conversationID: String) async throws -> [Message]
    func deleteConversation(id: String) async throws
}

public enum ConversationError: Error, Equatable, Sendable {
    case notFound
    case illegalTransition(from: MessageStatus, to: MessageStatus)
    case emptyQuestion
}

/// 讨论记录服务：保证状态机迁移合法，终态不可被迟到响应覆盖。
public actor ConversationService {
    private let repository: ConversationRepository
    private let clock: WallClock
    private let ids: IDGenerating

    public init(repository: ConversationRepository, clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator()) {
        self.repository = repository; self.clock = clock; self.ids = ids
    }

    public func startConversation(context: ReadingContextSnapshot, scopeMode: ScopeMode = .readOnly,
                                  additionalBookIDs: [BookID] = [], reflectionID: String? = nil, title: String? = nil) async throws -> Conversation {
        let now = clock.now()
        let defaultTitle = context.selectedText.map { "关于「\(String($0.prefix(16)))」" } ?? "\(context.bookTitle) 讨论"
        let c = Conversation(id: ids.make("conv"), title: title ?? defaultTitle, primaryBookID: context.bookID,
                             additionalBookIDs: additionalBookIDs, scopeMode: scopeMode, context: context,
                             reflectionID: reflectionID, createdAt: now, updatedAt: now)
        try await repository.save(c)
        return c
    }

    /// 切换范围必须显式调用并持久化，界面与执行记录可见。
    public func setScope(conversationID: String, mode: ScopeMode, additionalBookIDs: [BookID]? = nil) async throws -> Conversation {
        guard var c = try await repository.conversation(id: conversationID) else { throw ConversationError.notFound }
        c.scopeMode = mode
        if let extra = additionalBookIDs { c.additionalBookIDs = extra }
        c.updatedAt = clock.now()
        try await repository.save(c)
        return c
    }

    public func addUserMessage(conversationID: String, text: String) async throws -> Message {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationError.emptyQuestion }
        guard let c = try await repository.conversation(id: conversationID) else { throw ConversationError.notFound }
        let now = clock.now()
        let m = Message(id: ids.make("msg"), conversationID: conversationID, role: .user, text: trimmed, status: .sent,
                        scopeMode: c.scopeMode, createdAt: now, updatedAt: now)
        try await repository.save(m)
        return m
    }

    /// 按状态机更新消息；非法迁移（如已取消后迟到的完成）被拒绝。
    public func transition(messageID: String, to status: MessageStatus, mutate: @Sendable (inout Message) -> Void = { _ in }) async throws -> Message {
        guard var m = try await repository.message(id: messageID) else { throw ConversationError.notFound }
        guard m.status == status || m.status.canTransition(to: status) else {
            throw ConversationError.illegalTransition(from: m.status, to: status)
        }
        m.status = status
        mutate(&m)
        m.updatedAt = clock.now()
        try await repository.save(m)
        return m
    }
}
