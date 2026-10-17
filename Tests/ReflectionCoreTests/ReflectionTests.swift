import Testing
import Foundation
@testable import ReflectionCore
import LibraryCore
import ReaderCore
import Persistence
import TestSupport

private func snapshot(_ clock: ManualClock, selected: String? = "选中的句子", chapter: Int = 1) -> ReadingContextSnapshot {
    let book = Make.book(fingerprint: "v1")
    let ch = Make.chapter(index: chapter, text: "这里有选中的句子和其他内容。")
    return ReadingContextSnapshot(bookID: book.id, bookVersion: "v1", bookTitle: book.title, chapterIndex: chapter, chapterTitle: "第二章",
                                  locator: Locator.make(book: book, chapter: ch, range: TextSpan(start: 3, end: 8)),
                                  selectedText: selected, sessionID: "sess_1", capturedAt: clock.now())
}

@Suite("M04 反思")
struct ReflectionServiceTests {
    func make() throws -> (ReflectionService, SQLiteReflectionRepository, ManualClock) {
        let repo = SQLiteReflectionRepository(try AppDatabase.inMemory())
        let clock = ManualClock()
        return (ReflectionService(repository: repo, clock: clock, ids: SequentialIDGenerator()), repo, clock)
    }

    @Test("REF-01 反思关联书籍、位置、选段、会话和时间")
    func capturesReadingContext() async throws {
        let (svc, repo, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "初步想法")
        let loaded = try #require(try await repo.reflection(id: r.id))
        #expect(loaded.context.selectedText == "选中的句子")
        #expect(loaded.context.sessionID == "sess_1")
        #expect(loaded.context.locator?.range == TextSpan(start: 3, end: 8))
        #expect(loaded.context.capturedAt == clock.now())
    }

    @Test("REF-01 之后更换阅读位置不覆盖当时的证据快照")
    func snapshotIsFrozen() async throws {
        let (svc, repo, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "a")
        clock.advance(by: 100)
        _ = try await svc.updateDraft(id: r.id, text: "修改后")
        let loaded = try #require(try await repo.reflection(id: r.id))
        #expect(loaded.context.chapterIndex == 1)
        #expect(loaded.context.capturedAt == r.context.capturedAt)
        #expect(loaded.updatedAt > loaded.createdAt)
    }

    @Test("REF-02 草稿自动保存，重启后可恢复")
    func draftsSurviveRestart() async throws {
        let db = try AppDatabase.inMemory()
        let clock = ManualClock()
        let svc1 = ReflectionService(repository: SQLiteReflectionRepository(db), clock: clock, ids: SequentialIDGenerator())
        let r = try await svc1.startDraft(context: snapshot(clock))
        _ = try await svc1.updateDraft(id: r.id, text: "写到一半的想法")
        // 模拟重启：新的服务实例读取同一数据库
        let svc2 = ReflectionService(repository: SQLiteReflectionRepository(db), clock: clock, ids: SequentialIDGenerator(start: 100))
        let drafts = try await svc2.pendingDrafts()
        #expect(drafts.map(\.text) == ["写到一半的想法"])
    }

    @Test("REF-02 连续点击保存只产生一条记录")
    func commitIdempotent() async throws {
        let (svc, repo, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "想法")
        let a = try await svc.commit(id: r.id, commitKey: "k1")
        let b = try await svc.commit(id: r.id, commitKey: "k1")
        let c = try await svc.commit(id: r.id, commitKey: "k2")
        #expect(a.id == b.id && b.id == c.id)
        #expect(try await repo.reflections(bookID: nil).count == 1)
        #expect(try await svc.reflections(bookID: nil).count == 1)
    }

    @Test("REF-02 空白内容不能提交")
    func emptyCommitRejected() async throws {
        let (svc, _, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "   ")
        await #expect(throws: ReflectionError.emptyText) { try await svc.commit(id: r.id, commitKey: "k") }
    }

    @Test("REF-02 已保存反思不能再当作草稿修改")
    func savedIsNotDraft() async throws {
        let (svc, _, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "x")
        _ = try await svc.commit(id: r.id, commitKey: "k")
        await #expect(throws: ReflectionError.alreadySaved) { try await svc.updateDraft(id: r.id, text: "y") }
        await #expect(throws: ReflectionError.alreadySaved) { try await svc.discardDraft(id: r.id) }
    }

    @Test("REF-02 修改已保存反思保留前后内容")
    func editKeepsHistory() async throws {
        let (svc, repo, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "旧观点")
        _ = try await svc.commit(id: r.id, commitKey: "k")
        clock.advance(by: 60)
        let edited = try await svc.edit(id: r.id, newText: "新观点")
        #expect(edited.text == "新观点")
        let edits = try await repo.edits(reflectionID: r.id)
        #expect(edits.count == 1 && edits[0].before == "旧观点" && edits[0].after == "新观点")
        // 相同内容不产生修改记录
        _ = try await svc.edit(id: r.id, newText: "新观点")
        #expect(try await repo.edits(reflectionID: r.id).count == 1)
    }

