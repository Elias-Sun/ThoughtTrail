import Foundation
import GRDB
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import BrainCore
import LearningCore
import AchievementCore

/// 结构化备份（DATA-02）。带 schema 版本与校验和；不含密钥；可选包含 EPUB 原文件；不含音频与派生索引。
public struct BackupArchive: Codable, Sendable {
    public static let formatID = "thoughttrail-backup"
    public static let currentVersion = 2

    public var format: String
    public var schemaVersion: Int
    public var createdAt: Date
    public var includesEPUB: Bool
    public var includesAudio: Bool
    /// payload 规范 JSON 的 SHA-256。
    public var checksum: String
    public var payload: BackupPayload
}

public struct BackupPayload: Codable, Sendable, Equatable {
    public struct BookEntry: Codable, Sendable, Equatable {
        public var book: Book
        public var chapters: [Chapter]?
        public var toc: [TOCEntry]?
        /// base64 EPUB（仅 includesEPUB）。
        public var epubBase64: String?
    }
    public struct ReadRangeEntry: Codable, Sendable, Equatable {
        public var bookID: BookID
        public var version: String
        public var chapterIndex: Int
        public var start: Int
        public var end: Int
    }

    public var books: [BookEntry]
    public var annotations: [Annotation]
    public var bookmarks: [Bookmark]
    public var positions: [ReadingPosition]
    public var readRanges: [ReadRangeEntry]
    public var sessions: [ReadingSession]
    public var reflections: [Reflection]
    public var reflectionEdits: [ReflectionEdit]
    public var conversations: [Conversation]
    public var messages: [Message]
    public var brainItems: [BrainItem]
    public var relations: [Relation]
    public var revisions: [Revision]
    public var proposals: [MemoryProposal]
    public var learningItems: [LearningItem]
    public var attempts: [Attempt]
    public var feedback: [Feedback]
    public var mastery: [MasteryRecord]
    public var schedules: [ReviewSchedule]
    public var achievements: [UnlockedAchievement]
    /// 非敏感设置（不含密钥）。
    public var settings: [String: String]
}

public enum BackupError: Error, Equatable, Sendable {
    case notABackup
    case corrupted(String)
    case checksumMismatch
    case unsupportedVersion(Int)
}

public struct RestoreReport: Sendable, Equatable {
    public var books: Int
    public var booksMissingSource: Int
    public var reflections: Int
    public var brainItems: Int
    public var messages: Int
    public var learningItems: Int
    public var alreadyRestored: Bool
}

/// 备份导出与恢复。恢复在单个事务中执行：校验失败或写入失败都不修改现有数据。
public final class BackupService: Sendable {
    let db: AppDatabase
    let files: BookFileStore?
    /// 设置中允许写入备份的键（排除任何密钥相关键）。
    static let secretKeyFragments = ["key", "secret", "token", "password"]
    static let primaryKeys: [String: [String]] = ["mastery": ["bookID", "knowledgePoint"], "reading_position": ["bookID"],
                                                  "feedback": ["attemptID"], "review_schedule": ["itemID"]]

    public init(db: AppDatabase, files: BookFileStore?) { self.db = db; self.files = files }

