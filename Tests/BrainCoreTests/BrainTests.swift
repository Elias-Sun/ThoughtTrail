import Testing
import Foundation
@testable import BrainCore
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import Persistence
import TestSupport

private let bookRef = EvidenceRef.book("b1", version: "v1", chapter: 0, range: TextSpan(start: 0, end: 20), quote: "复习应按间隔进行")
private let reflRef = EvidenceRef.reflection("refl_1", bookID: "b1", quote: "我觉得复习很重要")

private func context(scope: RetrievalScope? = nil) -> ProposalContext {
    ProposalContext(conversationID: "conv", messageID: "msg", evidenceByLabel: ["E1": bookRef, "E2": reflRef], scope: scope)
}

private func make() throws -> (BrainService, SQLiteBrainRepository, ManualClock) {
    let repo = SQLiteBrainRepository(try AppDatabase.inMemory())
    let clock = ManualClock()
    return (BrainService(repository: repo, clock: clock, ids: SequentialIDGenerator()), repo, clock)
}

@Suite("M09 条目与修订")
struct BrainItemTests {
    @Test("MEM-01 分别创建观点、问题与记忆，可按类型筛选")
    func createKinds() async throws {
        let (svc, repo, _) = try make()
        _ = try await svc.create(kind: .thought, content: "带着问题读书更有效")
        _ = try await svc.create(kind: .question, content: "精读和泛读如何分配？")
        _ = try await svc.create(kind: .memory, content: "复习间隔 1/3/7 天", evidence: [bookRef])
        #expect(try await repo.items(kinds: [.question], includeInactive: false).count == 1)
        #expect(try await repo.items(kinds: nil, includeInactive: false).count == 3)
    }

    @Test("MEM-01 空内容与超长内容被拒绝")
    func contentValidation() async throws {
        let (svc, _, _) = try make()
        await #expect(throws: BrainError.emptyContent) { try await svc.create(kind: .thought, content: "  ") }
        await #expect(throws: BrainError.contentTooLong) {
            try await svc.create(kind: .thought, content: String(repeating: "长", count: ProposalValidator.maxContentLength + 1))
        }
    }

    @Test("MEM-04 编辑保留前后内容、时间与原因")
    func editCreatesRevision() async throws {
        let (svc, _, clock) = try make()
        let item = try await svc.create(kind: .thought, content: "旧观点")
        clock.advance(by: 30)
        let edited = try await svc.edit(itemID: item.id, expectedRevision: 1, newContent: "新观点", reason: "读到新证据")
        #expect(edited.revision == 2 && edited.content == "新观点")
        let revs = try await svc.revisions(itemID: item.id)
        #expect(revs.count == 1)
        #expect(revs[0].before == "旧观点" && revs[0].after == "新观点" && revs[0].reason == "读到新证据")
        #expect(revs[0].at == clock.now())
    }

    @Test("MEM-04 基于过期版本的编辑被拒绝，不静默覆盖")
    func staleEditRejected() async throws {
        let (svc, repo, _) = try make()
        let item = try await svc.create(kind: .thought, content: "v1")
        _ = try await svc.edit(itemID: item.id, expectedRevision: 1, newContent: "v2", reason: "")
        await #expect(throws: BrainError.revisionConflict(expected: 1, actual: 2)) {
            try await svc.edit(itemID: item.id, expectedRevision: 1, newContent: "v2-other", reason: "")
        }
        #expect(try await repo.item(id: item.id)?.content == "v2")
    }

    @Test("MEM-04 内容未变化时不产生修订")
    func noOpEdit() async throws {
        let (svc, _, _) = try make()
        let item = try await svc.create(kind: .thought, content: "相同")
        let same = try await svc.edit(itemID: item.id, expectedRevision: 1, newContent: " 相同 ", reason: "")
        #expect(same.revision == 1)
        #expect(try await svc.revisions(itemID: item.id).isEmpty)
    }

    @Test("MEM-01 按内容搜索，删除的条目不出现")
    func search() async throws {
        let (svc, _, _) = try make()
        let a = try await svc.create(kind: .memory, content: "遗忘曲线说明复习要及时")
        _ = try await svc.create(kind: .thought, content: "批注让阅读变成思考")
        #expect(try await svc.search("复习").map(\.id) == [a.id])
        try await svc.setStatus(itemID: a.id, status: .deleted)
        #expect(try await svc.search("复习").isEmpty)
        #expect(try await svc.search("").count == 1)
    }

    @Test("MEM-01 问题可标记为已解决")
    func resolveQuestion() async throws {
        let (svc, repo, _) = try make()
        let q = try await svc.create(kind: .question, content: "如何安排复习？")
        try await svc.markResolved(questionID: q.id, resolved: true)
        #expect(try await repo.item(id: q.id)?.resolved == true)
        let t = try await svc.create(kind: .thought, content: "不是问题")
        await #expect(throws: BrainError.notFound) { try await svc.markResolved(questionID: t.id, resolved: true) }
    }

    @Test("MEM-03 用户建立关系；重复建立返回同一关系；不能自关联")
    func userRelations() async throws {
        let (svc, _, _) = try make()
        let a = try await svc.create(kind: .thought, content: "甲")
        let b = try await svc.create(kind: .thought, content: "乙")
        let r1 = try await svc.link(from: a.id, to: b.id, type: .conflicts)
        let r2 = try await svc.link(from: a.id, to: b.id, type: .conflicts)
        #expect(r1.id == r2.id && r1.origin == .user)
        #expect(try await svc.relations(itemID: b.id).count == 1)
        await #expect(throws: BrainError.selfRelation) { try await svc.link(from: a.id, to: a.id, type: .supports) }
    }
}

