import Testing
import Foundation
@testable import ContextRouting
import LibraryCore
import ReadingSessionCore
import RetrievalCore

@Suite("M07 边界情况")
struct RoutingEdgeTests {
    func state(_ id: BookID) -> BookReadState {
        var s = BookReadState(bookID: id, bookVersion: "v-\(id)")
        s.markRead(chapterIndex: 0, range: TextSpan(start: 0, end: 50))
        return s
    }

    @Test("CTX-02 已授权但没有阅读状态（如已删除）的书被拒绝")
    func permittedButNoState() {
        let req = RoutingRequest(question: "q", primaryBookID: "b1", selectionText: nil, userScope: .readOnly,
                                 permittedBookIDs: ["b1", "b2"], readStates: ["b1": state("b1")], hasHistory: false)
        let plan = SemanticPlan(intent: .crossBook, queries: ["q"], targetBookIDs: ["b1", "b2"], sources: [.bookText], scope: .readOnly)
        let p = PolicyCompiler().compile(plan: plan, request: req)
        #expect(p.scopes.map(\.bookID) == ["b1"])
        #expect(p.notes.contains { $0.code == "book_rejected" && $0.detail.contains("b2") })
    }

    @Test("5.2 用户切换全书范围后，策略允许访问未读章节")
    func wholeBookAllowsUnread() {
        let req = RoutingRequest(question: "结局", primaryBookID: "b1", selectionText: nil, userScope: .wholeBook,
                                 permittedBookIDs: ["b1"], readStates: ["b1": state("b1")], hasHistory: false)
        let s = PolicyCompiler().compile(plan: nil, request: req).retrievalScope
        #expect(s.allows(bookID: "b1", version: "v-b1", chapterIndex: 7, range: TextSpan(start: 0, end: 999)))
        #expect(!s.allows(bookID: "b1", version: "other", chapterIndex: 0, range: TextSpan(start: 0, end: 1)))
    }

    @Test("CTX-01 needs_retrieval=false 被解析并保留")
    func needsRetrievalFalse() throws {
        let p = try SemanticPlanParser.parse(#"{"intent":"explainSelection","needs_retrieval":false,"sources":["selection"]}"#)
        #expect(p.needsRetrieval == false && p.sources == [.selection])
    }

    @Test("CTX-04 英文章节关键词识别为章节理解")
    func englishChapterKeyword() {
        let req = RoutingRequest(question: "Summarize this chapter", primaryBookID: "b1", selectionText: nil, userScope: .readOnly,
                                 permittedBookIDs: ["b1"], readStates: ["b1": state("b1")], hasHistory: false)
        #expect(RuleBasedPlanner.plan(for: req).intent == .chapterUnderstanding)
    }
}
