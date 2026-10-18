import Testing
import Foundation
import GRDB
@testable import Persistence
import LibraryCore
import ReaderCore
import ReadingSessionCore
import ReflectionCore
import RetrievalCore
import BrainCore
import LearningCore
import AchievementCore
import AgentRuntime
import TestSupport

@Suite("M13 迁移")
struct MigrationTests {
    @Test("DATA-01 新库应用全部迁移")
    func freshDatabase() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.appliedMigrations() == ["v1", "v2"])
    }

    @Test("DATA-01 旧库样本（v1）迁移到最新并回填新列")
    func legacyMigration() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue, upTo: "v1")
        let now = Date(timeIntervalSince1970: 1_000)
        let msg = Message(id: "m1", conversationID: "c1", role: .assistant, text: "旧回答", status: .verified, createdAt: now, updatedAt: now)
        let conv = Conversation(id: "c1", title: "t", primaryBookID: "b",
                                context: ReadingContextSnapshot(bookID: "b", bookVersion: "v", bookTitle: "b", chapterIndex: nil, chapterTitle: nil,
                                                                locator: nil, selectedText: nil, sessionID: nil, capturedAt: now),
                                createdAt: now, updatedAt: now)
        let sched = ReviewSchedule(itemID: "q1", step: 1, dueDay: DayKey(year: 2026, month: 5, day: 4), timeZoneID: "UTC")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (id, primaryBookID, payload) VALUES (?, ?, ?)", arguments: ["c1", "b", try Codec.encode(conv)])
            try db.execute(sql: "INSERT INTO message (id, conversationID, requestKey, createdAt, payload) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["m1", "c1", nil, 1000.0, try Codec.encode(msg)])
            try db.execute(sql: "INSERT INTO review_schedule (itemID, payload) VALUES (?, ?)", arguments: ["q1", try Codec.encode(sched)])
        }
        let migrated = try AppDatabase(queue)
        #expect(try migrated.appliedMigrations() == ["v1", "v2"])
        let (status, due) = try queue.read { db in
            (try String.fetchOne(db, sql: "SELECT status FROM message WHERE id = 'm1'"),
             try String.fetchOne(db, sql: "SELECT dueDay FROM review_schedule WHERE itemID = 'q1'"))
        }
        #expect(status == "verified")
        #expect(due == "2026-05-04")
    }

    @Test("DATA-01 重复执行迁移是幂等的")
    func migrationIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue)
        #expect(try AppDatabase(queue).appliedMigrations() == ["v1", "v2"])
    }

    @Test("DATA-01 磁盘数据库可重开并保留数据（模拟重启）")
    func onDiskReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("db.sqlite")
        do {
            let db = try AppDatabase.onDisk(at: url)
            try await SQLiteBookRepository(db).insert(Make.book(), chapters: [Make.chapter(text: "正文")], toc: [])
        }
        let reopened = try AppDatabase.onDisk(at: url)
        #expect(try await SQLiteBookRepository(reopened).chapters(bookID: "b1").first?.text == "正文")
    }
}