@Suite("M09 记忆提议")
struct ProposalTests {
    @Test("MEM-02 合法提议保存为待确认，不直接写入条目")
    func pendingNotWritten() async throws {
        let (svc, repo, _) = try make()
        let props = try await svc.submit([(.create(kind: .memory, content: "复习按间隔进行", evidence: [bookRef]), "讨论得出")], context: context())
        #expect(props.first?.status == .pending)
        #expect(try await repo.items(kinds: nil, includeInactive: true).isEmpty)
    }

    @Test("MEM-02 确认后才生效，条目标记为来自确认的提议")
    func confirmApplies() async throws {
        let (svc, repo, _) = try make()
        let p = try await svc.submit([(.create(kind: .memory, content: "复习按间隔进行", evidence: [bookRef]), "")], context: context())[0]
        let confirmed = try await svc.confirm(proposalID: p.id)
        let item = try #require(try await repo.item(id: confirmed.resultItemID!))
        #expect(item.origin == .confirmedProposal)
        #expect(item.sourceProposalID == p.id)
        #expect(item.evidence == [bookRef])
    }

    @Test("MEM-02 拒绝不会暗中写入")
    func rejectWritesNothing() async throws {
        let (svc, repo, _) = try make()
        let p = try await svc.submit([(.create(kind: .memory, content: "x 内容", evidence: [bookRef]), "")], context: context())[0]
        let rejected = try await svc.reject(proposalID: p.id)
        #expect(rejected.status == .rejected)
        #expect(try await repo.items(kinds: nil, includeInactive: true).isEmpty)
        await #expect(throws: BrainError.proposalNotPending(.rejected)) { try await svc.confirm(proposalID: p.id) }
    }

    @Test("MEM-04 重复处理同一讨论不会生成重复提议")
    func idempotentSubmit() async throws {
        let (svc, repo, _) = try make()
        let action = ProposalAction.create(kind: .memory, content: "同一条记忆", evidence: [bookRef])
        let a = try await svc.submit([(action, "")], context: context())
        let b = try await svc.submit([(action, "")], context: context())
        #expect(a[0].id == b[0].id)
        #expect(try await repo.proposals(status: nil).count == 1)
    }

    @Test("MEM-04 与已有条目重复的提议被标记为无效")
    func duplicateOfExisting() async throws {
        let (svc, _, _) = try make()
        let existing = try await svc.create(kind: .memory, content: "复习应当按照间隔进行", evidence: [bookRef])
        let p = try await svc.submit([(.create(kind: .memory, content: "复习应当按照间隔进行。", evidence: [bookRef]), "")], context: context())[0]
        #expect(p.status == .invalid)
        #expect(p.issues.contains("duplicate_of:\(existing.id)"))
        await #expect(throws: BrainError.proposalNotPending(.invalid)) { try await svc.confirm(proposalID: p.id) }
    }

