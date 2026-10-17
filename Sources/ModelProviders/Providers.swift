import Foundation
import AgentRuntime
import RetrievalCore

/// SSE 行解析（OpenAI 兼容流式帧）。
public enum SSEParser {
    public enum Frame: Equatable, Sendable {
        case data(String)
        case done
        case ignored
    }

    public static func parse(line: String) -> Frame {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return .ignored }
        guard trimmed.hasPrefix("data:") else { return .ignored }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        return .data(payload)
    }
}

/// OpenAI 兼容对话适配器（百炼 compatible-mode 的千问、DeepSeek 等）。
public struct OpenAICompatibleChatProvider: ChatModel {
    public let endpoint: ProviderEndpoint
    public let transport: HTTPTransport
    public var modelID: String { endpoint.model }

    public init(endpoint: ProviderEndpoint, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint; self.transport = transport
    }

    func body(_ request: ChatRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": request.maxOutputTokens,
            "temperature": request.temperature,
            "stream": stream,
        ]
        if request.jsonMode { body["response_format"] = ["type": "json_object"] }
        if stream { body["stream_options"] = ["include_usage": true] }
        return body
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let req = try await endpoint.request(path: "chat/completions", body: body(request, stream: false))
        let response = try await transport.send(req)
        guard (200..<300).contains(response.status) else {
            throw ProviderErrorMapper.map(status: response.status, body: response.body, headers: response.headers)
        }
        return try Self.parseCompletion(response.body, model: endpoint.model)
    }

    public static func parseCompletion(_ data: Data, model: String) throws -> ChatResponse {
        guard !data.isEmpty else { throw ProviderError.emptyResponse }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("响应不是 JSON")
        }
        if obj["error"] != nil { throw ProviderErrorMapper.map(status: 400, body: data) }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ProviderError.invalidResponse("缺少 choices")
        }
        let content = (message["content"] as? String) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.emptyResponse }
        return ChatResponse(text: content, finishReason: finishReason(first["finish_reason"] as? String),
                            usage: usage(obj["usage"]), model: (obj["model"] as? String) ?? model)
    }

    static func finishReason(_ s: String?) -> FinishReason {
        switch s {
        case "stop": return .stop
        case "length": return .length
        case "content_filter": return .contentFilter
        default: return .other
        }
    }

    static func usage(_ any: Any?) -> TokenUsage? {
        guard let u = any as? [String: Any], let p = u["prompt_tokens"] as? Int else { return nil }
        let c = (u["completion_tokens"] as? Int) ?? max(0, ((u["total_tokens"] as? Int) ?? p) - p)
        return TokenUsage(promptTokens: p, completionTokens: c, source: .reported)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let endpoint = self.endpoint, transport = self.transport
        let bodyData = (try? JSONSerialization.data(withJSONObject: self.body(request, stream: true), options: [.sortedKeys])) ?? Data()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try await endpoint.request(path: "chat/completions", jsonBody: bodyData, stream: true)
                    let response = try await transport.stream(req)
                    guard (200..<300).contains(response.status) else {
                        var text = ""
                        for try await line in response.lines { text += line }
                        throw ProviderErrorMapper.map(status: response.status, body: Data(text.utf8), headers: response.headers)
                    }
                    var finish: FinishReason?
                    var usage: TokenUsage?
                    var sawDone = false
                    var sawContent = false
                    for try await line in response.lines {
                        try Task.checkCancellation()
                        switch SSEParser.parse(line: line) {
                        case .ignored: continue
                        case .done: sawDone = true
                        case .data(let payload):
                            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                                throw ProviderError.invalidResponse("流式帧不是 JSON")
                            }
                            if obj["error"] != nil { throw ProviderErrorMapper.map(status: 500, body: Data(payload.utf8)) }
                            if let u = Self.usage(obj["usage"]) { usage = u }
                            if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
                                if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
                                    sawContent = true
                                    continuation.yield(.delta(content))
                                }
                                if let fr = first["finish_reason"] as? String { finish = Self.finishReason(fr) }
                            }
                        }
                        if sawDone { break }
                    }
                    guard let finish else { throw ProviderError.streamTruncated }
                    guard sawContent else { throw ProviderError.emptyResponse }
                    continuation.yield(.finished(finish, usage))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 百炼文本向量（compatible-mode /embeddings，text-embedding-v4）。校验数量、顺序、维度与数值。
