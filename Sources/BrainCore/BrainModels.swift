import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore
import RetrievalCore

/// 思考与记忆类型（MEM-01）。
public enum BrainItemKind: String, Codable, Sendable, CaseIterable {
    /// 观点/思考。
    case thought
    /// 待解问题。
    case question
    /// 可复用记忆。
    case memory

    public var displayName: String {
        switch self {
        case .thought: return "观点"
        case .question: return "问题"
        case .memory: return "记忆"
        }
    }
}

public enum BrainItemStatus: String, Codable, Sendable {
    case active, archived, deleted
}

/// 来源：用户直接创建，或经用户确认的模型提议（自动建议与用户结论可区分，MEM-03）。
public enum BrainOrigin: String, Codable, Sendable {
    case user
    case confirmedProposal
}

public enum EvidenceRefKind: String, Codable, Sendable {
    case bookText
    case reflection
    case message
}

/// 记忆的证据引用。来源删除/修订后标记失效，不保留伪装有效的孤立记录（统一规则 3）。
public struct EvidenceRef: Codable, Hashable, Sendable {
    public var kind: EvidenceRefKind
    public var bookID: BookID?
    public var bookVersion: String?
    public var chapterIndex: Int?
    public var range: TextSpan?
    public var recordID: String?
    public var quote: String
    public var isValid: Bool
    public var invalidReason: String?

    public init(kind: EvidenceRefKind, bookID: BookID?, bookVersion: String? = nil, chapterIndex: Int? = nil,
                range: TextSpan? = nil, recordID: String? = nil, quote: String, isValid: Bool = true, invalidReason: String? = nil) {
        self.kind = kind; self.bookID = bookID; self.bookVersion = bookVersion; self.chapterIndex = chapterIndex
        self.range = range; self.recordID = recordID; self.quote = quote; self.isValid = isValid; self.invalidReason = invalidReason
    }

    public static func book(_ bookID: BookID, version: String, chapter: Int, range: TextSpan, quote: String) -> EvidenceRef {
        EvidenceRef(kind: .bookText, bookID: bookID, bookVersion: version, chapterIndex: chapter, range: range, quote: quote)
    }

    public static func reflection(_ id: String, bookID: BookID?, quote: String) -> EvidenceRef {
        EvidenceRef(kind: .reflection, bookID: bookID, recordID: id, quote: quote)
    }

    /// 同一来源（用于提议校验与去重）。
    public func sameSource(as other: EvidenceRef) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .bookText:
            return bookID == other.bookID && bookVersion == other.bookVersion && chapterIndex == other.chapterIndex
                && (range.flatMap { r in other.range.map { r.overlaps($0) || r == $0 } } ?? false)
        case .reflection, .message:
            return recordID == other.recordID
        }
    }
}

public struct BrainItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: BrainItemKind
    public var content: String
    public var status: BrainItemStatus
    public var origin: BrainOrigin
    public var evidence: [EvidenceRef]
    public var revision: Int
    public var sourceProposalID: String?
    public var resolved: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, kind: BrainItemKind, content: String, status: BrainItemStatus = .active, origin: BrainOrigin,
                evidence: [EvidenceRef], revision: Int = 1, sourceProposalID: String? = nil, resolved: Bool = false,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.kind = kind; self.content = content; self.status = status; self.origin = origin
        self.evidence = evidence; self.revision = revision; self.sourceProposalID = sourceProposalID
        self.resolved = resolved; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// 至少有一条原文证据且全部有效。
    public var hasValidBookEvidence: Bool {
        evidence.contains { $0.kind == .bookText && $0.isValid }
    }

    /// 存在已失效的来源。
    public var hasInvalidEvidence: Bool { evidence.contains { !$0.isValid } }

    public var bookIDs: Set<BookID> { Set(evidence.compactMap(\.bookID)) }
}

public enum RelationType: String, Codable, Sendable, CaseIterable {
    case supports, conflicts, complements, extends

