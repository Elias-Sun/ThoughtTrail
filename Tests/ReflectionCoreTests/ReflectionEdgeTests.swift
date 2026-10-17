import Testing
import Foundation
@testable import ReflectionCore
import LibraryCore
import Persistence
import TestSupport

private func ctx(_ book: BookID = "b1") -> ReadingContextSnapshot {
    ReadingContextSnapshot(bookID: book, bookVersion: "v", bookTitle: "书", chapterIndex: 0, chapterTitle: nil, locator: nil,
                           selectedText: nil, sessionID: nil, capturedAt: Date(timeIntervalSince1970: 0))
}

@Suite("M04 边界情况")
struct ReflectionEdgeTests {
    @Test("REF-02 已保存反思按时间倒序列出，草稿不在其中，可按书筛选")
    func listing() async throws {
        let repo = SQLiteReflectionRepository(try AppDatabase.inMemory())
        let clock = ManualClock()
        let svc = ReflectionService(repository: repo, clock: clock, ids: SequentialIDGenerator())
        let a = try await svc.startDraft(context: ctx("b1"), text: "早")
        _ = try await svc.commit(id: a.id, commitKey: "a")
        clock.advance(by: 10)
        let b = try await svc.startDraft(context: ctx("b2"), text: "晚")
        _ = try await svc.commit(id: b.id, commitKey: "b")
        _ = try await svc.startDraft(context: ctx("b1"), text: "草稿")
        #expect(try await svc.reflections(bookID: nil).map(\.text) == ["早", "晚"].reversed())
        #expect(try await svc.reflections(bookID: "b1").map(\.text) == ["早"])
    }

    @Test("CHAT-02 每种消息状态都有区分的展示名")
    func statusDisplayNames() {
        let names = MessageStatus.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(MessageStatus.verified.displayName == "已核查" && MessageStatus.verifying.displayName == "核查中")
    }

    @Test("CHAT-04 不存在的消息无法迁移状态")
    func transitionMissing() async throws {
        let svc = ConversationService(repository: SQLiteReflectionRepository(try AppDatabase.inMemory()), clock: ManualClock(), ids: SequentialIDGenerator())
        await #expect(throws: ConversationError.notFound) { try await svc.transition(messageID: "none", to: .failed) }
        await #expect(throws: ConversationError.notFound) { try await svc.setScope(conversationID: "none", mode: .wholeBook) }
    }

    @Test("CHAT-01 按书籍列出讨论，删除讨论同时删除消息")
    func conversationsByBook() async throws {
        let repo = SQLiteReflectionRepository(try AppDatabase.inMemory())
        let svc = ConversationService(repository: repo, clock: ManualClock(), ids: SequentialIDGenerator())
        let c1 = try await svc.startConversation(context: ctx("b1"))
        _ = try await svc.startConversation(context: ctx("b2"))
        let m = try await svc.addUserMessage(conversationID: c1.id, text: "问题")
        #expect(try await repo.conversations(bookID: "b1").count == 1)
        try await repo.deleteConversation(id: c1.id)
        #expect(try await repo.message(id: m.id) == nil)
    }

    @Test("REF-02 编辑空白内容被拒绝；不存在的反思报错")
    func editValidation() async throws {
        let svc = ReflectionService(repository: SQLiteReflectionRepository(try AppDatabase.inMemory()), clock: ManualClock(), ids: SequentialIDGenerator())
        let r = try await svc.startDraft(context: ctx(), text: "内容")
        _ = try await svc.commit(id: r.id, commitKey: "k")
        await #expect(throws: ReflectionError.emptyText) { try await svc.edit(id: r.id, newText: "  ") }
        await #expect(throws: ReflectionError.notFound) { try await svc.edit(id: "none", newText: "x") }
        await #expect(throws: ReflectionError.notFound) { try await svc.commit(id: "none", commitKey: "z") }
    }
}
