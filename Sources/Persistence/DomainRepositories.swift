import Foundation
import GRDB
import LibraryCore
import BrainCore
import LearningCore
import AchievementCore
import AgentRuntime

/// 思考与记忆仓储。确认提议时条目、关系、修订与提议状态在一个事务中写入。
public final class SQLiteBrainRepository: BrainRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static func write(_ item: BrainItem, _ db: Database) throws {
        try db.execute(sql: Upsert.sql("brain_item", columns: ["id", "kind", "status", "payload"], primaryKey: ["id"]),
                       arguments: [item.id, item.kind.rawValue, item.status.rawValue, try Codec.encode(item)])
    }

    static func write(_ p: MemoryProposal, _ db: Database) throws {
        try db.execute(sql: Upsert.sql("proposal", columns: ["id", "idempotencyKey", "status", "messageID", "payload"], primaryKey: ["id"]),
                       arguments: [p.id, p.idempotencyKey, p.status.rawValue, p.messageID, try Codec.encode(p)])
    }

    public func save(_ item: BrainItem) async throws { try await db.writer.write { try Self.write(item, $0) } }

    public func item(id: String) async throws -> BrainItem? {
        try await db.writer.read { try $0.fetchPayload(BrainItem.self, sql: "SELECT payload FROM brain_item WHERE id = ?", arguments: [id]) }
    }

    public func items(kinds: [BrainItemKind]?, includeInactive: Bool) async throws -> [BrainItem] {
        try await db.writer.read { db in
            var items = try db.fetchPayloads(BrainItem.self, sql: includeInactive ? "SELECT payload FROM brain_item"
                                             : "SELECT payload FROM brain_item WHERE status = 'active'")
            if let kinds { items = items.filter { kinds.contains($0.kind) } }
            return items.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        }
    }

    public func save(_ relation: Relation) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("relation", columns: ["id", "fromID", "toID", "payload"], primaryKey: ["id"]),
                           arguments: [relation.id, relation.fromID, relation.toID, try Codec.encode(relation)])
        }
    }

    public func relations(itemID: String) async throws -> [Relation] {
        try await db.writer.read {
            try $0.fetchPayloads(Relation.self, sql: "SELECT payload FROM relation WHERE fromID = ? OR toID = ?", arguments: [itemID, itemID])
        }
    }

    public func allRelations() async throws -> [Relation] {
        try await db.writer.read { try $0.fetchPayloads(Relation.self, sql: "SELECT payload FROM relation") }
    }

    public func deleteRelation(id: String) async throws {
        try await db.writer.write { try $0.execute(sql: "DELETE FROM relation WHERE id = ?", arguments: [id]) }
    }

    public func appendRevision(_ revision: Revision) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO revision (id, itemID, number, payload) VALUES (?, ?, ?, ?)",
                           arguments: [revision.id, revision.itemID, revision.number, try Codec.encode(revision)])
        }
    }

    public func revisions(itemID: String) async throws -> [Revision] {
        try await db.writer.read { try $0.fetchPayloads(Revision.self, sql: "SELECT payload FROM revision WHERE itemID = ? ORDER BY number", arguments: [itemID]) }
    }

    public func save(_ proposal: MemoryProposal) async throws { try await db.writer.write { try Self.write(proposal, $0) } }

    public func proposal(id: String) async throws -> MemoryProposal? {
        try await db.writer.read { try $0.fetchPayload(MemoryProposal.self, sql: "SELECT payload FROM proposal WHERE id = ?", arguments: [id]) }
    }

    public func proposal(idempotencyKey: String) async throws -> MemoryProposal? {
        try await db.writer.read { try $0.fetchPayload(MemoryProposal.self, sql: "SELECT payload FROM proposal WHERE idempotencyKey = ?", arguments: [idempotencyKey]) }
    }

    public func proposals(status: ProposalStatus?) async throws -> [MemoryProposal] {
        try await db.writer.read { db in
            if let status { return try db.fetchPayloads(MemoryProposal.self, sql: "SELECT payload FROM proposal WHERE status = ?", arguments: [status.rawValue]) }
            return try db.fetchPayloads(MemoryProposal.self, sql: "SELECT payload FROM proposal")
        }
    }

    public func applyAtomically(items: [BrainItem], relations: [Relation], revisions: [Revision], proposal: MemoryProposal) async throws {
        try await db.writer.write { db in
            // 并发确认保护：提议必须仍为 pending
            let current = try String.fetchOne(db, sql: "SELECT status FROM proposal WHERE id = ?", arguments: [proposal.id])
            guard current == ProposalStatus.pending.rawValue else { throw BrainError.proposalNotPending(ProposalStatus(rawValue: current ?? "") ?? .invalid) }
            for i in items { try Self.write(i, db) }
            for r in relations {
                try db.execute(sql: "INSERT INTO relation (id, fromID, toID, payload) VALUES (?, ?, ?, ?)",
                               arguments: [r.id, r.fromID, r.toID, try Codec.encode(r)])
            }
            for r in revisions {
                try db.execute(sql: "INSERT INTO revision (id, itemID, number, payload) VALUES (?, ?, ?, ?)",
                               arguments: [r.id, r.itemID, r.number, try Codec.encode(r)])
            }
            try Self.write(proposal, db)
        }
    }
}

