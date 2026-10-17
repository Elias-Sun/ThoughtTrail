import Foundation
import LibraryCore

/// 中英文分词：拉丁字母/数字按词切分（小写、轻量词干化），CJK 按单字 + 二元组切分。
/// 不依赖默认英文分词对中文的假设（3.1 词法检索）。FTS5 索引与内存 BM25 共用该分词结果。
public struct TextSegmenter: Sendable {
    public static let version = "seg-v1-cjk-bigram"

    static let englishStopwords: Set<String> = [
        "a", "an", "the", "of", "to", "and", "or", "is", "are", "was", "were", "be", "been", "in", "on", "at",
        "it", "its", "that", "this", "for", "with", "as", "by", "from", "but", "not", "do", "does", "did",
        "what", "which", "who", "how", "why", "when", "where", "i", "you", "he", "she", "we", "they",
    ]
    static let cjkStopUnigrams: Set<String> = [
        "的", "了", "是", "在", "和", "也", "就", "都", "而", "及", "与", "着", "或", "一", "个", "这", "那", "之",
        "吗", "呢", "吧", "啊", "么", "什", "怎", "为",
    ]

    public var includeUnigrams: Bool

    public init(includeUnigrams: Bool = true) { self.includeUnigrams = includeUnigrams }

    public func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        var cjkRun: [Character] = []

        func flushWord() {
            guard !word.isEmpty else { return }
            let w = Self.stem(word.lowercased())
            if !Self.englishStopwords.contains(w) && !w.isEmpty { out.append(w) }
            word = ""
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if includeUnigrams || cjkRun.count == 1 {
                for ch in cjkRun {
                    let s = String(ch)
                    if !Self.cjkStopUnigrams.contains(s) { out.append(s) }
                }
            }
            if cjkRun.count >= 2 {
                for i in 0..<(cjkRun.count - 1) { out.append(String(cjkRun[i]) + String(cjkRun[i + 1])) }
            }
            cjkRun.removeAll()
        }

        for ch in text {
            guard let scalar = ch.unicodeScalars.first else { continue }
            if Self.isCJKIdeograph(scalar) {
                flushWord()
                cjkRun.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                word.append(ch)
            } else if ch == "'" || ch == "’" {
                // 撇号：don't → dont；所有格 's 由 stem 处理
                if !word.isEmpty { word.append("'") }
            } else {
                flushWord(); flushCJK()
            }
        }
        flushWord(); flushCJK()
        return out
    }

    /// 轻量英文词干化（复数、所有格、-ing/-ed 常见形式）。
    static func stem(_ w: String) -> String {
        var s = w
        if s.hasSuffix("'s") { s.removeLast(2) }
        s = s.replacingOccurrences(of: "'", with: "")
        guard s.count > 3, s.allSatisfy({ $0.isASCII }) else { return s }
        if s.hasSuffix("ies") && s.count > 4 { return String(s.dropLast(3)) + "y" }
        if s.hasSuffix("sses") { return String(s.dropLast(2)) }
        if s.hasSuffix("ing") && s.count > 5 { return String(s.dropLast(3)) }
        if s.hasSuffix("ed") && s.count > 4 { return String(s.dropLast(2)) }
        if s.hasSuffix("s") && !s.hasSuffix("ss") && !s.hasSuffix("us") && !s.hasSuffix("is") { return String(s.dropLast()) }
        return s
    }

    public static func isCJKIdeograph(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// FTS5 存储/查询用的空格分隔形式。
    public func ftsDocument(_ text: String) -> String { tokens(text).joined(separator: " ") }

    /// FTS5 MATCH 查询：每个 token 加引号，以 OR 连接，交给 bm25() 排序。
    public func ftsQuery(_ text: String) -> String? {
        let unique = Array(NSOrderedSet(array: tokens(text))) as? [String] ?? []
        guard !unique.isEmpty else { return nil }
        return unique.prefix(64).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " OR ")
    }
}

/// 句子边界切分（中英文标点与换行），返回 UTF-16 区间。
public enum SentenceSplitter {
    static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]

    public static func sentences(in text: String, range: TextSpan? = nil) -> [TextSpan] {
        let base = range ?? TextSpan(start: 0, end: text.utf16Length)
        let slice = text.substring(utf16: base)
        var result: [TextSpan] = []
        var start = 0
        var offset = 0
        let chars = Array(slice)
        for (i, ch) in chars.enumerated() {
            let w = String(ch).utf16.count
            offset += w
            var isEnd = terminators.contains(ch) || ch == "\n"
            if ch == "." {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                isEnd = next.isWhitespace
            }
            // 结束标点后的右引号/括号归入本句
            if isEnd, i + 1 < chars.count, "”’」』）)\"".contains(chars[i + 1]) { isEnd = false }
            if !isEnd, i > 0, "”’」』）)\"".contains(ch), terminators.contains(chars[i - 1]) { isEnd = true }
            if isEnd {
                if offset > start { result.append(TextSpan(start: base.start + start, end: base.start + offset)) }
                start = offset
            }
        }
        if offset > start { result.append(TextSpan(start: base.start + start, end: base.start + offset)) }
        // 去除纯空白句
        return result.filter { !text.substring(utf16: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
