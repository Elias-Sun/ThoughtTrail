import Foundation
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import BrainCore
import AgentRuntime
import ModelProviders
import EvidenceVerificationCore
import LearningCore
import BenchCore
import TestSupport

/// 离线评测：固定语料、固定参数、确定性组件。--live 时额外用真实百炼 Embedding/Rerank 与对话模型复核（产生费用，需显式触发）。
enum EvalRunner {
    static let frozenConfig = RetrievalConfig() // 5.4 初始参数：50/50/20/8

    static func run(evaluationDir: URL, outputDir: URL) async throws {
        let live = CommandLine.arguments.contains("--live")
        let (source, _) = try CorpusBuilder.load(evaluationDir)
        let corpus = try CorpusBuilder.buildEPUBs(source, into: nil)
        let dsDir = evaluationDir.appendingPathComponent("datasets")
        let manifests = try JSONDecoder().decode([DatasetManifest].self, from: Data(contentsOf: dsDir.appendingPathComponent("manifest.json")))
        let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let store = BenchRunStore(directory: outputDir)
        var results: [BenchRunResult] = []

        func dataset<T: Decodable>(_ name: String, _ type: T.Type) throws -> ([T], DatasetManifest) {
            let url = dsDir.appendingPathComponent("\(name).jsonl")
            let r = try DatasetLoader.loadJSONL(T.self, url: url)
            guard let m = manifests.first(where: { $0.name == name }) else { throw CorpusError.missing("清单缺少 \(name)") }
            guard DatasetLoader.verifyFrozen(m, actualSHA256: r.sha256) || m.split == .dev else { throw CorpusError.missing("\(name) 已被修改（哈希不符）") }
            if !r.errors.isEmpty { throw CorpusError.quote("\(name) 有 \(r.errors.count) 行解析失败：\(r.errors.prefix(3))") }
            return (r.items, m)
        }

        func context(_ m: DatasetManifest, _ sha: String, _ config: [String: String]) -> BenchContext {
            BenchContext(datasetName: m.name, datasetVersion: m.version, datasetSHA256: sha, annotationStatus: m.annotationStatus,
                         configuration: config, runID: runID, now: Date())
        }

        // 检索索引（与应用相同的切块与检索代码）
        let retrievalStore = InMemoryRetrievalStore()
        let hashEmbedder = HashEmbeddingService(model: "hash-bow-256", dimensions: 256)
        for id in corpus.order {
            let b = corpus.books[id]!
            let set = Chunker().chunk(chapters: b.chapters, bookVersion: b.version)
            try await retrievalStore.replaceChunks(bookID: id, set: set, manifest: IndexManifest(
                bookID: id, bookVersion: b.version, chunkingVersion: ChunkingConfig().version, embeddingProfile: hashEmbedder.profile,
                childCount: set.children.count, embeddedCount: set.children.count, vectorStatus: .complete, updatedAt: Date()))
            try await retrievalStore.saveEmbeddings(set.children.map {
                EmbeddingItem(childID: $0.id, bookID: id, fingerprint: $0.fingerprint, vector: hashEmbedder.vector($0.text))
            }, profile: hashEmbedder.profile)
        }
        let info = corpus.info()

        // 1. 检索消融
        let (rCases, rManifest) = try dataset("retrieval-dev", RetrievalCase.self)
        let rSHA = rManifest.frozenSHA256 ?? ""
        let base = HybridRetriever(chunks: retrievalStore, lexical: retrievalStore, vectors: retrievalStore, embedder: hashEmbedder,
                                   reranker: OverlapReranker(), config: frozenConfig)
        var variants: [(String, HybridRetriever, [String: String])] = [
            ("bm25", base.with(config: RetrievalConfig(useVector: false, useRerank: false)), ["retriever": "bm25", "embedding": "-"]),
            ("vector_hash", base.with(config: RetrievalConfig(useLexical: false, useRerank: false)), ["retriever": "vector", "embedding": "hash-bow-256（词袋代理，非语义模型）"]),
            ("hybrid", base.with(config: RetrievalConfig(useRerank: false)), ["retriever": "bm25+vector RRF", "embedding": "hash-bow-256"]),
            ("hybrid_rerank", base, ["retriever": "bm25+vector RRF + rerank", "embedding": "hash-bow-256", "rerank": "词项覆盖代理（非 qwen3-rerank）"]),
            ("hybrid_rerank_no_expand", base.with(config: RetrievalConfig(expandParents: false)), ["retriever": "同上，无父块扩展", "embedding": "hash-bow-256"]),
        ]
        if live, let liveRetriever = try await LiveProviders.retriever(store: retrievalStore, corpus: corpus) {
            variants.append(("live_hybrid_rerank", liveRetriever, ["retriever": "bm25+vector RRF + rerank", "embedding": "text-embedding-v4（真实）", "rerank": "qwen3-rerank（真实）"]))
        }
        for (name, retriever, cfg) in variants {
            let latencies = LatencyLog()
            var config = cfg
            config["final_limit"] = "\(frozenConfig.finalLimit)"
            config["variant"] = name
            var r = await RetrievalBenchRunner.run(cases: rCases, context: context(rManifest, rSHA, config)) { c in
                let scope = RetrievalScope(ScopeBuilder.scopes(c.scopes, books: info))
                let start = Date()
                let units = await retriever.retrieve(queries: [c.question], scope: scope).units
                await latencies.add(Date().timeIntervalSince(start) * 1000)
                return units.map { RetrievedSpan(bookID: $0.bookID, chapterIndex: $0.chapterIndex, start: $0.range.start, end: $0.range.end) }
            }
            r.suite = "retrieval_\(name)"
            let samples = await latencies.values
            r.metrics["latency_p50_ms"] = MetricValue(numerator: percentile(samples, 0.5), denominator: 1)
            r.metrics["latency_p95_ms"] = MetricValue(numerator: percentile(samples, 0.95), denominator: 1)
            results.append(r)
        }

        // 2. 阅读边界
        let (bCases, bManifest) = try dataset("boundary-dev", BoundaryCase.self)
        let boundary = await BoundaryBenchRunner.run(cases: bCases, context: context(bManifest, bManifest.frozenSHA256 ?? "", ["retriever": "hybrid_rerank + 父块扩展"])) { c in
            let scope = RetrievalScope(ScopeBuilder.scopes(c.scopes, books: info))
            if c.kind == "memory_unread" {
                // 构造证据位于未读第四章的记忆，召回不得返回
                let bookID = c.scopes[0].bookID
                let b = corpus.books[bookID]!
                let ch = b.chapters[3]
                let item = BrainItem(id: "m-\(c.id)", kind: .memory, content: c.query, origin: .confirmedProposal,
                                     evidence: [.book(bookID, version: b.version, chapter: 3, range: TextSpan(start: 0, end: ch.length), quote: c.query)],
                                     createdAt: Date(), updatedAt: Date())
                let recalled = MemoryRecall().recall(query: c.query, items: [item], scope: scope).recalled
                return (1, recalled.map { "记忆 \($0.item.id) 的来源越界" })
            }
            let units = await base.retrieve(queries: [c.query], scope: scope).units
            let violations = units.filter { !scope.allows(bookID: $0.bookID, version: $0.bookVersion, chapterIndex: $0.chapterIndex, range: $0.range) }
                .map { "\($0.bookID)#\($0.chapterIndex) \($0.range)" }
            return (units.count, violations)
        }
        results.append(boundary)

        // 3. 证据复核（启发式基线；--live 时追加模型裁判）
        let (vCases, vManifest) = try dataset("verification-dev", VerificationCase.self)
        var v = await VerificationBenchRunner.run(cases: vCases, judge: HeuristicClaimJudge(),
                                                  context: context(vManifest, vManifest.frozenSHA256 ?? "", ["judge": "heuristic-v1（离线基线）"]))
        v.suite = "verification_heuristic"
        results.append(v)
        if live, let judge = try LiveProviders.judge() {
            var lv = await VerificationBenchRunner.run(cases: vCases, judge: judge,
                                                       context: context(vManifest, vManifest.frozenSHA256 ?? "", ["judge": judge.name]))
            lv.suite = "verification_llm"
            results.append(lv)
        }

        // 4. 记忆提议规则
        let (mCases, mManifest) = try dataset("memory-dev", MemoryCase.self)
        results.append(MemoryBenchRunner.run(cases: mCases, context: context(mManifest, mManifest.frozenSHA256 ?? "", ["validator": "ProposalValidator"]), now: Date()))

        // 5. 自测可作答性与反馈
        let (lCases, lManifest) = try dataset("learning-dev", LearningCase.self)
        results.append(await LearningBenchRunner.run(cases: lCases, books: info, grader: HeuristicAnswerGrader(),
                                                     context: context(lManifest, lManifest.frozenSHA256 ?? "", ["grader": "heuristic-v1（离线基线）"]), now: Date()))

        // 6. 本地规模/时延（开发机，非验收设备）
        results.append(try await ScaleProbe.run(runID: runID))

        for r in results { _ = try store.save(r) }
        var report = BenchReportWriter.markdown(results)
        report = """
        > 运行：\(runID)；模式：\(live ? "离线 + 真实模型" : "离线（确定性组件）")。
        > 数据集为开发集（draft_unreviewed），未经独立人工复核，**不能作为第 9 节验收结论**。
        > hash-bow 向量与词项覆盖重排只是离线代理，不代表 text-embedding-v4 / qwen3-rerank 的效果。

        """ + report
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try report.write(to: outputDir.appendingPathComponent("REPORT-\(runID).md"), atomically: true, encoding: .utf8)
        try report.write(to: outputDir.appendingPathComponent("REPORT-latest.md"), atomically: true, encoding: .utf8)
        print(report)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))]
    }
}

