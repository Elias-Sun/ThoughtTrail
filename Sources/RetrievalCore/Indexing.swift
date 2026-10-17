import Foundation
import LibraryCore
import ReadingSessionCore

/// 索引任务报告。
public struct IndexingReport: Sendable, Equatable {
    public var embedded = 0
    public var reusedByFingerprint = 0
    public var alreadyEmbedded = 0
    /// 实际发出的远端批次（只统计真正执行的请求，不重复扣用任务计数）。
    public var remoteBatches = 0
    public var failedBatches = 0
    public var paused = false
    public var cancelled = false
    public var lastError: String?

    public var completed: Bool { !paused && !cancelled && failedBatches == 0 }
}

/// 索引批次预算（后台任务独立预算，不挤占前台讨论）。
public struct IndexingBudget: Sendable, Hashable {
    public var maxRemoteBatches: Int
    public var batchSize: Int

    public init(maxRemoteBatches: Int = 200, batchSize: Int = 10) {
        self.maxRemoteBatches = max(0, maxRemoteBatches); self.batchSize = max(1, batchSize)
    }
}

/// 书籍索引器：切块、写清单、按兼容性失效/重建、增量向量化（RAG-05/06）。
public struct BookIndexer: Sendable {
    public let store: ChunkStore
    public let embeddings: EmbeddingStore?
    public let chunker: Chunker
    public let clock: WallClock

    public init(store: ChunkStore, embeddings: EmbeddingStore?, chunker: Chunker = Chunker(), clock: WallClock = SystemClock()) {
        self.store = store; self.embeddings = embeddings; self.chunker = chunker; self.clock = clock
    }

    /// 确保词法索引与切块存在且与当前书籍版本一致；返回需要的动作。
    @discardableResult
    public func ensureLexicalIndex(book: Book, chapters: [Chapter], profile: EmbeddingProfile?) async throws -> IndexCompatibility {
        let existing = try await store.manifest(bookID: book.id)
        let compat = IndexCompatibility.check(existing, bookVersion: book.fingerprint, chunking: chunker.config, profile: profile)
        switch compat {
        case .compatible:
            return compat
        case .missing, .needsRechunk:
            let set = chunker.chunk(chapters: chapters, bookVersion: book.fingerprint)
            try await embeddings?.invalidateEmbeddings(bookID: book.id, keeping: nil)
            let manifest = IndexManifest(bookID: book.id, bookVersion: book.fingerprint, chunkingVersion: chunker.config.version,
                                         embeddingProfile: profile, childCount: set.children.count, embeddedCount: 0,
                                         vectorStatus: .none, updatedAt: clock.now())
            try await store.replaceChunks(bookID: book.id, set: set, manifest: manifest)
        case .needsReembed:
            try await embeddings?.invalidateEmbeddings(bookID: book.id, keeping: profile)
            if var m = existing {
                m.embeddingProfile = profile
                m.embeddedCount = 0
                m.vectorStatus = .none
                m.updatedAt = clock.now()
                try await store.saveManifest(m)
            }
        }
        return compat
    }

    /// 增量向量化：默认只处理已读范围内的子块（7.3）；按指纹复用；批次原子写入；可取消/暂停后续作。
    public func embed(bookID: BookID, scope: AccessScope?, service: EmbeddingService, budget: IndexingBudget = IndexingBudget(),
                      onProgress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> IndexingReport {
        var report = IndexingReport()
        guard let embeddings else { report.lastError = "no_embedding_store"; return report }
        do {
            var all = try await store.children(bookID: bookID)
            if let scope {
                all = all.filter { scope.allows(bookID: $0.bookID, version: $0.bookVersion, chapterIndex: $0.chapterIndex, range: $0.range) }
            }
            let done = try await embeddings.embeddedChildIDs(bookID: bookID, profile: service.profile)
            report.alreadyEmbedded = all.filter { done.contains($0.id) }.count
            var pending = all.filter { !done.contains($0.id) }

            // 指纹复用：相同内容 + 相同模型/维度的向量直接复用，不发请求
            let reuse = try await embeddings.vectors(fingerprints: pending.map(\.fingerprint), profile: service.profile)
            let reusable = pending.filter { reuse[$0.fingerprint] != nil }
            if !reusable.isEmpty {
                try await embeddings.saveEmbeddings(reusable.map {
                    EmbeddingItem(childID: $0.id, bookID: $0.bookID, fingerprint: $0.fingerprint, vector: reuse[$0.fingerprint]!)
                }, profile: service.profile)
                report.reusedByFingerprint = reusable.count
                pending.removeAll { reuse[$0.fingerprint] != nil }
            }

            let total = all.count
            var processed = report.alreadyEmbedded + report.reusedByFingerprint
            await onProgress(processed, total)
            let batchSize = min(budget.batchSize, max(1, service.maxBatchSize))
            var index = 0
            while index < pending.count {
                if Task.isCancelled { report.cancelled = true; break }
                if report.remoteBatches >= budget.maxRemoteBatches { report.paused = true; break }
                let batch = Array(pending[index..<min(pending.count, index + batchSize)])
                report.remoteBatches += 1
                do {
                    let vectors = try await service.embed(batch.map(\.text), purpose: .document)
                    guard vectors.count == batch.count else {
                        throw VectorError.dimensionMismatch(expected: batch.count, actual: vectors.count)
                    }
                    let items = zip(batch, vectors).map {
                        EmbeddingItem(childID: $0.id, bookID: $0.bookID, fingerprint: $0.fingerprint, vector: $1)
                    }
                    try await embeddings.saveEmbeddings(items, profile: service.profile)
                    report.embedded += batch.count
                } catch is CancellationError {
                    report.cancelled = true; break
                } catch {
                    report.failedBatches += 1
                    report.lastError = "\(error)"
                    // 失败即暂停，保留进度，用户可继续
                    report.paused = true
                    break
                }
                index += batch.count
                processed += batch.count
                await onProgress(processed, total)
            }

            if var m = try await store.manifest(bookID: bookID) {
                let count = try await embeddings.embeddedChildIDs(bookID: bookID, profile: service.profile).count
                m.embeddingProfile = service.profile
                m.embeddedCount = count
                m.vectorStatus = count == 0 ? .none : (count >= m.childCount ? .complete : .partial)
                m.updatedAt = clock.now()
                try await store.saveManifest(m)
            }
        } catch {
            report.lastError = "\(error)"
            report.failedBatches += 1
        }
        return report
    }
}