public struct DashScopeEmbeddingProvider: EmbeddingService {
    public let endpoint: ProviderEndpoint
    public let transport: HTTPTransport
    public let dimensions: Int
    public let maxBatchSize: Int
    /// 单条输入的保守 token 上限（v4 为 8192）。
    public let maxInputTokens: Int

    public var profile: EmbeddingProfile { EmbeddingProfile(model: endpoint.model, dimensions: dimensions) }

    public init(endpoint: ProviderEndpoint, dimensions: Int = ProviderPresets.defaultEmbeddingDimensions, maxBatchSize: Int = 10,
                maxInputTokens: Int = 8_000, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint; self.dimensions = dimensions; self.maxBatchSize = maxBatchSize
        self.maxInputTokens = maxInputTokens; self.transport = transport
    }

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var all: [[Float]] = []
        var start = 0
        while start < texts.count {
            let batch = Array(texts[start..<min(texts.count, start + maxBatchSize)])
            all += try await embedBatch(batch)
            start += batch.count
        }
        return all
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        let inputs = texts.map { t -> String in
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return TokenEstimator.truncate(s.isEmpty ? " " : s, toTokens: maxInputTokens)
        }
        let body: [String: Any] = ["model": endpoint.model, "input": inputs, "dimensions": dimensions, "encoding_format": "float"]
        let req = try await endpoint.request(path: "embeddings", body: body)
        let response = try await transport.send(req)
        guard (200..<300).contains(response.status) else {
            throw ProviderErrorMapper.map(status: response.status, body: response.body, headers: response.headers)
        }
        return try Self.parse(response.body, expectedCount: texts.count, dimensions: dimensions)
    }

    public static func parse(_ data: Data, expectedCount: Int, dimensions: Int) throws -> [[Float]] {
        guard !data.isEmpty else { throw ProviderError.emptyResponse }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("响应不是 JSON")
        }
        guard let items = obj["data"] as? [[String: Any]] else { throw ProviderError.invalidResponse("缺少 data") }
        guard items.count == expectedCount else {
            throw ProviderError.invalidResponse("向量数量 \(items.count) ≠ 输入数量 \(expectedCount)")
        }
        var out = [[Float]?](repeating: nil, count: expectedCount)
        for (i, item) in items.enumerated() {
            let idx = (item["index"] as? Int) ?? i
            guard out.indices.contains(idx), out[idx] == nil else { throw ProviderError.invalidResponse("向量 index 异常：\(idx)") }
            guard let raw = item["embedding"] as? [Any] else { throw ProviderError.invalidResponse("缺少 embedding") }
            let vec = raw.compactMap { ($0 as? NSNumber)?.floatValue }
            guard vec.count == raw.count else { throw ProviderError.invalidResponse("向量含非数值") }
            guard vec.count == dimensions else { throw ProviderError.dimensionMismatch(expected: dimensions, actual: vec.count) }
            guard vec.allSatisfy({ $0.isFinite }) else { throw ProviderError.invalidResponse("向量含非有限值") }
            out[idx] = vec
        }
        return out.map { $0! }
    }
}

/// 百炼重排（qwen3-rerank）。支持原生 text-rerank 与 compatible /reranks 两种协议。
public struct DashScopeRerankProvider: RerankService {
    public enum WireProtocol: String, Codable, Sendable {
        case native
        case compatible
    }

    public let endpoint: ProviderEndpoint
    public let transport: HTTPTransport
    public let protocolStyle: WireProtocol
    public let maxDocuments: Int
    public var modelID: String { endpoint.model }

    public init(endpoint: ProviderEndpoint, protocolStyle: WireProtocol = .native, maxDocuments: Int = 500,
                transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint; self.protocolStyle = protocolStyle; self.maxDocuments = maxDocuments; self.transport = transport
    }

