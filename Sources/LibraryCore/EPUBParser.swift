import Foundation
import ZIPFoundation

/// 导入与解析错误。每个错误都有面向用户的说明（LIB-02）。
public enum EPUBError: Error, Equatable, Sendable {
    case emptyFile
    case notZipArchive
    case missingContainer
    case missingPackageDocument(String)
    case invalidPackageDocument(String)
    case noReadableContent
    case drmProtected
    case unsupportedFormat(String)

    public var userMessage: String {
        switch self {
        case .emptyFile: return "文件为空，无法导入。"
        case .notZipArchive: return "文件已损坏或不是有效的 EPUB（无法作为 ZIP 打开）。"
        case .missingContainer: return "EPUB 缺少 META-INF/container.xml，文件可能已损坏。"
        case .missingPackageDocument(let p): return "找不到 EPUB 包文档：\(p)。"
        case .invalidPackageDocument(let r): return "EPUB 包文档无法解析：\(r)。"
        case .noReadableContent: return "EPUB 中没有可阅读的正文。"
        case .drmProtected: return "该 EPUB 受 DRM 或加密保护，暂不支持导入。"
        case .unsupportedFormat(let f): return "不支持的文件格式：\(f)。请选择 EPUB 文件。"
        }
    }
}

public struct ParsedPublication: Sendable {
    public var title: String
    public var authors: [String]
    public var language: String
    public var identifier: String?
    public var chapters: [ParsedChapter]
    public var toc: [TOCEntry]
    public var cover: Data?
    public var warnings: [String]
}

public struct ParsedChapter: Sendable, Hashable {
    public var index: Int
    public var href: String
    public var title: String
    public var text: String
    public var anchors: [String: Int]
    public var isLinear: Bool
}

/// EPUB 2/3 解析器：容器、OPF、spine、导航（nav/NCX）、封面与正文提取。
/// ZIP 读取使用 ZIPFoundation；OPF/XHTML 使用 Foundation XMLParser。
public struct EPUBParser: Sendable {
    public init() {}

    public func parse(data: Data, fileName: String = "book.epub") throws -> ParsedPublication {
        guard !data.isEmpty else { throw EPUBError.emptyFile }
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty && ext != "epub" { throw EPUBError.unsupportedFormat(ext) }
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw EPUBError.notZipArchive
        }
        let reader = ArchiveReader(archive: archive)
        var warnings: [String] = []

        if let mime = reader.string("mimetype"), mime.trimmingCharacters(in: .whitespacesAndNewlines) != "application/epub+zip" {
            warnings.append("mimetype 非标准：\(mime)")
        }
        guard let containerXML = reader.data("META-INF/container.xml") else { throw EPUBError.missingContainer }
        guard let opfPath = ContainerParser.rootfilePath(containerXML) else { throw EPUBError.missingContainer }
        if reader.data("META-INF/rights.xml") != nil { throw EPUBError.drmProtected }
        if let enc = reader.data("META-INF/encryption.xml"), EncryptionInspector.hasContentEncryption(enc) {
            throw EPUBError.drmProtected
        }
        guard let opfData = reader.data(opfPath) else { throw EPUBError.missingPackageDocument(opfPath) }
        let package: PackageDocument
        do { package = try PackageDocument.parse(opfData) } catch let e as EPUBError { throw e } catch {
            throw EPUBError.invalidPackageDocument("\(error)")
        }
        let baseDir = (opfPath as NSString).deletingLastPathComponent