    public var displayName: String {
        switch self {
        case .supports: return "支持"
        case .conflicts: return "冲突"
        case .complements: return "补充"
        case .extends: return "延伸"
        }
    }
}

public enum RelationOrigin: String, Codable, Sendable {
    /// 模型建议（经确认后写入，但仍标记为建议来源）。
    case suggested
    /// 用户自己建立的关系。
    case user
}

public struct Relation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fromID: String
    public var toID: String
    public var type: RelationType
    public var origin: RelationOrigin
    public var createdAt: Date

    public init(id: String, fromID: String, toID: String, type: RelationType, origin: RelationOrigin, createdAt: Date) {
        self.id = id; self.fromID = fromID; self.toID = toID; self.type = type; self.origin = origin; self.createdAt = createdAt
    }
}

/// 修订历史（MEM-04）：前后内容、时间和原因。
public struct Revision: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var itemID: String
    public var number: Int
    public var before: String
    public var after: String
    public var reason: String
    public var origin: BrainOrigin
    public var at: Date

    public init(id: String, itemID: String, number: Int, before: String, after: String, reason: String, origin: BrainOrigin, at: Date) {
        self.id = id; self.itemID = itemID; self.number = number; self.before = before; self.after = after
        self.reason = reason; self.origin = origin; self.at = at
    }
}

/// 模型提议的动作。
public enum ProposalAction: Codable, Hashable, Sendable {
    case create(kind: BrainItemKind, content: String, evidence: [EvidenceRef])
    case link(fromID: String, toID: String, type: RelationType)
    case revise(itemID: String, baseRevision: Int, newContent: String, reason: String)

    public var summary: String {
        switch self {
        case .create(let k, let c, _): return "新增\(k.displayName)：\(c)"
        case .link(let f, let t, let type): return "关联 \(f) → \(t)（\(type.displayName)）"
        case .revise(let id, _, let c, let r): return "修订 \(id)：\(c)（原因：\(r)）"
        }
    }

    /// 动作指纹，用于幂等键。
    public var fingerprint: String {
        switch self {
        case .create(let k, let c, _): return Fingerprint.short("create|\(k.rawValue)|\(c.normalizedForComparison)", length: 16)
        case .link(let f, let t, let type): return Fingerprint.short("link|\(f)|\(t)|\(type.rawValue)", length: 16)
        case .revise(let id, let base, let c, _): return Fingerprint.short("revise|\(id)|\(base)|\(c.normalizedForComparison)", length: 16)
        }
    }
}

public enum ProposalStatus: String, Codable, Sendable {
    case pending
    case confirmed
    case rejected
    /// 未通过格式/来源/重复/冲突校验，不能确认。
    case invalid
}

/// 记忆更新提议：先作为候选保存，经校验和用户确认后才生效（MEM-02、统一规则 4）。
public struct MemoryProposal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var idempotencyKey: String
    public var conversationID: String?
    public var messageID: String?
    public var action: ProposalAction
    public var rationale: String
    public var status: ProposalStatus
    public var issues: [String]
    public var createdAt: Date
    public var decidedAt: Date?
    public var resultItemID: String?

    public init(id: String, idempotencyKey: String, conversationID: String?, messageID: String?, action: ProposalAction,
                rationale: String, status: ProposalStatus, issues: [String], createdAt: Date, decidedAt: Date? = nil,
                resultItemID: String? = nil) {
        self.id = id; self.idempotencyKey = idempotencyKey; self.conversationID = conversationID; self.messageID = messageID
        self.action = action; self.rationale = rationale; self.status = status; self.issues = issues
        self.createdAt = createdAt; self.decidedAt = decidedAt; self.resultItemID = resultItemID
    }
}

/// 文本相似度（字符二元组 Jaccard），用于重复检测。
public enum TextSimilarity {
    public static func jaccard(_ a: String, _ b: String) -> Double {
        let sa = bigrams(a.normalizedForComparison), sb = bigrams(b.normalizedForComparison)
        guard !sa.isEmpty || !sb.isEmpty else { return 1 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0]) + String(chars[$0 + 1]) })
    }
}
