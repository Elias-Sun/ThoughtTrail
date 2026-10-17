import Foundation
import LibraryCore
import ReadingSessionCore

/// 检索结果（ID + 分数）。BM25 与向量分数各自处理，不直接相加（RAG-03）。
public struct ScoredID: Hashable, Sendable {
    public var id: String
    public var score: Double

    public init(id: String, score: Double) { self.id = id; self.score = score }
}

/// 检索可见范围：逐本书使用各自的已读区间（READ-05）。
public struct RetrievalScope: Sendable, Hashable {
    public var scopes: [BookID: AccessScope]

    public init(_ scopes: [AccessScope]) {
        var dict: [BookID: AccessScope] = [:]
        for s in scopes { dict[s.bookID] = s }
        self.scopes = dict
    }

    public var bookIDs: [BookID] { scopes.keys.sorted() }

    /// 子块必须整体位于允许区间内且版本一致。
    public func allows(_ child: ChildChunk) -> Bool {
        guard let s = scopes[child.bookID] else { return false }
        return s.allows(bookID: child.bookID, version: child.bookVersion, chapterIndex: child.chapterIndex, range: child.range)
    }

    public func allows(bookID: BookID, version: String, chapterIndex: Int, range: TextSpan) -> Bool {
        scopes[bookID]?.allows(bookID: bookID, version: version, chapterIndex: chapterIndex, range: range) ?? false
    }

    public func clip(bookID: BookID, version: String, chapterIndex: Int, range: TextSpan) -> [TextSpan] {
        scopes[bookID]?.clip(bookID: bookID, version: version, chapterIndex: chapterIndex, range: range) ?? []
    }
}

/// 内存 BM25 索引（k1=1.2, b=0.75）。与 FTS5 实现共享分词。
public struct BM25Index: Sendable {
    public var k1: Double = 1.2
    public var b: Double = 0.75
    private var postings: [String: [(doc: Int, tf: Int)]] = [:]
    private var docIDs: [String] = []
    private var docLengths: [Int] = []
    private var idToDoc: [String: Int] = [:]
    private var removed: Set<Int> = []
    private var totalLength = 0
    private let segmenter: TextSegmenter

    public init(segmenter: TextSegmenter = TextSegmenter()) { self.segmenter = segmenter }

    public var count: Int { docIDs.count - removed.count }

    /// 添加文档；同 ID 重复添加会先移除旧版本（幂等）。返回是否被索引（空文本不入索引）。
    @discardableResult
    public mutating func add(id: String, text: String) -> Bool {
        if idToDoc[id] != nil { remove(id: id) }
        let tokens = segmenter.tokens(text)
        guard !tokens.isEmpty else { return false }
        let doc = docIDs.count
        docIDs.append(id)
        docLengths.append(tokens.count)
        idToDoc[id] = doc
        totalLength += tokens.count
        var tf: [String: Int] = [:]
        for t in tokens { tf[t, default: 0] += 1 }
        for (t, n) in tf { postings[t, default: []].append((doc, n)) }
        return true
    }

    public mutating func remove(id: String) {
        guard let doc = idToDoc[id] else { return }
        removed.insert(doc)
        totalLength -= docLengths[doc]
        idToDoc[id] = nil
    }

    public func contains(id: String) -> Bool { idToDoc[id] != nil }

    public func search(_ query: String, limit: Int, filter: (String) -> Bool = { _ in true }) -> [ScoredID] {
        let qTokens = Array(Set(segmenter.tokens(query)))
        guard !qTokens.isEmpty, count > 0, limit > 0 else { return [] }
        let n = Double(count)
        let avgdl = Double(max(1, totalLength)) / n
        var scores: [Int: Double] = [:]
        for t in qTokens {
            guard let plist = postings[t] else { continue }
            let live = plist.filter { !removed.contains($0.doc) }
            guard !live.isEmpty else { continue }
            let df = Double(live.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            for (doc, tf) in live {
                let dl = Double(docLengths[doc])
                let f = Double(tf)
                scores[doc, default: 0] += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl))
            }
        }
        return scores
            .filter { filter(docIDs[$0.key]) }
            .map { ScoredID(id: docIDs[$0.key], score: $0.value) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            .prefix(limit).map { $0 }
    }
}

public enum VectorError: Error, Equatable, Sendable {
    case dimensionMismatch(expected: Int, actual: Int)
    case nonFinite
    case zeroVector
}