        // spine → 章节
        var chapters: [ParsedChapter] = []
        var hrefToIndex: [String: Int] = [:]
        for itemref in package.spine {
            guard let item = package.manifest[itemref.idref] else {
                warnings.append("spine 引用了不存在的条目：\(itemref.idref)"); continue
            }
            let path = PathResolver.resolve(item.href, relativeTo: baseDir)
            guard let content = reader.data(path) else {
                warnings.append("缺失章节文件：\(path)"); continue
            }
            let extracted = XHTMLTextExtractor.extract(content)
            let index = chapters.count
            hrefToIndex[path] = index
            chapters.append(ParsedChapter(index: index, href: path, title: extracted.title ?? "",
                                          text: extracted.text, anchors: extracted.anchors,
                                          isLinear: itemref.linear))
        }
        guard chapters.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EPUBError.noReadableContent
        }

        // 目录：EPUB3 nav 优先，其次 NCX
        var toc: [TOCEntry] = []
        if let navItem = package.manifest.values.first(where: { $0.properties.contains("nav") }) {
            let navPath = PathResolver.resolve(navItem.href, relativeTo: baseDir)
            if let navData = reader.data(navPath) {
                let navDir = (navPath as NSString).deletingLastPathComponent
                toc = NavParser.parseNav(navData).map { raw in
                    Self.makeEntry(raw, baseDir: navDir, hrefToIndex: hrefToIndex, chapters: chapters)
                }
            }
        }
        if toc.isEmpty, let ncxID = package.tocID, let ncxItem = package.manifest[ncxID] {
            let ncxPath = PathResolver.resolve(ncxItem.href, relativeTo: baseDir)
            if let ncxData = reader.data(ncxPath) {
                let ncxDir = (ncxPath as NSString).deletingLastPathComponent
                toc = NavParser.parseNCX(ncxData).map { raw in
                    Self.makeEntry(raw, baseDir: ncxDir, hrefToIndex: hrefToIndex, chapters: chapters)
                }
            }
        }
        if toc.isEmpty {
            warnings.append("缺少目录，按章节生成默认目录")
            toc = chapters.filter { $0.isLinear && !$0.text.isEmpty }.map {
                TOCEntry(title: $0.title.isEmpty ? "第 \($0.index + 1) 章" : $0.title, level: 0,
                         chapterIndex: $0.index, offset: 0, href: $0.href)
            }
        }
        // 用目录标题补全章节标题
        for entry in toc where entry.offset == 0 {
            if let idx = entry.chapterIndex, chapters[idx].title.isEmpty { chapters[idx].title = entry.title }
        }
        for i in chapters.indices where chapters[i].title.isEmpty {
            chapters[i].title = "第 \(i + 1) 部分"
        }

        // 封面
        var cover: Data?
        if let coverItem = package.coverItem {
            cover = reader.data(PathResolver.resolve(coverItem.href, relativeTo: baseDir))
        }

        let title = package.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = ((fileName as NSString).deletingPathExtension as String)
        return ParsedPublication(
            title: (title?.isEmpty == false ? title! : (fallbackTitle.isEmpty ? Book.untitled : fallbackTitle)),
            authors: package.creators.filter { !$0.isEmpty },
            language: package.language ?? "und",
            identifier: package.identifier,
            chapters: chapters,
            toc: toc,
            cover: cover,
            warnings: warnings
        )
    }

    private static func makeEntry(_ raw: NavParser.RawEntry, baseDir: String, hrefToIndex: [String: Int],
                                  chapters: [ParsedChapter]) -> TOCEntry {
        let parts = raw.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        let path = PathResolver.resolve(file, relativeTo: baseDir)
        let index = hrefToIndex[path]
        var offset = 0
        if let index, let fragment, let anchorOffset = chapters[index].anchors[fragment] { offset = anchorOffset }
        return TOCEntry(title: raw.title, level: raw.level, chapterIndex: index, offset: offset, href: raw.href)
    }
}

// MARK: - ZIP 读取

struct ArchiveReader {
    let archive: Archive
    private let lowercasedIndex: [String: String]

    init(archive: Archive) {
        self.archive = archive
        var idx: [String: String] = [:]
        for entry in archive { idx[entry.path.lowercased()] = entry.path }
        lowercasedIndex = idx
    }

    func data(_ path: String) -> Data? {
        let candidates = [path, path.removingPercentEncoding ?? path]
        for candidate in candidates {
            let actual = archive[candidate] != nil ? candidate : lowercasedIndex[candidate.lowercased()]
            guard let actual, let entry = archive[actual], entry.type == .file else { continue }
            var out = Data()
            do {
                _ = try archive.extract(entry, skipCRC32: false) { out.append($0) }
                return out
            } catch {
                return nil
            }
        }
        return nil
    }

    func string(_ path: String) -> String? {
        data(path).flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum PathResolver {
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let withoutFragment = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? decoded
        let combined = base.isEmpty ? withoutFragment : base + "/" + withoutFragment
        var stack: [Substring] = []
        for comp in combined.split(separator: "/") {
            if comp == "." || comp.isEmpty { continue }
            if comp == ".." { _ = stack.popLast(); continue }
            stack.append(comp)
        }
        return stack.joined(separator: "/")
    }
}

// MARK: - XML 辅助

/// 简易 DOM，供 OPF/NAV/NCX 解析。
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""
    weak var parent: XMLNode?

    init(name: String, attributes: [String: String]) {
        self.name = name; self.attributes = attributes
    }

    /// 去掉命名空间前缀后的本地名。
    var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

    func attr(_ key: String) -> String? {
        if let v = attributes[key] { return v }
        return attributes.first { $0.key.split(separator: ":").last.map(String.init) == key }?.value
    }

    func descendants(_ local: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children {
            if c.localName == local { out.append(c) }
            out += c.descendants(local)
        }
        return out
    }

    func firstChild(_ local: String) -> XMLNode? { children.first { $0.localName == local } }

    var allText: String { text + children.map(\.allText).joined() }
}

final class DOMBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    static func parse(_ data: Data) -> XMLNode? {
        let builder = DOMBuilder()
        let parser = XMLParser(data: HTMLEntities.xmlSafe(data))
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        node.parent = stack.last
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }
}

