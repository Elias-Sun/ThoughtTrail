import Foundation

/// 从 XHTML 章节提取规范化正文：块级元素间以 `\n` 分段，段内空白合并。
/// 返回的偏移体系（UTF-16）是阅读器定位、切块与证据的唯一依据。
public enum XHTMLTextExtractor {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var title: String?
        public var anchors: [String: Int]
    }

    static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "section", "article",
        "pre", "dt", "dd", "figcaption", "tr", "table", "ul", "ol", "header", "footer", "aside",
        "nav", "hr", "figure", "address", "main", "body",
    ]
    static let skippedElements: Set<String> = ["head", "script", "style", "title", "svg", "math"]

    public static func extract(_ data: Data) -> Result {
        let builder = Builder()
        let parser = XMLParser(data: HTMLEntities.xmlSafe(data))
        parser.delegate = builder
        if parser.parse() {
            return builder.finish()
        }
        return fallback(String(decoding: data, as: UTF8.self))
    }

    public static func extract(_ html: String) -> Result {
        extract(Data(html.utf8))
    }

    /// 非良构 XHTML 的退化路径：正则去标签。
    static func fallback(_ html: String) -> Result {
        var s = html
        for tag in ["head", "script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        let blockPattern = "</?(" + blockElements.joined(separator: "|") + ")(\\s[^>]*)?>"
        s = s.replacingOccurrences(of: blockPattern, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = HTMLEntities.decode(s)
        let builder = Builder()
        for line in s.components(separatedBy: "\n") {
            builder.breakParagraph()
            builder.append(line)
        }
        return builder.finish()
    }

    final class Builder: NSObject, XMLParserDelegate {
        private var out = ""
        private var outLength = 0
        private var pendingBreak = false
        private var skipDepth = 0
        private var pendingAnchors: [String] = []
        private var anchors: [String: Int] = [:]
        private var headingDepth = 0
        private var headingText = ""
        private var title: String?

        func breakParagraph() { pendingBreak = true }

        func append(_ string: String) {
            for ch in string {
                if ch.isWhitespace || ch == "\u{200B}" {
                    if out.isEmpty || out.last == "\n" || out.last == " " || pendingBreak { continue }
                    out.append(" "); outLength += 1
                    continue
                }
                if pendingBreak && !out.isEmpty {
                    if out.last == " " { out.removeLast(); outLength -= 1 }
                    if out.last != "\n" { out.append("\n"); outLength += 1 }
                }
                pendingBreak = false
                if !pendingAnchors.isEmpty {
                    for a in pendingAnchors where anchors[a] == nil { anchors[a] = outLength }
                    pendingAnchors.removeAll()
                }
                out.append(ch)
                outLength += String(ch).utf16.count
            }
        }

        func finish() -> Result {
            while out.last == " " || out.last == "\n" { out.removeLast() }
            let length = out.utf16.count
            for a in pendingAnchors where anchors[a] == nil { anchors[a] = length }
            for (k, v) in anchors where v > length { anchors[k] = length }
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(text: out, title: (t?.isEmpty ?? true) ? nil : t, anchors: anchors)
        }

        private func local(_ name: String) -> String {
            (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = local(elementName)
            if XHTMLTextExtractor.skippedElements.contains(name) { skipDepth += 1; return }
            if skipDepth > 0 { return }
            if let id = attributeDict["id"] ?? attributeDict["xml:id"] { pendingAnchors.append(id) }
            if name == "br" { pendingBreak = true }
            if XHTMLTextExtractor.blockElements.contains(name) { pendingBreak = true }
            if ["h1", "h2", "h3"].contains(name) && title == nil { headingDepth += 1 }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = local(elementName)
            if XHTMLTextExtractor.skippedElements.contains(name) { skipDepth = max(0, skipDepth - 1); return }
            if skipDepth > 0 { return }
            if XHTMLTextExtractor.blockElements.contains(name) { pendingBreak = true }
            if ["h1", "h2", "h3"].contains(name) && headingDepth > 0 {
                headingDepth -= 1
                if headingDepth == 0 && title == nil {
                    let t = headingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { title = t }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            if headingDepth > 0 { headingText += string }
            append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard skipDepth == 0 else { return }
            append(String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}

/// HTML 命名实体处理：XMLParser 只认识 XML 的 5 个实体。
public enum HTMLEntities {
    static let named: [String: String] = [
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{00AD}",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "divide": "÷",
        "mdash": "—", "ndash": "–", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "sbquo": "‚", "bdquo": "„", "prime": "′", "Prime": "″", "sect": "§", "para": "¶",
        "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á", "ccedil": "ç", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß", "ntilde": "ñ", "iexcl": "¡", "iquest": "¿",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "plusmn": "±", "larr": "←", "rarr": "→",
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    ]
    static let xmlBuiltins: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
    static var entityRegex: NSRegularExpression { try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);") }

    /// 把非 XML 内置的命名实体替换为数字字符引用，未知实体转义为文本。
    public static func xmlSafe(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return data }
        guard s.contains("&") else { return data }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            if xmlBuiltins.contains(name) {
                result += "&\(name);"
            } else if let rep = named[name] {
                result += rep.unicodeScalars.map { "&#\($0.value);" }.joined()
            } else {
                result += "&amp;\(name);"
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return Data(result.utf8)
    }

    /// 解码命名实体与数字引用（用于退化路径）。
    public static func decode(_ s: String) -> String {
        var out = s
        if let numeric = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let body = ns.substring(with: m.range(at: 1))
                let value = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let v = value, let scalar = Unicode.Scalar(v) { result.append(Character(scalar)) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        for (name, rep) in named where name != "amp" { out = out.replacingOccurrences(of: "&\(name);", with: rep) }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
