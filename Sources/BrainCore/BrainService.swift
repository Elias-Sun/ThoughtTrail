import Foundation
import LibraryCore
import ReadingSessionCore
import RetrievalCore

public protocol BrainRepository: Sendable {
    func save(_ item: BrainItem) async throws
    func item(id: String) async throws -> BrainItem?
    func items(kinds: [BrainItemKind]?, includeInactive: Bool) async throws -> [BrainItem]
    func save(_ relation: Relation) async throws
    func relations(itemID: String) async throws -> [Relation]
    func allRelations() async throws -> [Relation]
    func deleteRelation(id: String) async throws
    func appendRevision(_ revision: Revision) async throws
    func revisions(itemID: String) async throws -> [Revision]
    func save(_ proposal: MemoryProposal) async throws
    func proposal(id: String) async throws -> MemoryProposal?
    func proposal(idempotencyKey: String) async throws -> MemoryProposal?
    func proposals(status: ProposalStatus?) async throws -> [MemoryProposal]
    /// 在单个事务中应用一组写入（确认提议时使用）。
    func applyAtomically(items: [BrainItem], relations: [Relation], revisions: [Revision], proposal: MemoryProposal) async throws
}

public enum BrainError: Error, Equatable, Sendable {
    case emptyContent
    case contentTooLong
    case notFound
    /// 修改时基于的版本已过期：冲突不能静默覆盖（MEM-04）。
    case revisionConflict(expected: Int, actual: Int)
    case proposalNotPending(ProposalStatus)
    case proposalInvalid([String])
    case selfRelation
}

/// 提议校验上下文：本次讨论允许作为来源的证据。
public struct ProposalContext: Sendable {
    public var conversationID: String?
    public var messageID: String?
    /// 讨论中可用证据标签 → 证据引用。
    public var evidenceByLabel: [String: EvidenceRef]
    public var scope: RetrievalScope?

    public init(conversationID: String?, messageID: String?, evidenceByLabel: [String: EvidenceRef], scope: RetrievalScope?) {
        self.conversationID = conversationID; self.messageID = messageID
        self.evidenceByLabel = evidenceByLabel; self.scope = scope
    }
}

/// 提议校验：格式、来源、重复与冲突（MEM-02/04）。
public struct ProposalValidator: Sendable {
    public static let maxContentLength = 2_000
    public static let duplicateThreshold = 0.8

    public init() {}

    public func issues(for action: ProposalAction, existing: [BrainItem], relations: [Relation],
                       context: ProposalContext) -> [String] {
        var issues: [String] = []
        switch action {
        case .create(let kind, let content, let evidence):
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { issues.append("empty_content") }
            if trimmed.count > Self.maxContentLength { issues.append("content_too_long") }
            if kind != .question && evidence.isEmpty { issues.append("missing_evidence") }
            let allowed = Array(context.evidenceByLabel.values)
            for ref in evidence where !allowed.contains(where: { $0.sameSource(as: ref) }) {
                issues.append("evidence_not_from_discussion")
                break
            }
            if let scope = context.scope {
                for ref in evidence where ref.kind == .bookText {
                    guard let b = ref.bookID, let v = ref.bookVersion, let c = ref.chapterIndex, let r = ref.range,
                          scope.allows(bookID: b, version: v, chapterIndex: c, range: r) else {
                        issues.append("evidence_out_of_scope"); break
                    }
                }
            }
            if let dup = existing.first(where: { $0.status == .active && $0.kind == kind
                && TextSimilarity.jaccard($0.content, trimmed) >= Self.duplicateThreshold }) {
                issues.append("duplicate_of:\(dup.id)")
            }
        case .link(let from, let to, let type):
            if from == to { issues.append("self_relation") }
            for id in [from, to] where !existing.contains(where: { $0.id == id && $0.status == .active }) {
                issues.append("unknown_item:\(id)")
            }
            if relations.contains(where: { $0.fromID == from && $0.toID == to && $0.type == type }) {
                issues.append("relation_exists")
            }
        case .revise(let itemID, let base, let newContent, let reason):
            guard let item = existing.first(where: { $0.id == itemID && $0.status == .active }) else {
                issues.append("unknown_item:\(itemID)"); break
            }
            if item.revision != base { issues.append("revision_conflict:\(base)->\(item.revision)") }
            let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { issues.append("empty_content") }
            if trimmed.count > Self.maxContentLength { issues.append("content_too_long") }
            if trimmed == item.content { issues.append("no_change") }
            if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("missing_reason") }
        }
        return issues
    }
}

