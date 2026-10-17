import Foundation
import LibraryCore
import BenchCore
import TestSupport

/// 语料源（Evaluation/corpus-src/books.json）。
struct CorpusSource: Codable {
    struct Book: Codable {
        struct Chapter: Codable { var title: String; var paragraphs: [String] }
        var id: String
        var title: String
        var author: String
        var language: String
        var genre: String
        var chapters: [Chapter]
    }
    var version: String
    var books: [Book]
}

/// 问题源（Evaluation/corpus-src/questions.json）。relevant: [bookID, chapterIndex, quote, grade]
struct QuestionSource: Codable {
    struct Question: Codable {
        var id: String
        var category: String
        var question: String
        var relevant: [[QuoteRef]]?
        var books: [String]?
        var read: [String: [Int]]?
    }

    enum QuoteRef: Codable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .string(let s): try c.encode(s); case .int(let i): try c.encode(i) }
        }

        var string: String? { if case .string(let s) = self { return s }; return nil }
        var int: Int? { if case .int(let i) = self { return i }; return nil }
    }

    var version: String
    var questions: [Question]
}

/// 已解析语料：书籍版本与章节正文（与应用导入同一解析器）。
struct ParsedCorpus {
    struct Book {
        var id: String
        var title: String
        var language: String
        var version: String
        var chapters: [Chapter]
    }
    var books: [String: Book]
    var order: [String]

    func info() -> [BookID: ScopeBuilder.BookInfo] {
        books.mapValues { ScopeBuilder.BookInfo(version: $0.version, chapterLengths: Dictionary(uniqueKeysWithValues: $0.chapters.map { ($0.index, $0.length) })) }
    }

    /// 引语 → UTF-16 区间（必须唯一定位）。
    func span(book: String, chapter: Int, quote: String) throws -> TextSpan {
        guard let b = books[book], let ch = b.chapters.first(where: { $0.index == chapter }) else {
            throw CorpusError.missing("\(book)#\(chapter)")
        }
        let hits = ch.text.utf16Ranges(of: quote)
        guard hits.count == 1 else { throw CorpusError.quote("\(book)#\(chapter)：引语出现 \(hits.count) 次：\(quote)") }
        return hits[0]
    }

    /// 包含区间的整个段落。
    func paragraph(book: String, chapter: Int, containing span: TextSpan) -> TextSpan {
        let ch = books[book]!.chapters.first { $0.index == chapter }!
        return ch.paragraphRanges.first { $0.contains(span) } ?? span
    }
}

enum CorpusError: Error, CustomStringConvertible {
    case missing(String)
    case quote(String)
    var description: String {
        switch self { case .missing(let s): return "缺少章节：\(s)"; case .quote(let s): return s }
    }
}

enum CorpusBuilder {
    static func load(_ evaluationDir: URL) throws -> (CorpusSource, QuestionSource) {
        let src = evaluationDir.appendingPathComponent("corpus-src")
        let books = try JSONDecoder().decode(CorpusSource.self, from: Data(contentsOf: src.appendingPathComponent("books.json")))
        let questions = try JSONDecoder().decode(QuestionSource.self, from: Data(contentsOf: src.appendingPathComponent("questions.json")))
        return (books, questions)
    }