    public func rerank(query: String, documents: [String], topN: Int) async throws -> [RerankScore] {
        guard !documents.isEmpty else { return [] }
        let docs = Array(documents.prefix(maxDocuments))
        let n = max(1, min(topN, docs.count))
        let path: String
        let body: [String: Any]
        switch protocolStyle {
        case .native:
            path = "services/rerank/text-rerank/text-rerank"
            body = ["model": endpoint.model, "input": ["query": query, "documents": docs],
                    "parameters": ["top_n": n, "return_documents": false]]
        case .compatible:
            path = "reranks"
            body = ["model": endpoint.model, "query": query, "documents": docs, "top_n": n]
        }
        let req = try await endpoint.request(path: path, body: body)
        let response = try await transport.send(req)
        guard (200..<300).contains(response.status) else {
            throw ProviderErrorMapper.map(status: response.status, body: response.body, headers: response.headers)
        }
        return try Self.parse(response.body, documentCount: docs.count)
    }

    public static func parse(_ data: Data, documentCount: Int) throws -> [RerankScore] {
        guard !data.isEmpty else { throw ProviderError.emptyResponse }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("响应不是 JSON")
        }
        let results = ((obj["output"] as? [String: Any])?["results"] as? [[String: Any]])
            ?? (obj["results"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]])
        guard let results else { throw ProviderError.invalidResponse("缺少 results") }
        var seen: Set<Int> = []
        var out: [RerankScore] = []
        for r in results {
            guard let idx = r["index"] as? Int, let score = (r["relevance_score"] as? NSNumber)?.doubleValue ?? (r["score"] as? NSNumber)?.doubleValue else {
                throw ProviderError.invalidResponse("重排结果缺少 index/score")
            }
            guard (0..<documentCount).contains(idx), score.isFinite, seen.insert(idx).inserted else {
                throw ProviderError.invalidRerankIndex
            }
            out.append(RerankScore(index: idx, score: score))
        }
        return out
    }
}

/// 连接检测（设置页“检测连接”）：三类接口分别检测，结果脱敏。
public struct ConnectionCheckResult: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case chat, embedding, rerank }
    public var kind: Kind
    public var ok: Bool
    public var model: String
    public var latencyMs: Int
    public var detail: String
}

public enum ConnectionChecker {
    public static func checkChat(_ model: ChatModel) async -> ConnectionCheckResult {
        let start = Date()
        do {
            let r = try await model.complete(ChatRequest(messages: [.user("请只回复：好")], maxOutputTokens: 8, temperature: 0, stage: "connection_check"))
            return .init(kind: .chat, ok: true, model: r.model, latencyMs: ms(start), detail: "返回 \(r.text.count) 字；用量\(r.usage == nil ? "未知" : "已报告")")
        } catch {
            return .init(kind: .chat, ok: false, model: model.modelID, latencyMs: ms(start), detail: describe(error))
        }
    }

    public static func checkEmbedding(_ service: EmbeddingService) async -> ConnectionCheckResult {
        let start = Date()
        do {
            let v = try await service.embed(["连接测试", "connection test"], purpose: .query)
            return .init(kind: .embedding, ok: true, model: service.profile.model, latencyMs: ms(start),
                         detail: "返回 \(v.count) 条向量，维度 \(v.first?.count ?? 0)")
        } catch {
            return .init(kind: .embedding, ok: false, model: service.profile.model, latencyMs: ms(start), detail: describe(error))
        }
    }

    public static func checkRerank(_ service: RerankService) async -> ConnectionCheckResult {
        let start = Date()
        do {
            let r = try await service.rerank(query: "什么是重排序？", documents: ["重排序模型按相关性排序候选文本。", "今天天气晴朗。"], topN: 2)
            let top = r.max { $0.score < $1.score }?.index
            return .init(kind: .rerank, ok: true, model: service.modelID, latencyMs: ms(start),
                         detail: "返回 \(r.count) 条结果，最相关下标 \(top.map(String.init) ?? "-")")
        } catch {
            return .init(kind: .rerank, ok: false, model: service.modelID, latencyMs: ms(start), detail: describe(error))
        }
    }

    static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    static func describe(_ error: Error) -> String {
        if let p = error as? ProviderError { return "\(p.code)：\(p.userMessage)" }
        return Redactor.redact("\(error)")
    }
}