/// 思考与记忆服务。
public actor BrainService {
    private let repository: BrainRepository
    private let clock: WallClock
    private let ids: IDGenerating
    private let validator = ProposalValidator()

    public init(repository: BrainRepository, clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator()) {
        self.repository = repository; self.clock = clock; self.ids = ids
    }

    // MARK: 用户直接操作

    public func create(kind: BrainItemKind, content: String, evidence: [EvidenceRef] = []) async throws -> BrainItem {
        let trimmed = try Self.validContent(content)
        let now = clock.now()
        let item = BrainItem(id: ids.make("brain"), kind: kind, content: trimmed, origin: .user, evidence: evidence,
                             createdAt: now, updatedAt: now)
        try await repository.save(item)
        return item
    }

    /// 编辑：必须基于当前版本；保留修订记录。
    public func edit(itemID: String, expectedRevision: Int, newContent: String, reason: String) async throws -> BrainItem {
        guard var item = try await repository.item(id: itemID), item.status != .deleted else { throw BrainError.notFound }
        guard item.revision == expectedRevision else {
            throw BrainError.revisionConflict(expected: expectedRevision, actual: item.revision)
        }
        let trimmed = try Self.validContent(newContent)
        guard trimmed != item.content else { return item }
        let now = clock.now()
        let rev = Revision(id: ids.make("rev"), itemID: itemID, number: item.revision + 1, before: item.content, after: trimmed,
                           reason: reason.isEmpty ? "用户编辑" : reason, origin: .user, at: now)
        item.content = trimmed
        item.revision += 1
        item.updatedAt = now
        try await repository.appendRevision(rev)
        try await repository.save(item)
        return item
    }

    public func setStatus(itemID: String, status: BrainItemStatus) async throws {
        guard var item = try await repository.item(id: itemID) else { throw BrainError.notFound }
        item.status = status
        item.updatedAt = clock.now()
        try await repository.save(item)
    }

    public func markResolved(questionID: String, resolved: Bool) async throws {
        guard var item = try await repository.item(id: questionID), item.kind == .question else { throw BrainError.notFound }
        item.resolved = resolved
        item.updatedAt = clock.now()
        try await repository.save(item)
    }

    public func link(from: String, to: String, type: RelationType) async throws -> Relation {
        guard from != to else { throw BrainError.selfRelation }
        guard try await repository.item(id: from) != nil, try await repository.item(id: to) != nil else { throw BrainError.notFound }
        if let existing = try await repository.relations(itemID: from).first(where: { $0.fromID == from && $0.toID == to && $0.type == type }) {
            return existing
        }
        let r = Relation(id: ids.make("rel"), fromID: from, toID: to, type: type, origin: .user, createdAt: clock.now())
        try await repository.save(r)
        return r
    }

    public func revisions(itemID: String) async throws -> [Revision] {
        try await repository.revisions(itemID: itemID).sorted { $0.number < $1.number }
    }

    public func relations(itemID: String) async throws -> [Relation] {
        try await repository.relations(itemID: itemID)
    }

    /// 搜索（MEM-01）：按内容词项匹配，默认只返回有效条目。
    public func search(_ query: String, kinds: [BrainItemKind]? = nil) async throws -> [BrainItem] {
        let items = try await repository.items(kinds: kinds, includeInactive: false)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items.sorted { $0.updatedAt > $1.updatedAt } }
        let segmenter = TextSegmenter()
        let qTokens = Set(segmenter.tokens(q))
        return items.compactMap { item -> (BrainItem, Int)? in
            let overlap = Set(segmenter.tokens(item.content)).intersection(qTokens).count
            return overlap > 0 || item.content.localizedCaseInsensitiveContains(q) ? (item, overlap) : nil
        }.sorted { $0.1 == $1.1 ? $0.0.updatedAt > $1.0.updatedAt : $0.1 > $1.1 }.map(\.0)
    }

    // MARK: 提议

    /// 保存提议。同一讨论/消息/动作重复提交返回已有提议，不生成重复记录（MEM-04）。
    public func submit(_ actions: [(ProposalAction, String)], context: ProposalContext) async throws -> [MemoryProposal] {
        let existing = try await repository.items(kinds: nil, includeInactive: false)
        let relations = try await repository.allRelations()
        var out: [MemoryProposal] = []
        for (action, rationale) in actions {
            let key = "\(context.conversationID ?? "-"):\(context.messageID ?? "-"):\(action.fingerprint)"
            if let prior = try await repository.proposal(idempotencyKey: key) { out.append(prior); continue }
            let issues = validator.issues(for: action, existing: existing, relations: relations, context: context)
            let p = MemoryProposal(id: ids.make("prop"), idempotencyKey: key, conversationID: context.conversationID,
                                   messageID: context.messageID, action: action, rationale: rationale,
                                   status: issues.isEmpty ? .pending : .invalid, issues: issues, createdAt: clock.now())
            try await repository.save(p)
            out.append(p)
        }
        return out
    }

    /// 用户确认：重新校验后原子写入。
    public func confirm(proposalID: String) async throws -> MemoryProposal {
        guard var p = try await repository.proposal(id: proposalID) else { throw BrainError.notFound }
        if p.status == .confirmed { return p }
        guard p.status == .pending else { throw BrainError.proposalNotPending(p.status) }
        let existing = try await repository.items(kinds: nil, includeInactive: false)
        let relations = try await repository.allRelations()
        // 确认时状态可能已变化：只重新检查重复/冲突/存在性（来源已在提交时校验）
        let recheck = validator.issues(for: p.action, existing: existing, relations: relations,
                                       context: ProposalContext(conversationID: nil, messageID: nil,
                                                                evidenceByLabel: Self.evidenceMap(p.action), scope: nil))
        guard recheck.isEmpty else {
            p.status = .invalid; p.issues = recheck; p.decidedAt = clock.now()
            try await repository.save(p)
            throw BrainError.proposalInvalid(recheck)
        }
        let now = clock.now()
        var items: [BrainItem] = []
        var rels: [Relation] = []
        var revs: [Revision] = []
        switch p.action {
        case .create(let kind, let content, let evidence):
            let item = BrainItem(id: ids.make("brain"), kind: kind, content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                                 origin: .confirmedProposal, evidence: evidence, sourceProposalID: p.id, createdAt: now, updatedAt: now)
            items.append(item)
            p.resultItemID = item.id
        case .link(let from, let to, let type):
            let r = Relation(id: ids.make("rel"), fromID: from, toID: to, type: type, origin: .suggested, createdAt: now)
            rels.append(r)
            p.resultItemID = r.id
        case .revise(let itemID, _, let newContent, let reason):
            guard var item = existing.first(where: { $0.id == itemID }) else { throw BrainError.notFound }
            revs.append(Revision(id: ids.make("rev"), itemID: itemID, number: item.revision + 1, before: item.content,
                                 after: newContent, reason: reason, origin: .confirmedProposal, at: now))
            item.content = newContent
            item.revision += 1
            item.updatedAt = now
            items.append(item)
            p.resultItemID = itemID
        }
        p.status = .confirmed
        p.decidedAt = now
        try await repository.applyAtomically(items: items, relations: rels, revisions: revs, proposal: p)
        return p
    }

    /// 拒绝：只改变提议状态，不写入任何条目。
    public func reject(proposalID: String) async throws -> MemoryProposal {
        guard var p = try await repository.proposal(id: proposalID) else { throw BrainError.notFound }
        if p.status == .rejected { return p }
        guard p.status == .pending || p.status == .invalid else { throw BrainError.proposalNotPending(p.status) }
        p.status = .rejected
        p.decidedAt = clock.now()
        try await repository.save(p)
        return p
    }

    public func pendingProposals() async throws -> [MemoryProposal] {
        try await repository.proposals(status: .pending).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: 来源失效

    /// 书籍被删除或版本失效：标记相关证据失效（统一规则 3）。返回受影响条目。
    @discardableResult
    public func invalidateBookSources(bookID: BookID, reason: String) async throws -> [BrainItem] {
        try await updateEvidence { ref in
            ref.bookID == bookID && ref.kind == .bookText ? (false, reason) : nil
        }
    }

    @discardableResult
    public func restoreBookSources(bookID: BookID, version: String) async throws -> [BrainItem] {
        try await updateEvidence { ref in
            ref.bookID == bookID && ref.kind == .bookText && ref.bookVersion == version && !ref.isValid ? (true, nil) : nil
        }
    }

    @discardableResult
    public func invalidateReflection(id: String, reason: String) async throws -> [BrainItem] {
        try await updateEvidence { ref in
            ref.kind == .reflection && ref.recordID == id ? (false, reason) : nil
        }
    }

    private func updateEvidence(_ change: (EvidenceRef) -> (Bool, String?)?) async throws -> [BrainItem] {
        var affected: [BrainItem] = []
        for var item in try await repository.items(kinds: nil, includeInactive: true) {
            var changed = false
            for i in item.evidence.indices {
                if let (valid, reason) = change(item.evidence[i]), item.evidence[i].isValid != valid {
                    item.evidence[i].isValid = valid
                    item.evidence[i].invalidReason = reason
                    changed = true
                }
            }
            if changed {
                item.updatedAt = clock.now()
                try await repository.save(item)
                affected.append(item)
            }
        }
        return affected
    }

    static func validContent(_ s: String) throws -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrainError.emptyContent }
        guard trimmed.count <= ProposalValidator.maxContentLength else { throw BrainError.contentTooLong }
        return trimmed
    }

    static func evidenceMap(_ action: ProposalAction) -> [String: EvidenceRef] {
        guard case .create(_, _, let ev) = action else { return [:] }
        return Dictionary(uniqueKeysWithValues: ev.enumerated().map { ("R\($0.offset)", $0.element) })
    }
}