    public func export(includeEPUB: Bool, now: Date) async throws -> Data {
        var payload = try await db.writer.read { db -> BackupPayload in
            let books = try db.fetchPayloads(Book.self, sql: "SELECT payload FROM book ORDER BY id")
            var entries: [BackupPayload.BookEntry] = []
            for b in books {
                var e = BackupPayload.BookEntry(book: b, chapters: nil, toc: nil, epubBase64: nil)
                if includeEPUB {
                    e.chapters = try db.fetchPayloads(Chapter.self, sql: "SELECT payload FROM chapter WHERE bookID = ? ORDER BY idx", arguments: [b.id])
                    e.toc = try db.fetchPayloads(TOCEntry.self, sql: "SELECT payload FROM toc_entry WHERE bookID = ? ORDER BY ord", arguments: [b.id])
                }
                entries.append(e)
            }
            let ranges = try Row.fetchAll(db, sql: "SELECT * FROM read_range ORDER BY bookID, version, chapterIndex, start").map {
                BackupPayload.ReadRangeEntry(bookID: $0["bookID"], version: $0["version"], chapterIndex: $0["chapterIndex"], start: $0["start"], end: $0["end"])
            }
            var settings: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM app_setting") {
                let key: String = row["key"]
                if !Self.secretKeyFragments.contains(where: { key.lowercased().contains($0) }) { settings[key] = row["value"] }
            }
            return BackupPayload(
                books: entries,
                annotations: try db.fetchPayloads(Annotation.self, sql: "SELECT payload FROM annotation ORDER BY id"),
                bookmarks: try db.fetchPayloads(Bookmark.self, sql: "SELECT payload FROM bookmark ORDER BY id"),
                positions: try db.fetchPayloads(ReadingPosition.self, sql: "SELECT payload FROM reading_position ORDER BY bookID"),
                readRanges: ranges,
                sessions: try db.fetchPayloads(ReadingSession.self, sql: "SELECT payload FROM reading_session ORDER BY id"),
                reflections: try db.fetchPayloads(Reflection.self, sql: "SELECT payload FROM reflection ORDER BY id"),
                reflectionEdits: try db.fetchPayloads(ReflectionEdit.self, sql: "SELECT payload FROM reflection_edit ORDER BY rowid"),
                conversations: try db.fetchPayloads(Conversation.self, sql: "SELECT payload FROM conversation ORDER BY id"),
                messages: try db.fetchPayloads(Message.self, sql: "SELECT payload FROM message ORDER BY createdAt, id"),
                brainItems: try db.fetchPayloads(BrainItem.self, sql: "SELECT payload FROM brain_item ORDER BY id"),
                relations: try db.fetchPayloads(Relation.self, sql: "SELECT payload FROM relation ORDER BY id"),
                revisions: try db.fetchPayloads(Revision.self, sql: "SELECT payload FROM revision ORDER BY itemID, number"),
                proposals: try db.fetchPayloads(MemoryProposal.self, sql: "SELECT payload FROM proposal ORDER BY id"),
                learningItems: try db.fetchPayloads(LearningItem.self, sql: "SELECT payload FROM learning_item ORDER BY id"),
                attempts: try db.fetchPayloads(Attempt.self, sql: "SELECT payload FROM attempt ORDER BY id"),
                feedback: try db.fetchPayloads(Feedback.self, sql: "SELECT payload FROM feedback ORDER BY attemptID"),
                mastery: try db.fetchPayloads(MasteryRecord.self, sql: "SELECT payload FROM mastery ORDER BY bookID, knowledgePoint"),
                schedules: try db.fetchPayloads(ReviewSchedule.self, sql: "SELECT payload FROM review_schedule ORDER BY itemID"),
                achievements: try db.fetchPayloads(UnlockedAchievement.self, sql: "SELECT payload FROM achievement ORDER BY id"),
                settings: settings)
        }
        if includeEPUB, let files {
            for i in payload.books.indices {
                if let data = try await files.loadFile(for: payload.books[i].book.id) {
                    payload.books[i].epubBase64 = data.base64EncodedString()
                }
            }
        }
        let payloadData = try Codec.encode(payload)
        let archive = BackupArchive(format: BackupArchive.formatID, schemaVersion: BackupArchive.currentVersion, createdAt: now,
                                    includesEPUB: includeEPUB, includesAudio: false,
                                    checksum: Fingerprint.sha256(payloadData), payload: payload)
        return try Codec.encode(archive)
    }

    /// 解析并校验备份（版本、格式、校验和）。旧版本备份先迁移再校验。
    public static func decode(_ data: Data) throws -> BackupArchive {
        guard !data.isEmpty, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.corrupted("不是有效的 JSON")
        }
        guard obj["format"] as? String == BackupArchive.formatID else { throw BackupError.notABackup }
        guard let version = obj["schemaVersion"] as? Int else { throw BackupError.corrupted("缺少 schemaVersion") }
        guard version >= 1 && version <= BackupArchive.currentVersion else { throw BackupError.unsupportedVersion(version) }
        var migrated = obj
        if version == 1 { migrated = try BackupMigrator.v1ToV2(obj) }
        guard let payloadObj = migrated["payload"] else { throw BackupError.corrupted("缺少 payload") }
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObj, options: [.sortedKeys])
        let payload: BackupPayload
        do { payload = try Codec.decode(BackupPayload.self, payloadData) } catch {
            throw BackupError.corrupted("payload 结构不符：\(error)")
        }
        // 校验和基于原始（迁移前）payload 的规范编码
        let originalPayload = try JSONSerialization.data(withJSONObject: obj["payload"] as Any, options: [.sortedKeys])
        let expected = obj["checksum"] as? String
        let reencoded = try Codec.encode(payload)
        guard expected == Fingerprint.sha256(originalPayload) || expected == Fingerprint.sha256(reencoded) else {
            throw BackupError.checksumMismatch
        }
        guard let createdAtRaw = obj["createdAt"] as? Double else { throw BackupError.corrupted("缺少 createdAt") }
        return BackupArchive(format: BackupArchive.formatID, schemaVersion: BackupArchive.currentVersion,
                             createdAt: Date(timeIntervalSince1970: createdAtRaw),
                             includesEPUB: obj["includesEPUB"] as? Bool ?? false, includesAudio: obj["includesAudio"] as? Bool ?? false,
                             checksum: expected ?? "", payload: payload)
    }

    /// 恢复：按 ID 覆盖写入（重复导入幂等）；未包含 EPUB 的书标记来源缺失。
    public func restore(_ data: Data) async throws -> RestoreReport {
        let archive = try Self.decode(data)
        let p = archive.payload
        let alreadyKey = "restored_backup_\(archive.checksum.prefix(16))"
        let already = try await db.writer.read { try String.fetchOne($0, sql: "SELECT value FROM app_setting WHERE key = ?", arguments: [alreadyKey]) } != nil
        let missing = try await db.writer.write { db -> Int in
            var missing = 0
            for entry in p.books {
                var book = entry.book
                let hasContent = entry.chapters != nil && !(entry.chapters!.isEmpty)
                let existingStatus = try String.fetchOne(db, sql: "SELECT status FROM book WHERE id = ?", arguments: [book.id])
                let existingHasChapters = try Int.fetchOne(db, sql: "SELECT count(*) FROM chapter WHERE bookID = ?", arguments: [book.id]) ?? 0 > 0
                if !hasContent && !(existingStatus == BookStatus.active.rawValue && existingHasChapters) {
                    book.status = .sourceUnavailable
                    missing += 1
                }
                // 同指纹不同 ID 的书已存在：保留现有记录
                if let other = try String.fetchOne(db, sql: "SELECT id FROM book WHERE fingerprint = ? AND id != ?", arguments: [book.fingerprint, book.id]) {
                    _ = other
                    continue
                }
                try db.execute(sql: Upsert.sql("book", columns: ["id", "fingerprint", "status", "title", "payload"], primaryKey: ["id"]),
                               arguments: [book.id, book.fingerprint, book.status.rawValue, book.title, try Codec.encode(book)])
                if hasContent {
                    try SQLiteBookRepository.writeChapters(db, bookID: book.id, chapters: entry.chapters ?? [], toc: entry.toc ?? [])
                }
            }
            func upsert<T: Encodable>(_ table: String, _ columns: [String], _ items: [T], _ values: (T) -> [any DatabaseValueConvertible]) throws {
                let pk = Self.primaryKeys[table] ?? [columns[0]]
                let sql = Upsert.sql(table, columns: columns + ["payload"], primaryKey: pk)
                for item in items {
                    var args = values(item)
                    args.append(try Codec.encode(item))
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                }
            }
            try upsert("annotation", ["id", "bookID"], p.annotations) { [$0.id, $0.bookID] }
            try upsert("bookmark", ["id", "bookID"], p.bookmarks) { [$0.id, $0.bookID] }
            try upsert("reading_position", ["bookID"], p.positions) { [$0.bookID] }
            try upsert("reading_session", ["id", "bookID", "status"], p.sessions) { [$0.id, $0.bookID, $0.status.rawValue] }
            try upsert("reflection", ["id", "bookID", "state", "commitKey"], p.reflections) { [$0.id, $0.bookID, $0.state.rawValue, $0.commitKey] }
            try upsert("conversation", ["id", "primaryBookID"], p.conversations) { [$0.id, $0.primaryBookID] }
            try upsert("message", ["id", "conversationID", "requestKey", "createdAt", "status"], p.messages) {
                [$0.id, $0.conversationID, $0.requestKey, $0.createdAt.timeIntervalSince1970, $0.status.rawValue]
            }
            try upsert("brain_item", ["id", "kind", "status"], p.brainItems) { [$0.id, $0.kind.rawValue, $0.status.rawValue] }
            try upsert("relation", ["id", "fromID", "toID"], p.relations) { [$0.id, $0.fromID, $0.toID] }
            try upsert("revision", ["id", "itemID", "number"], p.revisions) { [$0.id, $0.itemID, $0.number] }
            try upsert("proposal", ["id", "idempotencyKey", "status", "messageID"], p.proposals) { [$0.id, $0.idempotencyKey, $0.status.rawValue, $0.messageID] }
            try upsert("learning_item", ["id", "bookID"], p.learningItems) { [$0.id, $0.bookID] }
            try upsert("attempt", ["id", "itemID", "idempotencyKey"], p.attempts) { [$0.id, $0.itemID, $0.idempotencyKey] }
            try upsert("feedback", ["attemptID"], p.feedback) { [$0.attemptID] }
            try upsert("mastery", ["bookID", "knowledgePoint"], p.mastery) { [$0.bookID, $0.knowledgePoint] }
            try upsert("review_schedule", ["itemID", "dueDay"], p.schedules) { [$0.itemID, $0.dueDay.description] }
            try upsert("achievement", ["id"], p.achievements) { [$0.id] }
            // 修改记录与已读区间：按内容去重后写入
            for e in p.reflectionEdits {
                let data = try Codec.encode(e)
                let exists = try Int.fetchOne(db, sql: "SELECT count(*) FROM reflection_edit WHERE reflectionID = ? AND payload = ?", arguments: [e.reflectionID, data]) ?? 0
                if exists == 0 { try db.execute(sql: "INSERT INTO reflection_edit (reflectionID, payload) VALUES (?, ?)", arguments: [e.reflectionID, data]) }
            }
            var grouped: [String: ReadRangeSet] = [:]
            for r in p.readRanges { grouped["\(r.bookID)\u{1}\(r.version)\u{1}\(r.chapterIndex)", default: ReadRangeSet()].insert(TextSpan(start: r.start, end: r.end)) }
            for (key, set) in grouped {
                let parts = key.split(separator: "\u{1}").map(String.init)
                var merged = set
                for row in try Row.fetchAll(db, sql: "SELECT start, \"end\" FROM read_range WHERE bookID = ? AND version = ? AND chapterIndex = ?",
                                            arguments: [parts[0], parts[1], Int(parts[2])!]) {
                    merged.insert(TextSpan(start: row["start"], end: row["end"]))
                }
                try db.execute(sql: "DELETE FROM read_range WHERE bookID = ? AND version = ? AND chapterIndex = ?", arguments: [parts[0], parts[1], Int(parts[2])!])
                for r in merged.ranges {
                    try db.execute(sql: "INSERT INTO read_range (bookID, version, chapterIndex, start, \"end\") VALUES (?, ?, ?, ?, ?)",
                                   arguments: [parts[0], parts[1], Int(parts[2])!, r.start, r.end])
                }
            }
            for (k, v) in p.settings where !Self.secretKeyFragments.contains(where: { k.lowercased().contains($0) }) {
                try db.execute(sql: "INSERT OR REPLACE INTO app_setting (key, value) VALUES (?, ?)", arguments: [k, v])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO app_setting (key, value) VALUES (?, ?)", arguments: [alreadyKey, "\(archive.createdAt.timeIntervalSince1970)"])
            return missing
        }
        if archive.includesEPUB, let files {
            for entry in p.books {
                if let b64 = entry.epubBase64, let data = Data(base64Encoded: b64) {
                    try await files.save(data, for: entry.book.id, fileName: entry.book.fileName)
                }
            }
        }
        return RestoreReport(books: p.books.count, booksMissingSource: missing, reflections: p.reflections.count,
                             brainItems: p.brainItems.count, messages: p.messages.count, learningItems: p.learningItems.count,
                             alreadyRestored: already)
    }
}

