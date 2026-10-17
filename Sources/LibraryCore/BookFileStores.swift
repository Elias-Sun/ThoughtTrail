import Foundation

/// 沙盒目录中的书籍文件存储：`<root>/<bookID>/book.epub` 与 `cover`。
public struct DiskBookFileStore: BookFileStore {
    public let root: URL

    public init(root: URL) { self.root = root }

    private func dir(_ id: BookID) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    public func save(_ data: Data, for bookID: BookID, fileName: String) async throws {
        try FileManager.default.createDirectory(at: dir(bookID), withIntermediateDirectories: true)
        try data.write(to: dir(bookID).appendingPathComponent("book.epub"), options: .atomic)
    }

    public func saveCover(_ data: Data, for bookID: BookID) async throws {
        try FileManager.default.createDirectory(at: dir(bookID), withIntermediateDirectories: true)
        try data.write(to: dir(bookID).appendingPathComponent("cover"), options: .atomic)
    }

    public func loadFile(for bookID: BookID) async throws -> Data? {
        try? Data(contentsOf: dir(bookID).appendingPathComponent("book.epub"))
    }

    public func loadCover(for bookID: BookID) async throws -> Data? {
        try? Data(contentsOf: dir(bookID).appendingPathComponent("cover"))
    }

    public func removeAll(for bookID: BookID) async throws {
        let d = dir(bookID)
        if FileManager.default.fileExists(atPath: d.path) { try FileManager.default.removeItem(at: d) }
    }

    public func exists(for bookID: BookID) async -> Bool {
        FileManager.default.fileExists(atPath: dir(bookID).appendingPathComponent("book.epub").path)
    }
}

/// 内存文件存储（测试、预览）。可注入写入失败以验证“失败不残留”。
public actor InMemoryBookFileStore: BookFileStore {
    private var files: [BookID: Data] = [:]
    private var covers: [BookID: Data] = [:]
    public var failNextSave = false

    public init() {}

    public func setFailNextSave(_ v: Bool) { failNextSave = v }

    public func save(_ data: Data, for bookID: BookID, fileName: String) async throws {
        if failNextSave { failNextSave = false; throw CocoaError(.fileWriteOutOfSpace) }
        files[bookID] = data
    }

    public func saveCover(_ data: Data, for bookID: BookID) async throws { covers[bookID] = data }
    public func loadFile(for bookID: BookID) async throws -> Data? { files[bookID] }
    public func loadCover(for bookID: BookID) async throws -> Data? { covers[bookID] }
    public func removeAll(for bookID: BookID) async throws { files[bookID] = nil; covers[bookID] = nil }
    public func exists(for bookID: BookID) async -> Bool { files[bookID] != nil }
    public var storedCount: Int { files.count }
}