actor LatencyLog {
    var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}

/// 规模探测：5,000 与 20,000 子块的本地召回时延（P50/P95）与索引体积估算。
enum ScaleProbe {
    static func run(runID: String) async throws -> BenchRunResult {
        var metrics: [String: MetricValue] = [:]
        let words = ["读书", "复习", "记忆", "思考", "批注", "灯塔", "风暴", "桥梁", "船长", "港口", "问题", "证据", "观点", "章节", "作者",
                     "茶叶", "节气", "星空", "钟表", "雨水", "storm", "bridge", "salt", "bees", "library"]
        for size in [5_000, 20_000] {
            let store = InMemoryRetrievalStore()
            let emb = HashEmbeddingService(dimensions: 256)
            var parents: [ParentChunk] = [], children: [ChildChunk] = []
            var textBytes = 0
            for i in 0..<size {
                let text = (0..<16).map { words[(i * 7 + $0 * 3 + $0 * $0) % words.count] }.joined(separator: "，") + "。第\(i)段。"
                textBytes += text.utf8.count
                let p = ParentChunk(id: "p\(i)", bookID: "scale", bookVersion: "v", chapterIndex: i / 100, range: TextSpan(start: 0, end: text.utf16Length), text: text, fingerprint: "\(i)")
                parents.append(p)
                children.append(ChildChunk(id: "c\(i)", parentID: p.id, bookID: "scale", bookVersion: "v", chapterIndex: i / 100, range: p.range, text: text, fingerprint: "f\(i)"))
            }
            let buildStart = Date()
            try await store.replaceChunks(bookID: "scale", set: ChunkSet(parents: parents, children: children),
                                          manifest: IndexManifest(bookID: "scale", bookVersion: "v", chunkingVersion: "t", embeddingProfile: emb.profile,
                                                                  childCount: size, embeddedCount: size, vectorStatus: .complete, updatedAt: Date()))
            try await store.saveEmbeddings(children.map { EmbeddingItem(childID: $0.id, bookID: "scale", fingerprint: $0.fingerprint, vector: emb.vector($0.text)) }, profile: emb.profile)
            let buildMs = Date().timeIntervalSince(buildStart) * 1000
            let retriever = HybridRetriever(chunks: store, lexical: store, vectors: store, embedder: emb)
            let scope = RetrievalScope([.wholeBook(bookID: "scale", version: "v")])
            var samples: [Double] = []
            for i in 0..<30 {
                let start = Date()
                _ = await retriever.retrieve(queries: ["\(words[i % words.count])和\(words[(i + 9) % words.count])"], scope: scope)
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
            metrics["chunks_\(size)_p50_ms"] = MetricValue(numerator: EvalRunner.percentile(samples, 0.5), denominator: 1)
            metrics["chunks_\(size)_p95_ms"] = MetricValue(numerator: EvalRunner.percentile(samples, 0.95), denominator: 1)
            metrics["chunks_\(size)_build_ms"] = MetricValue(numerator: buildMs, denominator: 1)
            metrics["chunks_\(size)_vector_mb"] = MetricValue(numerator: Double(size * 256 * 4) / 1_048_576, denominator: 1)
            metrics["chunks_\(size)_text_mb"] = MetricValue(numerator: Double(textBytes) / 1_048_576, denominator: 1)
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return BenchRunResult(runID: runID, suite: "scale_local", datasetName: "synthetic", datasetVersion: "1", datasetSHA256: "-",
                              annotationStatus: .draftUnreviewed,
                              configuration: ["host": "macOS 开发机 \(machine)（非验收 iPhone）", "build": "debug/release 视调用方式", "dims": "256"],
                              createdAt: Date(), sampleCount: 30, metrics: metrics, confusion: nil, failures: [])
    }
}

/// 真实模型（仅 --live）：从环境变量读取密钥与模型，不写入任何结果文件。
enum LiveProviders {
    static func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 } }

