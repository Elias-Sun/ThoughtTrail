import Foundation
import LibraryCore
import ReadingSessionCore

/// 内存版检索存储：同时实现块存储、词法检索、向量检索与向量存储。
/// 用于离线评测（tt-bench）、测试与预览；生产环境由 Persistence 的 SQLite 实现。
public actor InMemoryRetrievalStore: ChunkStore, LexicalSearching, VectorSearching, EmbeddingStore {
    private var childrenByID: [String: ChildChunk] = [:]
    private var parentsByID: [String: ParentChunk] = [:]
    private var childIDsByBook: [BookID: [String]] = [:]
    private var manifests: [BookID: IndexManifest] = [:]
    private var bm25 = BM25Index()
    private var vectorIndexes: [EmbeddingProfile: VectorIndex] = [:]
    private var vectorFingerprints: [EmbeddingProfile: [String: [Float]]] = [:]
    private var embeddedByBook: [EmbeddingProfile: [BookID: Set<String>]] = [:]
    public private(set) var saveCalls = 0

    public init() {}

    public func replaceChunks(bookID: BookID, set: ChunkSet, manifest: IndexManifest) async throws {
        try await removeChunks(bookID: bookID)
        for p in set.parents { parentsByID[p.id] = p }
        var ids: [String] = []
        for c in set.children {
            childrenByID[c.id] = c
            if bm25.add(id: c.id, text: c.text) { ids.append(c.id) }
        }
        childIDsByBook[bookID] = ids
        manifests[bookID] = manifest
    }

    public func removeChunks(bookID: BookID) async throws {
        for id in childIDsByBook[bookID] ?? [] {
            bm25.remove(id: id)
            for key in vectorIndexes.keys { vectorIndexes[key]?.remove(id: id) }
            childrenByID[id] = nil
        }
        parentsByID = parentsByID.filter { $0.value.bookID != bookID }
        childIDsByBook[bookID] = nil
        manifests[bookID] = nil
        for key in embeddedByBook.keys { embeddedByBook[key]?[bookID] = nil }
    }

    public func children(ids: [String]) async throws -> [ChildChunk] { ids.compactMap { childrenByID[$0] } }
    public func parents(ids: [String]) async throws -> [ParentChunk] { ids.compactMap { parentsByID[$0] } }
    public func children(bookID: BookID) async throws -> [ChildChunk] {
        (childIDsByBook[bookID] ?? []).compactMap { childrenByID[$0] }
    }
    public func manifest(bookID: BookID) async throws -> IndexManifest? { manifests[bookID] }
    public func saveManifest(_ manifest: IndexManifest) async throws { manifests[manifest.bookID] = manifest }

    public func searchLexical(_ query: String, scope: RetrievalScope, limit: Int) async throws -> [ScoredID] {
        let children = childrenByID
        return bm25.search(query, limit: limit) { id in
            guard let c = children[id] else { return false }
            return scope.allows(c)
        }
    }

    public func searchVectors(_ query: [Float], profile: EmbeddingProfile, scope: RetrievalScope, limit: Int) async throws -> [ScoredID] {
        guard let index = vectorIndexes[profile] else { return [] }
        let children = childrenByID
        return try index.search(query, limit: limit) { id in
            guard let c = children[id] else { return false }
            return scope.allows(c)
        }
    }

    public func embeddedChildIDs(bookID: BookID, profile: EmbeddingProfile) async throws -> Set<String> {
        embeddedByBook[profile]?[bookID] ?? []
    }

    public func vectors(fingerprints: [String], profile: EmbeddingProfile) async throws -> [String: [Float]] {
        let all = vectorFingerprints[profile] ?? [:]
        var out: [String: [Float]] = [:]
        for f in fingerprints { if let v = all[f] { out[f] = v } }
        return out
    }

    public func saveEmbeddings(_ items: [EmbeddingItem], profile: EmbeddingProfile) async throws {
        // 先整体校验，任一异常则整批不写入（原子性）
        let validated = try items.map { ($0, try VectorIndex.validate($0.vector, dimension: profile.dimensions)) }
        saveCalls += 1
        var index = vectorIndexes[profile] ?? VectorIndex(dimension: profile.dimensions)
        for (item, _) in validated {
            try index.add(id: item.childID, vector: item.vector)
            vectorFingerprints[profile, default: [:]][item.fingerprint] = item.vector
            embeddedByBook[profile, default: [:]][item.bookID, default: []].insert(item.childID)
        }
        vectorIndexes[profile] = index
    }

    public func invalidateEmbeddings(bookID: BookID, keeping profile: EmbeddingProfile?) async throws {
        for key in vectorIndexes.keys where key != profile {
            for id in childIDsByBook[bookID] ?? [] { vectorIndexes[key]?.remove(id: id) }
            embeddedByBook[key]?[bookID] = nil
        }
    }

    public var childCount: Int { childrenByID.count }
}
