import Foundation
import LibraryCore
import ReadingSessionCore

/// 检索参数（5.4 初始值：两路各 50，融合后 20 进入重排，最终 8 个核心证据）。评测前冻结。
public struct RetrievalConfig: Codable, Hashable, Sendable {
    public var lexicalLimit: Int
    public var vectorLimit: Int
    public var fusedLimit: Int
    public var finalLimit: Int
    public var rrfK: Double
    public var expansionMaxChars: Int
    public var useLexical: Bool
    public var useVector: Bool
    public var useRerank: Bool
    public var expandParents: Bool

    public init(lexicalLimit: Int = 50, vectorLimit: Int = 50, fusedLimit: Int = 20, finalLimit: Int = 8,
                rrfK: Double = 60, expansionMaxChars: Int = 900, useLexical: Bool = true, useVector: Bool = true,
                useRerank: Bool = true, expandParents: Bool = true) {
        self.lexicalLimit = lexicalLimit; self.vectorLimit = vectorLimit; self.fusedLimit = fusedLimit
        self.finalLimit = finalLimit; self.rrfK = rrfK; self.expansionMaxChars = expansionMaxChars
        self.useLexical = useLexical; self.useVector = useVector; self.useRerank = useRerank
        self.expandParents = expandParents
    }

    public static let `default` = RetrievalConfig()
}

/// 一个检索证据单元：命中的子块 + 在已读边界内扩展后的区间。
public struct RetrievedUnit: Sendable, Hashable {
    public var child: ChildChunk
    public var parentID: String
    public var bookID: BookID
    public var bookVersion: String
    public var chapterIndex: Int
    /// 扩展后的区间（已按已读边界裁剪）。
    public var range: TextSpan
    public var text: String
    public var lexicalRank: Int?
    public var vectorRank: Int?
    public var fusedScore: Double
    public var rerankScore: Double?
    public var finalRank: Int
    /// 父块扩展因越界被裁剪。
    public var clippedByBoundary: Bool
}

public struct RetrievalDiagnostics: Sendable, Hashable {
    public var lexicalHits = 0
    public var vectorHits = 0
    public var fusedCount = 0
    public var reranked = false
    public var degradations: [String] = []
    public var droppedAtBoundaryCheck = 0
    public var clippedExpansions = 0
    public var queries: [String] = []

    public init() {}
}

public struct RetrievalResult: Sendable {
    public var units: [RetrievedUnit]
    public var diagnostics: RetrievalDiagnostics

    public init(units: [RetrievedUnit], diagnostics: RetrievalDiagnostics) {
        self.units = units; self.diagnostics = diagnostics
    }
}

/// 混合检索：范围过滤 → 双路召回 → RRF → Rerank → Small-to-Big → 再次检查边界。
/// Embedding 不可用时降级词法；Rerank 失败保留融合排序（RAG-06）。
public struct HybridRetriever: Sendable {
    public let chunks: ChunkStore
    public let lexical: LexicalSearching?
    public let vectors: VectorSearching?
    public let embedder: EmbeddingService?
    public let reranker: RerankService?
    public let config: RetrievalConfig

    public init(chunks: ChunkStore, lexical: LexicalSearching?, vectors: VectorSearching? = nil,
                embedder: EmbeddingService? = nil, reranker: RerankService? = nil, config: RetrievalConfig = .default) {
        self.chunks = chunks; self.lexical = lexical; self.vectors = vectors; self.embedder = embedder
        self.reranker = reranker; self.config = config
    }

    public func with(config: RetrievalConfig) -> HybridRetriever {
        HybridRetriever(chunks: chunks, lexical: lexical, vectors: vectors, embedder: embedder, reranker: reranker, config: config)
    }