    @Test("MEM-02 来源不是本次讨论证据的提议无效")
    func foreignEvidence() async throws {
        let (svc, _, _) = try make()
        let foreign = EvidenceRef.book("b9", version: "v", chapter: 3, range: TextSpan(start: 0, end: 5), quote: "别处")
        let p = try await svc.submit([(.create(kind: .memory, content: "来自别处", evidence: [foreign]), "")], context: context())[0]
        #expect(p.issues.contains("evidence_not_from_discussion"))
    }

    @Test("MEM-05 证据超出阅读范围的提议无效")
    func outOfScopeEvidence() async throws {
        let (svc, _, _) = try make()
        let scope = RetrievalScope([AccessScope.readOnly(BookReadState(bookID: "b1", bookVersion: "v1"))])
        let p = try await svc.submit([(.create(kind: .memory, content: "未读内容", evidence: [bookRef]), "")], context: context(scope: scope))[0]
        #expect(p.issues.contains("evidence_out_of_scope"))
    }

    @Test("MEM-02 记忆类提议缺少证据无效；问题类可以没有证据")
    func missingEvidence() async throws {
        let (svc, _, _) = try make()
        let props = try await svc.submit([(.create(kind: .memory, content: "无证据记忆", evidence: []), ""),
                                          (.create(kind: .question, content: "一个待解问题？", evidence: []), "")], context: context())
        #expect(props[0].issues.contains("missing_evidence"))
        #expect(props[1].status == .pending)
    }

    @Test("MEM-03 关联提议确认后关系标记为“建议”来源")
    func linkProposal() async throws {
        let (svc, repo, _) = try make()
        let a = try await svc.create(kind: .thought, content: "观点甲")
        let b = try await svc.create(kind: .memory, content: "记忆乙", evidence: [bookRef])
        let p = try await svc.submit([(.link(fromID: a.id, toID: b.id, type: .supports), "乙支持甲")], context: context())[0]
        _ = try await svc.confirm(proposalID: p.id)
        let rels = try await repo.relations(itemID: a.id)
        #expect(rels.count == 1 && rels[0].origin == .suggested && rels[0].type == .supports)
    }

    @Test("MEM-03 关联不存在的条目或已存在的关系无效")
    func invalidLinks() async throws {
        let (svc, _, _) = try make()
        let a = try await svc.create(kind: .thought, content: "甲")
        let b = try await svc.create(kind: .thought, content: "乙")
        _ = try await svc.link(from: a.id, to: b.id, type: .extends)
        let props = try await svc.submit([(.link(fromID: a.id, toID: "ghost", type: .supports), ""),
                                          (.link(fromID: a.id, toID: b.id, type: .extends), "")], context: context())
        #expect(props[0].issues.contains("unknown_item:ghost"))
        #expect(props[1].issues.contains("relation_exists"))
    }

    @Test("MEM-04 修订提议确认后记录修订历史")
    func reviseProposal() async throws {
        let (svc, repo, _) = try make()
        let item = try await svc.create(kind: .thought, content: "复习可有可无")
        let p = try await svc.submit([(.revise(itemID: item.id, baseRevision: 1, newContent: "复习必须按间隔进行", reason: "新证据"), "")], context: context())[0]
        _ = try await svc.confirm(proposalID: p.id)
        #expect(try await repo.item(id: item.id)?.revision == 2)
        let revs = try await svc.revisions(itemID: item.id)
        #expect(revs.first?.origin == .confirmedProposal && revs.first?.before == "复习可有可无")
    }

    @Test("MEM-04 修订提议基于的版本过期时确认失败，不覆盖用户修改")
    func reviseConflictOnConfirm() async throws {
        let (svc, repo, _) = try make()
        let item = try await svc.create(kind: .thought, content: "原始")
        let p = try await svc.submit([(.revise(itemID: item.id, baseRevision: 1, newContent: "模型改写", reason: "r"), "")], context: context())[0]
        _ = try await svc.edit(itemID: item.id, expectedRevision: 1, newContent: "用户先改了", reason: "")
        await #expect(throws: BrainError.self) { try await svc.confirm(proposalID: p.id) }
        #expect(try await repo.item(id: item.id)?.content == "用户先改了")
        #expect(try await repo.proposal(id: p.id)?.status == .invalid)
    }

