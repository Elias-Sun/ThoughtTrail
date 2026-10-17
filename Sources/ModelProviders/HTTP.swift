import Foundation
import AgentRuntime

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, Error>

    public init(status: Int, headers: [String: String], lines: AsyncThrowingStream<String, Error>) {
        self.status = status; self.headers = headers; self.lines = lines
    }
}

/// HTTP 传输抽象：生产用 URLSession，测试用可编排的桩（不依赖真实收费服务）。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return HTTPResponse(status: http?.statusCode ?? 0, headers: Self.headers(http), body: data)
        } catch {
            throw Self.map(error)
        }
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.map(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return HTTPStreamResponse(status: http?.statusCode ?? 0, headers: Self.headers(http), lines: stream)
        } catch {
            throw Self.map(error)
        }
    }

    static func headers(_ r: HTTPURLResponse?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in r?.allHeaderFields ?? [:] { out["\(k)".lowercased()] = "\(v)" }
        return out
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return ProviderError.cancelled }
        guard let u = error as? URLError else { return error }
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return ProviderError.offline
        case .timedOut: return ProviderError.timeout
        case .cancelled: return ProviderError.cancelled
        default: return ProviderError.invalidResponse("网络错误 \(u.code.rawValue)")
        }
    }
}

/// HTTP 错误到统一语义的映射（OpenAI 兼容错误体与 DashScope 原生错误体）。
public enum ProviderErrorMapper {
    public static func map(status: Int, body: Data, headers: [String: String] = [:]) -> ProviderError {
        let (code, message) = extract(body)
        let lowerMsg = (message ?? "").lowercased()
        let lowerCode = (code ?? "").lowercased()
        if lowerCode.contains("invalidapikey") || lowerCode == "invalid_api_key" { return .unauthorized }
        if lowerCode.contains("throttling") || lowerCode.contains("rate_limit") {
            return .rateLimited(retryAfter: headers["retry-after"].flatMap(Double.init))
        }
        if lowerCode.contains("accessdenied") || lowerCode.contains("access_denied") { return .forbidden }
        let tooLongMarkers = ["context length", "maximum context", "too long", "range of input length", "context_length_exceeded", "max_tokens"]
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 429: return .rateLimited(retryAfter: headers["retry-after"].flatMap(Double.init))
        case 400, 413, 422:
            if tooLongMarkers.contains(where: { lowerMsg.contains($0) || lowerCode.contains($0) }) { return .contextTooLong }
            return .badRequest(Redactor.redact(message ?? "HTTP \(status)"))
        case 404: return .badRequest("模型或接口不存在（404）：\(Redactor.redact(message ?? ""))")
        case 500...599: return .server(status: status)
        default: return .invalidResponse("HTTP \(status)")
        }
    }

    static func extract(_ body: Data) -> (code: String?, message: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (nil, String(data: body.prefix(300), encoding: .utf8))
        }
        if let err = obj["error"] as? [String: Any] {
            return ((err["code"] as? String) ?? (err["type"] as? String), err["message"] as? String)
        }
        return (obj["code"] as? String, obj["message"] as? String)
    }
}

/// 服务端点配置。密钥通过闭包从 Keychain 读取，不出现在配置对象与日志中。
public struct ProviderEndpoint: Sendable {
    public var baseURL: URL
    public var model: String
    public var timeout: TimeInterval
    public var apiKey: @Sendable () async throws -> String

    public init(baseURL: URL, model: String, timeout: TimeInterval = 60, apiKey: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL; self.model = model; self.timeout = timeout; self.apiKey = apiKey
    }

    func request(path: String, body: [String: Any], stream: Bool = false) async throws -> URLRequest {
        try await request(path: path, jsonBody: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), stream: stream)
    }

    func request(path: String, jsonBody: Data, stream: Bool = false) async throws -> URLRequest {
        let key: String
        do { key = try await apiKey() } catch { throw ProviderError.notConfigured("API 密钥") }
        guard !key.isEmpty else { throw ProviderError.notConfigured("API 密钥") }
        var url = baseURL
        for comp in path.split(separator: "/") { url.appendPathComponent(String(comp)) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.httpBody = jsonBody
        return req
    }
}

/// 预置服务地址（地域与业务空间在设置中选择）。
public enum ProviderPresets {
    public static let dashscopeBeijingCompatible = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
    public static let dashscopeBeijingNative = URL(string: "https://dashscope.aliyuncs.com/api/v1")!
    public static let dashscopeSingaporeCompatible = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")!
    public static let dashscopeSingaporeNative = URL(string: "https://dashscope-intl.aliyuncs.com/api/v1")!
    public static let deepseek = URL(string: "https://api.deepseek.com")!

    public static let defaultEmbeddingModel = "text-embedding-v4"
    public static let defaultEmbeddingDimensions = 1024
    public static let defaultRerankModel = "qwen3-rerank"
}