    public func retrieve(queries rawQueries: [String], scope: RetrievalScope) async -> RetrievalResult {
        var diag = RetrievalDiagnostics()
        let queries = rawQueries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        diag.queries = queries
        guard !queries.isEmpty, !scope.scopes.isEmpty else { return RetrievalResult(units: [], diagnostics: diag) }

        var lexicalLists: [[ScoredID]] = []
        var vectorLists: [[ScoredID]] = []

        if config.useLexical, let lexical {
            for q in queries {
                do {
                    let hits = try await lexical.searchLexical(q, scope: scope, limit: config.lexicalLimit)
                    lexicalLists.append(hits)
                    diag.lexicalHits += hits.count
                } catch {
                    diag.degradations.append("lexical_failed")
                }
            }
        }

        if config.useVector {
            if let embedder, let vectors {
                // 只对索引与当前向量模型兼容的书使用向量检索，不混查不兼容向量
                var compatibleScopes: [AccessScope] = []
                for (bookID, s) in scope.scopes {
                    let m = try? await chunks.manifest(bookID: bookID)
                    if let m, m.embeddingProfile == embedder.profile, m.vectorStatus != .invalidated, m.vectorStatus != .none {
                        compatibleScopes.append(s)
                    } else {
                        diag.degradations.append("vector_index_incompatible:\(bookID)")
                    }
                }
                if !compatibleScopes.isEmpty {
                    do {
                        let qvecs = try await embedder.embed(queries, purpose: .query)
                        guard qvecs.count == queries.count else { throw VectorError.dimensionMismatch(expected: queries.count, actual: qvecs.count) }
                        let vScope = RetrievalScope(compatibleScopes)
                        for v in qvecs {
                            let hits = try await vectors.searchVectors(v, profile: embedder.profile, scope: vScope, limit: config.vectorLimit)
                            vectorLists.append(hits)
                            diag.vectorHits += hits.count
                        }
                    } catch {
                        diag.degradations.append("embedding_unavailable_lexical_only")
                    }
                }
            } else {
                diag.degradations.append("vector_not_configured")
            }
        }

        let lexicalRanks = Self.bestRanks(lexicalLists)
        let vectorRanks = Self.bestRanks(vectorLists)
        var fused = RRF.fuse(lexicalLists + vectorLists, k: config.rrfK, limit: config.fusedLimit)
        diag.fusedCount = fused.count
        let fusedScores = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.score) })

        // 取子块（防御：再次检查范围）
        let childMap: [String: ChildChunk]
        do {
            childMap = Dictionary(uniqueKeysWithValues: try await chunks.children(ids: fused.map(\.id)).map { ($0.id, $0) })
        } catch {
            diag.degradations.append("chunk_store_failed")
            return RetrievalResult(units: [], diagnostics: diag)
        }
        fused = fused.filter { item in
            guard let c = childMap[item.id], scope.allows(c) else { diag.droppedAtBoundaryCheck += 1; return false }
            return true
        }

        var rerankScores: [String: Double] = [:]
        var ordered = fused
        if config.useRerank, let reranker, fused.count > 1 {
            do {
                let docs = fused.map { childMap[$0.id]?.text ?? "" }
                let results = try await reranker.rerank(query: queries.joined(separator: "\n"), documents: docs, topN: docs.count)
                let mapped = RerankMapper.map(results, candidates: fused)
                if mapped.ordered.allSatisfy({ !$0.score.isFinite }) || results.isEmpty {
                    diag.degradations.append("rerank_empty_kept_fusion")
                } else {
                    ordered = mapped.ordered
                    for item in mapped.ordered where item.score.isFinite { rerankScores[item.id] = item.score }
                    diag.reranked = true
                    if !mapped.invalidIndices.isEmpty { diag.degradations.append("rerank_invalid_indices:\(mapped.invalidIndices.count)") }
                }
            } catch {
                diag.degradations.append("rerank_failed_kept_fusion")
            }
        }

        let top = ordered.prefix(config.finalLimit).compactMap { childMap[$0.id] }
        var units: [RetrievedUnit] = []
        let parentMap: [String: ParentChunk]
        if config.expandParents {
            parentMap = Dictionary(uniqueKeysWithValues: ((try? await chunks.parents(ids: Array(Set(top.map(\.parentID))))) ?? []).map { ($0.id, $0) })
        } else {
            parentMap = [:]
        }
        for (rank, child) in top.enumerated() {
            var range = child.range
            var text = child.text
            var clipped = false
            if config.expandParents, let parent = parentMap[child.parentID] {
                let expansion = SmallToBig.expand(child: child, parent: parent, scope: scope, maxChars: config.expansionMaxChars)
                range = expansion.range; text = expansion.text; clipped = expansion.clipped
                if clipped { diag.clippedExpansions += 1 }
            }
            units.append(RetrievedUnit(child: child, parentID: child.parentID, bookID: child.bookID,
                                       bookVersion: child.bookVersion, chapterIndex: child.chapterIndex, range: range,
                                       text: text, lexicalRank: lexicalRanks[child.id], vectorRank: vectorRanks[child.id],
                                       fusedScore: fusedScores[child.id] ?? 0, rerankScore: rerankScores[child.id],
                                       finalRank: rank, clippedByBoundary: clipped))
        }
        units = SmallToBig.dedupe(units, maxChars: max(config.expansionMaxChars, 1))
        // 提交前最后一次边界检查
        let checked = units.filter { scope.allows(bookID: $0.bookID, version: $0.bookVersion, chapterIndex: $0.chapterIndex, range: $0.range) }
        diag.droppedAtBoundaryCheck += units.count - checked.count
        return RetrievalResult(units: checked, diagnostics: diag)
    }

    static func bestRanks(_ lists: [[ScoredID]]) -> [String: Int] {
        var out: [String: Int] = [:]
        for list in lists {
            for (i, item) in list.enumerated() { out[item.id] = min(out[item.id] ?? .max, i + 1) }
        }
        return out
    }
}