/// 自测与复习仓储。
public final class SQLiteLearningRepository: LearningRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static func writeSchedule(_ s: ReviewSchedule, _ db: Database) throws {
        try db.execute(sql: Upsert.sql("review_schedule", columns: ["itemID", "dueDay", "payload"], primaryKey: ["itemID"]),
                       arguments: [s.itemID, s.dueDay.description, try Codec.encode(s)])
    }

    static func writeMastery(_ m: MasteryRecord, _ db: Database) throws {
        try db.execute(sql: Upsert.sql("mastery", columns: ["bookID", "knowledgePoint", "payload"], primaryKey: ["bookID", "knowledgePoint"]),
                       arguments: [m.bookID, m.knowledgePoint, try Codec.encode(m)])
    }

    public func save(_ item: LearningItem) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("learning_item", columns: ["id", "bookID", "payload"], primaryKey: ["id"]),
                           arguments: [item.id, item.bookID, try Codec.encode(item)])
        }
    }

    public func item(id: String) async throws -> LearningItem? {
        try await db.writer.read { try $0.fetchPayload(LearningItem.self, sql: "SELECT payload FROM learning_item WHERE id = ?", arguments: [id]) }
    }

    public func items(bookID: BookID?) async throws -> [LearningItem] {
        try await db.writer.read { db in
            if let bookID { return try db.fetchPayloads(LearningItem.self, sql: "SELECT payload FROM learning_item WHERE bookID = ?", arguments: [bookID]) }
            return try db.fetchPayloads(LearningItem.self, sql: "SELECT payload FROM learning_item")
        }
    }

    public func attempt(idempotencyKey: String) async throws -> Attempt? {
        try await db.writer.read { try $0.fetchPayload(Attempt.self, sql: "SELECT payload FROM attempt WHERE idempotencyKey = ?", arguments: [idempotencyKey]) }
    }

    public func attempts(itemID: String) async throws -> [Attempt] {
        try await db.writer.read { try $0.fetchPayloads(Attempt.self, sql: "SELECT payload FROM attempt WHERE itemID = ?", arguments: [itemID]) }
    }

    public func feedback(attemptID: String) async throws -> Feedback? {
        try await db.writer.read { try $0.fetchPayload(Feedback.self, sql: "SELECT payload FROM feedback WHERE attemptID = ?", arguments: [attemptID]) }
    }

    public func mastery(knowledgePoint: String, bookID: BookID) async throws -> MasteryRecord? {
        try await db.writer.read {
            try $0.fetchPayload(MasteryRecord.self, sql: "SELECT payload FROM mastery WHERE bookID = ? AND knowledgePoint = ?", arguments: [bookID, knowledgePoint])
        }
    }

    public func masteryRecords(bookID: BookID?) async throws -> [MasteryRecord] {
        try await db.writer.read { db in
            if let bookID { return try db.fetchPayloads(MasteryRecord.self, sql: "SELECT payload FROM mastery WHERE bookID = ?", arguments: [bookID]) }
            return try db.fetchPayloads(MasteryRecord.self, sql: "SELECT payload FROM mastery")
        }
    }

    public func saveMastery(_ record: MasteryRecord) async throws { try await db.writer.write { try Self.writeMastery(record, $0) } }

    public func schedule(itemID: String) async throws -> ReviewSchedule? {
        try await db.writer.read { try $0.fetchPayload(ReviewSchedule.self, sql: "SELECT payload FROM review_schedule WHERE itemID = ?", arguments: [itemID]) }
    }

    public func schedules() async throws -> [ReviewSchedule] {
        try await db.writer.read { try $0.fetchPayloads(ReviewSchedule.self, sql: "SELECT payload FROM review_schedule ORDER BY dueDay") }
    }

    public func saveItem(_ item: LearningItem, schedule: ReviewSchedule) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("learning_item", columns: ["id", "bookID", "payload"], primaryKey: ["id"]),
                           arguments: [item.id, item.bookID, try Codec.encode(item)])
            try Self.writeSchedule(schedule, db)
        }
    }

    /// 同一幂等键的重复提交由 UNIQUE 约束拒绝，整个事务回滚，不产生重复复习记录（RUN-02）。
    public func recordAttempt(_ attempt: Attempt, feedback: Feedback, mastery: MasteryRecord, schedule: ReviewSchedule) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO attempt (id, itemID, idempotencyKey, payload) VALUES (?, ?, ?, ?)",
                           arguments: [attempt.id, attempt.itemID, attempt.idempotencyKey, try Codec.encode(attempt)])
            try db.execute(sql: "INSERT INTO feedback (attemptID, payload) VALUES (?, ?)", arguments: [attempt.id, try Codec.encode(feedback)])
            try Self.writeMastery(mastery, db)
            try Self.writeSchedule(schedule, db)
        }
    }
}

