import Foundation
import LibraryCore

/// 可观测记录（RUN-03）：用 traceID 关联规划、检索、模型、核查和存储。默认不记录敏感正文。
public struct TraceEvent: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable { case success, failure, degraded, cancelled, skipped }

    public var traceID: String
    public var stage: String
    public var name: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var model: String?
    public var usage: TokenUsage?
    public var outcome: Outcome
    public var errorCode: String?
    /// 降级原因（如 embedding 不可用 → 词法检索）。
    public var degradation: String?
    public var attributes: [String: String]

    public init(traceID: String, stage: String, name: String, startedAt: Date, duration: TimeInterval = 0,
                model: String? = nil, usage: TokenUsage? = nil, outcome: Outcome, errorCode: String? = nil,
                degradation: String? = nil, attributes: [String: String] = [:]) {
        self.traceID = traceID; self.stage = stage; self.name = name; self.startedAt = startedAt
        self.duration = duration; self.model = model; self.usage = usage; self.outcome = outcome
        self.errorCode = errorCode; self.degradation = degradation
        self.attributes = Redactor.safeAttributes(attributes)
    }

    /// 用量未知（供应商未返回）。
    public var usageUnknown: Bool { usage == nil && name == "model_call" }
}

public protocol TraceSink: Sendable {
    func persist(_ event: TraceEvent) async
}

public actor TraceRecorder {
    private var events: [TraceEvent] = []
    private let sink: TraceSink?
    private let capacity: Int

    public init(sink: TraceSink? = nil, capacity: Int = 5_000) {
        self.sink = sink; self.capacity = capacity
    }

    public func record(_ event: TraceEvent) async {
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        await sink?.persist(event)
    }

    public func events(traceID: String) -> [TraceEvent] { events.filter { $0.traceID == traceID } }
    public func allEvents() -> [TraceEvent] { events }
}

/// 脱敏：密钥、令牌、授权头不能出现在日志、截图或导出包（DATA-03）。
public enum Redactor {
    static let sensitiveKeyFragments = ["key", "token", "secret", "authorization", "password", "credential"]
    /// 默认不记录正文类字段。
    static let contentKeys: Set<String> = ["content", "text", "prompt", "question", "answer", "body", "evidence", "quote"]

    static var patterns: [NSRegularExpression] { [
        try! NSRegularExpression(pattern: "sk-[A-Za-z0-9_\\-]{8,}"),
        try! NSRegularExpression(pattern: "(?i)bearer\\s+[A-Za-z0-9._\\-]{8,}"),
        try! NSRegularExpression(pattern: "(?i)(api[_-]?key|access[_-]?token|secret)\\s*[=:]\\s*\"?[^\\s\",}]{6,}"),
    ] }

    public static func redact(_ s: String) -> String {
        var out = s
        for p in patterns {
            let ns = out as NSString
            out = p.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length), withTemplate: "[REDACTED]")
        }
        return out
    }

    public static func safeAttributes(_ attrs: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in attrs {
            let lower = k.lowercased()
            if sensitiveKeyFragments.contains(where: { lower.contains($0) }) { out[k] = "[REDACTED]"; continue }
            if contentKeys.contains(lower) { out[k] = "[omitted \(v.count) chars]"; continue }
            out[k] = redact(String(v.prefix(200)))
        }
        return out
    }

    /// 掩码显示密钥（设置页）：只显示末 4 位。
    public static func mask(_ secret: String) -> String {
        guard secret.count > 4 else { return String(repeating: "•", count: secret.count) }
        return String(repeating: "•", count: 8) + secret.suffix(4)
    }
}

/// 一次性完成门：完成与取消竞争时只有第一个生效，迟到结果被丢弃（RUN-02、10.1）。
public actor CompletionGate<Value: Sendable> {
    public enum State: Sendable {
        case pending
        case completed(Value)
        case cancelled
        case failed(String)
    }

    public private(set) var state: State = .pending

    public init() {}

    @discardableResult
    public func complete(_ value: Value) -> Bool {
        guard case .pending = state else { return false }
        state = .completed(value); return true
    }

    @discardableResult
    public func cancel() -> Bool {
        guard case .pending = state else { return false }
        state = .cancelled; return true
    }

    @discardableResult
    public func fail(_ reason: String) -> Bool {
        guard case .pending = state else { return false }
        state = .failed(reason); return true
    }

    public var isSettled: Bool {
        if case .pending = state { return false }
        return true
    }

    public var isCancelled: Bool {
        if case .cancelled = state { return true }
        return false
    }
}

/// 保守 Token 估算：没有精确 tokenizer 时使用（5.5）。CJK 按 1 字 ≈ 1 token，其余按 3 字符 ≈ 1 token 上取整。
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        var cjk = 0, other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        return cjk + Int((Double(other) / 3.0).rounded(.up))
    }

    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1.content) + 4 } + 2
    }

    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF, 0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// 截断到估算预算内（按字符逐步截断）。
    public static func truncate(_ text: String, toTokens budget: Int) -> String {
        guard estimate(text) > budget else { return text }
        var lo = 0, hi = text.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if estimate(String(text.prefix(mid))) <= budget { lo = mid } else { hi = mid - 1 }
        }
        return String(text.prefix(lo))
    }
}