/// 旧备份格式迁移。v1 中反思字段名为 "notes"，且没有成就与设置字段。
public enum BackupMigrator {
    public static func v1ToV2(_ obj: [String: Any]) throws -> [String: Any] {
        guard var payload = obj["payload"] as? [String: Any] else { throw BackupError.corrupted("缺少 payload") }
        if payload["reflections"] == nil { payload["reflections"] = payload["notes"] ?? [] }
        payload["notes"] = nil
        for key in ["achievements", "proposals", "reflectionEdits", "bookmarks", "sessions", "revisions", "relations",
                    "attempts", "feedback", "mastery", "schedules", "learningItems", "positions", "readRanges", "messages", "conversations",
                    "annotations", "brainItems"] where payload[key] == nil {
            payload[key] = []
        }
        if payload["settings"] == nil { payload["settings"] = [String: String]() }
        var out = obj
        out["payload"] = payload
        out["schemaVersion"] = 2
        return out
    }
}

/// Markdown 导出：便于阅读，不用于恢复。
public enum MarkdownExporter {
    public static func export(books: [Book], annotations: [Annotation], reflections: [Reflection], brainItems: [BrainItem],
                              conversations: [Conversation], messages: [Message]) -> String {
        var out = "# 思迹 ThoughtTrail 导出\n\n> 本文件便于阅读；恢复请使用结构化备份（.ttbackup）。\n\n"
        for book in books.sorted(by: { $0.title < $1.title }) {
            out += "## 《\(book.title)》 · \(book.authorLine)\n\n"
            if book.status == .sourceUnavailable { out += "_阅读文件已删除，以下笔记保留。_\n\n" }
            let anns = annotations.filter { $0.bookID == book.id }.sorted { ($0.locator.chapterIndex, $0.locator.range.start) < ($1.locator.chapterIndex, $1.locator.range.start) }
            if !anns.isEmpty {
                out += "### 批注\n\n"
                for a in anns {
                    out += "- > \(a.quote.replacingOccurrences(of: "\n", with: " "))\n"
                    if let n = a.note { out += "  - 笔记：\(n)\n" }
                }
                out += "\n"
            }
            let refls = reflections.filter { $0.bookID == book.id && $0.state == .saved }.sorted { $0.createdAt < $1.createdAt }
            if !refls.isEmpty {
                out += "### 反思\n\n"
                for r in refls {
                    out += "- \(r.text)\n"
                    if let sel = r.context.selectedText { out += "  - 选段：\(sel.prefix(80))\n" }
                }
                out += "\n"
            }
            for c in conversations.filter({ $0.primaryBookID == book.id }) {
                out += "### 讨论：\(c.title)\n\n"
                for m in messages.filter({ $0.conversationID == c.id }).sorted(by: { $0.createdAt < $1.createdAt }) {
                    out += m.role == .user ? "**问**：\(m.text)\n\n" : "**答**（\(m.status.displayName)）：\(m.text)\n\n"
                    for cite in m.citations { out += "  - [\(cite.label)] \(cite.quote.prefix(60))\(cite.structurallyValid ? "" : "（引用未通过校验）")\n" }
                }
            }
        }
        let items = brainItems.filter { $0.status == .active }
        if !items.isEmpty {
            out += "## 思考与记忆\n\n"
            for kind in BrainItemKind.allCases {
                let group = items.filter { $0.kind == kind }
                guard !group.isEmpty else { continue }
                out += "### \(kind.displayName)\n\n"
                for i in group {
                    out += "- \(i.content)（r\(i.revision)\(i.origin == .confirmedProposal ? "，来自已确认提议" : "")）\n"
                    for e in i.evidence { out += "  - 来源：\(e.quote.prefix(60))\(e.isValid ? "" : "（来源已失效）")\n" }
                }
                out += "\n"
            }
        }
        return out
    }
}