@Suite("M13 书籍仓储与删除")
struct BookRepositoryTests {
    @Test("DATA-01 写入失败时整体回滚（同指纹第二本书不留下章节）")
    func atomicInsert() async throws {
        let db = try AppDatabase.inMemory()
        let repo = SQLiteBookRepository(db)
        try await repo.insert(Make.book(id: "a", fingerprint: "same"), chapters: [Make.chapter(bookID: "a", text: "甲")], toc: [])
        await #expect(throws: (any Error).self) {
            try await repo.insert(Make.book(id: "b", fingerprint: "same"), chapters: [Make.chapter(bookID: "b", text: "乙")], toc: [])
        }
        #expect(try await repo.chapters(bookID: "b").isEmpty)
        #expect(try await repo.allBooks().count == 1)
    }

    @Test("LIB-04 仅删除文件：清除正文与索引，保留批注与反思并标记来源不可访问")
    func detachKeepsNotes() async throws {
        let env = try TestEnvironment()
        let (book, chapters) = try await env.importBook(Fixtures.zhBook())
        let ann = AnnotationService(repository: env.reading, clock: env.clock, ids: env.ids)
        _ = try await ann.addHighlight(book: book, chapter: chapters[0], range: TextSpan(start: 0, end: 5))
        let refl = ReflectionService(repository: env.reflections, clock: env.clock, ids: env.ids)
        let ctx = ReadingContextSnapshot(bookID: book.id, bookVersion: book.fingerprint, bookTitle: book.title, chapterIndex: 0, chapterTitle: nil,
                                         locator: nil, selectedText: nil, sessionID: nil, capturedAt: env.clock.now())
        let r = try await refl.startDraft(context: ctx, text: "想法")
        try await env.books.detachSource(bookID: book.id)
        #expect(try await env.books.chapters(bookID: book.id).isEmpty)
        #expect(try await env.retrieval.children(bookID: book.id).isEmpty)
        #expect(try await env.reading.annotations(bookID: book.id).count == 1)
        #expect(try await env.reflections.reflection(id: r.id)?.sourceUnavailable == true)
        #expect(try await env.books.book(id: book.id)?.status == .sourceUnavailable)
    }

    @Test("LIB-04 彻底删除：清理正文、索引、批注、会话、反思、讨论与练习，不影响其他书")
    func purgeEverything() async throws {
        let env = try TestEnvironment()
        let (book, chapters) = try await env.importBook(Fixtures.zhBook())
        let (other, _) = try await env.importBook(Fixtures.enBook(), name: "en.epub")
        try await env.markRead(book, chapters: chapters, indices: [0])
        _ = try await AnnotationService(repository: env.reading, clock: env.clock, ids: env.ids)
            .addHighlight(book: book, chapter: chapters[0], range: TextSpan(start: 0, end: 4))
        let (conv, _) = try await env.startDiscussion(book: book, question: "问题")
        try await env.reading.saveSession(ReadingSession(id: "s1", bookID: book.id, startedAt: env.clock.now()))
        let item = LearningItem(id: "q1", bookID: book.id, type: .comprehension, prompt: "题目内容是什么", referencePoints: ["a"], rubric: "",
                                evidence: [], knowledgePoint: "k", createdAt: env.clock.now())
        try await env.learning.saveItem(item, schedule: ReviewScheduler().initial(itemID: "q1", createdAt: env.clock.now(), timeZone: .current))
        try await env.books.purge(bookID: book.id)
        #expect(try await env.books.book(id: book.id) == nil)
        #expect(try await env.books.chapters(bookID: book.id).isEmpty)
        #expect(try await env.retrieval.children(bookID: book.id).isEmpty)
        #expect(try await env.reading.annotations(bookID: book.id).isEmpty)
        #expect(try await env.reading.sessions(bookID: book.id).isEmpty)
        #expect(try await env.reading.readState(bookID: book.id, version: book.fingerprint).chapters.isEmpty)
        #expect(try await env.reflections.conversation(id: conv.id) == nil)
        #expect(try await env.reflections.messages(conversationID: conv.id).isEmpty)
        #expect(try await env.learning.item(id: "q1") == nil)
        #expect(try await env.learning.schedule(itemID: "q1") == nil)
        #expect(try await env.books.book(id: other.id) != nil)
        let otherChildren = try await env.retrieval.children(bookID: other.id)
        #expect(!otherChildren.isEmpty)
    }

    @Test("LIB-04 重新挂接正文恢复书籍与反思可访问状态")
    func reattach() async throws {
        let env = try TestEnvironment()
        let (book, chapters) = try await env.importBook(Fixtures.zhBook())
        try await env.books.detachSource(bookID: book.id)
        try await env.books.reattach(bookID: book.id, chapters: chapters, toc: [], fileName: "x.epub", fileSize: 10)
        #expect(try await env.books.book(id: book.id)?.status == .active)
        #expect(try await env.books.chapters(bookID: book.id).count == chapters.count)
    }
}

