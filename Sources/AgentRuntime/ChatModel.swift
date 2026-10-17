import Foundation
import LibraryCore

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

public struct ChatMessage: Codable, Hashable, Sendable {
    public var role: ChatRole
    public var content: String

    public init(role: ChatRole, content: String) {
        self.role = role; self.content = content
    }

    public static func system(_ s: String) -> ChatMessage { ChatMessage(role: .system, content: s) }
    public static func user(_ s: String) -> ChatMessage { ChatMessage(role: .user, content: s) }
    public static func assistant(_ s: String) -> ChatMessage { ChatMessage(role: .assistant, content: s) }
}

public struct ChatRequest: Sendable, Hashable {
    public var messages: [ChatMessage]
    public var maxOutputTokens: Int
    public var temperature: Double
    /// 要求模型输出 JSON（规划、复核、记忆提议、出题等结构化任务）。
    public var jsonMode: Bool
    /// 调用阶段（planning / generation / verification ...），用于追踪与测试桩匹配。
    public var stage: String

    public init(messages: [ChatMessage], maxOutputTokens: Int = 1_500, temperature: Double = 0.3,
                jsonMode: Bool = false, stage: String = "generation") {
        self.messages = messages; self.maxOutputTokens = maxOutputTokens; self.temperature = temperature
        self.jsonMode = jsonMode; self.stage = stage
    }
}

public enum FinishReason: String, Codable, Sendable {
    case stop
    /// 达到输出上限，结果不完整。
    case length
    case contentFilter
    case other
}

/// Token 用量。区分服务端报告的真实用量与本地估算（5.5）。
public struct TokenUsage: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case reported, estimated }
    public var promptTokens: Int
    public var completionTokens: Int
    public var source: Source

    public init(promptTokens: Int, completionTokens: Int, source: Source) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.source = source
    }

    public var totalTokens: Int { promptTokens + completionTokens }
}

public struct ChatResponse: Sendable, Hashable {
    public var text: String
    public var finishReason: FinishReason
    /// nil 表示供应商未返回用量（记为“未知”）。
    public var usage: TokenUsage?
    public var model: String

    public init(text: String, finishReason: FinishReason, usage: TokenUsage?, model: String) {
        self.text = text; self.finishReason = finishReason; self.usage = usage; self.model = model
    }
}

public enum ChatStreamEvent: Sendable, Hashable {
    case delta(String)
    case finished(FinishReason, TokenUsage?)
}

/// 对话模型接口。具体 HTTP 适配在 ModelProviders。
public protocol ChatModel: Sendable {
    var modelID: String { get }
    func complete(_ request: ChatRequest) async throws -> ChatResponse
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

extension ChatModel {
    /// 消费流式响应，逐段回调，返回完整结果。流结束但没有 finished 帧视为截断。
    public func collectStream(_ request: ChatRequest, onDelta: @Sendable (String) async -> Void) async throws -> ChatResponse {
        var text = ""
        var finish: FinishReason?
        var usage: TokenUsage?
        for try await event in stream(request) {
            try Task.checkCancellation()
            switch event {
            case .delta(let d):
                text += d
                await onDelta(d)
            case .finished(let f, let u):
                finish = f; usage = u
            }
        }
        guard let finish else { throw ProviderError.streamTruncated }
        return ChatResponse(text: text, finishReason: finish, usage: usage, model: modelID)
    }
}

/// 统一的供应商错误语义（10.3 必测故障）。
public enum ProviderError: Error, Equatable, Sendable {
    case offline
    case timeout
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: Double?)
    case server(status: Int)
    case badRequest(String)
    case contextTooLong
    case emptyResponse
    case invalidResponse(String)
    case streamTruncated
    case dimensionMismatch(expected: Int, actual: Int)
    case invalidRerankIndex
    case notConfigured(String)
    case cancelled

    /// 可重试错误：网络抖动、限流、5xx、空响应、流截断。鉴权、请求错误、超长不可重试。
    public var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .rateLimited, .server, .emptyResponse, .streamTruncated: return true
        default: return false
        }
    }

    public var code: String {
        switch self {
        case .offline: return "offline"
        case .timeout: return "timeout"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .rateLimited: return "rate_limited"
        case .server(let s): return "server_\(s)"
        case .badRequest: return "bad_request"
        case .contextTooLong: return "context_too_long"
        case .emptyResponse: return "empty_response"
        case .invalidResponse: return "invalid_response"
        case .streamTruncated: return "stream_truncated"
        case .dimensionMismatch: return "dimension_mismatch"
        case .invalidRerankIndex: return "invalid_rerank_index"
        case .notConfigured: return "not_configured"
        case .cancelled: return "cancelled"
        }
    }

    public var userMessage: String {
        switch self {
        case .offline: return "网络不可用，问题已保留，可稍后重试。"
        case .timeout: return "请求超时，问题已保留，可重试。"
        case .unauthorized: return "密钥无效或已过期（401），请在设置中检查模型配置。"
        case .forbidden: return "没有访问该模型的权限（403），请检查地域、业务空间与模型授权。"
        case .rateLimited: return "请求过于频繁（限流），请稍后重试。"
        case .server(let s): return "模型服务暂时不可用（\(s)），请稍后重试。"
        case .badRequest(let m): return "请求被拒绝：\(Redactor.redact(m))"
        case .contextTooLong: return "上下文超出模型限制，已尝试裁剪仍失败。"
        case .emptyResponse: return "模型返回了空结果。"
        case .invalidResponse: return "模型返回内容无法解析。"
        case .streamTruncated: return "回答在传输中被截断，结果不完整。"
        case .dimensionMismatch(let e, let a): return "向量维度不符（期望 \(e)，实际 \(a)）。"
        case .invalidRerankIndex: return "重排结果索引异常，已保留融合排序。"
        case .notConfigured(let what): return "尚未配置\(what)。"
        case .cancelled: return "已取消。"
        }
    }
}
