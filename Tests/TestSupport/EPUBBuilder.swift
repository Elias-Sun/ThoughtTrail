import Foundation
import ZIPFoundation

/// 确定性 EPUB 夹具生成器（测试、评测语料与 UI 自动化使用）。
public struct EPUBBuilder: Sendable {
    public struct ChapterSpec: Sendable {
        public var title: String
        public var paragraphs: [String]
        public var anchors: [Int: String]
        public var linear: Bool

        public init(title: String, paragraphs: [String], anchors: [Int: String] = [:], linear: Bool = true) {
            self.title = title; self.paragraphs = paragraphs; self.anchors = anchors; self.linear = linear
        }
    }

    public enum TOCStyle: Sendable { case nav, ncx, none }

    public var title: String?
    public var authors: [String]
    public var language: String
    public var identifier: String
    public var chapters: [ChapterSpec]
    public var tocStyle: TOCStyle
    public var coverPNG: Data?
    public var includeContainer = true
    public var includeOPF = true
    public var encryption: String?
    public var rights = false
    public var extraEntities = false
    public var malformedChapterIndex: Int?

    public init(title: String?, authors: [String] = ["测试作者"], language: String = "zh-CN", identifier: String = "urn:uuid:test",
                chapters: [ChapterSpec], tocStyle: TOCStyle = .nav, coverPNG: Data? = nil) {
        self.title = title; self.authors = authors; self.language = language; self.identifier = identifier
        self.chapters = chapters; self.tocStyle = tocStyle; self.coverPNG = coverPNG
    }