    static func endpoint(_ base: String, model: String, keyVar: String) -> ProviderEndpoint? {
        guard let key = env(keyVar) ?? env("DASHSCOPE_API_KEY"), let url = URL(string: base) else { return nil }
        return ProviderEndpoint(baseURL: url, model: model) { key }
    }

    static func retriever(store: InMemoryRetrievalStore, corpus: ParsedCorpus) async throws -> HybridRetriever? {
        let base = env("TT_EMBED_BASE_URL") ?? ProviderPresets.dashscopeBeijingCompatible.absoluteString
        let rerankBase = env("TT_RERANK_BASE_URL") ?? ProviderPresets.dashscopeBeijingNative.absoluteString
        guard let ep = endpoint(base, model: env("TT_EMBED_MODEL") ?? "text-embedding-v4", keyVar: "TT_EMBED_KEY"),
              let rr = endpoint(rerankBase, model: env("TT_RERANK_MODEL") ?? "qwen3-rerank", keyVar: "TT_RERANK_KEY") else {
            print("未设置 DASHSCOPE_API_KEY（或 TT_EMBED_KEY/TT_RERANK_KEY），跳过真实模型检索评测")
            return nil
        }
        let embedding = DashScopeEmbeddingProvider(endpoint: ep, dimensions: Int(env("TT_EMBED_DIMS") ?? "1024") ?? 1024)
        for id in corpus.order {
            let report = await BookIndexer(store: store, embeddings: store).embed(bookID: id, scope: nil, service: embedding)
            if report.failedBatches > 0 { print("向量化 \(id) 失败：\(report.lastError ?? "-")") }
        }
        let rerank = DashScopeRerankProvider(endpoint: rr)
        return HybridRetriever(chunks: store, lexical: store, vectors: store, embedder: embedding, reranker: rerank, config: EvalRunner.frozenConfig)
    }

    static func judge() throws -> ClaimJudge? {
        guard let ep = endpoint(env("TT_CHAT_BASE_URL") ?? ProviderPresets.dashscopeBeijingCompatible.absoluteString,
                                model: env("TT_VERIFIER_MODEL") ?? env("TT_CHAT_MODEL") ?? "qwen-plus", keyVar: "TT_CHAT_KEY") else { return nil }
        let model = OpenAICompatibleChatProvider(endpoint: ep)
        let clock = SystemClock()
        // 评测时每组陈述独立预算
        return PerCallJudge(model: model, clock: clock)
    }

    struct PerCallJudge: ClaimJudge {
        let model: ChatModel
        let clock: WallClock
        var name: String { "llm:\(model.modelID)" }
        func judge(_ inputs: [ClaimJudgeInput]) async throws -> [ClaimJudgement] {
            let exec = BoundedExecutor(budget: TaskBudget(limits: .discussion, clock: clock), clock: clock, traceID: "bench")
            return try await LLMClaimJudge(model: model, executor: exec).judge(inputs)
        }
    }
}