@Suite("M13 讨论与反思仓储")
struct ConversationRepositoryTests {
    @Test("REF-02 提交键唯一：同一键不能产生第二条反思")
    func commitKeyUnique() async throws {
        let repo = SQLiteReflectionRepository(try AppDatabase.inMemory())
        let ctx = ReadingContextSnapshot(bookID: "b", bookVersion: "v", bookTitle: "b", chapterIndex: nil, chapterTitle: nil, locator: nil,
                                         selectedText: nil, sessionID: nil, capturedAt: Date())
        try await repo.save(Reflection(id: "r1", context: ctx, text: "a", source: .typed, state: .saved, createdAt: Date(), updatedAt: Date(), commitKey: "k"))
        await #expect(throws: (any Error).self) {
            try await repo.save(Reflection(id: "r2", context: ctx, text: "b", source: .typed, state: .saved, createdAt: Date(), updatedAt: Date(), commitKey: "k"))
        }
    }

    @Test("DATA-01 更新会话（如切换范围）不会级联删除其消息")
    func conversationUpdateKeepsMessages() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.enBook())
        let (conv, user) = try await env.startDiscussion(book: book, question: "q")
        _ = try await env.conversationService().setScope(conversationID: conv.id, mode: .wholeBook)
        #expect(try await env.reflections.message(id: user.id) != nil)
        #expect(try await env.reflections.conversation(id: conv.id)?.scopeMode == .wholeBook)
    }

    @Test("DATA-01 备份恢复覆盖已有书籍时不丢失其章节")
    func restoreOverExistingBookKeepsChapters() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.enBook())
        let data = try await BackupService(db: env.db, files: env.files).export(includeEPUB: false, now: env.clock.now())
        _ = try await BackupService(db: env.db, files: env.files).restore(data)
        #expect(try await env.books.chapters(bookID: book.id).count == 3)
        #expect(try await env.books.book(id: book.id)?.status == .active)
    }

    @Test("10.3 启动时把进行中的回答标记为失败并保留内容")
    func failInterrupted() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.enBook())
        let (conv, _) = try await env.startDiscussion(book: book, question: "q")
        let now = env.clock.now()
        try await env.reflections.save(Message(id: "a1", conversationID: conv.id, role: .assistant, text: "半截草稿", status: .drafting, createdAt: now, updatedAt: now))
        try await env.reflections.save(Message(id: "a2", conversationID: conv.id, role: .assistant, text: "完成", status: .verified, createdAt: now, updatedAt: now))
        #expect(try await env.reflections.failInterruptedMessages(reason: "被中断") == 1)
        let m = try #require(try await env.reflections.message(id: "a1"))
        #expect(m.status == .failed && m.text == "半截草稿" && m.errorDescription == "被中断")
        #expect(try await env.reflections.message(id: "a2")?.status == .verified)
    }

    @Test("RUN-02 按请求键取最近一次回答，消息按时间排序")
    func requestKeyLookup() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.enBook())
        let (conv, _) = try await env.startDiscussion(book: book, question: "q")
        let t0 = env.clock.now()
        try await env.reflections.save(Message(id: "x1", conversationID: conv.id, role: .assistant, text: "1", status: .failed, requestKey: "k", createdAt: t0, updatedAt: t0))
        try await env.reflections.save(Message(id: "x2", conversationID: conv.id, role: .assistant, text: "2", status: .verified, requestKey: "k",
                                               createdAt: t0.addingTimeInterval(5), updatedAt: t0))
        #expect(try await env.reflections.message(requestKey: "k")?.id == "x2")
        #expect(try await env.reflections.messages(conversationID: conv.id).map(\.id).suffix(2) == ["x1", "x2"])
    }
}