    @Test("REF-03 语音转写原文与人工修改分别保存")
    func voiceTranscriptKept() async throws {
        let (svc, repo, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock))
        _ = try await svc.updateDraft(id: r.id, text: "人工修改后的文字", transcript: "人工修改后得文字", audioFileName: "voice_1.m4a")
        let loaded = try #require(try await repo.reflection(id: r.id))
        #expect(loaded.source == .voice)
        #expect(loaded.originalTranscript == "人工修改后得文字")
        #expect(loaded.audioFileName == "voice_1.m4a")
    }

    @Test("REF-02 丢弃草稿后不再出现在恢复列表")
    func discardDraft() async throws {
        let (svc, _, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: "x")
        try await svc.discardDraft(id: r.id)
        #expect(try await svc.pendingDrafts().isEmpty)
    }

    @Test("REF-02 超长文本被截断到上限")
    func lengthCapped() async throws {
        let (svc, _, clock) = try make()
        let r = try await svc.startDraft(context: snapshot(clock), text: String(repeating: "字", count: ReflectionService.maxLength + 50))
        #expect(r.text.count == ReflectionService.maxLength)
    }
}

@Suite("M04 讨论记录")
struct ConversationTests {
    func make() throws -> (ConversationService, SQLiteReflectionRepository, ManualClock) {
        let repo = SQLiteReflectionRepository(try AppDatabase.inMemory())
        let clock = ManualClock()
        return (ConversationService(repository: repo, clock: clock, ids: SequentialIDGenerator()), repo, clock)
    }

    @Test("CHAT-02 生成完成不等于核查通过：只有 verified 视为已核查")
    func verifiedOnlyFromVerification() {
        #expect(MessageStatus.verified.isVerifiedSuccess)
        for s in MessageStatus.allCases where s != .verified { #expect(!s.isVerifiedSuccess) }
        #expect(!MessageStatus.drafting.canTransition(to: .verified))
        #expect(MessageStatus.verifying.canTransition(to: .verified))
    }

    @Test("CHAT-04 终态不能被迟到的响应改写")
    func terminalStatesAreFinal() {
        for terminal in MessageStatus.allCases where terminal.isTerminal {
            for next in MessageStatus.allCases { #expect(!terminal.canTransition(to: next)) }
        }
    }

    @Test("CHAT-02 状态按 准备→草稿→核查→结果 推进")
    func happyPathTransitions() async throws {
        let (svc, repo, clock) = try make()
        let conv = try await svc.startConversation(context: snapshot(clock))
        let user = try await svc.addUserMessage(conversationID: conv.id, text: "问题")
        let a = Message(id: "a1", conversationID: conv.id, role: .assistant, text: "", status: .preparing, replyTo: user.id,
                        createdAt: clock.now(), updatedAt: clock.now())
        try await repo.save(a)
        _ = try await svc.transition(messageID: "a1", to: .drafting)
        _ = try await svc.transition(messageID: "a1", to: .verifying) { $0.text = "草稿" }
        let done = try await svc.transition(messageID: "a1", to: .needsAttention)
        #expect(done.text == "草稿" && done.status == .needsAttention)
        await #expect(throws: ConversationError.illegalTransition(from: .needsAttention, to: .verified)) {
            try await svc.transition(messageID: "a1", to: .verified)
        }
    }

    @Test("CHAT-04 用户问题先持久化，空问题被拒绝")
    func userMessagePersisted() async throws {
        let (svc, repo, clock) = try make()
        let conv = try await svc.startConversation(context: snapshot(clock))
        let m = try await svc.addUserMessage(conversationID: conv.id, text: "  这段话是什么意思？ ")
        #expect(try await repo.message(id: m.id)?.text == "这段话是什么意思？")
        await #expect(throws: ConversationError.emptyQuestion) { try await svc.addUserMessage(conversationID: conv.id, text: " ") }
        await #expect(throws: ConversationError.notFound) { try await svc.addUserMessage(conversationID: "nope", text: "q") }
    }

    @Test("5.2 切换到全书范围必须显式记录，并体现在新消息上")
    func scopeSwitchRecorded() async throws {
        let (svc, repo, clock) = try make()
        let conv = try await svc.startConversation(context: snapshot(clock))
        #expect(conv.scopeMode == .readOnly)
        _ = try await svc.setScope(conversationID: conv.id, mode: .wholeBook)
        #expect(try await repo.conversation(id: conv.id)?.scopeMode == .wholeBook)
        let m = try await svc.addUserMessage(conversationID: conv.id, text: "结局是什么？")
        #expect(m.scopeMode == .wholeBook)
    }

    @Test("CHAT-01 以选段开启的讨论标题与上下文来自选段")
    func titleFromSelection() async throws {
        let (svc, _, clock) = try make()
        let conv = try await svc.startConversation(context: snapshot(clock, selected: "带着问题去读书才有收获"))
        #expect(conv.title.contains("带着问题去读书"))
        #expect(conv.context.selectedText == "带着问题去读书才有收获")
    }

    @Test("READ-05 跨书讨论只包含用户明确添加的书")
    func crossBookIDs() async throws {
        let (svc, _, clock) = try make()
        let conv = try await svc.startConversation(context: snapshot(clock), additionalBookIDs: ["b2", "b1"])
        #expect(conv.allBookIDs == ["b1", "b2"])
    }

    @Test("CHAT-04 同状态重复迁移是幂等的")
    func sameStateIdempotent() async throws {
        let (svc, repo, clock) = try make()
        let conv = try await svc.startConversation(context: snapshot(clock))
        try await repo.save(Message(id: "a", conversationID: conv.id, role: .assistant, text: "", status: .cancelled,
                                    createdAt: clock.now(), updatedAt: clock.now()))
        let again = try await svc.transition(messageID: "a", to: .cancelled)
        #expect(again.status == .cancelled)
    }
}
