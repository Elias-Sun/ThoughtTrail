import Testing
import Foundation
@testable import ModelProviders
import AgentRuntime
import RetrievalCore
import TestSupport

private func chat(_ t: StubTransport, model: String = "qwen-plus") -> OpenAICompatibleChatProvider {
    OpenAICompatibleChatProvider(endpoint: .stub(model: model), transport: t)
}

private let okCompletion = #"{"model":"qwen-plus","choices":[{"message":{"role":"assistant","content":"回答[E1]"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}"#

@Suite("M12 对话适配器")
struct ChatProviderTests {
    @Test("M12 非流式响应解析内容、结束原因与服务端用量")
    func parseCompletion() async throws {
        let t = StubTransport([.response(200, okCompletion, [:])])
        let r = try await chat(t).complete(ChatRequest(messages: [.user("q")]))
        #expect(r.text == "回答[E1]" && r.finishReason == .stop)
        #expect(r.usage == TokenUsage(promptTokens: 12, completionTokens: 5, source: .reported))
    }

    @Test("M12 请求体包含模型、消息、输出上限；JSON 模式设置 response_format；携带 Bearer 鉴权")
    func requestShape() async throws {
        let t = StubTransport([.response(200, okCompletion, [:])])
        _ = try await chat(t).complete(ChatRequest(messages: [.system("s"), .user("q")], maxOutputTokens: 321, jsonMode: true))
        let body = try #require(t.lastBody)
        #expect(body["model"] as? String == "qwen-plus")
        #expect(body["max_tokens"] as? Int == 321)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        #expect((body["messages"] as? [[String: String]])?.map { $0["role"]! } == ["system", "user"])
        #expect(t.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-0123456789")
        #expect(t.requests.last?.url?.path == "/v1/chat/completions")
    }

    @Test("10.3 长度截断的结束原因被保留")
    func lengthFinish() async throws {
        let body = #"{"choices":[{"message":{"content":"半截"},"finish_reason":"length"}]}"#
        let r = try await chat(StubTransport([.response(200, body, [:])])).complete(ChatRequest(messages: [.user("q")]))
        #expect(r.finishReason == .length)
        #expect(r.usage == nil)
    }

