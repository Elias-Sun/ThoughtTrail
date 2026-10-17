import Testing
import Foundation
@testable import RetrievalCore
import LibraryCore
import TestSupport

@Suite("M06 分词")
struct SegmenterTests {
    let seg = TextSegmenter()

    @Test("RAG-02 中文按单字与二元组切分，不依赖英文分词假设")
    func cjkBigrams() {
        let t = seg.tokens("遗忘曲线")
        #expect(t.contains("遗忘") && t.contains("忘曲") && t.contains("曲线"))
        #expect(t.contains("遗") && t.contains("线"))
    }

    @Test("RAG-02 中文虚词单字被过滤，二元组保留")
    func cjkStopwords() {
        let t = seg.tokens("我的书")
        #expect(!t.contains("的"))
        #expect(t.contains("我的") && t.contains("的书"))
    }

    @Test("RAG-02 英文小写化、去停用词并做轻量词干化")
    func englishStemming() {
        #expect(seg.tokens("The Bridges were DAMAGED") == ["bridge", "damag"])
        #expect(seg.tokens("stories") == ["story"])
        #expect(seg.tokens("glass") == ["glass"])
    }

    @Test("RAG-02 中英混排与专有名词数字都能切出")
    func mixedText() {
        let t = seg.tokens("Westmere港口有7座桥")
        #expect(t.contains("westmere"))
        #expect(t.contains("港口"))
        #expect(t.contains("7"))
    }

    @Test("RAG-02 所有格与缩写处理")
    func apostrophes() {
        #expect(seg.tokens("keeper's lamp") == ["keeper", "lamp"])
        #expect(seg.tokens("didn't").first == "didnt")
    }

    @Test("RAG-02 FTS 查询为每个词项加引号并以 OR 连接")
    func ftsQuery() {
        let q = seg.ftsQuery("读书\"方法")
        #expect(q?.contains("\"读书\"") == true)
        #expect(q?.contains(" OR ") == true)
        #expect(!(q ?? "").contains("\"\"\""))
        #expect(seg.ftsQuery("的 the ，。") == nil)
    }

    @Test("RAG-02 FTS 文档形式与分词一致")
    func ftsDocument() {
        #expect(seg.ftsDocument("复习间隔") == seg.tokens("复习间隔").joined(separator: " "))
    }
}

@Suite("M06 句子切分")
struct SentenceTests {
    @Test("RAG-01 中文句末标点切分并保留绝对偏移")
    func chinese() {
        let text = "第一句。第二句！第三句？"
        let s = SentenceSplitter.sentences(in: text)
        #expect(s.count == 3)
        #expect(text.substring(utf16: s[1]) == "第二句！")
    }

    @Test("RAG-01 英文句点后跟空白才断句，小数不断开")
    func englishPeriods() {
        let text = "Pi is 3.14 roughly. Next sentence here."
        let s = SentenceSplitter.sentences(in: text).map { text.substring(utf16: $0).trimmingCharacters(in: .whitespaces) }
        #expect(s == ["Pi is 3.14 roughly.", "Next sentence here."])
    }

    @Test("RAG-01 句末标点后的右引号归入本句")
    func closingQuotes() {
        let text = "他说：“走吧。”然后离开。"
        let s = SentenceSplitter.sentences(in: text).map { text.substring(utf16: $0) }
        #expect(s.first == "他说：“走吧。”")
    }

    @Test("RAG-01 区间参数限定切分范围")
    func rangeLimited() {
        let text = "前文。目标一。目标二。后文。"
        let r = TextSpan(start: 3, end: 11)
        let s = SentenceSplitter.sentences(in: text, range: r)
        #expect(s.map { text.substring(utf16: $0) } == ["目标一。", "目标二。"])
    }
}

@Suite("M06 父子切块")
struct ChunkerTests {
    let chapter = Make.chapter(text: (0..<12).map { "第\($0)段。这里是一些用于测试切块的中文内容，句子足够长以便组合。另一句话补充说明。" }.joined(separator: "\n"))

    @Test("RAG-01 每个子块区间都能回查到章节原文")
    func childrenTraceable() {
        let set = Chunker(config: ChunkingConfig(parentMaxChars: 200, childMaxChars: 60)).chunk(chapter: chapter, bookVersion: "abcdef1234567890")
        #expect(!set.children.isEmpty)
        for c in set.children {
            #expect(chapter.text.substring(utf16: c.range) == c.text)
            #expect(c.bookVersion == "abcdef1234567890")
            #expect(c.fingerprint == Fingerprint.short(c.text, length: 16))
        }
    }

    @Test("RAG-01 子块位于其父块区间内，父块不超过上限")
    func childrenInsideParents() {
        let set = Chunker(config: ChunkingConfig(parentMaxChars: 200, childMaxChars: 60)).chunk(chapter: chapter, bookVersion: "v")
        let parents = Dictionary(uniqueKeysWithValues: set.parents.map { ($0.id, $0) })
        for c in set.children {
            let p = try! #require(parents[c.parentID])
            #expect(p.range.contains(c.range))
        }
        #expect(set.parents.allSatisfy { $0.range.length <= 200 })
    }

    @Test("RAG-05 同一内容与配置切块 ID 稳定")
    func stableIDs() {
        let a = Chunker().chunk(chapter: chapter, bookVersion: "v1234567890123")
        let b = Chunker().chunk(chapter: chapter, bookVersion: "v1234567890123")
        #expect(a.children.map(\.id) == b.children.map(\.id))
        #expect(a.children.first?.id.hasPrefix("b1/v12345678901:0:p0:c") == true)
    }

    @Test("RAG-02 空白段落不产生子块")
    func emptySkipped() {
        let set = Chunker().chunk(chapter: Make.chapter(text: "   \n \n"), bookVersion: "v")
        #expect(set.children.isEmpty && set.parents.isEmpty)
    }

    @Test("RAG-01 超长段落按句切分为多个父块")
    func longParagraphSplit() {
        let long = Make.chapter(text: String(repeating: "很长的一句话用于测试。", count: 60))
        let set = Chunker(config: ChunkingConfig(parentMaxChars: 120, childMaxChars: 40)).chunk(chapter: long, bookVersion: "v")
        #expect(set.parents.count > 1)
        #expect(set.parents.allSatisfy { $0.range.length <= 120 })
    }

    @Test("RAG-01 过短的尾块并入前一子块")
    func shortTailMerged() {
        let text = String(repeating: "甲", count: 50) + "。" + "乙。"
        let set = Chunker(config: ChunkingConfig(parentMaxChars: 400, childMaxChars: 52, childMinChars: 10)).chunk(chapter: Make.chapter(text: text), bookVersion: "v")
        #expect(set.children.count == 1)
        #expect(set.children[0].text.hasSuffix("乙。"))
    }

    @Test("RAG-05 切块策略版本随配置变化")
    func versionReflectsConfig() {
        #expect(ChunkingConfig(parentMaxChars: 1200, childMaxChars: 320).version != ChunkingConfig(parentMaxChars: 1000, childMaxChars: 320).version)
        #expect(ChunkingConfig().version.contains(TextSegmenter.version))
    }

    @Test("RAG-01 无标点的超长句被硬切，不丢字")
    func hardSplit() {
        let text = String(repeating: "字", count: 130)
        let set = Chunker(config: ChunkingConfig(parentMaxChars: 400, childMaxChars: 50, childMinChars: 5)).chunk(chapter: Make.chapter(text: text), bookVersion: "v")
        #expect(set.children.map(\.text).joined() == text)
    }
}