    /// 生成语料 EPUB，并用应用同一解析器解析。
    static func buildEPUBs(_ source: CorpusSource, into dir: URL?) throws -> ParsedCorpus {
        var parsed: [String: ParsedCorpus.Book] = [:]
        for b in source.books {
            let builder = EPUBBuilder(title: b.title, authors: [b.author], language: b.language, identifier: "urn:thoughttrail:\(b.id)",
                                      chapters: b.chapters.map { .init(title: $0.title, paragraphs: $0.paragraphs) })
            let data = try builder.build()
            if let dir {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent("\(b.id).epub"))
            }
            let pub = try EPUBParser().parse(data: data, fileName: "\(b.id).epub")
            let chapters = pub.chapters.map { Chapter(bookID: b.id, index: $0.index, href: $0.href, title: $0.title, text: $0.text) }
            parsed[b.id] = .init(id: b.id, title: b.title, language: b.language, version: Fingerprint.sha256(data), chapters: chapters)
        }
        return ParsedCorpus(books: parsed, order: source.books.map(\.id))
    }

    /// tt-bench corpus：写 EPUB 与全部开发集数据文件（含 sha256 清单）。
    static func write(to evaluationDir: URL) throws {
        let (source, questions) = try load(evaluationDir)
        let corpus = try buildEPUBs(source, into: evaluationDir.appendingPathComponent("corpus"))
        let dsDir = evaluationDir.appendingPathComponent("datasets")
        try FileManager.default.createDirectory(at: dsDir, withIntermediateDirectories: true)
        var manifests: [DatasetManifest] = []

        func writeJSONL<T: Encodable>(_ name: String, _ items: [T], description: String) throws {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let lines = try items.map { String(decoding: try enc.encode($0), as: UTF8.self) }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            try data.write(to: dsDir.appendingPathComponent("\(name).jsonl"))
            manifests.append(DatasetManifest(name: name, version: source.version, split: .dev, annotationStatus: .draftUnreviewed,
                                             description: "\(description)（\(items.count) 条）", frozenSHA256: Fingerprint.sha256(data)))
            print("  \(name): \(items.count) 条")
        }

        try writeJSONL("retrieval-dev", try DatasetGenerators.retrieval(questions, corpus: corpus), description: "检索/回答问题：局部、跨章、跨书、批注记忆、不可回答")
        try writeJSONL("verification-dev", DatasetGenerators.verification(corpus), description: "陈述-证据对：支持/证据不足/矛盾各三分之一，按规则扰动生成")
        try writeJSONL("boundary-dev", DatasetGenerators.boundary(corpus), description: "阅读边界场景：章内未读、跳读、父块扩展、跨书、全书切换")
        try writeJSONL("memory-dev", DatasetGenerators.memory(corpus), description: "记忆提议场景：新增、重复、冲突、修订、关联、来源校验")
        try writeJSONL("learning-dev", try DatasetGenerators.learning(questions, corpus: corpus), description: "自测题：可作答性与反馈参考评分")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifests).write(to: dsDir.appendingPathComponent("manifest.json"))
        print("已生成语料 \(corpus.books.count) 本与数据集到 \(evaluationDir.path)")
    }
}

/// 由源文本按规则生成数据集。标签由构造方式决定，仍需独立人工复核后才能作为验收依据。
enum DatasetGenerators {
    static func retrieval(_ q: QuestionSource, corpus: ParsedCorpus) throws -> [RetrievalCase] {
        try q.questions.map { item in
            let relevant: [RelevantSpan] = try (item.relevant ?? []).map { ref in
                guard ref.count == 4, let b = ref[0].string, let ch = ref[1].int, let quote = ref[2].string, let grade = ref[3].int else {
                    throw CorpusError.quote("\(item.id)：relevant 格式错误")
                }
                let s = try corpus.span(book: b, chapter: ch, quote: quote)
                return RelevantSpan(bookID: b, chapterIndex: ch, start: s.start, end: s.end, grade: grade)
            }
            let books = item.books ?? Array(Set(relevant.map(\.bookID))).sorted()
            let scopes = books.map { b in
                ScopeSpec(bookID: b, readChapters: item.read?[b] ?? corpus.books[b]!.chapters.map(\.index))
            }
            guard let category = RetrievalCategory(rawValue: item.category) else { throw CorpusError.quote("\(item.id)：未知类别") }
            return RetrievalCase(id: item.id, category: category, question: item.question, scopes: scopes, relevant: relevant, note: nil)
        }
    }

    /// 所有段落（书、章、段落区间、文本）。
    static func paragraphs(_ corpus: ParsedCorpus) -> [(book: String, chapter: Int, range: TextSpan, text: String)] {
        corpus.order.flatMap { id -> [(String, Int, TextSpan, String)] in
            corpus.books[id]!.chapters.flatMap { ch in
                ch.paragraphRanges.dropFirst().map { (id, ch.index, $0, ch.text.substring(utf16: $0)) } // 跳过章节标题行
            }
        }.map { (book: $0.0, chapter: $0.1, range: $0.2, text: $0.3) }
    }