    /// 固定修改时间：同样内容生成的 EPUB 字节完全一致（指纹可复现）。
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public func build() throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        func add(_ path: String, _ string: String, compress: Bool = true) throws {
            let data = Data(string.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Self.fixedDate,
                                 compressionMethod: compress ? .deflate : .none) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        func addData(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Self.fixedDate, compressionMethod: .none) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        try add("mimetype", "application/epub+zip", compress: false)
        if includeContainer {
            try add("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """)
        }
        if let enc = encryption { try add("META-INF/encryption.xml", enc) }
        if rights { try add("META-INF/rights.xml", "<rights/>") }

        var manifest = ""
        var spine = ""
        for (i, ch) in chapters.enumerated() {
            manifest += "<item id=\"ch\(i)\" href=\"text/ch\(i).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"ch\(i)\"\(ch.linear ? "" : " linear=\"no\"")/>\n"
            var body = "<h1 id=\"top\(i)\">\(Self.esc(ch.title))</h1>\n"
            for (pi, p) in ch.paragraphs.enumerated() {
                let idAttr = ch.anchors[pi].map { " id=\"\($0)\"" } ?? ""
                var text = Self.esc(p)
                if extraEntities { text = text.replacingOccurrences(of: " ", with: "&nbsp;") + "&mdash;" }
                body += "<p\(idAttr)>\(text)</p>\n"
            }
            var xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(Self.esc(ch.title))</title><style>p{margin:0}</style></head>
            <body>\(body)</body></html>
            """
            if malformedChapterIndex == i { xhtml = "<html><body><p>未闭合段落<p>第二段 & 裸露的符号<br></body>" }
            try add("OEBPS/text/ch\(i).xhtml", xhtml)
        }
        switch tocStyle {
        case .nav:
            manifest += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
            var lis = ""
            for (i, ch) in chapters.enumerated() {
                lis += "<li><a href=\"text/ch\(i).xhtml\">\(Self.esc(ch.title))</a>"
                let anchored = ch.anchors.sorted { $0.key < $1.key }
                if !anchored.isEmpty {
                    lis += "<ol>" + anchored.map { "<li><a href=\"text/ch\(i).xhtml#\($0.value)\">\(Self.esc(ch.title)) · \($0.value)</a></li>" }.joined() + "</ol>"
                }
                lis += "</li>\n"
            }
            try add("OEBPS/nav.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head>
            <body><nav epub:type="toc"><ol>\(lis)</ol></nav></body></html>
            """)
        case .ncx:
            manifest += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
            let points = chapters.enumerated().map { i, ch in
                "<navPoint id=\"np\(i)\" playOrder=\"\(i + 1)\"><navLabel><text>\(Self.esc(ch.title))</text></navLabel><content src=\"text/ch\(i).xhtml\"/></navPoint>"
            }.joined(separator: "\n")
            try add("OEBPS/toc.ncx", """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>\(points)</navMap></ncx>
            """)
        case .none:
            break
        }
        var coverMeta = ""
        if let cover = coverPNG {
            manifest += "<item id=\"cover\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>\n"
            coverMeta = "<meta name=\"cover\" content=\"cover\"/>"
            try addData("OEBPS/cover.png", cover)
        }
        if includeOPF {
            let titleTag = title.map { "<dc:title>\(Self.esc($0))</dc:title>" } ?? ""
            let creators = authors.map { "<dc:creator>\(Self.esc($0))</dc:creator>" }.joined()
            try add("OEBPS/content.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(titleTag)\(creators)<dc:language>\(language)</dc:language><dc:identifier id="uid">\(identifier)</dc:identifier>\(coverMeta)</metadata>
              <manifest>\(manifest)</manifest>
              <spine\(tocStyle == .ncx ? " toc=\"ncx\"" : "")>\(spine)</spine>
            </package>
            """)
        }
        guard let data = archive.data else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

/// 固定测试书籍。
public enum Fixtures {
    /// 1x1 PNG。
    public static let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    public static let zhChapters: [EPUBBuilder.ChapterSpec] = [
        .init(title: "第一章 读书的方法", paragraphs: [
            "读书最重要的是带着问题去读。没有问题的阅读，往往只是在扫视文字。",
            "作者认为，做批注能把被动的接收变成主动的思考。每读完一节，就用一句话复述它的主旨。",
            "精读与泛读各有用处：精读用于奠基之作，泛读用于扩展视野。",
        ], anchors: [1: "annotate"]),
        .init(title: "第二章 记忆与复习", paragraphs: [
            "遗忘曲线表明，新学的内容在最初几天遗忘得最快。",
            "因此复习应当按照逐渐拉长的间隔进行，例如第1天、第3天、第7天。",
            "自测比重读更有效，因为提取本身会强化记忆。",
        ]),
        .init(title: "第三章 思考的习惯", paragraphs: [
            "写下自己的看法，并且找到支持它的证据，是形成独立判断的第一步。",
            "当新的证据与旧观点冲突时，应当修订观点，而不是忽视证据。",
        ]),
        .init(title: "第四章 结局的秘密", paragraphs: [
            "在最后一章，作者揭示：灯塔管理员其实就是失踪多年的船长。",
            "这个秘密只有读到结尾的人才会知道。",
        ]),
    ]

    public static let enChapters: [EPUBBuilder.ChapterSpec] = [
        .init(title: "Chapter 1. The Harbor", paragraphs: [
            "The harbor town of Westmere had seven bridges and one lighthouse.",
            "Every evening the keeper lit the lamp at exactly six o'clock.",
        ]),
        .init(title: "Chapter 2. The Storm", paragraphs: [
            "A storm arrived in late October and damaged three of the bridges.",
            "The fishermen did not sail for twelve days.",
        ]),
        .init(title: "Chapter 3. The Return", paragraphs: [
            "In the final chapter the missing captain returned to Westmere.",
        ]),
    ]

    public static func zhBook(title: String? = "阅读之道", identifier: String = "urn:uuid:zh-1") throws -> Data {
        try EPUBBuilder(title: title, authors: ["林知"], language: "zh-CN", identifier: identifier, chapters: zhChapters,
                        coverPNG: tinyPNG).build()
    }

    public static func enBook() throws -> Data {
        try EPUBBuilder(title: "The Lighthouse Keeper", authors: ["A. Writer"], language: "en", identifier: "urn:uuid:en-1",
                        chapters: enChapters, tocStyle: .ncx).build()
    }
}