    @Test("MEM-04 两个相似提议依次确认：第二个因重复失效")
    func secondDuplicateInvalidOnConfirm() async throws {
        let (svc, repo, _) = try make()
        let props = try await svc.submit([(.create(kind: .memory, content: "间隔复习有效", evidence: [bookRef]), "a")], context: context())
        let ctx2 = ProposalContext(conversationID: "conv2", messageID: "m2", evidenceByLabel: ["E1": bookRef], scope: nil)
        let props2 = try await svc.submit([(.create(kind: .memory, content: "间隔复习有效！", evidence: [bookRef]), "b")], context: ctx2)
        _ = try await svc.confirm(proposalID: props[0].id)
        await #expect(throws: BrainError.self) { try await svc.confirm(proposalID: props2[0].id) }
        #expect(try await repo.items(kinds: [.memory], includeInactive: false).count == 1)
    }

    @Test("MEM-02 重复确认同一提议是幂等的")
    func confirmTwice() async throws {
        let (svc, repo, _) = try make()
        let p = try await svc.submit([(.create(kind: .memory, content: "唯一", evidence: [bookRef]), "")], context: context())[0]
        _ = try await svc.confirm(proposalID: p.id)
        _ = try await svc.confirm(proposalID: p.id)
        #expect(try await repo.items(kinds: nil, includeInactive: false).count == 1)
    }

    @Test("MEM-02 待确认列表按时间排序")
    func pendingList() async throws {
        let (svc, _, clock) = try make()
        _ = try await svc.submit([(.create(kind: .question, content: "问题一？", evidence: []), "")], context: context())
        clock.advance(by: 5)
        _ = try await svc.submit([(.create(kind: .question, content: "问题二是什么？", evidence: []), "")], context: context())
        #expect(try await svc.pendingProposals().count == 2)
    }
}

@Suite("M09 来源失效与再关联")
struct RecallTests {
    @Test("MEM-05 书籍删除后原文证据标记失效，恢复后重新生效")
    func invalidateAndRestore() async throws {
        let (svc, repo, _) = try make()
        let item = try await svc.create(kind: .memory, content: "间隔复习", evidence: [bookRef, reflRef])
        let affected = try await svc.invalidateBookSources(bookID: "b1", reason: "已删除")
        #expect(affected.map(\.id) == [item.id])
        let after = try #require(try await repo.item(id: item.id))
        #expect(after.evidence[0].isValid == false && after.evidence[0].invalidReason == "已删除")
        #expect(after.evidence[1].isValid)
        _ = try await svc.restoreBookSources(bookID: "b1", version: "v1")
        #expect(try await repo.item(id: item.id)?.evidence.allSatisfy(\.isValid) == true)
    }

    @Test("MEM-05 反思被删除后对应证据失效")
    func invalidateReflection() async throws {
        let (svc, repo, _) = try make()
        let item = try await svc.create(kind: .thought, content: "个人观点", evidence: [reflRef])
        _ = try await svc.invalidateReflection(id: "refl_1", reason: "反思已删除")
        #expect(try await repo.item(id: item.id)?.hasInvalidEvidence == true)
    }

    func items(_ now: Date) -> [BrainItem] {
        [
            BrainItem(id: "in", kind: .memory, content: "复习要按间隔", origin: .user, evidence: [bookRef], createdAt: now, updatedAt: now),
            BrainItem(id: "late", kind: .memory, content: "复习的结局揭示", origin: .user,
                      evidence: [.book("b1", version: "v1", chapter: 5, range: TextSpan(start: 0, end: 9), quote: "结局")], createdAt: now, updatedAt: now),
            BrainItem(id: "foreign", kind: .memory, content: "另一本书的复习", origin: .user,
                      evidence: [.book("b9", version: "v", chapter: 0, range: TextSpan(start: 0, end: 9), quote: "x")], createdAt: now, updatedAt: now),
            BrainItem(id: "dead", kind: .memory, content: "失效来源的复习", origin: .user,
                      evidence: [EvidenceRef(kind: .bookText, bookID: "b1", bookVersion: "v1", chapterIndex: 0, range: TextSpan(start: 0, end: 5), quote: "q", isValid: false)],
                      createdAt: now, updatedAt: now),
            BrainItem(id: "personal", kind: .thought, content: "我对复习的看法", origin: .user, evidence: [], createdAt: now, updatedAt: now),
            BrainItem(id: "gone", kind: .memory, content: "已删除的复习", status: .deleted, origin: .user, evidence: [bookRef], createdAt: now, updatedAt: now),
        ]
    }