enum ContainerParser {
    static func rootfilePath(_ data: Data) -> String? {
        guard let root = DOMBuilder.parse(data) else { return nil }
        let rootfiles = root.descendants("rootfile")
        let preferred = rootfiles.first { $0.attr("media-type") == "application/oebps-package+xml" } ?? rootfiles.first
        return preferred?.attr("full-path")
    }
}

enum EncryptionInspector {
    /// 字体混淆算法不算内容加密。
    static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    static func hasContentEncryption(_ data: Data) -> Bool {
        guard let root = DOMBuilder.parse(data) else { return true }
        let methods = root.descendants("EncryptionMethod").compactMap { $0.attr("Algorithm") }
        let encryptedCount = root.descendants("EncryptedData").count
        if encryptedCount == 0 { return false }
        return methods.contains { !fontObfuscation.contains($0) } || methods.count < encryptedCount
    }
}

struct PackageDocument {
    struct Item { let id: String; let href: String; let mediaType: String; let properties: [String] }
    struct ItemRef { let idref: String; let linear: Bool }

    var title: String?
    var creators: [String] = []
    var language: String?
    var identifier: String?
    var manifest: [String: Item] = [:]
    var spine: [ItemRef] = []
    var tocID: String?
    var coverItem: Item?

    static func parse(_ data: Data) throws -> PackageDocument {
        guard let root = DOMBuilder.parse(data), root.localName == "package" else {
            throw EPUBError.invalidPackageDocument("根元素不是 package")
        }
        var doc = PackageDocument()
        if let metadata = root.firstChild("metadata") ?? root.descendants("metadata").first {
            doc.title = metadata.descendants("title").first?.allText
            doc.creators = metadata.descendants("creator").map { $0.allText.trimmingCharacters(in: .whitespacesAndNewlines) }
            doc.language = metadata.descendants("language").first?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            doc.identifier = metadata.descendants("identifier").first?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let coverMeta = metadata.descendants("meta").first(where: { $0.attr("name") == "cover" }),
               let coverID = coverMeta.attr("content") {
                doc.pendingCoverID = coverID
            }
        }
        guard let manifest = root.firstChild("manifest") else {
            throw EPUBError.invalidPackageDocument("缺少 manifest")
        }
        for node in manifest.children where node.localName == "item" {
            guard let id = node.attr("id"), let href = node.attr("href") else { continue }
            let props = (node.attr("properties") ?? "").split(separator: " ").map(String.init)
            doc.manifest[id] = Item(id: id, href: href, mediaType: node.attr("media-type") ?? "", properties: props)
        }
        guard let spine = root.firstChild("spine") else {
            throw EPUBError.invalidPackageDocument("缺少 spine")
        }
        doc.tocID = spine.attr("toc")
        doc.spine = spine.children.filter { $0.localName == "itemref" }.compactMap {
            guard let idref = $0.attr("idref") else { return nil }
            return ItemRef(idref: idref, linear: $0.attr("linear") != "no")
        }
        if doc.spine.isEmpty { throw EPUBError.noReadableContent }
        if let coverProp = doc.manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            doc.coverItem = coverProp
        } else if let id = doc.pendingCoverID, let item = doc.manifest[id] {
            doc.coverItem = item
        }
        return doc
    }

    /// EPUB2 `<meta name="cover">` 指向的 manifest id。
    var pendingCoverID: String?
}

enum NavParser {
    struct RawEntry { let title: String; let href: String; let level: Int }

    static func parseNav(_ data: Data) -> [RawEntry] {
        guard let root = DOMBuilder.parse(data) else { return [] }
        let navs = root.descendants("nav")
        let tocNav = navs.first { ($0.attr("type") ?? "").contains("toc") } ?? navs.first
        guard let nav = tocNav, let ol = nav.descendants("ol").first else { return [] }
        var out: [RawEntry] = []
        walk(ol, level: 0, into: &out)
        return out
    }

    private static func walk(_ ol: XMLNode, level: Int, into out: inout [RawEntry]) {
        for li in ol.children where li.localName == "li" {
            if let a = li.children.first(where: { $0.localName == "a" }), let href = a.attr("href") {
                let title = a.allText.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(RawEntry(title: title.isEmpty ? href : title, href: href, level: level))
            }
            if let sub = li.children.first(where: { $0.localName == "ol" }) {
                walk(sub, level: level + 1, into: &out)
            }
        }
    }

    static func parseNCX(_ data: Data) -> [RawEntry] {
        guard let root = DOMBuilder.parse(data), let navMap = root.descendants("navMap").first else { return [] }
        var out: [RawEntry] = []
        walkNCX(navMap, level: 0, into: &out)
        return out
    }

    private static func walkNCX(_ node: XMLNode, level: Int, into out: inout [RawEntry]) {
        for point in node.children where point.localName == "navPoint" {
            let title = point.firstChild("navLabel")?.descendants("text").first?.allText
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let src = point.firstChild("content")?.attr("src") {
                out.append(RawEntry(title: title.isEmpty ? src : title, href: src, level: level))
            }
            walkNCX(point, level: level + 1, into: &out)
        }
    }
}
