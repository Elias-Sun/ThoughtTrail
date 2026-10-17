import Foundation
import GRDB
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore

/// 书籍仓储（LIB-01…04）。导入、删除、挂接在单个事务中完成。
public final class SQLiteBookRepository: BookRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func insert(_ book: Book, chapters: [Chapter], toc: [TOCEntry]) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO book (id, fingerprint, status, title, payload) VALUES (?, ?, ?, ?, ?)",
                           arguments: [book.id, book.fingerprint, book.status.rawValue, book.title, try Codec.encode(book)])
            try Self.writeChapters(db, bookID: book.id, chapters: chapters, toc: toc)
        }
    }

    static func writeChapters(_ db: Database, bookID: BookID, chapters: [Chapter], toc: [TOCEntry]) throws {
        try db.execute(sql: "DELETE FROM chapter WHERE bookID = ?", arguments: [bookID])
        try db.execute(sql: "DELETE FROM toc_entry WHERE bookID = ?", arguments: [bookID])
        for c in chapters {
            try db.execute(sql: "INSERT INTO chapter (bookID, idx, payload) VALUES (?, ?, ?)", arguments: [bookID, c.index, try Codec.encode(c)])
        }
        for (i, t) in toc.enumerated() {
            try db.execute(sql: "INSERT INTO toc_entry (bookID, ord, payload) VALUES (?, ?, ?)", arguments: [bookID, i, try Codec.encode(t)])
        }
    }

    public func book(id: BookID) async throws -> Book? {
        try await db.writer.read { try $0.fetchPayload(Book.self, sql: "SELECT payload FROM book WHERE id = ?", arguments: [id]) }
    }

    public func book(fingerprint: String) async throws -> Book? {
        try await db.writer.read { try $0.fetchPayload(Book.self, sql: "SELECT payload FROM book WHERE fingerprint = ?", arguments: [fingerprint]) }
    }

    public func allBooks() async throws -> [Book] {
        try await db.writer.read { try $0.fetchPayloads(Book.self, sql: "SELECT payload FROM book") }
    }

    public func chapters(bookID: BookID) async throws -> [Chapter] {
        try await db.writer.read { try $0.fetchPayloads(Chapter.self, sql: "SELECT payload FROM chapter WHERE bookID = ? ORDER BY idx", arguments: [bookID]) }
    }

    public func chapter(bookID: BookID, index: Int) async throws -> Chapter? {
        try await db.writer.read { try $0.fetchPayload(Chapter.self, sql: "SELECT payload FROM chapter WHERE bookID = ? AND idx = ?", arguments: [bookID, index]) }
    }

    public func toc(bookID: BookID) async throws -> [TOCEntry] {
        try await db.writer.read { try $0.fetchPayloads(TOCEntry.self, sql: "SELECT payload FROM toc_entry WHERE bookID = ? ORDER BY ord", arguments: [bookID]) }
    }

    public func update(_ book: Book) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE book SET status = ?, title = ?, payload = ? WHERE id = ?",
                           arguments: [book.status.rawValue, book.title, try Codec.encode(book), book.id])
        }
    }

    public func detachSource(bookID: BookID) async throws {
        try await db.writer.write { db in
            guard var book = try db.fetchPayload(Book.self, sql: "SELECT payload FROM book WHERE id = ?", arguments: [bookID]) else { return }
            try db.execute(sql: "DELETE FROM chapter WHERE bookID = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM toc_entry WHERE bookID = ?", arguments: [bookID])
            try Self.deleteIndex(db, bookID: bookID)
            book.status = .sourceUnavailable
            book.indexState = .notIndexed
            try db.execute(sql: "UPDATE book SET status = ?, payload = ? WHERE id = ?",
                           arguments: [book.status.rawValue, try Codec.encode(book), bookID])
            // 反思保留，标记来源不可访问
            for var r in try db.fetchPayloads(Reflection.self, sql: "SELECT payload FROM reflection WHERE bookID = ?", arguments: [bookID]) {
                r.sourceUnavailable = true
                try db.execute(sql: "UPDATE reflection SET payload = ? WHERE id = ?", arguments: [try Codec.encode(r), r.id])
            }
            try db.execute(sql: "UPDATE learning_item SET payload = json_set(payload, '$.status', 'retired') WHERE bookID = ?", arguments: [bookID])
        }
    }

    public func reattach(bookID: BookID, chapters: [Chapter], toc: [TOCEntry], fileName: String, fileSize: Int) async throws {
        try await db.writer.write { db in
            guard var book = try db.fetchPayload(Book.self, sql: "SELECT payload FROM book WHERE id = ?", arguments: [bookID]) else { return }
            try Self.writeChapters(db, bookID: bookID, chapters: chapters, toc: toc)
            book.status = .active
            book.fileName = fileName
            book.fileSize = fileSize
            book.chapterCount = chapters.count
            try db.execute(sql: "UPDATE book SET status = ?, payload = ? WHERE id = ?",
                           arguments: [book.status.rawValue, try Codec.encode(book), bookID])
            for var r in try db.fetchPayloads(Reflection.self, sql: "SELECT payload FROM reflection WHERE bookID = ?", arguments: [bookID]) {
                r.sourceUnavailable = false
                try db.execute(sql: "UPDATE reflection SET payload = ? WHERE id = ?", arguments: [try Codec.encode(r), r.id])
            }
        }
    }

    /// 彻底删除：同步清理正文、索引、批注、会话、反思、讨论、练习（LIB-04）。记忆证据由 BrainService 标记失效。
    public func purge(bookID: BookID) async throws {
        try await db.writer.write { db in
            try Self.deleteIndex(db, bookID: bookID)
            for table in ["annotation", "bookmark", "reading_position", "read_range", "reading_session"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE bookID = ?", arguments: [bookID])
            }
            try db.execute(sql: "DELETE FROM reflection_edit WHERE reflectionID IN (SELECT id FROM reflection WHERE bookID = ?)", arguments: [bookID])
            try db.execute(sql: "DELETE FROM reflection WHERE bookID = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM conversation WHERE primaryBookID = ?", arguments: [bookID])
            let items = try String.fetchAll(db, sql: "SELECT id FROM learning_item WHERE bookID = ?", arguments: [bookID])
            for id in items {
                try db.execute(sql: "DELETE FROM feedback WHERE attemptID IN (SELECT id FROM attempt WHERE itemID = ?)", arguments: [id])
                try db.execute(sql: "DELETE FROM attempt WHERE itemID = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM review_schedule WHERE itemID = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM learning_item WHERE bookID = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM mastery WHERE bookID = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [bookID]) // 级联章节与目录
        }
    }

    static func deleteIndex(_ db: Database, bookID: BookID) throws {
        try db.execute(sql: "DELETE FROM child_fts WHERE bookID = ?", arguments: [bookID])
        try db.execute(sql: "DELETE FROM child_chunk WHERE bookID = ?", arguments: [bookID])
        try db.execute(sql: "DELETE FROM parent_chunk WHERE bookID = ?", arguments: [bookID])
        try db.execute(sql: "DELETE FROM embedding WHERE bookID = ?", arguments: [bookID])
        try db.execute(sql: "DELETE FROM index_manifest WHERE bookID = ?", arguments: [bookID])
    }
}

/// 批注、书签、阅读位置、已读区间与会话。
public final class SQLiteReadingRepository: AnnotationRepository, ReadingStateRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func save(_ annotation: Annotation) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("annotation", columns: ["id", "bookID", "payload"], primaryKey: ["id"]),
                           arguments: [annotation.id, annotation.bookID, try Codec.encode(annotation)])
        }
    }

    public func delete(annotationID: String) async throws {
        try await db.writer.write { try $0.execute(sql: "DELETE FROM annotation WHERE id = ?", arguments: [annotationID]) }
    }

    public func annotation(id: String) async throws -> Annotation? {
        try await db.writer.read { try $0.fetchPayload(Annotation.self, sql: "SELECT payload FROM annotation WHERE id = ?", arguments: [id]) }
    }

    public func annotations(bookID: BookID) async throws -> [Annotation] {
        try await db.writer.read { try $0.fetchPayloads(Annotation.self, sql: "SELECT payload FROM annotation WHERE bookID = ?", arguments: [bookID]) }
    }

    public func save(_ bookmark: Bookmark) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("bookmark", columns: ["id", "bookID", "payload"], primaryKey: ["id"]),
                           arguments: [bookmark.id, bookmark.bookID, try Codec.encode(bookmark)])
        }
    }

    public func delete(bookmarkID: String) async throws {
        try await db.writer.write { try $0.execute(sql: "DELETE FROM bookmark WHERE id = ?", arguments: [bookmarkID]) }
    }

    public func bookmarks(bookID: BookID) async throws -> [Bookmark] {
        try await db.writer.read { try $0.fetchPayloads(Bookmark.self, sql: "SELECT payload FROM bookmark WHERE bookID = ?", arguments: [bookID]) }
    }

    public func savePosition(_ position: ReadingPosition) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("reading_position", columns: ["bookID", "payload"], primaryKey: ["bookID"]),
                           arguments: [position.bookID, try Codec.encode(position)])
        }
    }

    public func position(bookID: BookID) async throws -> ReadingPosition? {
        try await db.writer.read { try $0.fetchPayload(ReadingPosition.self, sql: "SELECT payload FROM reading_position WHERE bookID = ?", arguments: [bookID]) }
    }

    public func readState(bookID: BookID, version: String) async throws -> BookReadState {
        try await db.writer.read { db in
            var state = BookReadState(bookID: bookID, bookVersion: version)
            for row in try Row.fetchAll(db, sql: "SELECT chapterIndex, start, \"end\" FROM read_range WHERE bookID = ? AND version = ?",
                                        arguments: [bookID, version]) {
                state.markRead(chapterIndex: row["chapterIndex"], range: TextSpan(start: row["start"], end: row["end"]))
            }
            return state
        }
    }

    /// 合并后整体替换该章区间（事务内，重复追加幂等）。
    public func addReadRange(bookID: BookID, version: String, chapterIndex: Int, range: TextSpan) async throws {
        guard !range.isEmpty else { return }
        try await db.writer.write { db in
            var set = ReadRangeSet()
            for row in try Row.fetchAll(db, sql: "SELECT start, \"end\" FROM read_range WHERE bookID = ? AND version = ? AND chapterIndex = ?",
                                        arguments: [bookID, version, chapterIndex]) {
                set.insert(TextSpan(start: row["start"], end: row["end"]))
            }
            set.insert(range)
            try db.execute(sql: "DELETE FROM read_range WHERE bookID = ? AND version = ? AND chapterIndex = ?",
                           arguments: [bookID, version, chapterIndex])
            for r in set.ranges {
                try db.execute(sql: "INSERT INTO read_range (bookID, version, chapterIndex, start, \"end\") VALUES (?, ?, ?, ?, ?)",
                               arguments: [bookID, version, chapterIndex, r.start, r.end])
            }
        }
    }

    public func saveSession(_ session: ReadingSession) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("reading_session", columns: ["id", "bookID", "status", "payload"], primaryKey: ["id"]),
                           arguments: [session.id, session.bookID, session.status.rawValue, try Codec.encode(session)])
        }
    }

    public func sessions(bookID: BookID?) async throws -> [ReadingSession] {
        try await db.writer.read { db in
            if let bookID {
                return try db.fetchPayloads(ReadingSession.self, sql: "SELECT payload FROM reading_session WHERE bookID = ?", arguments: [bookID])
            }
            return try db.fetchPayloads(ReadingSession.self, sql: "SELECT payload FROM reading_session")
        }
    }

    public func openSessions() async throws -> [ReadingSession] {
        try await db.writer.read { try $0.fetchPayloads(ReadingSession.self, sql: "SELECT payload FROM reading_session WHERE status != 'ended'") }
    }
}

