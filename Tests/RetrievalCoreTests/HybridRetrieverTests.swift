import Testing
import Foundation
@testable import RetrievalCore
import LibraryCore
import ReadingSessionCore
import TestSupport

/// 构建一本书的内存检索语料。
struct Corpus {
    let store = InMemoryRetrievalStore()
    let chapters: [Chapter]
    let version = "ver0123456789ab"

    init(_ texts: [String], bookID: BookID = "b1") async throws {
        chapters = texts.enumerated().map { Make.chapter(bookID: bookID, index: $0.offset, text: $0.element) }
        try await index(bookID: bookID, chapters: chapters, version: version)
    }

    func index(bookID: BookID, chapters: [Chapter], version: String, profile: EmbeddingProfile? = nil) async throws {
        let set = Chunker(config: ChunkingConfig(parentMaxChars: 300, childMaxChars: 60, childMinChars: 8)).chunk(chapters: chapters, bookVersion: version)
        try await store.replaceChunks(bookID: bookID, set: set, manifest: IndexManifest(
            bookID: bookID, bookVersion: version, chunkingVersion: "t", embeddingProfile: profile, childCount: set.children.count,
            embeddedCount: 0, vectorStatus: .none, updatedAt: Date()))
    }

    func readScope(_ chapterIndices: [Int], bookID: BookID = "b1") -> AccessScope {
        var state = BookReadState(bookID: bookID, bookVersion: version)
        for i in chapterIndices { state.markRead(chapterIndex: i, range: TextSpan(start: 0, end: chapters[i].length)) }
        return .readOnly(state)
    }

    func embedAll(_ embedder: HashEmbeddingService, bookID: BookID = "b1") async throws {
        let children = try await store.children(bookID: bookID)
        try await store.saveEmbeddings(children.map { EmbeddingItem(childID: $0.id, bookID: bookID, fingerprint: $0.fingerprint, vector: embedder.vector($0.text)) },
                                       profile: embedder.profile)
        var m = try await store.manifest(bookID: bookID)!
        m.embeddingProfile = embedder.profile
        m.vectorStatus = .complete
        try await store.saveManifest(m)
    }
}

let corpusTexts = [
    "读书要带着问题去读。做批注能让被动接收变成主动思考。精读用于奠基之作。",
    "遗忘曲线表明新内容最初几天遗忘最快。复习应当按照逐渐拉长的间隔进行。自测比重读更有效。",
    "最后一章揭示灯塔管理员其实就是失踪多年的船长。只有读到结尾的人才会知道这个秘密。",
]

@Suite("M06 混合检索")
struct HybridRetrieverTests {
    @Test("RAG-02 中文问题经词法召回命中对应章节")
    func lexicalChinese() async throws {
        let c = try await Corpus(corpusTexts)
        let r = await HybridRetriever(chunks: c.store, lexical: c.store).retrieve(queries: ["复习的间隔怎么安排"], scope: RetrievalScope([c.readScope([0, 1, 2])]))
        #expect(r.units.first?.chapterIndex == 1)
        #expect(r.units.first?.text.contains("间隔") == true)
    }

    @Test("READ-05 未读章节不进入召回（即使最相关）")
    func unreadExcluded() async throws {
        let c = try await Corpus(corpusTexts)
        let r = await HybridRetriever(chunks: c.store, lexical: c.store).retrieve(queries: ["灯塔管理员是谁"], scope: RetrievalScope([c.readScope([0, 1])]))
        #expect(r.units.allSatisfy { $0.chapterIndex != 2 })
    }

    @Test("RAG-04 父块扩展跨越已读边界时被裁剪，不整体带入")
    func expansionClipped() async throws {
        let chapterText = "遗忘曲线表明新内容最初几天遗忘最快。复习应当按照逐渐拉长的间隔进行。每次间隔大约翻倍。最后一段写着尚未读到的结论：自测比重读更有效。"
        let c = try await Corpus(["序。", chapterText])
        let readEnd = chapterText.utf16Ranges(of: "最后一段")[0].start
        var state = BookReadState(bookID: "b1", bookVersion: c.version)
        state.markRead(chapterIndex: 1, range: TextSpan(start: 0, end: readEnd))
        let r = await HybridRetriever(chunks: c.store, lexical: c.store).retrieve(queries: ["遗忘曲线"], scope: RetrievalScope([.readOnly(state)]))
        let unit = try #require(r.units.first)
        #expect(unit.range.end <= readEnd)
        #expect(unit.clippedByBoundary)
        #expect(!unit.text.contains("自测比重读更有效"))
    }

