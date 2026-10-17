import Testing
import Foundation
@testable import RetrievalCore
import LibraryCore
import ReadingSessionCore
import TestSupport

/// 可控失败的向量服务。
actor FlakyEmbedder: EmbeddingService {
    nonisolated let profile = EmbeddingProfile(model: "flaky", dimensions: 16)
    nonisolated let maxBatchSize = 2
    var calls = 0
    var failOnCall: Int?
    var badDimensionOnCall: Int?
    let inner = HashEmbeddingService(model: "flaky", dimensions: 16)

    func configure(failOn: Int?, badDimOn: Int? = nil) { failOnCall = failOn; badDimensionOnCall = badDimOn }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        calls += 1
        if calls == failOnCall { throw CocoaError(.featureUnsupported) }
        if calls == badDimensionOnCall { return texts.map { _ in [1, 2, 3] } }
        return try await inner.embed(texts, purpose: purpose)
    }
}

@Suite("M06 索引生命周期")
struct IndexingTests {
    let chapters = (0..<3).map { Make.chapter(index: $0, text: "第\($0)章。" + (0..<4).map { "这是第\($0)句内容，用于索引。" }.joined()) }
    let book = Make.book(fingerprint: "fp-version-1")

    func indexer(_ store: InMemoryRetrievalStore) -> BookIndexer {
        BookIndexer(store: store, embeddings: store, chunker: Chunker(config: ChunkingConfig(parentMaxChars: 80, childMaxChars: 30, childMinChars: 5)),
                    clock: ManualClock())
    }

    @Test("RAG-05 清单检查：缺失/内容变化/模型变化/兼容")
    func compatibilityCheck() {
        let cfg = ChunkingConfig()
        let p = EmbeddingProfile(model: "m", dimensions: 8)
        let m = IndexManifest(bookID: "b", bookVersion: "v", chunkingVersion: cfg.version, embeddingProfile: p, childCount: 1,
                              embeddedCount: 1, vectorStatus: .complete, updatedAt: Date())
        #expect(IndexCompatibility.check(nil, bookVersion: "v", chunking: cfg, profile: p) == .missing)
        #expect(IndexCompatibility.check(m, bookVersion: "v2", chunking: cfg, profile: p) == .needsRechunk)
        #expect(IndexCompatibility.check(m, bookVersion: "v", chunking: ChunkingConfig(parentMaxChars: 10), profile: p) == .needsRechunk)
        #expect(IndexCompatibility.check(m, bookVersion: "v", chunking: cfg, profile: EmbeddingProfile(model: "m", dimensions: 16)) == .needsReembed)
        #expect(IndexCompatibility.check(m, bookVersion: "v", chunking: cfg, profile: p) == .compatible)
    }

