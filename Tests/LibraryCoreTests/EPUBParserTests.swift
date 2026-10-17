import Testing
import Foundation
@testable import LibraryCore
import TestSupport

@Suite("M01 EPUB 解析")
struct EPUBParserTests {
    let parser = EPUBParser()

    @Test("LIB-01 解析中文 EPUB 的标题、作者与语言")
    func parsesMetadata() throws {
        let p = try parser.parse(data: Fixtures.zhBook(), fileName: "a.epub")
        #expect(p.title == "阅读之道")
        #expect(p.authors == ["林知"])
        #expect(p.language == "zh-CN")
        #expect(p.identifier == "urn:uuid:zh-1")
    }

    @Test("LIB-01 章节按 spine 顺序提取，标题取自 h1")
    func chaptersInSpineOrder() throws {
        let p = try parser.parse(data: Fixtures.zhBook())
        #expect(p.chapters.count == 4)
        #expect(p.chapters.map(\.title) == Fixtures.zhChapters.map(\.title))
        #expect(p.chapters.map(\.index) == [0, 1, 2, 3])
    }

    @Test("RAG-01 正文提取为规范段落，不含标签且可回查原文")
    func normalizedText() throws {
        let p = try parser.parse(data: Fixtures.zhBook())
        let text = p.chapters[0].text
        #expect(!text.contains("<"))
        #expect(text.hasPrefix("第一章 读书的方法\n读书最重要的是带着问题去读。"))
        #expect(text.components(separatedBy: "\n").count == 4)
    }

    @Test("LIB-01 EPUB3 nav 目录包含嵌套锚点并解析出偏移")
    func navTOCWithAnchors() throws {
        let p = try parser.parse(data: Fixtures.zhBook())
        let anchor = try #require(p.toc.first { $0.href.hasSuffix("#annotate") })
        #expect(anchor.level == 1)
        #expect(anchor.chapterIndex == 0)
        let text = p.chapters[0].text
        #expect(text.substring(utf16: TextSpan(start: anchor.offset, end: anchor.offset + 5)) == "作者认为，")
    }

    @Test("LIB-01 没有 nav 时使用 NCX 目录")
    func ncxFallback() throws {
        let p = try parser.parse(data: Fixtures.enBook())
        #expect(p.toc.map(\.title) == ["Chapter 1. The Harbor", "Chapter 2. The Storm", "Chapter 3. The Return"])
        #expect(p.toc.allSatisfy { $0.chapterIndex != nil })
    }

    @Test("LIB-01 缺少目录时按章节生成默认目录并给出警告")
    func defaultTOC() throws {
        var b = EPUBBuilder(title: "无目录", chapters: Fixtures.zhChapters)
        b.tocStyle = .none
        let p = try parser.parse(data: b.build())
        #expect(p.toc.count == 4)
        #expect(p.warnings.contains { $0.contains("缺少目录") })
    }

    @Test("LIB-01 提取封面图片")
    func coverExtracted() throws {
        let p = try parser.parse(data: Fixtures.zhBook())
        #expect(p.cover == Fixtures.tinyPNG)
    }

    @Test("LIB-01 缺少标题时使用文件名作为默认值")
    func missingTitleFallsBackToFileName() throws {
        let p = try parser.parse(data: Fixtures.zhBook(title: nil), fileName: "我的书.epub")
        #expect(p.title == "我的书")
    }

    @Test("LIB-01 缺少作者时展示“佚名”")
    func missingAuthorDefault() throws {
        let data = try EPUBBuilder(title: "无作者", authors: [], chapters: Fixtures.enChapters).build()
        let p = try parser.parse(data: data)
        #expect(p.authors.isEmpty)
        let book = Book(id: "x", title: p.title, authors: p.authors, language: p.language, identifier: nil, fingerprint: "f",
                        fileName: "f", fileSize: 1, chapterCount: 1, hasCover: false, importedAt: Date())
        #expect(book.authorLine == "佚名")
    }

    @Test("LIB-02 空文件明确提示")
    func emptyFile() {
        #expect(throws: EPUBError.emptyFile) { try parser.parse(data: Data()) }
    }

    @Test("LIB-02 非 ZIP 文件判定为损坏")
    func notZip() {
        #expect(throws: EPUBError.notZipArchive) { try parser.parse(data: Data("这不是 EPUB".utf8)) }
    }

