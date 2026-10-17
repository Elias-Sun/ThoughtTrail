import Foundation
import LibraryCore

/// 数据集清单（9.1）：版本、划分、冻结哈希与标注状态。
public struct DatasetManifest: Codable, Hashable, Sendable {
    public enum Split: String, Codable, Sendable { case dev, acceptance }
    public enum AnnotationStatus: String, Codable, Sendable {
        /// 开发者自拟、未经独立人工复核：不能作为最终验收依据。
        case draftUnreviewed = "draft_unreviewed"
        case humanReviewed = "human_reviewed"
    }

    public var name: String
    public var version: String
    public var split: Split
    public var annotationStatus: AnnotationStatus
    public var description: String
    /// 冻结时记录的数据文件 SHA-256；评测时校验未被改动。
    public var frozenSHA256: String?

    public init(name: String, version: String, split: Split, annotationStatus: AnnotationStatus, description: String, frozenSHA256: String? = nil) {
        self.name = name; self.version = version; self.split = split; self.annotationStatus = annotationStatus
        self.description = description; self.frozenSHA256 = frozenSHA256
    }
}

/// 标注的相关证据区间（grade 1–3，用于 nDCG）。
public struct RelevantSpan: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var chapterIndex: Int
    public var start: Int
    public var end: Int
    public var grade: Int

    public init(bookID: BookID, chapterIndex: Int, start: Int, end: Int, grade: Int = 1) {
        self.bookID = bookID; self.chapterIndex = chapterIndex; self.start = start; self.end = end; self.grade = max(1, grade)
    }

    public var range: TextSpan { TextSpan(start: start, end: end) }
}

/// 检索结果中的一个区间（评测输入）。
public struct RetrievedSpan: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var chapterIndex: Int
    public var start: Int
    public var end: Int

    public init(bookID: BookID, chapterIndex: Int, start: Int, end: Int) {
        self.bookID = bookID; self.chapterIndex = chapterIndex; self.start = start; self.end = end
    }

    public var range: TextSpan { TextSpan(start: start, end: end) }
}

/// 阅读范围设定：每本书已读的章节（整章）及可选的章内区间。
public struct ScopeSpec: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var readChapters: [Int]
    public var partialRanges: [PartialRange]?
    public var wholeBook: Bool?

    public struct PartialRange: Codable, Hashable, Sendable {
        public var chapterIndex: Int
        public var start: Int
        public var end: Int

        public init(chapterIndex: Int, start: Int, end: Int) {
            self.chapterIndex = chapterIndex; self.start = start; self.end = end
        }
    }

    public init(bookID: BookID, readChapters: [Int], partialRanges: [PartialRange]? = nil, wholeBook: Bool? = nil) {
        self.bookID = bookID; self.readChapters = readChapters; self.partialRanges = partialRanges; self.wholeBook = wholeBook
    }
}

public enum RetrievalCategory: String, Codable, Sendable, CaseIterable {
    case local, crossChapter, crossBook, annotationMemory, unanswerable
}

public struct RetrievalCase: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var category: RetrievalCategory
    public var question: String
    public var scopes: [ScopeSpec]
    public var relevant: [RelevantSpan]
    public var note: String?

    public init(id: String, category: RetrievalCategory, question: String, scopes: [ScopeSpec], relevant: [RelevantSpan], note: String?) {
        self.id = id; self.category = category; self.question = question; self.scopes = scopes; self.relevant = relevant; self.note = note
    }

    public var answerable: Bool { category != .unanswerable && !relevant.isEmpty }
}

public struct VerificationCase: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var claim: String
    public var evidence: [String]
    /// supported | insufficient | contradicted
    public var label: String
    /// 扰动类型：number / negation / condition / subject / time / none
    public var perturbation: String?

    public init(id: String, claim: String, evidence: [String], label: String, perturbation: String?) {
        self.id = id; self.claim = claim; self.evidence = evidence; self.label = label; self.perturbation = perturbation
    }
}

