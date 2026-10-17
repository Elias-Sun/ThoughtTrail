import Foundation
import LibraryCore
import ReadingSessionCore

/// 向量模型身份：模型 + 维度。变化时旧向量失效，禁止混查（RAG-05）。
public struct EmbeddingProfile: Codable, Hashable, Sendable, CustomStringConvertible {
    public var model: String
    public var dimensions: Int

    public init(model: String, dimensions: Int) { self.model = model; self.dimensions = dimensions }
    public var description: String { "\(model)@\(dimensions)" }
}

public enum EmbeddingPurpose: String, Sendable {
    case document, query
}

/// 向量化服务接口（百炼 text-embedding-v4 等，由 ModelProviders 实现）。
public protocol EmbeddingService: Sendable {
    var profile: EmbeddingProfile { get }
    /// 单次批量上限。
    var maxBatchSize: Int { get }
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]]
}

/// 重排服务接口（百炼 qwen3-rerank 等）。
public protocol RerankService: Sendable {
    var modelID: String { get }
    func rerank(query: String, documents: [String], topN: Int) async throws -> [RerankScore]
}

/// 子块/父块存储（Persistence 用 SQLite 实现；InMemoryChunkStore 用于测试与评测）。
public protocol ChunkStore: Sendable {
    func children(ids: [String]) async throws -> [ChildChunk]
    func parents(ids: [String]) async throws -> [ParentChunk]
    func children(bookID: BookID) async throws -> [ChildChunk]
    func replaceChunks(bookID: BookID, set: ChunkSet, manifest: IndexManifest) async throws
    func manifest(bookID: BookID) async throws -> IndexManifest?
    func saveManifest(_ manifest: IndexManifest) async throws
    func removeChunks(bookID: BookID) async throws
}

/// 词法检索接口（FTS5/BM25）。实现需在范围过滤后返回最多 limit 条。
public protocol LexicalSearching: Sendable {
    func searchLexical(_ query: String, scope: RetrievalScope, limit: Int) async throws -> [ScoredID]
}

/// 向量检索接口。只能返回与 profile 一致的向量。
public protocol VectorSearching: Sendable {
    func searchVectors(_ query: [Float], profile: EmbeddingProfile, scope: RetrievalScope, limit: Int) async throws -> [ScoredID]
}

/// 向量记录存储（索引任务写入）。
public protocol EmbeddingStore: Sendable {
    func embeddedChildIDs(bookID: BookID, profile: EmbeddingProfile) async throws -> Set<String>
    /// 按内容指纹查已存在的向量（换书重导或重新切块后复用）。
    func vectors(fingerprints: [String], profile: EmbeddingProfile) async throws -> [String: [Float]]
    /// 原子写入一批向量。
    func saveEmbeddings(_ items: [EmbeddingItem], profile: EmbeddingProfile) async throws
    /// 删除与 profile 不一致的向量。
    func invalidateEmbeddings(bookID: BookID, keeping profile: EmbeddingProfile?) async throws
}

public struct EmbeddingItem: Sendable, Hashable {
    public var childID: String
    public var bookID: BookID
    public var fingerprint: String
    public var vector: [Float]

    public init(childID: String, bookID: BookID, fingerprint: String, vector: [Float]) {
        self.childID = childID; self.bookID = bookID; self.fingerprint = fingerprint; self.vector = vector
    }
}

/// 索引清单：切块策略、向量模型、维度与内容版本（RAG-05）。
public struct IndexManifest: Codable, Hashable, Sendable {
    public enum VectorStatus: String, Codable, Sendable { case none, partial, complete, invalidated }

    public var bookID: BookID
    public var bookVersion: String
    public var chunkingVersion: String
    public var embeddingProfile: EmbeddingProfile?
    public var childCount: Int
    public var embeddedCount: Int
    public var vectorStatus: VectorStatus
    public var updatedAt: Date

    public init(bookID: BookID, bookVersion: String, chunkingVersion: String, embeddingProfile: EmbeddingProfile?,
                childCount: Int, embeddedCount: Int, vectorStatus: VectorStatus, updatedAt: Date) {
        self.bookID = bookID; self.bookVersion = bookVersion; self.chunkingVersion = chunkingVersion
        self.embeddingProfile = embeddingProfile; self.childCount = childCount; self.embeddedCount = embeddedCount
        self.vectorStatus = vectorStatus; self.updatedAt = updatedAt
    }
}

public enum IndexCompatibility: Equatable, Sendable {
    case compatible
    /// 书籍内容或切块策略变化：需要重新切块（同时重建向量）。
    case needsRechunk
    /// 向量模型/维度变化：仅需重建向量。
    case needsReembed
    case missing

    public static func check(_ manifest: IndexManifest?, bookVersion: String, chunking: ChunkingConfig,
                             profile: EmbeddingProfile?) -> IndexCompatibility {
        guard let m = manifest else { return .missing }
        if m.bookVersion != bookVersion || m.chunkingVersion != chunking.version { return .needsRechunk }
        if let profile, m.embeddingProfile != nil, m.embeddingProfile != profile { return .needsReembed }
        if m.vectorStatus == .invalidated { return .needsReembed }
        return .compatible
    }
}