    static let zhNumerals: [(String, String)] = [("四十", "二十"), ("二十三", "三十二"), ("二十", "三十"), ("十二", "十五"), ("三百", "五百"),
                                                  ("八十八", "六十六"), ("八十", "九十"), ("一千", "三百"), ("四", "六"), ("三", "五"), ("七", "九"),
                                                  ("两", "三"), ("六", "八"), ("五", "七"), ("九", "四"), ("二", "三")]
    static let zhNegations: [(String, String)] = [("能", "不能"), ("可以", "不可以"), ("需要", "不需要"), ("比", "不比"), ("是", "不是"),
                                                   ("会", "不会"), ("有", "没有"), ("越", "越不")]
    static let enNumbers: [(String, String)] = [("forty", "sixty"), ("twelve", "twenty"), ("four", "six"), ("two thousand", "five hundred"),
                                                 ("six weeks", "ten weeks"), ("one hundred", "ten"), ("twenty", "fifty"), ("thirty-five", "twenty"),
                                                 ("1908", "1958"), ("fifty", "five"), ("ninth", "third"), ("hundred", "thousand"), ("two", "three")]
    static let enNegations: [(String, String)] = [(" is ", " is not "), (" are ", " are not "), (" was ", " was not "), (" can ", " cannot "),
                                                   (" has ", " does not have "), (" had ", " had not "), (" need ", " do not need "),
                                                   (" stayed ", " never stayed "), (" left ", " never left ")]

    static func perturb(_ s: String, english: Bool) -> (String, String)? {
        for (a, b) in english ? enNumbers : zhNumerals where s.contains(a) {
            return (s.replacingOccurrences(of: a, with: b, options: [], range: s.range(of: a)), "number")
        }
        for (a, b) in english ? enNegations : zhNegations where s.contains(a) {
            return (s.replacingOccurrences(of: a, with: b, options: [], range: s.range(of: a)), "negation")
        }
        return nil
    }

    static func verification(_ corpus: ParsedCorpus) -> [VerificationCase] {
        let paras = paragraphs(corpus)
        var out: [VerificationCase] = []
        var supported = 0, contradicted = 0, insufficient = 0
        for (i, p) in paras.enumerated() {
            let english = corpus.books[p.book]!.language.hasPrefix("en")
            let claim = p.text.trimmingCharacters(in: CharacterSet(charactersIn: "。. "))
            if supported < 80 && i % 3 == 0 {
                out.append(VerificationCase(id: "V\(out.count + 1)", claim: claim, evidence: [p.text], label: "supported", perturbation: "none"))
                supported += 1
            } else if contradicted < 80 && i % 3 == 1, let (bad, kind) = perturb(claim, english: english) {
                out.append(VerificationCase(id: "V\(out.count + 1)", claim: bad, evidence: [p.text], label: "contradicted", perturbation: kind))
                contradicted += 1
            } else if insufficient < 80 {
                // 同书另一章节的事实作为陈述：证据不涉及
                let other = paras.first { $0.book == p.book && $0.chapter != p.chapter && $0.text != p.text && (i + $0.chapter) % 2 == 0 }
                    ?? paras[(i + 37) % paras.count]
                out.append(VerificationCase(id: "V\(out.count + 1)", claim: other.text.trimmingCharacters(in: CharacterSet(charactersIn: "。. ")),
                                            evidence: [p.text], label: "insufficient", perturbation: "unrelated"))
                insufficient += 1
            }
        }
        // 第二轮补足（按类别循环）直到各 80 条
        var j = 0
        while (supported < 80 || contradicted < 80 || insufficient < 80) && j < paras.count * 3 {
            let p = paras[j % paras.count]
            let english = corpus.books[p.book]!.language.hasPrefix("en")
            let claim = p.text.trimmingCharacters(in: CharacterSet(charactersIn: "。. "))
            if supported < 80 {
                let paraphrase = english ? "The text says that " + claim.prefix(1).lowercased() + claim.dropFirst() : "书中写道：" + claim
                out.append(VerificationCase(id: "V\(out.count + 1)", claim: paraphrase, evidence: [p.text], label: "supported", perturbation: "paraphrase"))
                supported += 1
            } else if contradicted < 80, let (bad, kind) = perturb(claim, english: english), !out.contains(where: { $0.claim == bad }) {
                out.append(VerificationCase(id: "V\(out.count + 1)", claim: bad, evidence: [p.text], label: "contradicted", perturbation: kind))
                contradicted += 1
            } else if insufficient < 80 {
                let other = paras[(j * 7 + 11) % paras.count]
                if other.book != p.book {
                    out.append(VerificationCase(id: "V\(out.count + 1)", claim: other.text.trimmingCharacters(in: CharacterSet(charactersIn: "。. ")),
                                                evidence: [p.text], label: "insufficient", perturbation: "other_book"))
                    insufficient += 1
                }
            }
            j += 1
        }
        return out
    }