    @Test("LIB-02 缺少 container.xml 判定为损坏")
    func missingContainer() throws {
        var b = EPUBBuilder(title: "坏", chapters: Fixtures.enChapters)
        b.includeContainer = false
        #expect(throws: EPUBError.missingContainer) { try parser.parse(data: b.build()) }
    }

    @Test("LIB-02 缺少 OPF 包文档")
    func missingOPF() throws {
        var b = EPUBBuilder(title: "坏", chapters: Fixtures.enChapters)
        b.includeOPF = false
        #expect(throws: EPUBError.missingPackageDocument("OEBPS/content.opf")) { try parser.parse(data: b.build()) }
    }

    @Test("LIB-02 内容加密的 EPUB 被识别为受保护")
    func encryptedContent() throws {
        var b = EPUBBuilder(title: "加密", chapters: Fixtures.enChapters)
        b.encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
        <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/></enc:EncryptedData></encryption>
        """
        #expect(throws: EPUBError.drmProtected) { try parser.parse(data: b.build()) }
    }

    @Test("LIB-02 仅字体混淆不视为 DRM")
    func fontObfuscationAllowed() throws {
        var b = EPUBBuilder(title: "字体", chapters: Fixtures.enChapters)
        b.encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
        <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></enc:EncryptedData></encryption>
        """
        #expect(try parser.parse(data: b.build()).chapters.count == 3)
    }

    @Test("LIB-02 含 rights.xml 的 EPUB 被识别为受保护")
    func rightsFile() throws {
        var b = EPUBBuilder(title: "版权", chapters: Fixtures.enChapters)
        b.rights = true
        #expect(throws: EPUBError.drmProtected) { try parser.parse(data: b.build()) }
    }

    @Test("LIB-02 不支持的扩展名明确提示")
    func unsupportedExtension() throws {
        #expect(throws: EPUBError.unsupportedFormat("pdf")) { try parser.parse(data: Fixtures.enBook(), fileName: "x.pdf") }
    }

    @Test("LIB-01 HTML 命名实体（&nbsp; &mdash;）不导致解析失败")
    func htmlEntities() throws {
        var b = EPUBBuilder(title: "实体", chapters: Fixtures.enChapters)
        b.extraEntities = true
        let p = try parser.parse(data: b.build())
        #expect(p.chapters[0].text.contains("—"))
        #expect(p.chapters[0].text.contains("harbor"))
    }

    @Test("LIB-01 非良构章节走退化提取路径仍有正文")
    func malformedChapterFallback() throws {
        var b = EPUBBuilder(title: "坏章节", chapters: Fixtures.enChapters)
        b.malformedChapterIndex = 1
        let p = try parser.parse(data: b.build())
        #expect(p.chapters[1].text.contains("未闭合段落"))
        #expect(p.chapters[1].text.contains("裸露的符号"))
        #expect(!p.chapters[1].text.contains("<p>"))
    }

    @Test("LIB-02 spine 为空视为没有可阅读内容")
    func emptySpine() throws {
        let data = try EPUBBuilder(title: "空", chapters: []).build()
        #expect(throws: EPUBError.noReadableContent) { try parser.parse(data: data) }
    }
}

@Suite("M01 正文提取")
struct ExtractorTests {
    @Test("RAG-01 跳过 head/script/style，块级元素分段")
    func skipsNonContent() {
        let r = XHTMLTextExtractor.extract("<html><head><title>T</title><style>p{}</style></head><body><script>x()</script><p>甲  乙</p><div>丙</div></body></html>")
        #expect(r.text == "甲 乙\n丙")
    }

    @Test("READ-03 锚点偏移指向锚点后第一个字符")
    func anchorOffsets() {
        let r = XHTMLTextExtractor.extract("<html><body><p>第一段</p><p id=\"x\">第二段</p><span id=\"end\"/></body></html>")
        #expect(r.anchors["x"] == 4)
        #expect(r.anchors["end"] == r.text.utf16Length)
    }

    @Test("RAG-01 退化路径解码数字实体")
    func fallbackDecodesEntities() {
        let r = XHTMLTextExtractor.fallback("<p>A&#38;B&#x4E2D;</p><p>C&nbsp;D</p>")
        #expect(r.text == "A&B中\nC D")
    }
}