    var scope: RetrievalScope {
        var s = BookReadState(bookID: "b1", bookVersion: "v1")
        s.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 100))
        return RetrievalScope([.readOnly(s)])
    }

    @Test("MEM-05 越界来源的记忆整条排除，避免摘要泄露未读内容")
    func excludesOutOfScope() {
        let out = MemoryRecall().recall(query: "复习", items: items(Date()), scope: scope)
        let ids = Set(out.recalled.map(\.item.id))
        #expect(!ids.contains("late") && !ids.contains("foreign"))
        #expect(out.excludedOutOfScope == 2)
    }

    @Test("MEM-05 来源失效或已删除的记忆不伪装成有效证据")
    func excludesInvalidAndDeleted() {
        let out = MemoryRecall().recall(query: "复习", items: items(Date()), scope: scope)
        let ids = Set(out.recalled.map(\.item.id))
        #expect(!ids.contains("dead") && !ids.contains("gone"))
        #expect(out.excludedInvalidSource == 1)
    }

    @Test("MEM-05 仅有个人来源的观点被标记为个人记忆而非书籍证据")
    func personalOnlyFlag() {
        let out = MemoryRecall().recall(query: "复习", items: items(Date()), scope: scope)
        #expect(out.recalled.first { $0.item.id == "personal" }?.personalOnly == true)
        #expect(out.recalled.first { $0.item.id == "in" }?.personalOnly == false)
    }

    @Test("MEM-05 召回按相关度排序并受 limit 限制")
    func limitAndOrder() {
        let out = MemoryRecall().recall(query: "复习 间隔", items: items(Date()), scope: scope, limit: 1)
        #expect(out.recalled.map(\.item.id) == ["in"])
    }

    @Test("MEM-02 解析模型提议：标签映射为证据，未知动作被丢弃")
    func parseProposals() throws {
        let text = """
        ```json
        {"proposals":[
          {"action":"create","kind":"memory","content":"复习按间隔","evidence":["E1","E9"],"rationale":"讨论结论"},
          {"action":"link","from_id":"a","to_id":"b","relation":"conflicts"},
          {"action":"revise","item_id":"t1","content":"新内容","reason":"新证据"},
          {"action":"delete_everything"}
        ]}
        ```
        """
        let existing = [BrainItem(id: "t1", kind: .thought, content: "旧", origin: .user, evidence: [], revision: 3, createdAt: Date(), updatedAt: Date())]
        let r = try ProposalParser.parse(text, context: context(), existing: existing)
        #expect(r.actions.count == 3)
        if case .create(_, _, let ev) = r.actions[0].0 { #expect(ev == [bookRef]) } else { Issue.record("应为 create") }
        if case .revise(_, let base, _, _) = r.actions[2].0 { #expect(base == 3) } else { Issue.record("应为 revise") }
        #expect(r.rejected.contains("unknown_action:delete_everything"))
        #expect(r.rejected.contains("create:unknown_evidence_label"))
    }

    @Test("MEM-02 畸形提议输出抛出解析错误")
    func malformedProposals() {
        #expect(throws: BrainParseError.noJSON) { try ProposalParser.parse("没有 JSON", context: context(), existing: []) }
        #expect(throws: BrainParseError.self) { try ProposalParser.parse(#"{"items":[]}"#, context: context(), existing: []) }
    }

    @Test("MEM-04 文本相似度用于重复检测")
    func similarity() {
        #expect(TextSimilarity.jaccard("复习应当按照间隔进行", "复习应当按照间隔进行。") > 0.9)
        #expect(TextSimilarity.jaccard("复习", "灯塔") == 0)
    }
}
