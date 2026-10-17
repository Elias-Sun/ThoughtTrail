import Foundation

/// 数字抽取：阿拉伯数字、中文数字（含“两”“十”“百”“千”“万”）与英文数字词统一为数值，用于陈述与证据的数字一致性检查。
public enum NumberExtractor {
    static let zhDigits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    static let zhUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1_000, "万": 10_000]
    /// 不视为数量的常见词（避免“一些”“一起”“第一”等误判）。
    static let zhIgnored = ["一些", "一起", "一直", "一样", "一边", "一切", "一点", "一般", "一旦", "统一", "唯一", "万一", "一定"]

    static let enWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100, "thousand": 1_000, "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "ninth": 9, "tenth": 10,
    ]

    public static func numbers(in raw: String) -> Set<String> {
        var out: Set<String> = []
        // 章节编号（第二章、第3节、Chapter 2）不是陈述中的数量
        var text = raw.replacingOccurrences(of: "第[零〇一二两三四五六七八九十百千0-9]+[章节卷部回篇]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)chapter\\s+[0-9]+", with: " ", options: .regularExpression)
        // 阿拉伯数字
        if let regex = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?") {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                out.insert(Double(raw).map { $0 == $0.rounded() ? String(Int($0)) : raw } ?? raw)
            }
        }
        // 中文数字串
        var cleaned = text
        for w in zhIgnored { cleaned = cleaned.replacingOccurrences(of: w, with: "  ") }
        var run = ""
        func flush() {
            if !run.isEmpty, let v = parseChinese(run) { out.insert(String(v)) }
            run = ""
        }
        for ch in cleaned {
            if zhDigits[ch] != nil || zhUnits[ch] != nil { run.append(ch) } else { flush() }
        }
        flush()
        // 英文数字词（相邻词组合，如 "two thousand" / "thirty-five"）
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "-")))
            .flatMap { $0.split(separator: "-").map(String.init) }
        var total = 0, current = 0, inNumber = false
        func flushEn() {
            if inNumber { out.insert(String(total + current)) }
            total = 0; current = 0; inNumber = false
        }
        for w in words {
            guard let v = enWords[w] else { flushEn(); continue }
            inNumber = true
            if v == 100 { current = max(current, 1) * 100 }
            else if v == 1_000 { total += max(current, 1) * 1_000; current = 0 }
            else { current += v }
        }
        flushEn()
        return out
    }

    /// 解析中文数字（支持“四十”“二十三”“三百”“一千”“一六一〇”这类逐位写法）。
    static func parseChinese(_ s: String) -> Int? {
        let chars = Array(s)
        if !chars.contains(where: { zhUnits[$0] != nil }) {
            // 逐位：一六一〇 → 1610；单字 → 数值
            var v = 0
            for c in chars { guard let d = zhDigits[c] else { return nil }; v = v * 10 + d }
            return v
        }
        var total = 0, section = 0, digit = 0
        for c in chars {
            if let d = zhDigits[c] {
                digit = d
            } else if let u = zhUnits[c] {
                if u == 10_000 {
                    section = (section + digit) * u
                    total += section; section = 0
                } else {
                    section += (digit == 0 ? 1 : digit) * u
                }
                digit = 0
            }
        }
        return total + section + digit
    }
}