/// 内存向量索引（余弦相似度，暴力扫描）。异常向量不进入有效索引（RAG-02）。
public struct VectorIndex: Sendable {
    public let dimension: Int
    private var ids: [String] = []
    private var storage: [Float] = []
    private var idToSlot: [String: Int] = [:]
    private var removed: Set<Int> = []

    public init(dimension: Int) { self.dimension = dimension }

    public var count: Int { ids.count - removed.count }

    public static func validate(_ v: [Float], dimension: Int) throws -> [Float] {
        guard v.count == dimension else { throw VectorError.dimensionMismatch(expected: dimension, actual: v.count) }
        guard v.allSatisfy({ $0.isFinite }) else { throw VectorError.nonFinite }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-12 else { throw VectorError.zeroVector }
        return v.map { $0 / norm }
    }

    public mutating func add(id: String, vector: [Float]) throws {
        let normalized = try Self.validate(vector, dimension: dimension)
        if let slot = idToSlot[id] {
            storage.replaceSubrange(slot * dimension..<(slot + 1) * dimension, with: normalized)
            return
        }
        idToSlot[id] = ids.count
        ids.append(id)
        storage.append(contentsOf: normalized)
    }

    public mutating func remove(id: String) {
        guard let slot = idToSlot[id] else { return }
        removed.insert(slot)
        idToSlot[id] = nil
    }

    public func contains(id: String) -> Bool { idToSlot[id] != nil }

    public func search(_ query: [Float], limit: Int, filter: (String) -> Bool = { _ in true }) throws -> [ScoredID] {
        let q = try Self.validate(query, dimension: dimension)
        guard limit > 0 else { return [] }
        var results: [ScoredID] = []
        results.reserveCapacity(min(ids.count, 1024))
        storage.withUnsafeBufferPointer { buf in
            for slot in 0..<ids.count where !removed.contains(slot) {
                let id = ids[slot]
                guard filter(id) else { continue }
                var dot: Float = 0
                let base = slot * dimension
                for i in 0..<dimension { dot += buf[base + i] * q[i] }
                results.append(ScoredID(id: id, score: Double(dot)))
            }
        }
        return results.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(limit).map { $0 }
    }
}

/// Reciprocal Rank Fusion：只使用名次，避免 BM25 与余弦分数尺度不同（RAG-03）。
public enum RRF {
    public static func fuse(_ lists: [[ScoredID]], k: Double = 60, limit: Int) -> [ScoredID] {
        var scores: [String: Double] = [:]
        var bestRank: [String: Int] = [:]
        for list in lists {
            var seen: Set<String> = []
            for (rank, item) in list.enumerated() where !seen.contains(item.id) {
                seen.insert(item.id)
                scores[item.id, default: 0] += 1.0 / (k + Double(rank + 1))
                bestRank[item.id] = min(bestRank[item.id] ?? .max, rank)
            }
        }
        return scores.map { ScoredID(id: $0.key, score: $0.value) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                let ra = bestRank[$0.id] ?? .max, rb = bestRank[$1.id] ?? .max
                return ra == rb ? $0.id < $1.id : ra < rb
            }
            .prefix(limit).map { $0 }
    }
}

/// 重排结果项（文档在请求中的下标 + 相关度）。
public struct RerankScore: Hashable, Sendable, Codable {
    public var index: Int
    public var score: Double

    public init(index: Int, score: Double) { self.index = index; self.score = score }
}

/// 把重排结果映射回候选 ID：处理乱序、越界、重复、缺失（RAG-03）。
public enum RerankMapper {
    public struct Outcome: Sendable, Equatable {
        public var ordered: [ScoredID]
        public var invalidIndices: [Int]
        public var missingIDs: [String]
    }

    public static func map(_ results: [RerankScore], candidates: [ScoredID]) -> Outcome {
        var seen: Set<Int> = []
        var invalid: [Int] = []
        var ranked: [ScoredID] = []
        for r in results.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) {
            guard candidates.indices.contains(r.index), r.score.isFinite else { invalid.append(r.index); continue }
            guard seen.insert(r.index).inserted else { invalid.append(r.index); continue }
            ranked.append(ScoredID(id: candidates[r.index].id, score: r.score))
        }
        // 重排未返回的候选保持融合顺序排在后面
        let missing = candidates.enumerated().filter { !seen.contains($0.offset) }.map(\.element)
        return Outcome(ordered: ranked + missing.map { ScoredID(id: $0.id, score: -.infinity) },
                       invalidIndices: invalid, missingIDs: missing.map(\.id))
    }
}