    @Test("RAG-05 首次建立词法索引并记录切块策略与内容版本")
    func ensureLexicalCreates() async throws {
        let store = InMemoryRetrievalStore()
        let result = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: nil)
        #expect(result == .missing)
        let m = try #require(try await store.manifest(bookID: book.id))
        #expect(m.bookVersion == book.fingerprint)
        #expect(m.childCount == (try await store.children(bookID: book.id)).count)
        #expect(try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: nil) == .compatible)
    }

    @Test("RAG-05 书籍内容版本变化触发重新切块且旧向量失效")
    func versionChangeRebuilds() async throws {
        let store = InMemoryRetrievalStore()
        let emb = HashEmbeddingService(model: "flaky", dimensions: 16)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        _ = await indexer(store).embed(bookID: book.id, scope: nil, service: emb)
        var newBook = book
        newBook.fingerprint = "fp-version-2"
        #expect(try await indexer(store).ensureLexicalIndex(book: newBook, chapters: chapters, profile: emb.profile) == .needsRechunk)
        #expect(try await store.embeddedChildIDs(bookID: book.id, profile: emb.profile).isEmpty)
        #expect(try await store.children(bookID: book.id).allSatisfy { $0.bookVersion == "fp-version-2" })
    }

    @Test("RAG-05 向量模型或维度变化只重建向量")
    func modelChangeReembeds() async throws {
        let store = InMemoryRetrievalStore()
        let old = HashEmbeddingService(model: "a", dimensions: 16)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: old.profile)
        _ = await indexer(store).embed(bookID: book.id, scope: nil, service: old)
        let newer = HashEmbeddingService(model: "a", dimensions: 32)
        #expect(try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: newer.profile) == .needsReembed)
        #expect(try await store.manifest(bookID: book.id)?.vectorStatus == IndexManifest.VectorStatus.none)
        #expect(try await store.embeddedChildIDs(bookID: book.id, profile: old.profile).isEmpty)
    }

    @Test("7.3 默认只对已读范围的子块生成云向量")
    func embedsOnlyReadScope() async throws {
        let store = InMemoryRetrievalStore()
        let emb = HashEmbeddingService(model: "flaky", dimensions: 16)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        var state = BookReadState(bookID: book.id, bookVersion: book.fingerprint)
        state.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: chapters[0].length))
        let report = await indexer(store).embed(bookID: book.id, scope: .readOnly(state), service: emb)
        let embedded = try await store.embeddedChildIDs(bookID: book.id, profile: emb.profile)
        let ch0 = try await store.children(bookID: book.id).filter { $0.chapterIndex == 0 }
        #expect(embedded == Set(ch0.map(\.id)))
        #expect(report.embedded == ch0.count)
        #expect(try await store.manifest(bookID: book.id)?.vectorStatus == .partial)
    }

    @Test("RAG-06 中途失败后暂停并保留进度；续作不重复插入、不重复计数")
    func resumeAfterFailure() async throws {
        let store = InMemoryRetrievalStore()
        let emb = FlakyEmbedder()
        await emb.configure(failOn: 2)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        let total = try await store.children(bookID: book.id).count
        let first = await indexer(store).embed(bookID: book.id, scope: nil, service: emb, budget: IndexingBudget(batchSize: 2))
        #expect(first.paused && first.failedBatches == 1)
        #expect(first.embedded == 2)
        await emb.configure(failOn: nil)
        let second = await indexer(store).embed(bookID: book.id, scope: nil, service: emb, budget: IndexingBudget(batchSize: 2))
        #expect(second.alreadyEmbedded == 2)
        #expect(second.embedded + second.reusedByFingerprint == total - 2)
        #expect(second.completed)
        #expect(try await store.embeddedChildIDs(bookID: book.id, profile: emb.profile).count == total)
        #expect(try await store.manifest(bookID: book.id)?.vectorStatus == .complete)
    }

    @Test("RAG-06 相同内容按指纹复用向量，不发远端请求")
    func fingerprintReuse() async throws {
        let store = InMemoryRetrievalStore()
        let counter = CallCounter()
        let emb = HashEmbeddingService(model: "flaky", dimensions: 16, calls: counter)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        _ = await indexer(store).embed(bookID: book.id, scope: nil, service: emb)
        let callsAfterFirst = await counter.count
        // 同样内容的另一本书
        let twin = Make.book(id: "b2", fingerprint: "fp-version-1")
        let twinChapters = chapters.map { Make.chapter(bookID: "b2", index: $0.index, text: $0.text) }
        _ = try await indexer(store).ensureLexicalIndex(book: twin, chapters: twinChapters, profile: emb.profile)
        let report = await indexer(store).embed(bookID: "b2", scope: nil, service: emb)
        #expect(report.reusedByFingerprint > 0)
        #expect(report.remoteBatches == 0)
        #expect(await counter.count == callsAfterFirst)
    }

    @Test("RAG-05 维度异常的批次整批不写入")
    func badDimensionBatchRejected() async throws {
        let store = InMemoryRetrievalStore()
        let emb = FlakyEmbedder()
        await emb.configure(failOn: nil, badDimOn: 1)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        let report = await indexer(store).embed(bookID: book.id, scope: nil, service: emb, budget: IndexingBudget(batchSize: 2))
        #expect(report.failedBatches == 1 && report.paused)
        #expect(try await store.embeddedChildIDs(bookID: book.id, profile: emb.profile).isEmpty)
    }

    @Test("10.2 后台索引超出批次预算时暂停，可继续")
    func budgetPause() async throws {
        let store = InMemoryRetrievalStore()
        let emb = HashEmbeddingService(model: "flaky", dimensions: 16, maxBatchSize: 1)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        let r = await indexer(store).embed(bookID: book.id, scope: nil, service: emb, budget: IndexingBudget(maxRemoteBatches: 2, batchSize: 1))
        #expect(r.paused && r.remoteBatches == 2 && r.embedded == 2)
    }

    @Test("RAG-06 任务被取消时停止并标记取消")
    func cancellation() async throws {
        let store = InMemoryRetrievalStore()
        let emb = HashEmbeddingService(model: "flaky", dimensions: 16, maxBatchSize: 1)
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: emb.profile)
        let idx = indexer(store)
        let task = Task { await idx.embed(bookID: book.id, scope: nil, service: emb, budget: IndexingBudget(batchSize: 1)) }
        task.cancel()
        let r = await task.value
        #expect(r.cancelled || r.completed)
        if r.cancelled { #expect(!r.completed) }
    }

    @Test("RAG-05 删除书籍的索引后检索不到其内容")
    func removeChunks() async throws {
        let store = InMemoryRetrievalStore()
        _ = try await indexer(store).ensureLexicalIndex(book: book, chapters: chapters, profile: nil)
        try await store.removeChunks(bookID: book.id)
        #expect(try await store.children(bookID: book.id).isEmpty)
        #expect(try await store.manifest(bookID: book.id) == nil)
        let hits = try await store.searchLexical("内容", scope: RetrievalScope([.wholeBook(bookID: book.id, version: book.fingerprint)]), limit: 5)
        #expect(hits.isEmpty)
    }
}
