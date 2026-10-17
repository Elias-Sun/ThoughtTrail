import Foundation
import LibraryCore
import RetrievalCore
import AgentRuntime
import ModelProviders

/// 立即返回的等待（测试重试退避）。
public struct ImmediateSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation() }
}

/// 按阶段编排的对话模型桩：每个阶段一个响应队列，记录收到的请求。
public final class ScriptedChatModel: ChatModel, @unchecked Sendable {
    public enum Step: Sendable {
        case text(String, FinishReason = .stop, TokenUsage? = TokenUsage(promptTokens: 10, completionTokens: 5, source: .reported))
        /// 流式：逐段返回。
        case chunks([String], FinishReason = .stop)
        case fail(ProviderError)
        /// 先输出若干片段再失败（流式截断、断网）。
        case partialThenFail([String], ProviderError)
        /// 等待一段真实时间后返回（用于超时/取消竞争）。
        case delayed(TimeInterval, String)
        /// 一直等待直到被取消。
        case hang
    }

    private let lock = NSLock()
    private var queues: [String: [Step]] = [:]
    private var fallback: Step?
    public private(set) var requests: [ChatRequest] = []
    public let modelID: String

    public init(modelID: String = "stub-chat", fallback: Step? = nil) {
        self.modelID = modelID; self.fallback = fallback
    }

    public func enqueue(_ stage: String, _ steps: Step...) {
        lock.withLock { queues[stage, default: []] += steps }
    }

    public func setFallback(_ step: Step?) { lock.withLock { fallback = step } }

    public var requestCount: Int { lock.withLock { requests.count } }
    public func requests(stage: String) -> [ChatRequest] { lock.withLock { requests.filter { $0.stage == stage } } }

    private func next(for request: ChatRequest) -> Step {
        lock.withLock {
            requests.append(request)
            if var q = queues[request.stage], !q.isEmpty {
                let s = q.removeFirst(); queues[request.stage] = q; return s
            }
            return fallback ?? .fail(.emptyResponse)
        }
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        switch next(for: request) {
        case .text(let t, let f, let u): return ChatResponse(text: t, finishReason: f, usage: u, model: modelID)
        case .chunks(let c, let f): return ChatResponse(text: c.joined(), finishReason: f, usage: nil, model: modelID)
        case .fail(let e): throw e
        case .partialThenFail(_, let e): throw e
        case .delayed(let s, let t):
            try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            return ChatResponse(text: t, finishReason: .stop, usage: nil, model: modelID)
        case .hang:
            while true { try await Task.sleep(nanoseconds: 10_000_000) }
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let step = next(for: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch step {
                    case .text(let t, let f, let u):
                        continuation.yield(.delta(t)); continuation.yield(.finished(f, u))
                    case .chunks(let c, let f):
                        for piece in c { continuation.yield(.delta(piece)); await Task.yield() }
                        continuation.yield(.finished(f, nil))
                    case .fail(let e):
                        throw e
                    case .partialThenFail(let c, let e):
                        for piece in c { continuation.yield(.delta(piece)) }
                        throw e
                    case .delayed(let s, let t):
                        continuation.yield(.delta(String(t.prefix(4))))
                        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                        continuation.yield(.delta(String(t.dropFirst(4))))
                        continuation.yield(.finished(.stop, nil))
                    case .hang:
                        continuation.yield(.delta("思考中"))
                        while true { try await Task.sleep(nanoseconds: 10_000_000) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 确定性“哈希词袋”向量：仅用于离线测试与评测对照，不代表真实语义向量效果。
public struct HashEmbeddingService: EmbeddingService {
    public let profile: EmbeddingProfile
    public let maxBatchSize: Int
    let segmenter = TextSegmenter()
    let failing: Bool
    let calls: CallCounter?

    public init(model: String = "hash-embed", dimensions: Int = 64, maxBatchSize: Int = 10, failing: Bool = false, calls: CallCounter? = nil) {
        profile = EmbeddingProfile(model: model, dimensions: dimensions)
        self.maxBatchSize = maxBatchSize; self.failing = failing; self.calls = calls
    }

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        await calls?.increment()
        if failing { throw ProviderError.offline }
        return texts.map(vector)
    }

    public func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: profile.dimensions)
        for t in segmenter.tokens(text) {
            var h: UInt64 = 1469598103934665603
            for b in t.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(profile.dimensions))] += 1
        }
        if v.allSatisfy({ $0 == 0 }) { v[0] = 1e-3 }
        return v
    }
}

public actor CallCounter {
    public private(set) var count = 0
    public init() {}
    public func increment() { count += 1 }
}

/// 重排桩：按查询词项覆盖打分；可配置失败或返回异常索引。
public struct OverlapReranker: RerankService {
    public enum Mode: Sendable { case normal, failing, reversed, invalidIndices, empty }
    public let modelID = "stub-rerank"
    public let mode: Mode
    let calls: CallCounter?

    public init(mode: Mode = .normal, calls: CallCounter? = nil) { self.mode = mode; self.calls = calls }

    public func rerank(query: String, documents: [String], topN: Int) async throws -> [RerankScore] {
        await calls?.increment()
        let seg = TextSegmenter()
        let q = Set(seg.tokens(query))
        let scored = documents.enumerated().map { i, d in
            RerankScore(index: i, score: Double(Set(seg.tokens(d)).intersection(q).count) / Double(max(1, q.count)))
        }
        switch mode {
        case .normal: return scored.sorted { $0.score > $1.score }.prefix(topN).map { $0 }
        case .failing: throw ProviderError.server(status: 503)
        case .reversed: return scored.enumerated().map { RerankScore(index: $0.element.index, score: Double($0.offset)) }
        case .invalidIndices: return [RerankScore(index: 999, score: 1), RerankScore(index: -1, score: 0.5)] + scored.prefix(1)
        case .empty: return []
        }
    }
}

/// HTTP 传输桩：按路径后缀返回预置响应，记录请求（用于 Provider 协议测试）。
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    public enum Reply: Sendable {
        case response(Int, String, [String: String])
        case lines(Int, [String])
        case error(ProviderError)
    }

    private let lock = NSLock()
    private var replies: [Reply] = []
    public private(set) var requests: [URLRequest] = []

    public init(_ replies: [Reply] = []) { self.replies = replies }

    public func enqueue(_ r: Reply) { lock.withLock { replies.append(r) } }

    func pop(_ request: URLRequest) -> Reply {
        lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .error(.offline) : replies.removeFirst()
        }
    }

    public var lastBody: [String: Any]? {
        lock.withLock { requests.last?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch pop(request) {
        case .response(let s, let body, let h): return HTTPResponse(status: s, headers: h, body: Data(body.utf8))
        case .lines(let s, let lines): return HTTPResponse(status: s, body: Data(lines.joined(separator: "\n").utf8))
        case .error(let e): throw e
        }
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        switch pop(request) {
        case .response(let s, let body, let h):
            return HTTPStreamResponse(status: s, headers: h, lines: AsyncThrowingStream { c in c.yield(body); c.finish() })
        case .lines(let s, let lines):
            return HTTPStreamResponse(status: s, headers: [:], lines: AsyncThrowingStream { c in
                for l in lines { c.yield(l) }
                c.finish()
            })
        case .error(let e): throw e
        }
    }
}

extension ProviderEndpoint {
    public static func stub(model: String = "m", key: String = "sk-test-0123456789") -> ProviderEndpoint {
        ProviderEndpoint(baseURL: URL(string: "https://example.invalid/v1")!, model: model) { key }
    }
}
