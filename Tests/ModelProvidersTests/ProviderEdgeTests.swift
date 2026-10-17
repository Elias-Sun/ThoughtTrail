import Testing
import Foundation
@testable import ModelProviders
import AgentRuntime
import TestSupport

@Suite("M12 错误映射与传输")
struct ProviderEdgeTests {
    @Test("10.3 413/422 与超长提示映射为 contextTooLong；普通 400 保留脱敏信息")
    func badRequestVariants() {
        #expect(ProviderErrorMapper.map(status: 413, body: Data(#"{"error":{"message":"Request too long"}}"#.utf8)) == .contextTooLong)
        #expect(ProviderErrorMapper.map(status: 400, body: Data(#"{"code":"InvalidParameter","message":"Range of input length should be [1, 8192]"}"#.utf8)) == .contextTooLong)
        if case .badRequest(let m) = ProviderErrorMapper.map(status: 422, body: Data(#"{"error":{"message":"bad field with key sk-abcdefghijklmnop"}}"#.utf8)) {
            #expect(!m.contains("sk-abcdefghijklmnop"))
        } else { Issue.record("应为 badRequest") }
    }

    @Test("10.3 非 JSON 错误体与未知状态码")
    func nonJSONBodies() {
        #expect(ProviderErrorMapper.map(status: 502, body: Data("<html>Bad Gateway</html>".utf8)) == .server(status: 502))
        #expect(ProviderErrorMapper.map(status: 302, body: Data()) == .invalidResponse("HTTP 302"))
        #expect(ProviderErrorMapper.map(status: 400, body: Data(#"{"error":{"type":"rate_limit_exceeded","message":"x"}}"#.utf8)) == .rateLimited(retryAfter: nil))
    }

    @Test("10.3 系统网络错误映射：断网、超时、取消")
    func urlErrors() {
        #expect(URLSessionTransport.map(URLError(.notConnectedToInternet)) as? ProviderError == .offline)
        #expect(URLSessionTransport.map(URLError(.networkConnectionLost)) as? ProviderError == .offline)
        #expect(URLSessionTransport.map(URLError(.timedOut)) as? ProviderError == .timeout)
        #expect(URLSessionTransport.map(URLError(.cancelled)) as? ProviderError == .cancelled)
        #expect(URLSessionTransport.map(CancellationError()) as? ProviderError == .cancelled)
    }

    @Test("M12 内容过滤结束原因与缺失用量")
    func contentFilter() throws {
        let r = try OpenAICompatibleChatProvider.parseCompletion(Data(#"{"choices":[{"message":{"content":"部分"},"finish_reason":"content_filter"}]}"#.utf8), model: "m")
        #expect(r.finishReason == .contentFilter && r.usage == nil && r.model == "m")
        #expect(throws: ProviderError.self) { try OpenAICompatibleChatProvider.parseCompletion(Data(#"{"choices":[]}"#.utf8), model: "m") }
    }

    @Test("M12 预置地址区分北京与新加坡地域，默认模型为 text-embedding-v4 / qwen3-rerank")
    func presets() {
        #expect(ProviderPresets.dashscopeBeijingCompatible.host == "dashscope.aliyuncs.com")
        #expect(ProviderPresets.dashscopeSingaporeCompatible.host == "dashscope-intl.aliyuncs.com")
        #expect(ProviderPresets.defaultEmbeddingModel == "text-embedding-v4" && ProviderPresets.defaultRerankModel == "qwen3-rerank")
        #expect(ProviderPresets.defaultEmbeddingDimensions == 1024)
    }

    @Test("DATA-03 请求超时取自端点配置，鉴权头不出现在请求描述日志")
    func requestTimeoutAndLogging() async throws {
        let ep = ProviderEndpoint(baseURL: URL(string: "https://x.invalid/v1")!, model: "m", timeout: 12) { "sk-secretvalue12345678" }
        let req = try await ep.request(path: "chat/completions", body: ["a": 1])
        #expect(req.timeoutInterval == 12)
        #expect(!Redactor.redact("\(req.allHTTPHeaderFields ?? [:])").contains("sk-secretvalue12345678"))
    }
}
