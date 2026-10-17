import Foundation
import LibraryCore
import RetrievalCore
import ContextEngineering

/// 回答中的一条关键陈述。
public struct Claim: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    /// 句中引用的证据标签（E1…）。
    public var labels: [String]
    /// 以【一般知识】标注的书外知识，不要求书内引用。
    public var isGeneralKnowledge: Bool
    /// 说明限制/建议的元陈述（如“证据不足”），不作为事实核查对象。
    public var isMeta: Bool
    /// 是否在断言“书中/作者如何说”。
    public var assertsBookContent: Bool

    public init(id: String, text: String, labels: [String], isGeneralKnowledge: Bool, isMeta: Bool, assertsBookContent: Bool) {
        self.id = id; self.text = text; self.labels = labels; self.isGeneralKnowledge = isGeneralKnowledge
        self.isMeta = isMeta; self.assertsBookContent = assertsBookContent
    }

    /// 需要核查的事实陈述。
    public var requiresVerification: Bool { !isGeneralKnowledge && !isMeta }
}

/// 陈述拆分：按句切分，识别引用、一般知识标记和元陈述（EVID-02）。拆分粒度在评测前固定。
public enum ClaimExtractor {
    public static let metaKeywords = [
        "证据不足", "没有找到", "未找到", "无法确定", "无法判断", "不能确定", "建议你", "建议您", "可以补充", "可以继续阅读",
        "insufficient evidence", "could not find", "cannot determine", "i'm not sure", "you may want to",
    ]
    public static let bookContentMarkers = ["书中", "作者", "原文", "文中", "本书", "这一章", "本章", "the author", "the book", "the text", "chapter"]

    public static func extract(_ answer: String) -> [Claim] {
        var claims: [Claim] = []
        for span in SentenceSplitter.sentences(in: answer) {
            var sentence = answer.substring(utf16: span).trimmingCharacters(in: .whitespacesAndNewlines)
            // 去掉列表符号与标题符号
            while let first = sentence.first, "-*#•>0123456789.、 ".contains(first), sentence.count > 1 {
                if first.isNumber, !(sentence.dropFirst().first.map { ".、)".contains($0) } ?? false) { break }
                sentence.removeFirst()
            }
            sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            // 句首的引用（“……。[E1] 下一句”被切到下一句开头）属于前一条陈述
            if !claims.isEmpty, let lead = sentence.range(of: "^(\\[E\\d+(?:\\s*[,，、]\\s*E\\d+)*\\]\\s*)+", options: .regularExpression) {
                var last = claims.removeLast()
                for l in CitationExtractor.labels(in: String(sentence[lead])) where !last.labels.contains(l) { last.labels.append(l) }
                last.isMeta = false
                claims.append(last)
                sentence = String(sentence[lead.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !sentence.isEmpty else { continue }
            let labels = CitationExtractor.labels(in: sentence)
            let stripped = stripCitations(sentence)
            // 句末标点之后的引用（如“……。[E1]”）被切成单独片段：并入前一条陈述
            if stripped.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)).isEmpty, !labels.isEmpty, !claims.isEmpty {
                var last = claims.removeLast()
                for l in labels where !last.labels.contains(l) { last.labels.append(l) }
                last.isMeta = false
                claims.append(last)
                continue
            }
            guard stripped.count >= 4 else { continue }
            let lower = stripped.lowercased()
            let isGeneral = sentence.hasPrefix(PromptComposer.generalKnowledgeMarker)
            let isQuestion = stripped.hasSuffix("？") || stripped.hasSuffix("?")
            let isMeta = labels.isEmpty && (isQuestion || metaKeywords.contains { lower.contains($0) })
            let asserts = bookContentMarkers.contains { lower.contains($0) }
            claims.append(Claim(id: "C\(claims.count + 1)", text: stripped, labels: labels, isGeneralKnowledge: isGeneral,
                                isMeta: isMeta, assertsBookContent: asserts))
        }
        return claims
    }

    public static func stripCitations(_ s: String) -> String {
        s.replacingOccurrences(of: "\\[E\\d+(?:\\s*[,，、]\\s*E\\d+)*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: PromptComposer.generalKnowledgeMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