@Suite("M13 检索存储")
struct RetrievalStoreTests {
    @Test("RAG-02 FTS5 中文词语召回，结果映射到子块")
    func ftsChinese() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.zhBook())
        let hits = try await env.retrieval.searchLexical("遗忘曲线", scope: RetrievalScope([.wholeBook(bookID: book.id, version: book.fingerprint)]), limit: 3)
        let top = try #require(try await env.retrieval.children(ids: [hits[0].id]).first)
        #expect(top.chapterIndex == 1 && top.text.contains("遗忘曲线"))
    }

    @Test("READ-05 FTS5 召回在范围过滤后凑满结果，不返回未读子块")
    func ftsScope() async throws {
        let env = try TestEnvironment()
        let (book, chapters) = try await env.importBook(Fixtures.zhBook())
        try await env.markRead(book, chapters: chapters, indices: [0, 1])
        let scope = RetrievalScope([try await env.scope(book)])
        let hits = try await env.retrieval.searchLexical("作者 船长 读书 复习", scope: scope, limit: 10)
        let kids = try await env.retrieval.children(ids: hits.map(\.id))
        #expect(!kids.isEmpty && kids.allSatisfy { $0.chapterIndex <= 1 })
    }

    @Test("RAG-05 向量写入、检索与按模型失效")
    func vectors() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.zhBook())
        let emb = HashEmbeddingService(dimensions: 32)
        let kids = try await env.retrieval.children(bookID: book.id)
        try await env.retrieval.saveEmbeddings(kids.map { EmbeddingItem(childID: $0.id, bookID: book.id, fingerprint: $0.fingerprint, vector: emb.vector($0.text)) },
                                               profile: emb.profile)
        let scope = RetrievalScope([.wholeBook(bookID: book.id, version: book.fingerprint)])
        let hits = try await env.retrieval.searchVectors(emb.vector("自测比重读更有效"), profile: emb.profile, scope: scope, limit: 2)
        #expect(try await env.retrieval.children(ids: [hits[0].id]).first?.chapterIndex == 1)
        // 其他维度的同名模型查不到
        #expect(try await env.retrieval.searchVectors([Float](repeating: 1, count: 16), profile: EmbeddingProfile(model: emb.profile.model, dimensions: 16),
                                                      scope: scope, limit: 2).isEmpty)
        try await env.retrieval.invalidateEmbeddings(bookID: book.id, keeping: EmbeddingProfile(model: "other", dimensions: 8))
        #expect(try await env.retrieval.embeddedChildIDs(bookID: book.id, profile: emb.profile).isEmpty)
        #expect(try await env.retrieval.searchVectors(emb.vector("自测"), profile: emb.profile, scope: scope, limit: 2).isEmpty)
    }

    @Test("RAG-02 含异常值的向量批次整批拒绝写入")
    func invalidBatchRejected() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.zhBook())
        let kids = try await env.retrieval.children(bookID: book.id)
        let p = EmbeddingProfile(model: "m", dimensions: 2)
        await #expect(throws: VectorError.nonFinite) {
            try await env.retrieval.saveEmbeddings([EmbeddingItem(childID: kids[0].id, bookID: book.id, fingerprint: "a", vector: [1, 0]),
                                                    EmbeddingItem(childID: kids[1].id, bookID: book.id, fingerprint: "b", vector: [.nan, 0])], profile: p)
        }
        #expect(try await env.retrieval.embeddedChildIDs(bookID: book.id, profile: p).isEmpty)
    }

    @Test("RAG-06 按内容指纹查已有向量")
    func fingerprintLookup() async throws {
        let env = try TestEnvironment()
        let (book, _) = try await env.importBook(Fixtures.zhBook())
        let kid = try #require(try await env.retrieval.children(bookID: book.id).first)
        let p = EmbeddingProfile(model: "m", dimensions: 2)
        try await env.retrieval.saveEmbeddings([EmbeddingItem(childID: kid.id, bookID: book.id, fingerprint: kid.fingerprint, vector: [0.5, 0.5])], profile: p)
        #expect(try await env.retrieval.vectors(fingerprints: [kid.fingerprint, "missing"], profile: p) == [kid.fingerprint: [0.5, 0.5]])
    }
}

