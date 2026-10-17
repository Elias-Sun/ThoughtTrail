import Testing
import Foundation
@testable import RetrievalCore

@Suite("M06 BM25")
struct BM25Tests {
    func index() -> BM25Index {
        var i = BM25Index()
        i.add(id: "a", text: "遗忘曲线表明新学的内容遗忘得最快")
        i.add(id: "b", text: "复习应当按照逐渐拉长的间隔进行")
        i.add(id: "c", text: "The storm damaged three bridges in October")
        i.add(id: "d", text: "读书要带着问题去读")
        return i
    }

    @Test("RAG-02 中文词语召回相关文档排第一")
    func chineseQuery() {
        #expect(index().search("遗忘", limit: 3).first?.id == "a")
        #expect(index().search("复习的间隔", limit: 3).first?.id == "b")
    }

    @Test("RAG-02 英文短语召回")
    func englishQuery() {
        #expect(index().search("damaged bridges", limit: 3).first?.id == "c")
    }

    @Test("READ-05 过滤函数在召回阶段排除不可见文档")
    func filter() {
        let r = index().search("遗忘 复习", limit: 5) { $0 != "a" }
        #expect(!r.contains { $0.id == "a" })
        #expect(r.contains { $0.id == "b" })
    }

    @Test("RAG-05 删除后不再召回；重复添加同 ID 幂等")
    func removeAndReadd() {
        var i = index()
        i.remove(id: "a")
        #expect(i.search("遗忘", limit: 3).isEmpty)
        i.add(id: "b", text: "全新内容关于灯塔")
        i.add(id: "b", text: "全新内容关于灯塔")
        #expect(i.count == 3)
        #expect(i.search("灯塔", limit: 3).map(\.id) == ["b"])
    }

    @Test("RAG-02 空文本不进入索引，空查询无结果")
    func emptyHandling() {
        var i = BM25Index()
        #expect(i.add(id: "x", text: "  ，。 ") == false)
        #expect(i.count == 0)
        #expect(index().search("的 了", limit: 3).isEmpty)
    }

    @Test("RAG-03 稀有词的 IDF 权重高于常见词")
    func idfWeighting() {
        var i = BM25Index()
        for n in 0..<5 { i.add(id: "common\(n)", text: "读书 读书 方法 \(n)") }
        i.add(id: "rare", text: "读书 灯塔")
        #expect(i.search("读书 灯塔", limit: 1).first?.id == "rare")
    }

    @Test("RAG-03 同分按 ID 稳定排序，limit 生效")
    func stableOrdering() {
        var i = BM25Index()
        i.add(id: "y", text: "同样的文本")
        i.add(id: "x", text: "同样的文本")
        #expect(i.search("同样", limit: 1).map(\.id) == ["x"])
    }
}

@Suite("M06 向量索引")
struct VectorIndexTests {
    @Test("RAG-02 余弦相似度排序")
    func cosineOrdering() throws {
        var v = VectorIndex(dimension: 3)
        try v.add(id: "x", vector: [1, 0, 0])
        try v.add(id: "y", vector: [0.7, 0.7, 0])
        try v.add(id: "z", vector: [0, 0, 1])
        #expect(try v.search([1, 0.1, 0], limit: 3).map(\.id) == ["x", "y", "z"])
    }

    @Test("RAG-05 维度不符的向量被拒绝")
    func dimensionMismatch() {
        var v = VectorIndex(dimension: 4)
        #expect(throws: VectorError.dimensionMismatch(expected: 4, actual: 3)) { try v.add(id: "a", vector: [1, 2, 3]) }
        #expect(throws: VectorError.dimensionMismatch(expected: 4, actual: 2)) { try v.search([1, 2], limit: 1) }
    }

    @Test("RAG-02 NaN/无穷与零向量不进入有效索引")
    func invalidVectors() {
        var v = VectorIndex(dimension: 2)
        #expect(throws: VectorError.nonFinite) { try v.add(id: "a", vector: [.nan, 1]) }
        #expect(throws: VectorError.nonFinite) { try v.add(id: "a", vector: [.infinity, 1]) }
        #expect(throws: VectorError.zeroVector) { try v.add(id: "a", vector: [0, 0]) }
        #expect(v.count == 0)
    }

