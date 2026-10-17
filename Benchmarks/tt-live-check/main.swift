import Foundation
import AgentRuntime
import RetrievalCore
import ModelProviders

// tt-live-check：对话、Embedding、Rerank 三类真实接口分别联调（显式触发，会产生少量费用）。
// 环境变量：DASHSCOPE_API_KEY（或分别 TT_CHAT_KEY / TT_EMBED_KEY / TT_RERANK_KEY）
//          TT_CHAT_BASE_URL / TT_CHAT_MODEL、TT_EMBED_BASE_URL / TT_EMBED_MODEL / TT_EMBED_DIMS、TT_RERANK_BASE_URL / TT_RERANK_MODEL / TT_RERANK_PROTOCOL
// 输出：Evaluation/live/live-check-<时间>.json（已脱敏：不含密钥，不含完整请求正文）。

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 } }

struct CheckRecord: Codable {
    var kind: String
    var baseURL: String
    var model: String
    var ok: Bool
    var latencyMs: Int
    var checks: [String: String]
    var error: String?
}

func endpoint(_ base: String, _ model: String, _ keyVar: String) -> ProviderEndpoint? {
    guard let key = env(keyVar) ?? env("DASHSCOPE_API_KEY"), let url = URL(string: base) else { return nil }
    return ProviderEndpoint(baseURL: url, model: model, timeout: 30) { key }
}

func describe(_ error: Error) -> String {
    if let p = error as? ProviderError { return "\(p.code)：\(p.userMessage)" }
    return Redactor.redact("\(error)")
}

func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

var records: [CheckRecord] = []

// 1. 对话：非流式 + 流式帧
let chatBase = env("TT_CHAT_BASE_URL") ?? ProviderPresets.dashscopeBeijingCompatible.absoluteString
let chatModel = env("TT_CHAT_MODEL") ?? "qwen-plus"
if let ep = endpoint(chatBase, chatModel, "TT_CHAT_KEY") {
    let chat = OpenAICompatibleChatProvider(endpoint: ep)
    var rec = CheckRecord(kind: "chat", baseURL: chatBase, model: chatModel, ok: false, latencyMs: 0, checks: [:])
    let start = Date()
    do {
        let r = try await chat.complete(ChatRequest(messages: [.user("只输出 JSON：{\"ok\":true}")], maxOutputTokens: 20, temperature: 0, jsonMode: true, stage: "live"))
        rec.checks["complete.finish"] = r.finishReason.rawValue
        rec.checks["complete.usage"] = r.usage.map { "\($0.promptTokens)+\($0.completionTokens)（服务端报告）" } ?? "未返回"
        rec.checks["complete.json_parse"] = JSONExtraction.extractObject(r.text) != nil ? "ok" : "fail"
        var deltas = 0
        var finish = "-"
        var usage = "未返回"
        for try await e in chat.stream(ChatRequest(messages: [.user("用一句话介绍间隔复习。")], maxOutputTokens: 80, stage: "live")) {
            switch e {
            case .delta: deltas += 1
            case .finished(let f, let u): finish = f.rawValue; usage = u.map { "\($0.totalTokens)" } ?? "未返回"
            }
        }
        rec.checks["stream.delta_frames"] = "\(deltas)"
        rec.checks["stream.finish"] = finish
        rec.checks["stream.usage"] = usage
        rec.ok = deltas > 0 && finish != "-"
    } catch { rec.error = describe(error) }
    rec.latencyMs = ms(start)
    records.append(rec)
} else {
    print("跳过对话：未设置密钥")
}

