import Foundation
import LibraryCore
import RetrievalCore
import AgentRuntime

/// 把检索中的外部请求（查询向量、重排）计入讨论任务的共享预算（10.2：一次讨论 ≤6 次外部请求）。
struct BudgetedEmbeddingService: EmbeddingService {
    let inner: EmbeddingService
    let executor: BoundedExecutor
    var profile: EmbeddingProfile { inner.profile }
    var maxBatchSize: Int { inner.maxBatchSize }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        let inner = self.inner
        return try await executor.run(stage: "query_embedding", model: inner.profile.model, timeout: 10) {
            try await inner.embed(texts, purpose: purpose)
        }
    }
}

struct BudgetedRerankService: RerankService {
    let inner: RerankService
    let executor: BoundedExecutor
    var modelID: String { inner.modelID }

    func rerank(query: String, documents: [String], topN: Int) async throws -> [RerankScore] {
        let inner = self.inner
        return try await executor.run(stage: "rerank", model: inner.modelID, timeout: 10) {
            try await inner.rerank(query: query, documents: documents, topN: topN)
        }
    }
}