public struct BoundaryCase: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var query: String
    public var scopes: [ScopeSpec]
    public var note: String?

    public init(id: String, kind: String, query: String, scopes: [ScopeSpec], note: String?) {
        self.id = id; self.kind = kind; self.query = query; self.scopes = scopes; self.note = note
    }
}

public struct MemoryCase: Codable, Hashable, Sendable, Identifiable {
    public struct ExistingItem: Codable, Hashable, Sendable {
        public var id: String
        public var kind: String
        public var content: String
        public var revision: Int?

        public init(id: String, kind: String, content: String, revision: Int?) {
            self.id = id; self.kind = kind; self.content = content; self.revision = revision
        }
    }
    public var id: String
    public var kind: String
    public var existing: [ExistingItem]
    /// create | link | revise
    public var action: String
    public var content: String?
    public var targetID: String?
    public var linkToID: String?
    public var baseRevision: Int?
    public var evidenceAllowed: Bool
    public var evidenceInScope: Bool?
    /// pending | invalid
    public var expectedStatus: String
    public var expectedIssuePrefix: String?

    public init(id: String, kind: String, existing: [ExistingItem], action: String, content: String?, targetID: String?, linkToID: String?,
                baseRevision: Int?, evidenceAllowed: Bool, evidenceInScope: Bool?, expectedStatus: String, expectedIssuePrefix: String?) {
        self.id = id; self.kind = kind; self.existing = existing; self.action = action; self.content = content; self.targetID = targetID
        self.linkToID = linkToID; self.baseRevision = baseRevision; self.evidenceAllowed = evidenceAllowed; self.evidenceInScope = evidenceInScope
        self.expectedStatus = expectedStatus; self.expectedIssuePrefix = expectedIssuePrefix
    }
}

public struct LearningCase: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var prompt: String
    public var referencePoints: [String]
    public var evidence: [RelevantSpan]
    public var scopes: [ScopeSpec]
    public var answer: String
    public var expectedAnswerable: Bool
    /// 人工参考评分（0–1）；nil 表示应判定为不确定。
    public var expectedScore: Double?

    public init(id: String, bookID: BookID, prompt: String, referencePoints: [String], evidence: [RelevantSpan], scopes: [ScopeSpec],
                answer: String, expectedAnswerable: Bool, expectedScore: Double?) {
        self.id = id; self.bookID = bookID; self.prompt = prompt; self.referencePoints = referencePoints; self.evidence = evidence
        self.scopes = scopes; self.answer = answer; self.expectedAnswerable = expectedAnswerable; self.expectedScore = expectedScore
    }
}

public struct LoadError: Codable, Hashable, Sendable {
    public var line: Int
    public var message: String
}

/// JSONL 数据载入：逐行解析，坏行记录行号，不静默丢弃。
public enum DatasetLoader {
    public static func loadJSONL<T: Decodable>(_ type: T.Type, data: Data) -> (items: [T], errors: [LoadError]) {
        var items: [T] = []
        var errors: [LoadError] = []
        let text = String(decoding: data, as: UTF8.self)
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            do { items.append(try JSONDecoder().decode(T.self, from: Data(trimmed.utf8))) } catch {
                errors.append(LoadError(line: i + 1, message: "\(error)"))
            }
        }
        return (items, errors)
    }

    public static func loadJSONL<T: Decodable>(_ type: T.Type, url: URL) throws -> (items: [T], errors: [LoadError], sha256: String) {
        let data = try Data(contentsOf: url)
        let r = loadJSONL(type, data: data)
        return (r.items, r.errors, Fingerprint.sha256(data))
    }

    /// 校验冻结哈希：验收集被修改则拒绝评测。
    public static func verifyFrozen(_ manifest: DatasetManifest, actualSHA256: String) -> Bool {
        guard let frozen = manifest.frozenSHA256 else { return manifest.split == .dev }
        return frozen == actualSHA256
    }
}