@Suite("M13 事务与运行时存储")
struct TransactionTests {
    @Test("MEM-02 并发确认：提议已非 pending 时原子写入被拒绝")
    func applyGuard() async throws {
        let repo = SQLiteBrainRepository(try AppDatabase.inMemory())
        let now = Date()
        var p = MemoryProposal(id: "p", idempotencyKey: "k", conversationID: nil, messageID: nil,
                               action: .create(kind: .question, content: "问？", evidence: []), rationale: "", status: .rejected, issues: [], createdAt: now)
        try await repo.save(p)
        p.status = .confirmed
        let item = BrainItem(id: "i", kind: .question, content: "问？", origin: .confirmedProposal, evidence: [], createdAt: now, updatedAt: now)
        await #expect(throws: BrainError.proposalNotPending(.rejected)) {
            try await repo.applyAtomically(items: [item], relations: [], revisions: [], proposal: p)
        }
        #expect(try await repo.item(id: "i") == nil)
    }

    @Test("LEARN-05 同一作答键第二次写入整体回滚")
    func attemptUnique() async throws {
        let repo = SQLiteLearningRepository(try AppDatabase.inMemory())
        let now = Date()
        let att = Attempt(id: "a1", itemID: "q", answer: "x", submittedAt: now, idempotencyKey: "k")
        let fb = Feedback(attemptID: "a1", itemID: "q", correctPoints: [], missingPoints: [], evidence: [], grade: .scored(1), rationale: "", graderName: "t", createdAt: now)
        let m = MasteryRecord(knowledgePoint: "kp", bookID: "b", updatedAt: now)
        let s = ReviewSchedule(itemID: "q", step: 1, dueDay: DayKey(year: 2026, month: 1, day: 1), timeZoneID: "UTC")
        try await repo.recordAttempt(att, feedback: fb, mastery: m, schedule: s)
        var att2 = att; att2.id = "a2"
        var s2 = s; s2.step = 4
        await #expect(throws: (any Error).self) { try await repo.recordAttempt(att2, feedback: fb, mastery: m, schedule: s2) }
        #expect(try await repo.schedule(itemID: "q")?.step == 1)
        #expect(try await repo.attempts(itemID: "q").count == 1)
    }

    @Test("HABIT-01 成就重复插入被忽略；设置与追踪可读写")
    func runtimeStore() async throws {
        let store = SQLiteRuntimeStore(try AppDatabase.inMemory())
        let a = UnlockedAchievement(id: "first_day", title: "开卷有益", unlockedAt: Date(timeIntervalSince1970: 1), explanation: "e")
        try await store.insertIfAbsent([a])
        var later = a; later.unlockedAt = Date(timeIntervalSince1970: 99)
        try await store.insertIfAbsent([later])
        #expect(try await store.unlocked() == [a])
        try await store.setSetting("theme", "dark")
        #expect(try await store.setting("theme") == "dark")
        try await store.setSetting("theme", nil)
        #expect(try await store.setting("theme") == nil)
        await store.persist(TraceEvent(traceID: "t", stage: "s", name: "n", startedAt: Date(), outcome: .success))
        #expect(try await store.traceEvents(traceID: "t").count == 1)
    }
}

@Suite("M13 备份与导出")
struct BackupTests {
    func populated() async throws -> (TestEnvironment, Book) {
        let env = try TestEnvironment()
        let (book, chapters) = try await env.importBook(Fixtures.zhBook())
        try await env.markRead(book, chapters: chapters, indices: [0, 1])
        _ = try await AnnotationService(repository: env.reading, clock: env.clock, ids: env.ids)
            .addHighlight(book: book, chapter: chapters[0], range: TextSpan(start: 0, end: 6), note: "笔记")
        let (conv, user) = try await env.startDiscussion(book: book, question: "复习？")
        let now = env.clock.now()
        try await env.reflections.save(Message(id: "ans", conversationID: conv.id, role: .assistant, text: "回答[E1]", status: .verified,
                                               citations: [CitationSnapshot(label: "E1", evidenceID: "e", kind: .bookText, bookID: book.id,
                                                                            bookVersion: book.fingerprint, locator: nil, sourceRecordID: nil,
                                                                            quote: "引用原文", structurallyValid: true)],
                                               replyTo: user.id, createdAt: now, updatedAt: now))
        _ = try await BrainService(repository: env.brain, clock: env.clock, ids: env.ids)
            .create(kind: .memory, content: "间隔复习", evidence: [.book(book.id, version: book.fingerprint, chapter: 1, range: TextSpan(start: 0, end: 5), quote: "q")])
        try await env.runtime.setSetting("reader_theme", "sepia")
        try await env.runtime.setSetting("api_key_hint", "sk-should-not-export")
        return (env, book)
    }