    @Test("READ-05 向量检索支持范围过滤")
    func filtered() throws {
        var v = VectorIndex(dimension: 2)
        try v.add(id: "a", vector: [1, 0])
        try v.add(id: "b", vector: [0.9, 0.1])
        #expect(try v.search([1, 0], limit: 2) { $0 == "b" }.map(\.id) == ["b"])
    }

    @Test("RAG-05 同 ID 重新写入替换旧向量，删除后不召回")
    func replaceAndRemove() throws {
        var v = VectorIndex(dimension: 2)
        try v.add(id: "a", vector: [1, 0])
        try v.add(id: "a", vector: [0, 1])
        #expect(try v.search([0, 1], limit: 1).first?.score ?? 0 > 0.99)
        v.remove(id: "a")
        #expect(try v.search([0, 1], limit: 1).isEmpty)
    }
}

@Suite("M06 融合与重排映射")
struct FusionTests {
    @Test("RAG-03 RRF 只用名次融合：两路都靠前的结果排第一")
    func rrfRanking() {
        let lexical = [ScoredID(id: "a", score: 30), ScoredID(id: "b", score: 20), ScoredID(id: "c", score: 10)]
        let vector = [ScoredID(id: "b", score: 0.9), ScoredID(id: "d", score: 0.8), ScoredID(id: "a", score: 0.1)]
        let fused = RRF.fuse([lexical, vector], limit: 10)
        #expect(fused.prefix(2).map(\.id).sorted() == ["a", "b"])
        #expect(fused.first?.id == "b" || fused.first?.id == "a")
        #expect(Set(fused.map(\.id)) == ["a", "b", "c", "d"])
    }

    @Test("RAG-03 分数尺度差异不影响融合（只看名次）")
    func scaleInvariant() {
        let a = RRF.fuse([[ScoredID(id: "x", score: 1000), ScoredID(id: "y", score: 1)]], limit: 2)
        let b = RRF.fuse([[ScoredID(id: "x", score: 0.2), ScoredID(id: "y", score: 0.1)]], limit: 2)
        #expect(a == b)
    }

    @Test("RAG-03 单路内重复 ID 只计一次，limit 生效")
    func duplicatesAndLimit() {
        let fused = RRF.fuse([[ScoredID(id: "a", score: 1), ScoredID(id: "a", score: 1), ScoredID(id: "b", score: 1)]], limit: 1)
        #expect(fused.map(\.id) == ["a"])
        #expect(abs(fused[0].score - 1.0 / 61.0) < 1e-12)
    }

    @Test("RAG-03 重排结果正确映射回候选 ID（乱序返回）")
    func rerankMapping() {
        let candidates = [ScoredID(id: "a", score: 3), ScoredID(id: "b", score: 2), ScoredID(id: "c", score: 1)]
        let out = RerankMapper.map([RerankScore(index: 2, score: 0.9), RerankScore(index: 0, score: 0.5), RerankScore(index: 1, score: 0.1)], candidates: candidates)
        #expect(out.ordered.map(\.id) == ["c", "a", "b"])
        #expect(out.invalidIndices.isEmpty && out.missingIDs.isEmpty)
    }

    @Test("RAG-03 越界、重复与非有限分数的重排索引被丢弃并记录")
    func invalidIndices() {
        let candidates = [ScoredID(id: "a", score: 1), ScoredID(id: "b", score: 1)]
        let out = RerankMapper.map([RerankScore(index: 7, score: 1), RerankScore(index: 1, score: 0.8), RerankScore(index: 1, score: 0.7),
                                    RerankScore(index: 0, score: .nan)], candidates: candidates)
        #expect(out.ordered.first?.id == "b")
        #expect(Set(out.invalidIndices) == [7, 1, 0])
    }

    @Test("RAG-03 重排缺失的候选保持融合顺序排在后面")
    func missingAppended() {
        let candidates = [ScoredID(id: "a", score: 3), ScoredID(id: "b", score: 2), ScoredID(id: "c", score: 1)]
        let out = RerankMapper.map([RerankScore(index: 2, score: 0.9)], candidates: candidates)
        #expect(out.ordered.map(\.id) == ["c", "a", "b"])
        #expect(out.missingIDs == ["a", "b"])
    }
}
