import Foundation
import LibraryCore

public enum AgentTaskKind: String, Codable, Sendable, CaseIterable {
    case discussion, memoryProposal, quizGeneration, answerFeedback, indexing, verification
}

public enum AgentTaskStatus: String, Codable, Sendable {
    case running, succeeded, failed, cancelled
    /// 进程终止导致中断；重启后可由用户重试。
    case interrupted

    public var isFinal: Bool { self != .running }
}

/// 持久化的任务记录：幂等键 + 状态，用于恢复与去重（统一规则 5）。
public struct AgentTaskRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: AgentTaskKind
    public var idempotencyKey: String
    public var status: AgentTaskStatus
    public var traceID: String
    public var resultRef: String?
    public var errorCode: String?
    public var attempts: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, kind: AgentTaskKind, idempotencyKey: String, status: AgentTaskStatus, traceID: String,
                resultRef: String? = nil, errorCode: String? = nil, attempts: Int = 1, createdAt: Date, updatedAt: Date) {
        self.id = id; self.kind = kind; self.idempotencyKey = idempotencyKey; self.status = status
        self.traceID = traceID; self.resultRef = resultRef; self.errorCode = errorCode; self.attempts = attempts
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public protocol AgentTaskStore: Sendable {
    func save(_ record: AgentTaskRecord) async throws
    func task(idempotencyKey: String) async throws -> AgentTaskRecord?
    func tasks(status: AgentTaskStatus) async throws -> [AgentTaskRecord]
}

public enum TaskBeginResult: Sendable, Equatable {
    case started(AgentTaskRecord)
    /// 同一键已在执行：重复触发被忽略。
    case alreadyRunning(AgentTaskRecord)
    /// 同一键已成功完成：直接返回已有结果引用。
    case alreadySucceeded(AgentTaskRecord)
}

/// 任务登记：重复触发、晚到响应、取消与完成竞争不产生重复业务写入（RUN-02）。
/// 注意：本地幂等不等于远端请求绝不会重复计费。
public actor TaskRegistry {
    private let store: AgentTaskStore
    private let clock: WallClock
    private let ids: IDGenerating

    /// 正在登记中的键。actor 在 await 存储时会处理其他调用（可重入），
    /// 若不合并，同一键的并发调用都会在保存前读到“无记录”而各自开始。
    private var pendingBegins: [String: Task<TaskBeginResult, Error>] = [:]

    public init(store: AgentTaskStore, clock: WallClock, ids: IDGenerating) {
        self.store = store; self.clock = clock; self.ids = ids
    }

    public func begin(kind: AgentTaskKind, idempotencyKey: String) async throws -> TaskBeginResult {
        if let pending = pendingBegins[idempotencyKey] {
            // 同一键正在由另一调用登记：以其结果为准，本调用不再开始
            switch try await pending.value {
            case .started(let r), .alreadyRunning(let r): return .alreadyRunning(r)
            case .alreadySucceeded(let r): return .alreadySucceeded(r)
            }
        }
        let registration = Task { try await self.register(kind: kind, idempotencyKey: idempotencyKey) }
        pendingBegins[idempotencyKey] = registration
        defer { pendingBegins[idempotencyKey] = nil }
        return try await registration.value
    }

    private func register(kind: AgentTaskKind, idempotencyKey: String) async throws -> TaskBeginResult {
        let now = clock.now()
        if var existing = try await store.task(idempotencyKey: idempotencyKey) {
            switch existing.status {
            case .running: return .alreadyRunning(existing)
            case .succeeded: return .alreadySucceeded(existing)
            case .failed, .cancelled, .interrupted:
                existing.status = .running
                existing.attempts += 1
                existing.errorCode = nil
                existing.traceID = ids.make("trace")
                existing.updatedAt = now
                try await store.save(existing)
                return .started(existing)
            }
        }
        let record = AgentTaskRecord(id: ids.make("task"), kind: kind, idempotencyKey: idempotencyKey, status: .running,
                                     traceID: ids.make("trace"), createdAt: now, updatedAt: now)
        try await store.save(record)
        return .started(record)
    }

    /// 结束任务。只有 running 状态可以结束，迟到的第二次结束被忽略。
    @discardableResult
    public func finish(idempotencyKey: String, status: AgentTaskStatus, resultRef: String? = nil,
                       errorCode: String? = nil) async throws -> Bool {
        guard var record = try await store.task(idempotencyKey: idempotencyKey), record.status == .running else { return false }
        record.status = status
        record.resultRef = resultRef
        record.errorCode = errorCode
        record.updatedAt = clock.now()
        try await store.save(record)
        return true
    }

    /// 启动时把遗留的 running 任务标记为 interrupted。
    public func markInterruptedOnLaunch() async throws -> [AgentTaskRecord] {
        var out: [AgentTaskRecord] = []
        for var r in try await store.tasks(status: .running) {
            r.status = .interrupted
            r.updatedAt = clock.now()
            try await store.save(r)
            out.append(r)
        }
        return out
    }
}

/// 内存任务存储（测试、预览）。
public actor InMemoryAgentTaskStore: AgentTaskStore {
    private var byKey: [String: AgentTaskRecord] = [:]
    public init() {}
    public func save(_ record: AgentTaskRecord) async throws { byKey[record.idempotencyKey] = record }
    public func task(idempotencyKey: String) async throws -> AgentTaskRecord? { byKey[idempotencyKey] }
    public func tasks(status: AgentTaskStatus) async throws -> [AgentTaskRecord] {
        byKey.values.filter { $0.status == status }.sorted { $0.createdAt < $1.createdAt }
    }
}

/// 从模型输出中提取 JSON（容忍 ```json 围栏与前后说明文字）。结构化解析失败不得直接执行（CTX-01）。
public enum JSONExtraction {
    public static func extractObject(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = s.range(of: "```") {
            let afterFence = s[fenceStart.upperBound...]
            let bodyStart = afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex
            if let fenceEnd = s[bodyStart...].range(of: "```") {
                s = String(s[bodyStart..<fenceEnd.lowerBound])
            }
        }
        guard let open = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let openChar = s[open]
        let closeChar: Character = openChar == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var idx = open
        while idx < s.endIndex {
            let ch = s[idx]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == openChar { depth += 1 }
                else if ch == closeChar {
                    depth -= 1
                    if depth == 0 { return Data(s[open...idx].utf8) }
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = extractObject(text) else { throw ProviderError.invalidResponse("没有找到 JSON") }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw ProviderError.invalidResponse("JSON 结构不符：\(error)")
        }
    }
}