/// 任务记录、追踪、成就与设置。
public final class SQLiteRuntimeStore: AgentTaskStore, TraceSink, AchievementRepository {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func save(_ record: AgentTaskRecord) async throws {
        try await db.writer.write { db in
            try db.execute(sql: Upsert.sql("agent_task", columns: ["idempotencyKey", "status", "payload"], primaryKey: ["idempotencyKey"]),
                           arguments: [record.idempotencyKey, record.status.rawValue, try Codec.encode(record)])
        }
    }

    public func task(idempotencyKey: String) async throws -> AgentTaskRecord? {
        try await db.writer.read { try $0.fetchPayload(AgentTaskRecord.self, sql: "SELECT payload FROM agent_task WHERE idempotencyKey = ?", arguments: [idempotencyKey]) }
    }

    public func tasks(status: AgentTaskStatus) async throws -> [AgentTaskRecord] {
        try await db.writer.read { try $0.fetchPayloads(AgentTaskRecord.self, sql: "SELECT payload FROM agent_task WHERE status = ?", arguments: [status.rawValue]) }
    }

    public func persist(_ event: TraceEvent) async {
        _ = try? await db.writer.write { db in
            try db.execute(sql: "INSERT INTO trace_event (traceID, payload) VALUES (?, ?)", arguments: [event.traceID, try Codec.encode(event)])
        }
    }

    public func traceEvents(traceID: String) async throws -> [TraceEvent] {
        try await db.writer.read { try $0.fetchPayloads(TraceEvent.self, sql: "SELECT payload FROM trace_event WHERE traceID = ? ORDER BY rowid", arguments: [traceID]) }
    }

    public func recentTraceEvents(limit: Int) async throws -> [TraceEvent] {
        try await db.writer.read { try $0.fetchPayloads(TraceEvent.self, sql: "SELECT payload FROM trace_event ORDER BY rowid DESC LIMIT ?", arguments: [limit]) }
    }

    public func unlocked() async throws -> [UnlockedAchievement] {
        try await db.writer.read { try $0.fetchPayloads(UnlockedAchievement.self, sql: "SELECT payload FROM achievement") }
    }

    public func insertIfAbsent(_ achievements: [UnlockedAchievement]) async throws {
        try await db.writer.write { db in
            for a in achievements {
                try db.execute(sql: "INSERT OR IGNORE INTO achievement (id, payload) VALUES (?, ?)", arguments: [a.id, try Codec.encode(a)])
            }
        }
    }

    public func setting(_ key: String) async throws -> String? {
        try await db.writer.read { try String.fetchOne($0, sql: "SELECT value FROM app_setting WHERE key = ?", arguments: [key]) }
    }

    public func setSetting(_ key: String, _ value: String?) async throws {
        try await db.writer.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO app_setting (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM app_setting WHERE key = ?", arguments: [key])
            }
        }
    }
}