    @Test("DATA-02 导出后恢复到新库：关键记录与引用关系一致")
    func roundTrip() async throws {
        let (env, book) = try await populated()
        let data = try await BackupService(db: env.db, files: env.files).export(includeEPUB: false, now: env.clock.now())
        let target = try TestEnvironment()
        let report = try await BackupService(db: target.db, files: target.files).restore(data)
        #expect(report.books == 1 && report.booksMissingSource == 1)
        #expect(try await target.reading.annotations(bookID: book.id).first?.note == "笔记")
        let ans = try #require(try await target.reflections.message(id: "ans"))
        #expect(ans.citations.first?.quote == "引用原文" && ans.status == .verified)
        #expect(try await target.brain.items(kinds: nil, includeInactive: false).count == 1)
        #expect(try await target.reading.readState(bookID: book.id, version: book.fingerprint).chapters.count == 2)
        #expect(try await target.books.book(id: book.id)?.status == .sourceUnavailable)
        #expect(try await target.runtime.setting("reader_theme") == "sepia")
    }

    @Test("DATA-02 包含 EPUB 的备份恢复后书籍可直接阅读")
    func roundTripWithEPUB() async throws {
        let (env, book) = try await populated()
        let data = try await BackupService(db: env.db, files: env.files).export(includeEPUB: true, now: env.clock.now())
        let target = try TestEnvironment()
        let report = try await BackupService(db: target.db, files: target.files).restore(data)
        #expect(report.booksMissingSource == 0)
        #expect(try await target.books.book(id: book.id)?.status == .active)
        #expect(try await target.books.chapters(bookID: book.id).count == 4)
        #expect(await target.files.exists(for: book.id))
    }

