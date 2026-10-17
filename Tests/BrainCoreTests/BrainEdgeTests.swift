import Testing
import Foundation
@testable import BrainCore
import LibraryCore
import RetrievalCore
import Persistence
import TestSupport

@Suite("M09 边界情况")
struct BrainEdgeTests {
    func make() throws -> (BrainService, SQLiteBrainRepository) {
        let repo = SQLiteBrainRepository(try AppDatabase.inMemory())
        return (BrainService(repository: repo, clock: ManualClock(), ids: SequentialIDGenerator()), repo)
    }

    @Test("MEM-03 证据来源比较：同书同章重叠区间或同一记录视为同源")
    func sameSource() {
        let a = EvidenceRef.book("b", version: "v", chapter: 1, range: TextSpan(start: 0, end: 10), quote: "")
        #expect(a.sameSource(as: .book("b", version: "v", chapter: 1, range: TextSpan(start: 5, end: 15), quote: "x")))
        #expect(!a.sameSource(as: .book("b", version: "v", chapter: 2, range: TextSpan(start: 0, end: 10), quote: "")))
        #expect(!a.sameSource(as: .book("b", version: "v2", chapter: 1, range: TextSpan(start: 0, end: 10), quote: "")))
        #expect(EvidenceRef.reflection("r", bookID: nil, quote: "").sameSource(as: .reflection("r", bookID: "b", quote: "x")))
        #expect(!a.sameSource(as: .reflection("r", bookID: "b", quote: "")))
    }

    @Test("MEM-01 归档条目不出现在搜索与召回中")
    func archivedHidden() async throws {
        let (svc, _) = try make()
        let item = try await svc.create(kind: .memory, content: "归档的复习记忆", evidence: [])
        try await svc.setStatus(itemID: item.id, status: .archived)
        #expect(try await svc.search("复习").isEmpty)
    }

    @Test("MEM-05 来源失效的条目仍可查看，但标记为来源失效")
    func invalidatedStillVisible() async throws {
        let (svc, _) = try make()
        _ = try await svc.create(kind: .memory, content: "失效来源的复习", evidence: [.book("b", version: "v", chapter: 0, range: TextSpan(start: 0, end: 3), quote: "q")])
        _ = try await svc.invalidateBookSources(bookID: "b", reason: "删除")
        let found = try await svc.search("复习")
        #expect(found.count == 1 && found[0].hasInvalidEvidence && !found[0].hasValidBookEvidence)
    }

    @Test("MEM-03 删除关系后不再出现")
    func deleteRelation() async throws {
        let (svc, repo) = try make()
        let a = try await svc.create(kind: .thought, content: "甲")
        let b = try await svc.create(kind: .thought, content: "乙")
        let r = try await svc.link(from: a.id, to: b.id, type: .complements)
        try await repo.deleteRelation(id: r.id)
        #expect(try await svc.relations(itemID: a.id).isEmpty)
    }

    @Test("MEM-02 提议摘要可读，动作指纹对空白与标点不敏感")
    func actionSummaryAndFingerprint() {
        let a = ProposalAction.create(kind: .memory, content: "复习按间隔", evidence: [])
        let b = ProposalAction.create(kind: .memory, content: " 复习按间隔。", evidence: [])
        #expect(a.summary.contains("新增记忆"))
        #expect(a.fingerprint == b.fingerprint)
        #expect(ProposalAction.link(fromID: "x", toID: "y", type: .supports).fingerprint != ProposalAction.link(fromID: "y", toID: "x", type: .supports).fingerprint)
    }

    @Test("MEM-02 按状态列出提议")
    func proposalsByStatus() async throws {
        let (svc, repo) = try make()
        let ctx = ProposalContext(conversationID: "c", messageID: "m", evidenceByLabel: [:], scope: nil)
        let props = try await svc.submit([(.create(kind: .question, content: "问题甲是什么？", evidence: []), ""),
                                          (.create(kind: .memory, content: "无证据", evidence: []), "")], context: ctx)
        _ = try await svc.reject(proposalID: props[0].id)
        #expect(try await repo.proposals(status: .rejected).count == 1)
        #expect(try await repo.proposals(status: .invalid).count == 1)
        #expect(try await repo.proposals(status: nil).count == 2)
    }

    @Test("MEM-04 修订提议缺少原因或内容未变化时无效")
    func reviseValidation() async throws {
        let (svc, _) = try make()
        let item = try await svc.create(kind: .thought, content: "原文")
        let ctx = ProposalContext(conversationID: "c", messageID: "m", evidenceByLabel: [:], scope: nil)
        let props = try await svc.submit([(.revise(itemID: item.id, baseRevision: 1, newContent: "原文", reason: ""), "")], context: ctx)
        #expect(props[0].issues.contains("no_change") && props[0].issues.contains("missing_reason"))
    }
}