// 2. Embedding：维度、批量、顺序、相似度合理性
let embedBase = env("TT_EMBED_BASE_URL") ?? ProviderPresets.dashscopeBeijingCompatible.absoluteString
let embedModel = env("TT_EMBED_MODEL") ?? ProviderPresets.defaultEmbeddingModel
let dims = Int(env("TT_EMBED_DIMS") ?? "1024") ?? 1024
if let ep = endpoint(embedBase, embedModel, "TT_EMBED_KEY") {
    let emb = DashScopeEmbeddingProvider(endpoint: ep, dimensions: dims)
    var rec = CheckRecord(kind: "embedding", baseURL: embedBase, model: embedModel, ok: false, latencyMs: 0, checks: [:])
    let start = Date()
    do {
        let texts = ["复习应当按照逐渐拉长的间隔进行。", "间隔重复有助于长期记忆。", "港口的灯塔每十二秒闪一次。"] + (0..<9).map { "批量测试文本 \($0)" }
        let v = try await emb.embed(texts, purpose: .document)
        rec.checks["count"] = "\(v.count)/\(texts.count)"
        rec.checks["dimensions"] = "\(v.first?.count ?? 0)"
        func cos(_ a: [Float], _ b: [Float]) -> Double {
            let dot = zip(a, b).reduce(0) { $0 + Double($1.0 * $1.1) }
            let na = sqrt(a.reduce(0) { $0 + Double($1 * $1) }), nb = sqrt(b.reduce(0) { $0 + Double($1 * $1) })
            return dot / (na * nb)
        }
        let related = cos(v[0], v[1]), unrelated = cos(v[0], v[2])
        rec.checks["cos(related)"] = String(format: "%.3f", related)
        rec.checks["cos(unrelated)"] = String(format: "%.3f", unrelated)
        rec.checks["batches"] = "\(Int((Double(texts.count) / 10).rounded(.up)))（每批 ≤10）"
        rec.ok = v.count == texts.count && v.allSatisfy { $0.count == dims } && related > unrelated
    } catch { rec.error = describe(error) }
    rec.latencyMs = ms(start)
    records.append(rec)
} else {
    print("跳过 Embedding：未设置密钥")
}

// 3. Rerank：索引映射与顺序
let rerankBase = env("TT_RERANK_BASE_URL") ?? ProviderPresets.dashscopeBeijingNative.absoluteString
let rerankModel = env("TT_RERANK_MODEL") ?? ProviderPresets.defaultRerankModel
let proto = DashScopeRerankProvider.WireProtocol(rawValue: env("TT_RERANK_PROTOCOL") ?? "native") ?? .native
if let ep = endpoint(rerankBase, rerankModel, "TT_RERANK_KEY") {
    let rr = DashScopeRerankProvider(endpoint: ep, protocolStyle: proto)
    var rec = CheckRecord(kind: "rerank", baseURL: rerankBase, model: rerankModel, ok: false, latencyMs: 0, checks: ["protocol": proto.rawValue])
    let start = Date()
    do {
        let docs = ["今天天气晴朗，适合出门。", "复习应当按照逐渐拉长的间隔进行，例如一天、三天、一周。", "灯塔每十二秒闪一次。"]
        let r = try await rr.rerank(query: "复习的间隔应该怎么安排？", documents: docs, topN: 3)
        let top = r.max { $0.score < $1.score }
        rec.checks["results"] = "\(r.count)"
        rec.checks["top_index"] = "\(top?.index ?? -1)（期望 1）"
        rec.checks["scores"] = r.map { "\($0.index):\(String(format: "%.3f", $0.score))" }.joined(separator: ", ")
        rec.ok = top?.index == 1
    } catch { rec.error = describe(error) }
    rec.latencyMs = ms(start)
    records.append(rec)
} else {
    print("跳过 Rerank：未设置密钥")
}

let outDir = URL(fileURLWithPath: "Evaluation/live")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try enc.encode(records)
let file = outDir.appendingPathComponent("live-check-\(stamp).json")
try data.write(to: file)
for r in records {
    print("[\(r.ok ? "通过" : "失败")] \(r.kind) \(r.model) \(r.latencyMs)ms \(r.checks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))\(r.error.map { " 错误：\($0)" } ?? "")")
}
print(records.isEmpty ? "没有执行任何联调（请设置密钥环境变量）。" : "结果已写入 \(file.path)")
exit(records.isEmpty || records.contains { !$0.ok } ? 1 : 0)