/// Small-to-Big 扩展：child 命中后补充 parent，限制长度；跨越已读边界时裁剪（RAG-04）。
public enum SmallToBig {
    public struct Expansion: Sendable, Equatable {
        public var range: TextSpan
        public var text: String
        public var clipped: Bool
    }

    public static func expand(child: ChildChunk, parent: ParentChunk, scope: RetrievalScope, maxChars: Int) -> Expansion {
        let allowed = scope.clip(bookID: parent.bookID, version: parent.bookVersion, chapterIndex: parent.chapterIndex, range: parent.range)
        // 只取包含子块的那一段允许区间，不跨越未读空洞
        guard let segment = allowed.first(where: { $0.contains(child.range) }) else {
            return Expansion(range: child.range, text: child.text, clipped: true)
        }
        let clippedByScope = segment != parent.range
        var range = segment
        if range.length > maxChars {
            let extra = max(0, maxChars - child.range.length)
            let before = extra / 2
            var start = max(segment.start, child.range.start - before)
            var end = min(segment.end, start + max(maxChars, child.range.length))
            if end - start < maxChars { start = max(segment.start, end - maxChars) }
            end = max(end, child.range.end)
            range = TextSpan(start: start, end: end)
        }
        let local = TextSpan(start: range.start - parent.range.start, end: range.end - parent.range.start)
        return Expansion(range: range, text: parent.text.substring(utf16: local), clipped: clippedByScope)
    }

    /// 合并同章节内重叠的扩展区间，保留排名最好的单元；合并后不超过长度上限，否则丢弃排名较低者。
    public static func dedupe(_ units: [RetrievedUnit], maxChars: Int = .max) -> [RetrievedUnit] {
        var kept: [RetrievedUnit] = []
        for u in units.sorted(by: { $0.finalRank < $1.finalRank }) {
            if let i = kept.firstIndex(where: { $0.bookID == u.bookID && $0.chapterIndex == u.chapterIndex && $0.range.overlaps(u.range) }) {
                // 已有更高排名单元覆盖：若新单元扩出更多范围且来自同一父块，合并
                if kept[i].parentID == u.parentID {
                    let merged = kept[i].range.union(u.range)
                    if merged.length > kept[i].range.length, merged.length <= maxChars {
                        let combinedText = mergeText(kept[i], u, merged: merged)
                        kept[i].range = merged
                        kept[i].text = combinedText
                    }
                }
                continue
            }
            kept.append(u)
        }
        return kept
    }

    private static func mergeText(_ a: RetrievedUnit, _ b: RetrievedUnit, merged: TextSpan) -> String {
        // 两段在同一父块中，按区间拼接
        let first = a.range.start <= b.range.start ? a : b
        let second = first.range == a.range ? b : a
        if second.range.end <= first.range.end { return first.text }
        let overlap = max(0, first.range.end - second.range.start)
        let tail = second.text.substring(utf16: TextSpan(start: overlap, end: second.text.utf16Length))
        return first.text + tail
    }
}
