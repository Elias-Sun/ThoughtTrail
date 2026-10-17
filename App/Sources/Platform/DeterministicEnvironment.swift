import Foundation
import LibraryCore
import RetrievalCore
import AgentRuntime
import AppInfrastructure
import EvidenceVerificationCore

/// UI 自动化/演示用的确定性环境：独立数据目录、内存密钥、按关键词响应的模型桩。
/// 报告中明确说明：交互测试使用确定性网络响应，真实模型另行联调（8.2）。
enum DeterministicEnvironment {
    static func make(reset: Bool, clockOffsetDays: Int = 0) -> AppEnvironment {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThoughtTrail-UITest", isDirectory: true)
        if reset {
            try? FileManager.default.removeItem(at: base)
            UserDefaults.standard.removeObject(forKey: "reader.preferences")
        }
        let secrets = InMemorySecretStore([.chat: "sk-uitest-not-a-real-key-0001"])
        let chat = DemoChatModel()
        return AppEnvironment(databaseURL: base.appendingPathComponent("thoughttrail.sqlite"),
                              booksDirectory: base.appendingPathComponent("Books", isDirectory: true),
                              secrets: secrets, clock: OffsetClock(days: clockOffsetDays), fallbackJudge: HeuristicClaimJudge(),
                              overrides: ProviderOverrides(chat: chat, embedding: nil, rerank: nil))
    }
}

/// 带偏移的系统时钟：UI 自动化用来模拟“几天之后”打开应用（复习到期）。
struct OffsetClock: WallClock {
    let days: Int
    func now() -> Date { Date().addingTimeInterval(TimeInterval(days) * 86_400) }
}

/// 确定性对话模型：从提示词中的证据块抽取原句作答。
/// 问题包含“慢”时缓慢流式输出（用于取消），包含“断网”时返回离线错误，包含“错误示例”时给出与证据矛盾的数字。
struct DemoChatModel: ChatModel {
    let modelID = "demo-deterministic"

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let text = try await respond(request)
        return ChatResponse(text: text, finishReason: .stop, usage: TokenUsage(promptTokens: TokenEstimator.estimate(request.messages),
                                                                                 completionTokens: TokenEstimator.estimate(text), source: .estimated),
                            model: modelID)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let question = request.messages.last?.content ?? ""
                    if question.contains("断网") { throw ProviderError.offline }
                    let text = try await respond(request)
                    let slow = question.contains("慢")
                    for chunk in text.chunked(into: 6) {
                        try Task.checkCancellation()
                        continuation.yield(.delta(chunk))
                        try await Task.sleep(nanoseconds: slow ? 1_500_000_000 : 60_000_000)
                    }
                    continuation.yield(.finished(.stop, nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? ProviderError.cancelled : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func respond(_ request: ChatRequest) async throws -> String {
        let prompt = request.messages.map(\.content).joined(separator: "\n")
        switch request.stage {
        case "memory_proposal":
            let sentence = firstSentence(after: "[E1] ", in: prompt, sameLine: true) ?? "这次讨论的要点"
            return #"{"proposals":[{"action":"create","kind":"memory","content":"\#(sentence.prefix(40))","evidence":["E1"],"rationale":"来自讨论"}]}"#
        case "quiz_generation":
            let sentence = firstSentence(after: "[E1] ", in: prompt) ?? "本章内容"
            return #"{"questions":[{"type":"comprehension","prompt":"根据已读内容，作者在这一部分想说明什么？","reference_points":["\#(sentence.prefix(30))"],"rubric":"答出要点即可","evidence":["E1"],"knowledge_point":"本章要点"}]}"#
        case "connection_check":
            return "好"
        default:
            guard let sentence = firstSentence(after: "[E1]", in: prompt) else {
                return "在已读范围内没有找到足够依据。"
            }
            if prompt.contains("错误示例") {
                // 演示：在原句后附加证据中不存在的数字结论，复核应识别为未获支持
                let core = sentence.hasSuffix("。") ? String(sentence.dropLast()) : sentence
                return "\(core)，书中说这一结论被实验验证了37次。[E1]"
            }
            return "\(sentence)[E1]"
        }
    }

    /// 取证据标签行之后的第一句原文。
    private func firstSentence(after marker: String, in prompt: String, sameLine: Bool = false) -> String? {
        guard let r = prompt.range(of: marker) else { return nil }
        let afterHeader = sameLine ? prompt[r.upperBound...] : prompt[r.upperBound...].drop { $0 != "\n" }.dropFirst()
        let body = afterHeader.prefix { $0 != "\n" }
        let sentence = body.split(whereSeparator: { "。！？".contains($0) }).first.map(String.init) ?? String(body)
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed + "。"
    }
}

extension String {
    func chunked(into size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count >= size { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