    @Test("DATA-03 结构化备份不包含密钥类设置")
    func noSecretsInBackup() async throws {
        let (env, _) = try await populated()
        let data = try await BackupService(db: env.db, files: env.files).export(includeEPUB: false, now: env.clock.now())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("sk-should-not-export"))
        #expect(!text.contains("api_key_hint"))
        let archive = try BackupService.decode(data)
        #expect(archive.includesAudio == false && archive.schemaVersion == BackupArchive.currentVersion)
    }

    @Test("DATA-02 重复导入同一备份不产生重复记录")
    func idempotentRestore() async throws {
        let (env, book) = try await populated()
        let data = try await BackupService(db: env.db, files: env.files).export(includeEPUB: false, now: env.clock.now())
        let target = try TestEnvironment()
        let svc = BackupService(db: target.db, files: target.files)
        let first = try await svc.restore(data)
        let second = try await svc.restore(data)
        #expect(!first.alreadyRestored && second.alreadyRestored)
        #expect(try await target.reading.annotations(bookID: book.id).count == 1)
        #expect(try await target.brain.items(kinds: nil, includeInactive: true).count == 1)
        #expect(try await target.reading.readState(bookID: book.id, version: book.fingerprint).readRanges(chapterIndex: 0).count == 1)
    }

    @Test("DATA-02 篡改内容导致校验和不符，恢复被拒绝且不修改数据")
    func checksumMismatch() async throws {
        let (env, _) = try await populated()
        let data = try await BackupService(db: env.db, files: env.files).export(includeEPUB: false, now: env.clock.now())
        let tampered = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "笔记", with: "改过").utf8)
        let target = try TestEnvironment()
        await #expect(throws: BackupError.checksumMismatch) { try await BackupService(db: target.db, files: nil).restore(tampered) }
        #expect(try await target.books.allBooks().isEmpty)
    }

    @Test("DATA-02 损坏文件、非备份文件与不支持的版本给出明确错误")
    func badFiles() async throws {
        #expect(throws: BackupError.self) { try BackupService.decode(Data("{截断".utf8)) }
        #expect(throws: BackupError.notABackup) { try BackupService.decode(Data(#"{"format":"other"}"#.utf8)) }
        #expect(throws: BackupError.unsupportedVersion(99)) { try BackupService.decode(Data(#"{"format":"thoughttrail-backup","schemaVersion":99}"#.utf8)) }
        #expect(throws: BackupError.self) { try BackupService.decode(Data()) }
    }

    @Test("DATA-02 旧版本（v1）备份迁移后可恢复")
    func legacyBackup() async throws {
        let payload: [String: Any] = [
            "books": [], "notes": [[
                "id": "r-old", "text": "旧备份的反思", "source": "typed", "state": "saved", "createdAt": 1000.0, "updatedAt": 1000.0,
                "sourceUnavailable": false,
                "context": ["bookID": "b-old", "bookVersion": "v", "bookTitle": "旧书", "capturedAt": 1000.0],
            ]],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let archive: [String: Any] = ["format": "thoughttrail-backup", "schemaVersion": 1, "createdAt": 1000.0,
                                      "includesEPUB": false, "includesAudio": false,
                                      "checksum": Fingerprint.sha256(payloadData), "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: archive)
        let target = try TestEnvironment()
        let report = try await BackupService(db: target.db, files: nil).restore(data)
        #expect(report.reflections == 1)
        #expect(try await target.reflections.reflection(id: "r-old")?.text == "旧备份的反思")
    }

    @Test("DATA-02 Markdown 导出包含书籍、批注、讨论与记忆，便于阅读")
    func markdownExport() async throws {
        let (env, book) = try await populated()
        let md = MarkdownExporter.export(books: [book], annotations: try await env.reading.annotations(bookID: book.id),
                                         reflections: [], brainItems: try await env.brain.items(kinds: nil, includeInactive: false),
                                         conversations: try await env.reflections.conversations(bookID: nil),
                                         messages: try await env.reflections.messages(conversationID: try await env.reflections.conversations(bookID: nil)[0].id))
        #expect(md.contains("《阅读之道》"))
        #expect(md.contains("笔记：笔记"))
        #expect(md.contains("**答**（已核查）"))
        #expect(md.contains("### 记忆") && md.contains("间隔复习"))
    }
}

@Suite("M13 补充")
struct PersistenceEdgeTests {
    @Test("READ-01 书签保存、按书列出与删除")
    func bookmarks() async throws {
        let repo = SQLiteReadingRepository(try AppDatabase.inMemory())
        let book = Make.book(fingerprint: "v")
        let ch = Make.chapter(text: "第一页的内容")
        let b = Bookmark(id: "bm1", bookID: book.id, locator: Locator.make(book: book, chapter: ch, range: TextSpan(start: 0, end: 2)),
                         title: "第一页", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await repo.save(b)
        #expect(try await repo.bookmarks(bookID: book.id) == [b])
        #expect(try await repo.bookmarks(bookID: "other").isEmpty)
        try await repo.delete(bookmarkID: "bm1")
        #expect(try await repo.bookmarks(bookID: book.id).isEmpty)
    }

    @Test("READ-04 未结束会话列表不含已结束会话；不指定书时返回全部")
    func openSessions() async throws {
        let repo = SQLiteReadingRepository(try AppDatabase.inMemory())
        var ended = ReadingSession(id: "s1", bookID: "a", startedAt: Date()); ended.status = .ended
        try await repo.saveSession(ended)
        try await repo.saveSession(ReadingSession(id: "s2", bookID: "b", startedAt: Date()))
        #expect(try await repo.openSessions().map(\.id) == ["s2"])
        #expect(try await repo.sessions(bookID: nil).count == 2)
    }

    @Test("MEM-04 另一个提议使用相同幂等键时写入被拒绝，不覆盖原提议")
    func proposalKeyConflict() async throws {
        let repo = SQLiteBrainRepository(try AppDatabase.inMemory())
        let now = Date()
        let a = MemoryProposal(id: "p1", idempotencyKey: "k", conversationID: nil, messageID: nil,
                               action: .create(kind: .question, content: "问一？", evidence: []), rationale: "", status: .pending, issues: [], createdAt: now)
        var b = a; b.id = "p2"
        try await repo.save(a)
        await #expect(throws: (any Error).self) { try await repo.save(b) }
        #expect(try await repo.proposal(idempotencyKey: "k")?.id == "p1")
    }

    @Test("LIB-04 Markdown 导出标注来源不可访问的书与失效证据")
    func markdownMarksUnavailable() {
        let book = Make.book(status: .sourceUnavailable)
        let item = BrainItem(id: "i", kind: .memory, content: "记忆内容", origin: .user,
                             evidence: [EvidenceRef(kind: .bookText, bookID: book.id, quote: "原句", isValid: false)], createdAt: Date(), updatedAt: Date())
        let md = MarkdownExporter.export(books: [book], annotations: [], reflections: [], brainItems: [item], conversations: [], messages: [])
        #expect(md.contains("阅读文件已删除"))
        #expect(md.contains("（来源已失效）"))
    }
}
