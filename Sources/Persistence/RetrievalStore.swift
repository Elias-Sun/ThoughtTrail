import Foundation
import GRDB
import LibraryCore
import ReadingSessionCore
import RetrievalCore

/// SQLite 检索存储：父子块、FTS5 词法索引（CJK 二元组预分词 + bm25）、向量 BLOB。
public final class SQLiteRetrievalStore: ChunkStore, LexicalSearching, VectorSearching, EmbeddingStore, @unchecked Sendable {
    let db: AppDatabase
    let segmenter = TextSegmenter()
    private let cacheLock = NSLock()
    /// 向量缓存：key = bookID|model|dims。写入/失效时清除。
    private var vectorCache: [String: [(id: String, vector: [Float])]] = [:]

    public init(_ db: AppDatabase) { self.db = db }

    public func replaceChunks(bookID: BookID, set: ChunkSet, manifest: IndexManifest) async throws {
        let docs = set.children.map { ($0, segmenter.ftsDocument($0.text)) }
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM child_fts WHERE bookID = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM child_chunk WHERE bookID = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM parent_chunk WHERE bookID = ?", arguments: [bookID])
            for p in set.parents {
                try db.execute(sql: "INSERT INTO parent_chunk (id, bookID, payload) VALUES (?, ?, ?)", arguments: [p.id, bookID, try Codec.encode(p)])
            }
            for (c, tokens) in docs where !tokens.isEmpty {
                try db.execute(sql: """
                    INSERT INTO child_chunk (id, bookID, parentID, version, chapterIndex, start, "end", fingerprint, text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [c.id, bookID, c.parentID, c.bookVersion, c.chapterIndex, c.range.start, c.range.end, c.fingerprint, c.text])
                try db.execute(sql: "INSERT INTO child_fts (childID, bookID, tokens) VALUES (?, ?, ?)", arguments: [c.id, bookID, tokens])
            }
            try db.execute(sql: Upsert.sql("index_manifest", columns: ["bookID", "payload"], primaryKey: ["bookID"]), arguments: [bookID, try Codec.encode(manifest)])
        }
        clearCache(bookID: bookID)
    }

    public func removeChunks(bookID: BookID) async throws {
        try await db.writer.write { try SQLiteBookRepository.deleteIndex($0, bookID: bookID) }
        clearCache(bookID: bookID)
    }

    static func child(_ row: Row) -> ChildChunk {
        ChildChunk(id: row["id"], parentID: row["parentID"], bookID: row["bookID"], bookVersion: row["version"],
                   chapterIndex: row["chapterIndex"], range: TextSpan(start: row["start"], end: row["end"]),
                   text: row["text"], fingerprint: row["fingerprint"])
    }

    public func children(ids: [String]) async throws -> [ChildChunk] {
        guard !ids.isEmpty else { return [] }
        return try await db.writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM child_chunk WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
            let byID = Dictionary(uniqueKeysWithValues: rows.map { (Self.child($0).id, Self.child($0)) })
            return ids.compactMap { byID[$0] }
        }
    }

    public func parents(ids: [String]) async throws -> [ParentChunk] {
        guard !ids.isEmpty else { return [] }
        return try await db.writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try db.fetchPayloads(ParentChunk.self, sql: "SELECT payload FROM parent_chunk WHERE id IN (\(placeholders))",
                                        arguments: StatementArguments(ids))
        }
    }

    public func children(bookID: BookID) async throws -> [ChildChunk] {
        try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM child_chunk WHERE bookID = ? ORDER BY chapterIndex, start", arguments: [bookID]).map(Self.child)
        }
    }

    public func manifest(bookID: BookID) async throws -> IndexManifest? {
        try await db.writer.read { try $0.fetchPayload(IndexManifest.self, sql: "SELECT payload FROM index_manifest WHERE bookID = ?", arguments: [bookID]) }
    }

    public func saveManifest(_ manifest: IndexManifest) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("index_manifest", columns: ["bookID", "payload"], primaryKey: ["bookID"]), arguments: [manifest.bookID, try Codec.encode(manifest)])
        }
    }

    /// FTS5 bm25 召回，按页读取并在范围过滤后凑满 limit。
    public func searchLexical(_ query: String, scope: RetrievalScope, limit: Int) async throws -> [ScoredID] {
        guard let match = segmenter.ftsQuery(query), limit > 0, !scope.bookIDs.isEmpty else { return [] }
        let books = scope.bookIDs
        return try await db.writer.read { db in
            var out: [ScoredID] = []
            var offset = 0
            let page = max(limit * 2, 100)
            let placeholders = Array(repeating: "?", count: books.count).joined(separator: ",")
            while out.count < limit {
                var args: [any DatabaseValueConvertible] = [match]
                args += books
                args += [page, offset]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT c.*, bm25(child_fts) AS score FROM child_fts JOIN child_chunk c ON c.id = child_fts.childID
                    WHERE child_fts MATCH ? AND child_fts.bookID IN (\(placeholders))
                    ORDER BY score, c.id LIMIT ? OFFSET ?
                    """, arguments: StatementArguments(args))
                if rows.isEmpty { break }
                for row in rows {
                    let c = Self.child(row)
                    if scope.allows(c) { out.append(ScoredID(id: c.id, score: -(row["score"] as Double))) }
                    if out.count >= limit { break }
                }
                offset += page
                if rows.count < page { break }
            }
            return out
        }
    }

    public func searchVectors(_ query: [Float], profile: EmbeddingProfile, scope: RetrievalScope, limit: Int) async throws -> [ScoredID] {
        let q = try VectorIndex.validate(query, dimension: profile.dimensions)
        var allowedMeta: [String: ChildChunk] = [:]
        var candidates: [(id: String, vector: [Float])] = []
        for bookID in scope.bookIDs {
            let vectors = try await loadVectors(bookID: bookID, profile: profile)
            candidates += vectors
            for c in try await children(ids: vectors.map(\.id)) { allowedMeta[c.id] = c }
        }
        var scored: [ScoredID] = []
        for (id, v) in candidates {
            guard let c = allowedMeta[id], scope.allows(c) else { continue }
            var dot: Float = 0
            for i in 0..<min(v.count, q.count) { dot += v[i] * q[i] }
            scored.append(ScoredID(id: id, score: Double(dot)))
        }
        return Array(scored.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(limit))
    }

    private func cacheKey(_ bookID: BookID, _ p: EmbeddingProfile) -> String { "\(bookID)|\(p.model)|\(p.dimensions)" }

    private func loadVectors(bookID: BookID, profile: EmbeddingProfile) async throws -> [(id: String, vector: [Float])] {
        let key = cacheKey(bookID, profile)
        if let cached = cacheLock.withLock({ vectorCache[key] }) { return cached }
        let loaded: [(id: String, vector: [Float])] = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT childID, vector FROM embedding WHERE bookID = ? AND model = ? AND dims = ?",
                             arguments: [bookID, profile.model, profile.dimensions]).map { row in
                let raw = VectorBlob.decode(row["vector"])
                let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
                return (id: row["childID"] as String, vector: norm > 0 ? raw.map { $0 / norm } : raw)
            }
        }
        cacheLock.withLock { vectorCache[key] = loaded }
        return loaded
    }

    private func clearCache(bookID: BookID) {
        cacheLock.withLock { vectorCache = vectorCache.filter { !$0.key.hasPrefix("\(bookID)|") } }
    }

    public func embeddedChildIDs(bookID: BookID, profile: EmbeddingProfile) async throws -> Set<String> {
        try await db.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT childID FROM embedding WHERE bookID = ? AND model = ? AND dims = ?",
                                    arguments: [bookID, profile.model, profile.dimensions]))
        }
    }

    public func vectors(fingerprints: [String], profile: EmbeddingProfile) async throws -> [String: [Float]] {
        guard !fingerprints.isEmpty else { return [:] }
        return try await db.writer.read { db in
            var out: [String: [Float]] = [:]
            for chunk in stride(from: 0, to: fingerprints.count, by: 500).map({ Array(fingerprints[$0..<min(fingerprints.count, $0 + 500)]) }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                var args: [any DatabaseValueConvertible] = [profile.model, profile.dimensions]
                args += chunk
                for row in try Row.fetchAll(db, sql: "SELECT fingerprint, vector FROM embedding WHERE model = ? AND dims = ? AND fingerprint IN (\(placeholders))",
                                            arguments: StatementArguments(args)) {
                    out[row["fingerprint"]] = VectorBlob.decode(row["vector"])
                }
            }
            return out
        }
    }

    /// 整批校验后原子写入；异常向量不进入有效索引（RAG-02）。
    public func saveEmbeddings(_ items: [EmbeddingItem], profile: EmbeddingProfile) async throws {
        for item in items { _ = try VectorIndex.validate(item.vector, dimension: profile.dimensions) }
        try await db.writer.write { db in
            for item in items {
                try db.execute(sql: "INSERT OR REPLACE INTO embedding (childID, model, dims, bookID, fingerprint, vector) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [item.childID, profile.model, profile.dimensions, item.bookID, item.fingerprint, VectorBlob.encode(item.vector)])
            }
        }
        for b in Set(items.map(\.bookID)) { clearCache(bookID: b) }
    }

    public func invalidateEmbeddings(bookID: BookID, keeping profile: EmbeddingProfile?) async throws {
        try await db.writer.write { db in
            if let p = profile {
                try db.execute(sql: "DELETE FROM embedding WHERE bookID = ? AND NOT (model = ? AND dims = ?)", arguments: [bookID, p.model, p.dimensions])
            } else {
                try db.execute(sql: "DELETE FROM embedding WHERE bookID = ?", arguments: [bookID])
            }
        }
        clearCache(bookID: bookID)
    }
}