/// 反思与讨论记录。
public final class SQLiteReflectionRepository: ReflectionRepository, ConversationRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func save(_ reflection: Reflection) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("reflection", columns: ["id", "bookID", "state", "commitKey", "payload"], primaryKey: ["id"]),
                           arguments: [reflection.id, reflection.bookID, reflection.state.rawValue, reflection.commitKey,
                                       try Codec.encode(reflection)])
        }
    }

    public func reflection(id: String) async throws -> Reflection? {
        try await db.writer.read { try $0.fetchPayload(Reflection.self, sql: "SELECT payload FROM reflection WHERE id = ?", arguments: [id]) }
    }

    public func reflection(commitKey: String) async throws -> Reflection? {
        try await db.writer.read { try $0.fetchPayload(Reflection.self, sql: "SELECT payload FROM reflection WHERE commitKey = ?", arguments: [commitKey]) }
    }

    public func reflections(bookID: BookID?) async throws -> [Reflection] {
        try await db.writer.read { db in
            if let bookID { return try db.fetchPayloads(Reflection.self, sql: "SELECT payload FROM reflection WHERE bookID = ?", arguments: [bookID]) }
            return try db.fetchPayloads(Reflection.self, sql: "SELECT payload FROM reflection")
        }
    }

    public func drafts() async throws -> [Reflection] {
        try await db.writer.read { try $0.fetchPayloads(Reflection.self, sql: "SELECT payload FROM reflection WHERE state = 'draft'") }
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM reflection_edit WHERE reflectionID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM reflection WHERE id = ?", arguments: [id])
        }
    }

    public func appendEdit(_ edit: ReflectionEdit) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO reflection_edit (reflectionID, payload) VALUES (?, ?)", arguments: [edit.reflectionID, try Codec.encode(edit)])
        }
    }

    public func edits(reflectionID: String) async throws -> [ReflectionEdit] {
        try await db.writer.read {
            try $0.fetchPayloads(ReflectionEdit.self, sql: "SELECT payload FROM reflection_edit WHERE reflectionID = ? ORDER BY rowid", arguments: [reflectionID])
        }
    }

    public func save(_ conversation: Conversation) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("conversation", columns: ["id", "primaryBookID", "payload"], primaryKey: ["id"]),
                           arguments: [conversation.id, conversation.primaryBookID, try Codec.encode(conversation)])
        }
    }

    public func conversation(id: String) async throws -> Conversation? {
        try await db.writer.read { try $0.fetchPayload(Conversation.self, sql: "SELECT payload FROM conversation WHERE id = ?", arguments: [id]) }
    }

    public func conversations(bookID: BookID?) async throws -> [Conversation] {
        try await db.writer.read { db in
            if let bookID { return try db.fetchPayloads(Conversation.self, sql: "SELECT payload FROM conversation WHERE primaryBookID = ?", arguments: [bookID]) }
            return try db.fetchPayloads(Conversation.self, sql: "SELECT payload FROM conversation")
        }
    }

    public func save(_ message: Message) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("message", columns: ["id", "conversationID", "requestKey", "createdAt", "status", "payload"], primaryKey: ["id"]), arguments: [message.id, message.conversationID, message.requestKey, message.createdAt.timeIntervalSince1970,
                                 message.status.rawValue, try Codec.encode(message)])
        }
    }

    public func message(id: String) async throws -> Message? {
        try await db.writer.read { try $0.fetchPayload(Message.self, sql: "SELECT payload FROM message WHERE id = ?", arguments: [id]) }
    }

    public func message(requestKey: String) async throws -> Message? {
        try await db.writer.read {
            try $0.fetchPayload(Message.self, sql: "SELECT payload FROM message WHERE requestKey = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1", arguments: [requestKey])
        }
    }

    public func messages(conversationID: String) async throws -> [Message] {
        try await db.writer.read {
            try $0.fetchPayloads(Message.self, sql: "SELECT payload FROM message WHERE conversationID = ? ORDER BY createdAt, rowid", arguments: [conversationID])
        }
    }

    public func deleteConversation(id: String) async throws {
        try await db.writer.write { try $0.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id]) }
    }

    /// 启动恢复：仍处于进行中的消息（进程被终止）标记为失败，保留问题与草稿（10.3）。
    public func failInterruptedMessages(reason: String) async throws -> Int {
        try await db.writer.write { db in
            var count = 0
            for var m in try db.fetchPayloads(Message.self, sql: "SELECT payload FROM message WHERE status IN ('preparing','drafting','verifying')") {
                m.status = .failed
                m.errorDescription = reason
                try db.execute(sql: "UPDATE message SET status = ?, payload = ? WHERE id = ?", arguments: [m.status.rawValue, try Codec.encode(m), m.id])
                count += 1
            }
            return count
        }
    }
}