    @Test("10.3 401/403/429/5xx 映射为统一错误；429 读取 Retry-After")
    func httpErrors() async throws {
        let cases: [(Int, String, [String: String], ProviderError)] = [
            (401, #"{"error":{"message":"Incorrect API key"}}"#, [:], .unauthorized),
            (403, #"{"code":"Forbidden","message":"no access"}"#, [:], .forbidden),
            (429, #"{"error":{"message":"slow down"}}"#, ["retry-after": "3"], .rateLimited(retryAfter: 3)),
            (503, "", [:], .server(status: 503)),
        ]
        for (status, body, headers, expected) in cases {
            await #expect(throws: expected) {
                try await chat(StubTransport([.response(status, body, headers)])).complete(ChatRequest(messages: [.user("q")]))
            }
        }
    }

    @Test("10.3 模型超长错误被识别为 contextTooLong")
    func contextTooLong() async throws {
        let body = #"{"error":{"message":"This model's maximum context length is 32768 tokens","code":"context_length_exceeded"}}"#
        await #expect(throws: ProviderError.contextTooLong) {
            try await chat(StubTransport([.response(400, body, [:])])).complete(ChatRequest(messages: [.user("q")]))
        }
    }

    @Test("10.3 DashScope 原生错误码 InvalidApiKey 映射为 unauthorized")
    func dashscopeErrorCode() {
        #expect(ProviderErrorMapper.map(status: 400, body: Data(#"{"code":"InvalidApiKey","message":"Invalid API-key provided."}"#.utf8)) == .unauthorized)
        #expect(ProviderErrorMapper.map(status: 400, body: Data(#"{"code":"Throttling.RateQuota","message":"x"}"#.utf8)) == .rateLimited(retryAfter: nil))
        if case .badRequest(let m) = ProviderErrorMapper.map(status: 404, body: Data("{}".utf8)) { #expect(m.contains("404")) } else { Issue.record("应为 badRequest") }
    }

    @Test("10.3 空响应与无效 JSON")
    func emptyAndInvalid() async throws {
        await #expect(throws: ProviderError.emptyResponse) {
            try await chat(StubTransport([.response(200, #"{"choices":[{"message":{"content":"  "},"finish_reason":"stop"}]}"#, [:])])).complete(ChatRequest(messages: [.user("q")]))
        }
        await #expect(throws: ProviderError.invalidResponse("响应不是 JSON")) {
            try await chat(StubTransport([.response(200, "<html>", [:])])).complete(ChatRequest(messages: [.user("q")]))
        }
        await #expect(throws: ProviderError.emptyResponse) {
            try await chat(StubTransport([.response(200, "", [:])])).complete(ChatRequest(messages: [.user("q")]))
        }
    }

    @Test("DATA-03 未配置密钥时不发请求，返回 notConfigured")
    func missingKey() async throws {
        let t = StubTransport()
        let p = OpenAICompatibleChatProvider(endpoint: ProviderEndpoint(baseURL: URL(string: "https://x.invalid")!, model: "m") { "" }, transport: t)
        await #expect(throws: ProviderError.notConfigured("API 密钥")) { try await p.complete(ChatRequest(messages: [.user("q")])) }
        #expect(t.requests.isEmpty)
    }

    @Test("CHAT-02 流式帧逐段输出，结束帧携带用量")
    func streaming() async throws {
        let t = StubTransport([.lines(200, [
            ": keep-alive",
            #"data: {"choices":[{"delta":{"content":"第一"},"finish_reason":null}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"段"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#,
            "data: [DONE]",
        ])])
        var events: [ChatStreamEvent] = []
        for try await e in chat(t).stream(ChatRequest(messages: [.user("q")])) { events.append(e) }
        #expect(events == [.delta("第一"), .delta("段"), .finished(.stop, TokenUsage(promptTokens: 3, completionTokens: 2, source: .reported))])
        #expect((t.lastBody?["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test("10.3 流式截断：没有结束原因即报错，不当作完整结果")
    func streamTruncated() async throws {
        let t = StubTransport([.lines(200, [#"data: {"choices":[{"delta":{"content":"半"}}]}"#])])
        await #expect(throws: ProviderError.streamTruncated) {
            for try await _ in chat(t).stream(ChatRequest(messages: [.user("q")])) {}
        }
    }

    @Test("10.3 流中出现错误帧时报错")
    func streamErrorFrame() async throws {
        let t = StubTransport([.lines(200, [#"data: {"choices":[{"delta":{"content":"a"}}]}"#, #"data: {"error":{"message":"internal"}}"#])])
        await #expect(throws: ProviderError.server(status: 500)) {
            for try await _ in chat(t).stream(ChatRequest(messages: [.user("q")])) {}
        }
    }

    @Test("10.3 流式请求返回非 2xx 时读取错误体")
    func streamHTTPError() async throws {
        let t = StubTransport([.response(401, #"{"error":{"message":"bad key"}}"#, [:])])
        await #expect(throws: ProviderError.unauthorized) {
            for try await _ in chat(t).stream(ChatRequest(messages: [.user("q")])) {}
        }
    }

    @Test("10.3 流式无效帧与断网")
    func streamInvalidAndOffline() async throws {
        await #expect(throws: ProviderError.invalidResponse("流式帧不是 JSON")) {
            for try await _ in chat(StubTransport([.lines(200, ["data: {not json"])])).stream(ChatRequest(messages: [.user("q")])) {}
        }
        await #expect(throws: ProviderError.offline) {
            for try await _ in chat(StubTransport([.error(.offline)])).stream(ChatRequest(messages: [.user("q")])) {}
        }
    }

    @Test("M12 SSE 行解析：注释、数据、结束")
    func sse() {
        #expect(SSEParser.parse(line: ": ping") == .ignored)
        #expect(SSEParser.parse(line: "event: x") == .ignored)
        #expect(SSEParser.parse(line: "data: {\"a\":1}") == .data("{\"a\":1}"))
        #expect(SSEParser.parse(line: "data:[DONE]") == .done)
    }
}

@Suite("M12 向量与重排适配器")
struct EmbeddingRerankTests {
    func embeddingJSON(_ vectors: [(Int, [Float])]) -> String {
        let items = vectors.map { "{\"index\":\($0.0),\"embedding\":[\($0.1.map { String($0) }.joined(separator: ","))]}" }
        return "{\"data\":[\(items.joined(separator: ","))],\"model\":\"text-embedding-v4\",\"usage\":{\"prompt_tokens\":4,\"total_tokens\":4}}"
    }

    @Test("M12 向量按 index 重新排序（服务端乱序返回）")
    func reorderByIndex() async throws {
        let t = StubTransport([.response(200, embeddingJSON([(1, [0, 1]), (0, [1, 0])]), [:])])
        let p = DashScopeEmbeddingProvider(endpoint: .stub(model: "text-embedding-v4"), dimensions: 2, transport: t)
        #expect(try await p.embed(["甲", "乙"], purpose: .document) == [[1, 0], [0, 1]])
        let body = try #require(t.lastBody)
        #expect(body["dimensions"] as? Int == 2 && body["model"] as? String == "text-embedding-v4")
        #expect(t.requests.last?.url?.path == "/v1/embeddings")
    }

    @Test("RAG-05 返回维度与配置不符时报错")
    func dimensionMismatch() async throws {
        let t = StubTransport([.response(200, embeddingJSON([(0, [1, 0, 0])]), [:])])
        let p = DashScopeEmbeddingProvider(endpoint: .stub(), dimensions: 2, transport: t)
        await #expect(throws: ProviderError.dimensionMismatch(expected: 2, actual: 3)) { try await p.embed(["甲"], purpose: .query) }
    }

    @Test("M12 向量数量与输入不一致、index 重复时报错")
    func countAndIndexValidation() throws {
        #expect(throws: ProviderError.self) { try DashScopeEmbeddingProvider.parse(Data(embeddingJSON([(0, [1, 0])]).utf8), expectedCount: 2, dimensions: 2) }
        #expect(throws: ProviderError.self) { try DashScopeEmbeddingProvider.parse(Data(embeddingJSON([(0, [1, 0]), (0, [0, 1])]).utf8), expectedCount: 2, dimensions: 2) }
        #expect(throws: ProviderError.self) { try DashScopeEmbeddingProvider.parse(Data(#"{"data":[{"index":0,"embedding":["a",1]}]}"#.utf8), expectedCount: 1, dimensions: 2) }
    }

    @Test("M12 按批次上限拆分请求（text-embedding-v4 默认 10 条/批）")
    func batching() async throws {
        let one = (0..<10).map { ($0, [Float(1), Float(0)]) }
        let t = StubTransport([.response(200, embeddingJSON(one), [:]), .response(200, embeddingJSON([(0, [0, 1]), (1, [0, 1])]), [:])])
        let p = DashScopeEmbeddingProvider(endpoint: .stub(), dimensions: 2, maxBatchSize: 10, transport: t)
        let v = try await p.embed((0..<12).map { "文本\($0)" }, purpose: .document)
        #expect(v.count == 12 && t.requests.count == 2)
        #expect(try await p.embed([], purpose: .document).isEmpty)
        #expect(t.requests.count == 2)
    }

    @Test("M12 空白输入以占位符发送，过长输入被截断")
    func inputSanitizing() async throws {
        let t = StubTransport([.response(200, embeddingJSON([(0, [1, 0]), (1, [1, 0])]), [:])])
        let p = DashScopeEmbeddingProvider(endpoint: .stub(), dimensions: 2, maxInputTokens: 10, transport: t)
        _ = try await p.embed(["   ", String(repeating: "字", count: 50)], purpose: .document)
        let inputs = try #require(t.lastBody?["input"] as? [String])
        #expect(inputs[0] == " ")
        #expect(inputs[1].count == 10)
    }

    @Test("M12 原生重排协议：请求形状与 output.results 解析")
    func nativeRerank() async throws {
        let t = StubTransport([.response(200, #"{"output":{"results":[{"index":1,"relevance_score":0.92},{"index":0,"relevance_score":0.11}]},"usage":{"total_tokens":20}}"#, [:])])
        let p = DashScopeRerankProvider(endpoint: .stub(model: "qwen3-rerank"), transport: t)
        let r = try await p.rerank(query: "什么是重排？", documents: ["天气", "重排序模型"], topN: 5)
        #expect(r == [RerankScore(index: 1, score: 0.92), RerankScore(index: 0, score: 0.11)])
        let body = try #require(t.lastBody)
        #expect((body["input"] as? [String: Any])?["query"] as? String == "什么是重排？")
        #expect((body["parameters"] as? [String: Any])?["top_n"] as? Int == 2)
        #expect(t.requests.last?.url?.path == "/v1/services/rerank/text-rerank/text-rerank")
    }

    @Test("M12 兼容重排协议：/reranks 与顶层 results")
    func compatibleRerank() async throws {
        let t = StubTransport([.response(200, #"{"results":[{"index":0,"relevance_score":0.5}]}"#, [:])])
        let p = DashScopeRerankProvider(endpoint: .stub(), protocolStyle: .compatible, transport: t)
        #expect(try await p.rerank(query: "q", documents: ["a"], topN: 1) == [RerankScore(index: 0, score: 0.5)])
        #expect(t.lastBody?["query"] as? String == "q")
        #expect(t.requests.last?.url?.path == "/v1/reranks")
    }

    @Test("RAG-03 重排索引越界或重复时报 invalidRerankIndex")
    func rerankIndexValidation() {
        #expect(throws: ProviderError.invalidRerankIndex) {
            try DashScopeRerankProvider.parse(Data(#"{"results":[{"index":5,"relevance_score":0.1}]}"#.utf8), documentCount: 2)
        }
        #expect(throws: ProviderError.invalidRerankIndex) {
            try DashScopeRerankProvider.parse(Data(#"{"results":[{"index":0,"relevance_score":0.1},{"index":0,"relevance_score":0.2}]}"#.utf8), documentCount: 2)
        }
        #expect(throws: ProviderError.self) { try DashScopeRerankProvider.parse(Data(#"{"output":{}}"#.utf8), documentCount: 2) }
    }

    @Test("M12 文档数超过上限时截断，空文档列表不发请求")
    func rerankLimits() async throws {
        let t = StubTransport([.response(200, #"{"results":[{"index":0,"relevance_score":0.5},{"index":1,"relevance_score":0.4}]}"#, [:])])
        let p = DashScopeRerankProvider(endpoint: .stub(), protocolStyle: .compatible, maxDocuments: 2, transport: t)
        _ = try await p.rerank(query: "q", documents: ["a", "b", "c"], topN: 10)
        #expect((t.lastBody?["documents"] as? [String])?.count == 2)
        #expect(try await p.rerank(query: "q", documents: [], topN: 3).isEmpty)
        #expect(t.requests.count == 1)
    }

    @Test("DATA-03 连接检测分别报告三类接口，失败信息脱敏")
    func connectionChecks() async throws {
        let ok = StubTransport([.response(200, okCompletion, [:])])
        let chatResult = await ConnectionChecker.checkChat(chat(ok))
        #expect(chatResult.ok && chatResult.kind == .chat)
        let bad = StubTransport([.response(401, #"{"error":{"message":"key sk-leakedsecret123456"}}"#, [:])])
        let failed = await ConnectionChecker.checkEmbedding(DashScopeEmbeddingProvider(endpoint: .stub(), dimensions: 2, transport: bad))
        #expect(!failed.ok && failed.kind == .embedding)
        #expect(!failed.detail.contains("sk-leakedsecret123456"))
        let rr = await ConnectionChecker.checkRerank(DashScopeRerankProvider(endpoint: .stub(), transport: StubTransport([.error(.offline)])))
        #expect(!rr.ok && rr.detail.contains("offline"))
    }
}