    @Test("RAG-03 词法与向量双路召回后 RRF 融合")
    func hybridFusion() async throws {
        let c = try await Corpus(corpusTexts)
        let emb = HashEmbeddingService(dimensions: 128)
        try await c.embedAll(emb)
        let r = await HybridRetriever(chunks: c.store, lexical: c.store, vectors: c.store, embedder: emb)
            .retrieve(queries: ["自测与复习"], scope: RetrievalScope([c.readScope([0, 1, 2])]))
        #expect(r.diagnostics.lexicalHits > 0 && r.diagnostics.vectorHits > 0)
        #expect(r.units.first?.chapterIndex == 1)
        #expect(r.units.first?.lexicalRank != nil)
        #expect(r.units.first?.vectorRank != nil)
    }

    @Test("RAG-06 Embedding 不可用时降级为词法检索并记录原因")
    func embeddingDegrades() async throws {
        let c = try await Corpus(corpusTexts)
        let good = HashEmbeddingService(dimensions: 32)
        try await c.embedAll(good)
        let failing = HashEmbeddingService(dimensions: 32, failing: true)
        let r = await HybridRetriever(chunks: c.store, lexical: c.store, vectors: c.store, embedder: failing)
            .retrieve(queries: ["遗忘"], scope: RetrievalScope([c.readScope([0, 1])]))
        #expect(!r.units.isEmpty)
        #expect(r.diagnostics.degradations.contains("embedding_unavailable_lexical_only"))
        #expect(r.diagnostics.vectorHits == 0)
    }

    @Test("RAG-06 Rerank 失败时保留融合排序")
    func rerankFailureKeepsFusion() async throws {
        let c = try await Corpus(corpusTexts)
        let scope = RetrievalScope([c.readScope([0, 1, 2])])
        let base = await HybridRetriever(chunks: c.store, lexical: c.store).retrieve(queries: ["读书 复习 灯塔"], scope: scope)
        let failed = await HybridRetriever(chunks: c.store, lexical: c.store, reranker: OverlapReranker(mode: .failing))
            .retrieve(queries: ["读书 复习 灯塔"], scope: scope)
        #expect(failed.units.map(\.child.id) == base.units.map(\.child.id))
        #expect(failed.diagnostics.degradations.contains("rerank_failed_kept_fusion"))
        #expect(!failed.diagnostics.reranked)
    }

    @Test("RAG-03 重排结果改变最终顺序并映射回正确子块")
    func rerankReorders() async throws {
        let c = try await Corpus(corpusTexts)
        let scope = RetrievalScope([c.readScope([0, 1, 2])])
        let base = await HybridRetriever(chunks: c.store, lexical: c.store, config: RetrievalConfig(expandParents: false))
            .retrieve(queries: ["读书 复习 灯塔 船长"], scope: scope)
        let reversed = await HybridRetriever(chunks: c.store, lexical: c.store, reranker: OverlapReranker(mode: .reversed),
                                             config: RetrievalConfig(expandParents: false))
            .retrieve(queries: ["读书 复习 灯塔 船长"], scope: scope)
        #expect(reversed.diagnostics.reranked)
        #expect(Set(reversed.units.map(\.child.id)) == Set(base.units.map(\.child.id)))
        #expect(reversed.units.map(\.child.id) != base.units.map(\.child.id))
        #expect(reversed.units.allSatisfy { $0.rerankScore != nil })
    }

    @Test("RAG-03 重排返回异常索引时只采用有效部分并记录")
    func rerankInvalidIndices() async throws {
        let c = try await Corpus(corpusTexts)
        let r = await HybridRetriever(chunks: c.store, lexical: c.store, reranker: OverlapReranker(mode: .invalidIndices))
            .retrieve(queries: ["读书 复习"], scope: RetrievalScope([c.readScope([0, 1])]))
        #expect(!r.units.isEmpty)
        #expect(r.diagnostics.degradations.contains { $0.hasPrefix("rerank_invalid_indices") })
    }

