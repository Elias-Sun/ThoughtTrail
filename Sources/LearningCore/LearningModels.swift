import Foundation
import LibraryCore
import ReaderCore
import ReadingSessionCore

public enum QuestionType: String, Codable, Sendable, CaseIterable {
    /// 理解题。
    case comprehension
    /// 解释题。
    case explanation
    /// 观点比较题。
    case comparison

    public var displayName: String {
        switch self {
        case .comprehension: return "理解"
        case .explanation: return "解释"
        case .comparison: return "观点比较"
        }
    }
}

/// 题目证据：必须可定位到已读原文（LEARN-01）。
public struct LearningEvidence: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var bookVersion: String
    public var chapterIndex: Int
    public var range: TextSpan
    public var quote: String

    public init(bookID: BookID, bookVersion: String, chapterIndex: Int, range: TextSpan, quote: String) {
        self.bookID = bookID; self.bookVersion = bookVersion; self.chapterIndex = chapterIndex; self.range = range; self.quote = quote
    }
}

public enum LearningItemStatus: String, Codable, Sendable {
    case active, retired
}

/// 一道练习题。参考要点与评分依据在作答前不展示。
public struct LearningItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var type: QuestionType
    public var prompt: String
    public var referencePoints: [String]
    public var rubric: String
    public var evidence: [LearningEvidence]
    public var knowledgePoint: String
    public var relatedMemoryIDs: [String]
    public var status: LearningItemStatus
    public var createdAt: Date

    public init(id: String, bookID: BookID, type: QuestionType, prompt: String, referencePoints: [String], rubric: String,
                evidence: [LearningEvidence], knowledgePoint: String, relatedMemoryIDs: [String] = [],
                status: LearningItemStatus = .active, createdAt: Date) {
        self.id = id; self.bookID = bookID; self.type = type; self.prompt = prompt; self.referencePoints = referencePoints
        self.rubric = rubric; self.evidence = evidence; self.knowledgePoint = knowledgePoint
        self.relatedMemoryIDs = relatedMemoryIDs; self.status = status; self.createdAt = createdAt
    }

    /// 作答前可展示的视图：不含参考要点与评分依据（防止答案泄露）。
    public var presentation: QuestionPresentation {
        QuestionPresentation(id: id, bookID: bookID, type: type, prompt: prompt, knowledgePoint: knowledgePoint,
                             chapterIndices: Array(Set(evidence.map(\.chapterIndex))).sorted())
    }

    public var dedupeKey: String { Fingerprint.short("\(bookID)|\(prompt.normalizedForComparison)", length: 16) }
}

public struct QuestionPresentation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var type: QuestionType
    public var prompt: String
    public var knowledgePoint: String
    public var chapterIndices: [Int]
}

/// 自评（作答后由用户给出）。
public enum SelfRating: Int, Codable, Sendable, CaseIterable {
    case forgot = 0, hard = 1, good = 2, easy = 3

    public var displayName: String {
        switch self {
        case .forgot: return "没想起来"
        case .hard: return "有点吃力"
        case .good: return "基本掌握"
        case .easy: return "很轻松"
        }
    }
}

/// 评分：确定分数或“不确定”（依据不足时不作确定评分，LEARN-02）。
public enum Grade: Codable, Hashable, Sendable {
    case scored(Double)
    case uncertain(String)

    public var score: Double? {
        if case .scored(let s) = self { return s }
        return nil
    }
}

public struct Attempt: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var itemID: String
    /// 原始答案（原样保存）。
    public var answer: String
    public var submittedAt: Date
    public var idempotencyKey: String
    public var selfRating: SelfRating?

    public init(id: String, itemID: String, answer: String, submittedAt: Date, idempotencyKey: String, selfRating: SelfRating? = nil) {
        self.id = id; self.itemID = itemID; self.answer = answer; self.submittedAt = submittedAt
        self.idempotencyKey = idempotencyKey; self.selfRating = selfRating
    }
}

public struct Feedback: Codable, Hashable, Sendable {
    public var attemptID: String
    public var itemID: String
    public var correctPoints: [String]
    public var missingPoints: [String]
    public var evidence: [LearningEvidence]
    public var grade: Grade
    public var rationale: String
    public var graderName: String
    public var createdAt: Date

    public init(attemptID: String, itemID: String, correctPoints: [String], missingPoints: [String], evidence: [LearningEvidence],
                grade: Grade, rationale: String, graderName: String, createdAt: Date) {
        self.attemptID = attemptID; self.itemID = itemID; self.correctPoints = correctPoints; self.missingPoints = missingPoints
        self.evidence = evidence; self.grade = grade; self.rationale = rationale; self.graderName = graderName; self.createdAt = createdAt
    }
}

public enum MasteryLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case new, learning, familiar, mastered

    public static func < (l: MasteryLevel, r: MasteryLevel) -> Bool {
        allCases.firstIndex(of: l)! < allCases.firstIndex(of: r)!
    }

    public var displayName: String {
        switch self {
        case .new: return "新"
        case .learning: return "学习中"
        case .familiar: return "熟悉"
        case .mastered: return "掌握"
        }
    }
}

/// 按知识点记录的掌握情况（LEARN-03）。一次模型评分不会被当作永久掌握。
public struct MasteryRecord: Codable, Hashable, Sendable {
    public struct Event: Codable, Hashable, Sendable {
        public var at: Date
        public var score: Double?
        public var selfRating: SelfRating?
    }

    public var knowledgePoint: String
    public var bookID: BookID
    public var attempts: Int
    public var errors: Int
    public var recent: [Event]
    /// 人工修正：在下一次作答前生效。
    public var manualLevel: MasteryLevel?
    public var manualNote: String?
    public var updatedAt: Date

    public init(knowledgePoint: String, bookID: BookID, updatedAt: Date) {
        self.knowledgePoint = knowledgePoint; self.bookID = bookID; self.attempts = 0; self.errors = 0
        self.recent = []; self.manualLevel = nil; self.manualNote = nil; self.updatedAt = updatedAt
    }

    public static let recentWindow = 5
    public static let passScore = 0.6

    public mutating func record(score: Double?, selfRating: SelfRating?, at: Date) {
        attempts += 1
        if let s = score, s < Self.passScore { errors += 1 } else if score == nil, selfRating == .forgot { errors += 1 }
        recent.append(Event(at: at, score: score, selfRating: selfRating))
        if recent.count > Self.recentWindow { recent.removeFirst(recent.count - Self.recentWindow) }
        manualLevel = nil
        updatedAt = at
    }

    /// 掌握等级：人工修正优先；“掌握”至少需要最近两次独立作答均通过。
    public var level: MasteryLevel {
        if let manualLevel { return manualLevel }
        guard !recent.isEmpty else { return .new }
        let passes = recent.map { e -> Bool in
            if let s = e.score { return s >= Self.passScore }
            return (e.selfRating?.rawValue ?? 0) >= SelfRating.good.rawValue
        }
        let lastTwo = passes.suffix(2)
        if lastTwo.count == 2 && lastTwo.allSatisfy({ $0 }) && attempts >= 2 { return .mastered }
        if passes.last == true { return .familiar }
        return .learning
    }
}
