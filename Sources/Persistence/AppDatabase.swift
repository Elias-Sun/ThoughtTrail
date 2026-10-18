import Foundation
import GRDB
import LibraryCore

/// SQLite 数据库（GRDB）。关键字段建列与索引，领域对象完整内容以 JSON 存于 payload 列。
/// 迁移按版本追加，旧库样本在测试中验证（DATA-01）。
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public static let currentSchemaVersion = 2

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 仅迁移到指定版本（用于构造旧库样本）。
    public init(_ writer: any DatabaseWriter, upTo version: String) throws {
        self.writer = writer
        try Self.migrator.migrate(writer, upTo: version)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: configuration()))
    }

    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration()))
    }

    /// 把 WAL 内容写回主库并截断 WAL（统计库体积、备份前使用）。
    public func checkpoint() throws {
        try writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    }

    static func configuration() -> Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        c.label = "ThoughtTrail"
        return c
    }

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE book (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, status TEXT NOT NULL, title TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE chapter (bookID TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE, idx INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(bookID, idx));
            CREATE TABLE toc_entry (bookID TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE, ord INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(bookID, ord));
            CREATE TABLE annotation (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX annotation_book ON annotation(bookID);
            CREATE TABLE bookmark (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE reading_position (bookID TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE read_range (bookID TEXT NOT NULL, version TEXT NOT NULL, chapterIndex INTEGER NOT NULL, start INTEGER NOT NULL, "end" INTEGER NOT NULL);
            CREATE INDEX read_range_key ON read_range(bookID, version, chapterIndex);
            CREATE TABLE reading_session (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, status TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE reflection (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, state TEXT NOT NULL, commitKey TEXT UNIQUE, payload BLOB NOT NULL);
            CREATE TABLE reflection_edit (rowid INTEGER PRIMARY KEY AUTOINCREMENT, reflectionID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE conversation (id TEXT PRIMARY KEY, primaryBookID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE message (id TEXT PRIMARY KEY, conversationID TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE, requestKey TEXT, createdAt REAL NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX message_conv ON message(conversationID, createdAt);
            CREATE INDEX message_request ON message(requestKey);
            CREATE TABLE parent_chunk (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX parent_book ON parent_chunk(bookID);
            CREATE TABLE child_chunk (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, parentID TEXT NOT NULL, version TEXT NOT NULL, chapterIndex INTEGER NOT NULL, start INTEGER NOT NULL, "end" INTEGER NOT NULL, fingerprint TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX child_book ON child_chunk(bookID);
            CREATE VIRTUAL TABLE child_fts USING fts5(childID UNINDEXED, bookID UNINDEXED, tokens, tokenize = 'unicode61');
            CREATE TABLE embedding (childID TEXT NOT NULL, model TEXT NOT NULL, dims INTEGER NOT NULL, bookID TEXT NOT NULL, fingerprint TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(childID, model, dims));
            CREATE INDEX embedding_fp ON embedding(model, dims, fingerprint);
            CREATE INDEX embedding_book ON embedding(bookID, model, dims);
            CREATE TABLE index_manifest (bookID TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE brain_item (id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE relation (id TEXT PRIMARY KEY, fromID TEXT NOT NULL, toID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE revision (id TEXT PRIMARY KEY, itemID TEXT NOT NULL, number INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE proposal (id TEXT PRIMARY KEY, idempotencyKey TEXT NOT NULL UNIQUE, status TEXT NOT NULL, messageID TEXT, payload BLOB NOT NULL);
            CREATE TABLE learning_item (id TEXT PRIMARY KEY, bookID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE attempt (id TEXT PRIMARY KEY, itemID TEXT NOT NULL, idempotencyKey TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);
            CREATE TABLE feedback (attemptID TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE mastery (bookID TEXT NOT NULL, knowledgePoint TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(bookID, knowledgePoint));
            CREATE TABLE review_schedule (itemID TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE agent_task (idempotencyKey TEXT PRIMARY KEY, status TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE trace_event (rowid INTEGER PRIMARY KEY AUTOINCREMENT, traceID TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX trace_id ON trace_event(traceID);
            CREATE TABLE achievement (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE app_setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        }
        // v2：消息状态列（用于恢复中断任务与筛选）+ 复习到期日列（到期列表查询）。回填旧数据。
        m.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN status TEXT NOT NULL DEFAULT 'sent'")
            try db.execute(sql: "ALTER TABLE review_schedule ADD COLUMN dueDay TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "CREATE INDEX review_due ON review_schedule(dueDay)")
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM message") {
                if let obj = try? JSONSerialization.jsonObject(with: row["payload"] as Data) as? [String: Any],
                   let status = obj["status"] as? String {
                    try db.execute(sql: "UPDATE message SET status = ? WHERE id = ?", arguments: [status, row["id"] as String])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT itemID, payload FROM review_schedule") {
                if let obj = try? JSONSerialization.jsonObject(with: row["payload"] as Data) as? [String: Any],
                   let due = obj["dueDay"] as? [String: Any], let y = due["year"] as? Int, let mo = due["month"] as? Int, let d = due["day"] as? Int {
                    try db.execute(sql: "UPDATE review_schedule SET dueDay = ? WHERE itemID = ?",
                                   arguments: [String(format: "%04d-%02d-%02d", y, mo, d), row["itemID"] as String])
                }
            }
        }
        return m
    }

    public func appliedMigrations() throws -> [String] {
        try writer.read { db in try Self.migrator.appliedMigrations(db) }
    }
}

/// JSON 编解码（日期统一为 Unix 秒）。
enum Codec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func encode<T: Encodable>(_ v: T) throws -> Data { try encoder.encode(v) }
    static func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T { try decoder.decode(t, from: data) }
}

extension Database {
    func fetchPayloads<T: Decodable>(_ type: T.Type, sql: String, arguments: StatementArguments = []) throws -> [T] {
        try Row.fetchAll(self, sql: sql, arguments: arguments).map { try Codec.decode(T.self, $0["payload"]) }
    }

    func fetchPayload<T: Decodable>(_ type: T.Type, sql: String, arguments: StatementArguments = []) throws -> T? {
        guard let row = try Row.fetchOne(self, sql: sql, arguments: arguments) else { return nil }
        return try Codec.decode(T.self, row["payload"])
    }
}

/// 向量 BLOB 编解码（Float32 小端）。
enum VectorBlob {
    static func encode(_ v: [Float]) -> Data {
        var copy = v
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    static func decode(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }
}

/// 按主键更新的 UPSERT。不使用 INSERT OR REPLACE：后者在次级唯一约束冲突时会静默删除旧行（数据丢失）。
enum Upsert {
    static func sql(_ table: String, columns: [String], primaryKey: [String]) -> String {
        let quoted = columns.map { "\"\($0)\"" }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updates = columns.filter { !primaryKey.contains($0) }.map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")
        let conflict = primaryKey.map { "\"\($0)\"" }.joined(separator: ", ")
        return "INSERT INTO \(table) (\(quoted.joined(separator: ", "))) VALUES (\(placeholders)) ON CONFLICT(\(conflict)) DO UPDATE SET \(updates)"
    }
}