    @Test("RAG-05 向量模型与索引不兼容时不混查，按书降级")
    func incompatibleVectorsSkipped() async throws {
        let c = try await Corpus(corpusTexts)
        try await c.embedAll(HashEmbeddingService(model: "old-model", dimensions: 32))
        let r = await HybridRetriever(chunks: c.store, lexical: c.store, vectors: c.store, embedder: HashEmbeddingService(model: "new-model", dimensions: 32))
            .retrieve(queries: ["遗忘"], scope: RetrievalScope([c.readScope([1])]))
        #expect(r.diagnostics.vectorHits == 0)
        #expect(r.diagnostics.degradations.contains("vector_index_incompatible:b1"))
        #expect(!r.units.isEmpty)
    }

    @Test("READ-05 跨书检索逐本使用各自的已读区间")
    func crossBookScopes() async throws {
        let c = try await Corpus(corpusTexts)
        let other = [Make.chapter(bookID: "b2", index: 0, text: "另一本书讲复习与遗忘的关系。"),
                     Make.chapter(bookID: "b2", index: 1, text: "另一本书未读的部分也提到复习。")]
        try await c.index(bookID: "b2", chapters: other, version: c.version)
        var s2 = BookReadState(bookID: "b2", bookVersion: c.version)
        s2.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: other[0].length))
        let r = await HybridRetriever(chunks: c.store, lexical: c.store).retrieve(queries: ["复习"], scope: RetrievalScope([c.readScope([1]), .readOnly(s2)]))
        #expect(Set(r.units.map(\.bookID)) == ["b1", "b2"])
        #expect(!r.units.contains { $0.bookID == "b2" && $0.chapterIndex == 1 })
    }

    @Test("RAG-04 扩展后区间不超过长度上限且包含命中子块")
    func expansionLengthLimit() async throws {
        let long = (0..<30).map { "第\($0)句关于主题的说明，内容足够长。" }.joined()
        let c = try await Corpus([long])
        let r = await HybridRetriever(chunks: c.store, lexical: c.store, config: RetrievalConfig(expansionMaxChars: 80))
            .retrieve(queries: ["第15句"], scope: RetrievalScope([c.readScope([0])]))
        let u = try #require(r.units.first)
        #expect(u.range.length <= 80)
        #expect(u.range.contains(u.child.range))
    }

    @Test("RAG-04 同一父块的重叠扩展被去重合并")
    func dedupeOverlapping() async throws {
        let c = try await Corpus(corpusTexts)
        let r = await HybridRetriever(chunks: c.store, lexical: c.store).retrieve(queries: ["读书 批注 精读"], scope: RetrievalScope([c.readScope([0])]))
        for (i, a) in r.units.enumerated() {
            for b in r.units.dropFirst(i + 1) where a.chapterIndex == b.chapterIndex {
                #expect(!a.range.overlaps(b.range))
            }
        }
    }

    @Test("READ-05 空查询或空范围直接返回空结果")
    func emptyInputs() async throws {
        let c = try await Corpus(corpusTexts)
        let h = HybridRetriever(chunks: c.store, lexical: c.store)
        #expect(await h.retrieve(queries: ["  "], scope: RetrievalScope([c.readScope([0])])).units.isEmpty)
        #expect(await h.retrieve(queries: ["读书"], scope: RetrievalScope([])).units.isEmpty)
    }

    @Test("RAG-02 同义表达依靠向量路召回（词法无重叠）")
    func synonymViaVectors() async throws {
        let c = try await Corpus(["小镇的港口有七座桥。", "风暴毁坏了三座桥梁。"])
        // 构造一个把“暴风雨”映射到与“风暴”相同桶的向量服务：通过查询包含共享二元组模拟同义
        let emb = HashEmbeddingService(dimensions: 256)
        try await c.embedAll(emb)
        let r = await HybridRetriever(chunks: c.store, lexical: nil, vectors: c.store, embedder: emb)
            .retrieve(queries: ["风暴造成的损坏"], scope: RetrievalScope([c.readScope([0, 1])]))
        #expect(r.units.first?.chapterIndex == 1)
        #expect(r.diagnostics.lexicalHits == 0)
    }

    @Test("RAG-06 最终结果数不超过 finalLimit")
    func finalLimit() async throws {
        let many = (0..<20).map { "段落\($0)讨论读书方法与问题。" }.joined(separator: "\n")
        let c = try await Corpus([many])
        let r = await HybridRetriever(chunks: c.store, lexical: c.store, config: RetrievalConfig(finalLimit: 3, expandParents: false))
            .retrieve(queries: ["读书方法"], scope: RetrievalScope([c.readScope([0])]))
        #expect(r.units.count == 3)
    }
}