    static func boundary(_ corpus: ParsedCorpus) -> [BoundaryCase] {
        var out: [BoundaryCase] = []
        let paras = paragraphs(corpus)
        func fact(_ book: String, _ chapter: Int, _ k: Int = 0) -> String {
            let list = paras.filter { $0.book == book && $0.chapter == chapter }
            return list[k % list.count].text
        }
        for id in corpus.order {
            let b = corpus.books[id]!
            let n = b.chapters.count
            // 1) 章节未读：读前两章，问后两章的事实
            for k in 0..<3 {
                out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "unread_chapter", query: fact(id, n - 1 - (k % 2), k),
                                        scopes: [ScopeSpec(bookID: id, readChapters: [0, 1])], note: nil))
            }
            // 2) 跳读：读第一章与最后一章，问中间章节
            out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "skip_ahead", query: fact(id, 1, 1),
                                    scopes: [ScopeSpec(bookID: id, readChapters: [0, n - 1])], note: nil))
            out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "skip_ahead", query: fact(id, 2, 2),
                                    scopes: [ScopeSpec(bookID: id, readChapters: [0, n - 1])], note: nil))
            // 3) 章内未读（父块扩展必须裁剪）：只读第二章前两段
            let ch1 = b.chapters[1]
            let paraRanges = ch1.paragraphRanges
            let partial = TextSpan(start: 0, end: paraRanges[min(2, paraRanges.count - 1)].end)
            out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "parent_expansion", query: fact(id, 1, 2) + " " + fact(id, 1, 0),
                                    scopes: [ScopeSpec(bookID: id, readChapters: [], partialRanges: [.init(chapterIndex: 1, start: partial.start, end: partial.end)])],
                                    note: "只读到第二章第二段"))
            // 4) 跨书：两本书各自的已读范围
            let other = corpus.order[(corpus.order.firstIndex(of: id)! + 1) % corpus.order.count]
            out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "cross_book", query: fact(id, 3, 0) + " " + fact(other, 3, 1),
                                    scopes: [ScopeSpec(bookID: id, readChapters: [0, 1]), ScopeSpec(bookID: other, readChapters: [0])], note: nil))
            // 5) 记忆来源未读：记忆证据指向未读章节（由运行器构造记忆）
            out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "memory_unread", query: fact(id, 3, 0),
                                    scopes: [ScopeSpec(bookID: id, readChapters: [0, 1])], note: "记忆证据位于第四章"))
            // 6) 用户主动切换全书范围（对照：允许访问全部章节）
            if out.count % 12 < 2 {
                out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "whole_book_switch", query: fact(id, 3, 1),
                                        scopes: [ScopeSpec(bookID: id, readChapters: [], wholeBook: true)], note: nil))
            }
        }
        // 补足到 100
        var k = 0
        while out.count < 100 {
            let id = corpus.order[k % corpus.order.count]
            out.append(BoundaryCase(id: "BD\(out.count + 1)", kind: "unread_chapter", query: fact(id, 2, k), scopes: [ScopeSpec(bookID: id, readChapters: [0])], note: nil))
            k += 1
        }
        return Array(out.prefix(100))
    }

    static func memory(_ corpus: ParsedCorpus) -> [MemoryCase] {
        let paras = paragraphs(corpus)
        var out: [MemoryCase] = []
        func add(_ kind: String, existing: [MemoryCase.ExistingItem] = [], action: String, content: String?, target: String? = nil, link: String? = nil,
                 base: Int? = nil, allowed: Bool = true, inScope: Bool? = nil, expected: String, issue: String? = nil) {
            out.append(MemoryCase(id: "MEM\(out.count + 1)", kind: kind, existing: existing, action: action, content: content, targetID: target,
                                  linkToID: link, baseRevision: base, evidenceAllowed: allowed, evidenceInScope: inScope,
                                  expectedStatus: expected, expectedIssuePrefix: issue))
        }
        for i in 0..<6 {
            let p = paras[i * 13 % paras.count].text
            let q = paras[(i * 13 + 5) % paras.count].text
            add("new", action: "create", content: p, expected: "pending")
            add("duplicate", existing: [.init(id: "e\(i)", kind: "memory", content: p, revision: 1)], action: "create", content: p + "。", expected: "invalid", issue: "duplicate_of")
            add("near_duplicate_kept", existing: [.init(id: "e\(i)", kind: "memory", content: q, revision: 1)], action: "create", content: p, expected: "pending")
            add("conflict", existing: [.init(id: "t\(i)", kind: "thought", content: p, revision: 3)], action: "revise", content: q, target: "t\(i)", base: 2,
                expected: "invalid", issue: "revision_conflict")
            add("revise_ok", existing: [.init(id: "t\(i)", kind: "thought", content: p, revision: 2)], action: "revise", content: q, target: "t\(i)", base: 2, expected: "pending")
            add("revise_unknown", action: "revise", content: q, target: "ghost\(i)", base: 1, expected: "invalid", issue: "unknown_item")
            add("link_ok", existing: [.init(id: "a\(i)", kind: "thought", content: p, revision: 1), .init(id: "b\(i)", kind: "memory", content: q, revision: 1)],
                action: "link", content: nil, target: "a\(i)", link: "b\(i)", expected: "pending")
            add("link_unknown", existing: [.init(id: "a\(i)", kind: "thought", content: p, revision: 1)], action: "link", content: nil, target: "a\(i)", link: "nope",
                expected: "invalid", issue: "unknown_item")
            add("evidence_foreign", action: "create", content: q, allowed: false, expected: "invalid", issue: "evidence_not_from_discussion")
            add("evidence_out_of_scope", action: "create", content: q, inScope: false, expected: "invalid", issue: "evidence_out_of_scope")
        }
        return out
    }

    static func learning(_ q: QuestionSource, corpus: ParsedCorpus) throws -> [LearningCase] {
        let local = q.questions.filter { $0.category == "local" || $0.category == "annotationMemory" }
        return try local.prefix(60).enumerated().map { i, item in
            guard let ref = item.relevant?.first, let b = ref[0].string, let ch = ref[1].int, let quote = ref[2].string else {
                throw CorpusError.quote("\(item.id)：缺少证据")
            }
            let span = try corpus.span(book: b, chapter: ch, quote: quote)
            let all = corpus.books[b]!.chapters.map(\.index)
            let variant = i % 6
            var scopes = [ScopeSpec(bookID: b, readChapters: all)]
            var prompt = item.question
            var answer = quote
            var expectedAnswerable = true
            var expectedScore: Double? = 1
            switch variant {
            case 1:  // 错误答案
                answer = paragraphs(corpus).first { $0.book != b }!.text
                expectedScore = 0
            case 2:  // 证据所在章节未读：不可作答
                scopes = [ScopeSpec(bookID: b, readChapters: all.filter { $0 != ch })]
                expectedAnswerable = false
                expectedScore = nil
            case 3:  // 题干泄露答案：应拒绝
                prompt = quote + "，对吗？"
                expectedAnswerable = false
                expectedScore = nil
            case 4:  // 空答案
                answer = ""
                expectedScore = 0
            default:
                break
            }
            return LearningCase(id: "LRN\(i + 1)", bookID: b, prompt: prompt, referencePoints: [quote],
                                evidence: [RelevantSpan(bookID: b, chapterIndex: ch, start: span.start, end: span.end)], scopes: scopes,
                                answer: answer, expectedAnswerable: expectedAnswerable, expectedScore: expectedScore)
        }
    }
}