/// 跨书再关联（MEM-05）：只召回允许范围内、已确认、来源有效的记忆。
public struct MemoryRecall: Sendable {
    public struct Recalled: Sendable, Hashable {
        public var item: BrainItem
        public var score: Double
        /// 仅有个人来源（反思/无证据）：不能作为书籍证据展示。
        public var personalOnly: Bool
    }

    public struct Outcome: Sendable {
        public var recalled: [Recalled]
        public var excludedOutOfScope: Int
        public var excludedInvalidSource: Int
    }

    public init() {}

    public func recall(query: String, items: [BrainItem], scope: RetrievalScope, limit: Int = 5) -> Outcome {
        let segmenter = TextSegmenter()
        let qTokens = Set(segmenter.tokens(query))
        var out: [Recalled] = []
        var outOfScope = 0, invalid = 0
        for item in items where item.status == .active && item.kind != .question {
            // 来源越界：整条排除，避免摘要泄露未读内容
            let bookRefs = item.evidence.filter { $0.kind == .bookText }
            let violates = bookRefs.contains { ref in
                guard let b = ref.bookID, let v = ref.bookVersion, let c = ref.chapterIndex, let r = ref.range else { return true }
                return !scope.allows(bookID: b, version: v, chapterIndex: c, range: r)
            }
            let foreignBook = item.evidence.contains { ref in ref.bookID.map { scope.scopes[$0] == nil } ?? false }
            if violates || foreignBook { outOfScope += 1; continue }
            if !item.evidence.isEmpty && item.evidence.allSatisfy({ !$0.isValid }) { invalid += 1; continue }
            if bookRefs.contains(where: { !$0.isValid }) { invalid += 1; continue }
            guard !qTokens.isEmpty else { continue }
            let tokens = Set(segmenter.tokens(item.content))
            let overlap = Double(tokens.intersection(qTokens).count)
            guard overlap > 0 else { continue }
            let score = overlap / Double(max(1, qTokens.count))
            out.append(Recalled(item: item, score: score, personalOnly: !item.hasValidBookEvidence))
        }
        out.sort { $0.score == $1.score ? $0.item.id < $1.item.id : $0.score > $1.score }
        return Outcome(recalled: Array(out.prefix(limit)), excludedOutOfScope: outOfScope, excludedInvalidSource: invalid)
    }
}
