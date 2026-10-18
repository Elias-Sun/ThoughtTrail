import Testing
import Foundation
@testable import ContextEngineering
@testable import RetrievalCore
import LibraryCore
import ContextRouting
import AgentRuntime
import TestSupport

private let all = ContextSource.allCases

@Suite("M08 边界情况")
struct ContextEdgeTests {
    @Test("CTX-03 讨论历史可截断以装入剩余预算")
    func historyTruncated() {
        let book = Make.evidence("", String(repeating: "书", count: 80))
        let hist = Make.evidence("", String(repeating: "史", count: 400), kind: .history)
        let pkg = ContextAssembler(budgetTokens: 200, minTruncatedTokens: 40).assemble([book, hist], allowedSources: all)
        #expect(pkg.truncatedIDs == [hist.id])
        #expect(pkg.estimatedTokens <= 200)
    }
}
