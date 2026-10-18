import Foundation
import LibraryCore
import ReaderCore
import ReflectionCore
import RetrievalCore
import Persistence
#if os(iOS)
import UIKit
#endif

/// 本地时延探针（10.1）：仅在 `-perf-*` 启动参数下运行，结果写入 Documents/perf/，由 `Scripts/perf-sim.sh` 收集。
/// 在模拟器上得到的数字只作开发参考，不代替固定 iPhone 的 Release 验收。
@MainActor
enum PerfProbe {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf", isDirectory: true)
    }

    /// 冷启动：脚本在 `simctl launch` 之前记下宿主时间并通过 `-perf-launch-at` 传入；书库数据加载完成、下一轮主线程循环时记录就绪。
    static func markLaunchReady(arguments: [String], books: Int) async {
        guard let i = arguments.firstIndex(of: "-perf-launch-at"), i + 1 < arguments.count,
              let launchedAt = Double(arguments[i + 1]) else { return }
        await nextRunLoop()
        let ready = Date().timeIntervalSince1970
        let line = String(format: "{\"launch_to_ready_ms\":%.1f,\"process_to_ready_ms\":%.1f,\"books\":%d}\n",
                          (ready - launchedAt) * 1000, (ready - processStart()) * 1000, books)
        append(line, to: "coldstart.jsonl")
    }

    /// 任一 `-perf-*` 参数：测量期间禁止自动锁屏（否则真机锁屏后应用被挂起）；`-perf-reset` 清空上次的采样文件。
    static func prepare(arguments: [String]) {
        guard arguments.contains(where: { $0.hasPrefix("-perf") }) else { return }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        if arguments.contains("-perf-reset") { try? FileManager.default.removeItem(at: directory) }
    }

    /// 阅读器正文首次完成窗口内排版时（ReaderModel 收到可见区间）回调；只在采样时设置。
    static var onReaderVisibleText: (() -> Void)?
    static func readerReportedVisibleText() { onReaderVisibleText?(); onReaderVisibleText = nil }

    /// 界面级“重新打开书籍”：从发出打开请求到阅读器正文在窗口内完成首次排版（含导航、ReaderView 创建、
    /// 读库、定位与 TextKit 排版），之后关闭阅读器回到书库，重复 `samples` 次。
    static func measureUIReopen(app: AppModel, book: Book, samples: Int) async -> [Double] {
        var result: [Double] = []
        for _ in 0..<samples {
            var shown: Double?
            onReaderVisibleText = { shown = now() }
            let t0 = now()
            app.openRequest = .init(bookID: book.id, locator: nil)
            guard await waitUntil(timeout: 10, interval: 1_000_000, { shown != nil }), let shown else { onReaderVisibleText = nil; continue }
            result.append(shown - t0)
            app.openRequest = nil
            app.closeReaderRequest = UUID()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 等待返回动画与会话结束
        }
        return result
    }

    /// `-perf-import <文件名>`：从 Documents/ 导入一本 EPUB（走正式导入、解析与建索引路径），记录耗时。
    static var importMilliseconds: Double?
    static let longBookTitle = "长篇性能样本"

    static func importIfRequested(app: AppModel, arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "-perf-import"), i + 1 < arguments.count else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(arguments[i + 1])
        let t0 = now()
        await app.importEPUB(at: url)
        importMilliseconds = now() - t0
    }

    static func perfBook(_ app: AppModel) -> Book? {
        app.books.first { $0.title == longBookTitle } ?? app.books.first
    }

    /// 重开书籍、本地保存、取消响应各采样 `samples` 次，写入 suite.json。
    static func runSuite(app: AppModel, samples: Int = 30) async {
        guard let book = perfBook(app) else { write(#"{"error":"no book"}"#, to: "suite.json"); return }
        var reopen: [Double] = [], highlight: [Double] = [], reflection: [Double] = [], cancel: [Double] = []
        var lateChanges = 0

        let uiReopen = await measureUIReopen(app: app, book: book, samples: samples)
        for _ in 0..<samples {
            let t0 = now()
            let reader = ReaderModel(book: book, app: app)
            await reader.load(initial: nil)
            layoutFirstScreen(reader)
            reopen.append(now() - t0)
        }

        let reader = ReaderModel(book: book, app: app)
        await reader.load(initial: nil)
        guard let chapter = reader.currentChapter, chapter.length > 40 else { write(#"{"error":"no chapter"}"#, to: "suite.json"); return }
        for i in 0..<samples {
            let start = (i * 7) % (chapter.length - 20)
            reader.selection = TextSpan(start: start, end: start + 10)
            let t0 = now()
            await reader.addHighlight(note: i.isMultiple(of: 2) ? "性能采样批注" : nil)
            highlight.append(now() - t0)
        }

        let service = app.container.reflections
        for i in 0..<samples {
            guard let draft = try? await service.startDraft(context: await reader.contextSnapshot()) else { continue }
            let t0 = now()
            _ = try? await service.updateDraft(id: draft.id, text: "性能采样反思 \(i)：复习的间隔应当逐渐拉长。")
            _ = try? await service.commit(id: draft.id, commitKey: "perf-\(draft.id)")
            reflection.append(now() - t0)
        }

        for _ in 0..<samples {
            let discussion = DiscussionModel(app: app, book: book)
            await discussion.start(context: await reader.contextSnapshot(), selection: nil)
            discussion.input = "请慢慢讲讲复习的间隔"
            discussion.send()
            guard await waitUntil(timeout: 10, { discussion.liveStatus == .drafting && !discussion.liveDraft.isEmpty }) else { continue }
            let t0 = now()
            await discussion.cancel()
            cancel.append(now() - t0)
            // 迟到响应：取消后继续等待一个流式间隔，界面状态不能再变化
            let draftAtCancel = discussion.liveDraft
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            if discussion.running || discussion.liveStatus != nil || discussion.liveDraft != draftAtCancel
                || discussion.messages.last?.status != .cancelled { lateChanges += 1 }
        }

        let chapters = (try? await app.container.bookRepository.chapters(bookID: book.id)) ?? []
        let result: [String: Any] = [
            "samples": samples, "book": book.title, "chapter_utf16": chapter.length,
            "book_chapters": chapters.count, "book_utf16": chapters.reduce(0) { $0 + $1.length },
            "import_ms": importMilliseconds ?? -1, "device": deviceDescription(),
            "reopen_ms": reopen, "reopen_ui_ms": uiReopen, "highlight_save_ms": highlight, "reflection_save_ms": reflection,
            "cancel_ms": cancel, "cancel_late_state_changes": lateChanges,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            write(String(decoding: data, as: UTF8.self), to: "suite.json")
        }
    }

    /// `-perf-soak <分钟>`：同一进程内循环混合操作（每轮间隔 3 秒）（换章阅读、记为已读、批注增删、反思、讨论完成与取消、备份导出），
    /// 每 10 秒记录一次内存占用（phys_footprint），写入 soak.jsonl；正常结束时写 soak-summary.json。
    /// 进程若崩溃，汇总文件不会生成。
    static func runSoak(app: AppModel, minutes: Double) async {
        guard let book = perfBook(app) else { write(#"{"error":"no book"}"#, to: "soak-summary.json"); return }
        let started = Date()
        let deadline = started.addingTimeInterval(minutes * 60)
        var cycles = 0, discussions = 0, cancels = 0, highlights = 0, reflections = 0, backups = 0
        var failures: [String: Int] = [:]
        var lastSample = Date.distantPast
        func sample() {
            let line = String(format: "{\"t_s\":%.0f,\"footprint_mb\":%.1f,\"cycles\":%d}\n",
                              Date().timeIntervalSince(started), footprintMB(), cycles)
            append(line, to: "soak.jsonl")
            lastSample = Date()
        }
        sample()
        let reader = ReaderModel(book: book, app: app)
        await reader.load(initial: nil)
        while Date() < deadline {
            cycles += 1
            // 阅读：换章、排版、上报可见区间并记为已读
            if cycles > 1 { reader.nextChapter() }
            if reader.currentChapter == nil || reader.chapterIndex == reader.chapters.last?.index {
                reader.goTo(chapter: reader.chapters.first { $0.isLinear && $0.length > 0 }?.index ?? 0, offset: 0)
            }
            layoutFirstScreen(reader)
            if let ch = reader.currentChapter {
                reader.visibleRangeChanged(TextSpan(start: 0, end: min(ch.length, 600)))
                await reader.markPageRead()
                // 批注：添加，偶数轮删除一条，避免无限累积之外也覆盖删除路径
                reader.selection = TextSpan(start: 20, end: 40)
                await reader.addHighlight(note: "浸泡测试批注 \(cycles)")
                highlights += 1
                if cycles.isMultiple(of: 2), let a = reader.annotations.first { await reader.deleteAnnotation(a) }
            }
            // 反思
            if let d = try? await app.container.reflections.startDraft(context: await reader.contextSnapshot(), text: "浸泡测试反思 \(cycles)") {
                if (try? await app.container.reflections.commit(id: d.id, commitKey: "soak-\(d.id)")) != nil { reflections += 1 } else { failures["reflection_commit", default: 0] += 1 }
            }
            // 讨论：完成一次（含检索、生成、核查）；每 3 轮取消一次慢速回答
            let discussion = DiscussionModel(app: app, book: book)
            await discussion.start(context: await reader.contextSnapshot(), selection: nil)
            if cycles.isMultiple(of: 3) {
                discussion.input = "请慢慢讲讲复习的间隔"
                discussion.send()
                if await waitUntil(timeout: 10, { discussion.liveStatus == .drafting && !discussion.liveDraft.isEmpty }) {
                    await discussion.cancel(); cancels += 1
                } else { failures["slow_answer_not_streaming", default: 0] += 1 }
            } else {
                discussion.input = "这一章讲了什么？"
                discussion.send()
                if await waitUntil(timeout: 30, { !discussion.running && discussion.messages.count >= 2 }) { discussions += 1 } else { failures["discussion_not_finished", default: 0] += 1 }
            }
            // 备份导出（含 EPUB），每 10 轮一次
            if cycles.isMultiple(of: 10) {
                if let data = try? await app.container.backup.export(includeEPUB: true, now: Date()) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("soak-backup.json")
                    try? data.write(to: url, options: .atomic)
                    backups += 1
                } else { failures["backup_export", default: 0] += 1 }
            }
            if Date().timeIntervalSince(lastSample) >= 10 { sample() }
            // 每轮间隔 3 秒，接近连续使用的节奏；不间断循环会让数据量的增长掩盖内存是否泄漏
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        sample()
        await reader.close()
        let summary: [String: Any] = [
            "minutes": minutes, "elapsed_s": Date().timeIntervalSince(started), "cycles": cycles, "discussions_completed": discussions,
            "cancels": cancels, "highlights": highlights, "reflections": reflections, "backups": backups, "failures": failures.values.reduce(0, +), "failure_kinds": failures,
            "book": book.title, "device": deviceDescription(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            write(String(decoding: data, as: UTF8.self), to: "soak-summary.json")
        }
    }

    /// `-perf-recall`：10.1“5,000 个子块本地召回”与 20,000 子块规模检查。每个规模在独立的 SQLite 文件中
    /// 写入合成子块（约 300 字/子块、4 子块/父块，与默认切块上限一致）、FTS5 与 1024 维向量，
    /// 然后用正式的 HybridRetriever（词法 + 向量 + RRF + 父块扩展，无重排）检索。
    /// 查询向量由本地哈希向量生成，不含网络 Embedding/Rerank；首个查询（冷读向量索引）单独记录。
    static func runRecall(sizes: [Int] = [5_000, 20_000], samples: Int = 30) async {
        var results: [[String: Any]] = []
        for size in sizes {
            let url = directory.appendingPathComponent("recall-\(size).sqlite")
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let memStart = footprintMB()
            let embedder = LocalHashEmbedder(dimensions: 1024)
            let bookID = "perf-scale", version = "v1"
            var rng = SeededGenerator(seed: UInt64(size))
            var parents: [ParentChunk] = [], children: [ChildChunk] = []
            var textChars = 0
            for p in 0..<(size / 4) {
                var parentText = ""
                var kids: [ChildChunk] = []
                for k in 0..<4 {
                    let i = p * 4 + k
                    let text = syntheticChunk(index: i, rng: &rng)
                    textChars += text.count
                    let start = parentText.utf16.count
                    parentText += text
                    kids.append(ChildChunk(id: "c\(i)", parentID: "p\(p)", bookID: bookID, bookVersion: version, chapterIndex: p / 25,
                                           range: TextSpan(start: start, end: parentText.utf16.count), text: text, fingerprint: "f\(i)"))
                }
                parents.append(ParentChunk(id: "p\(p)", bookID: bookID, bookVersion: version, chapterIndex: p / 25,
                                           range: TextSpan(start: 0, end: parentText.utf16.count), text: parentText, fingerprint: "pf\(p)"))
                children += kids
            }
            var entry: [String: Any] = ["child_chunks": size, "parent_chunks": parents.count, "text_chars": textChars, "dims": embedder.profile.dimensions]
            do {
                let buildStart = now()
                let db = try AppDatabase.onDisk(at: url)
                let store = SQLiteRetrievalStore(db)
                try await store.replaceChunks(bookID: bookID, set: ChunkSet(parents: parents, children: children),
                                              manifest: IndexManifest(bookID: bookID, bookVersion: version, chunkingVersion: "perf", embeddingProfile: embedder.profile,
                                                                      childCount: size, embeddedCount: size, vectorStatus: .complete, updatedAt: Date()))
                for batch in stride(from: 0, to: children.count, by: 500) {
                    let slice = children[batch..<min(batch + 500, children.count)]
                    try await store.saveEmbeddings(slice.map { EmbeddingItem(childID: $0.id, bookID: bookID, fingerprint: $0.fingerprint,
                                                                             vector: embedder.vector($0.text)) }, profile: embedder.profile)
                }
                entry["build_ms"] = now() - buildStart
                parents = []; children = []
                entry["index_bytes"] = ["", "-wal", "-shm"].reduce(0) { total, suffix in
                    total + ((try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? Int) ?? 0)
                }
                // 新建存储对象：向量缓存为空，首个查询包含从 SQLite 读取并解码全部向量（冷读）
                let coldStore = SQLiteRetrievalStore(db)
                let retriever = HybridRetriever(chunks: coldStore, lexical: coldStore, vectors: coldStore, embedder: embedder)
                let scope = RetrievalScope([.wholeBook(bookID: bookID, version: version)])
                let memBeforeQueries = footprintMB()
                let c0 = now()
                let first = await retriever.retrieve(queries: [recallQuery(0)], scope: scope)
                entry["cold_first_query_ms"] = now() - c0
                var latencies: [Double] = [], hits: [Int] = [], peak = footprintMB()
                for q in 1...samples {
                    let t0 = now()
                    let r = await retriever.retrieve(queries: [recallQuery(q)], scope: scope)
                    latencies.append(now() - t0)
                    hits.append(r.units.count)
                    peak = max(peak, footprintMB())
                }
                entry["warm_ms"] = latencies
                entry["results_per_query"] = hits
                entry["cold_query_results"] = first.units.count
                entry["memory_mb"] = ["start": memStart, "before_queries": memBeforeQueries, "peak_during_queries": peak]
            } catch {
                entry["error"] = String(describing: error)
            }
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            results.append(entry)
        }
        let out: [String: Any] = ["device": deviceDescription(), "samples": samples, "runs": results]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            write(String(decoding: data, as: UTF8.self), to: "recall.json")
        }
    }

    private static let recallWords = ["复习", "记忆", "间隔", "笔记", "原文", "反例", "章节", "概念", "论证", "假设", "故事", "转折", "数据", "来源",
                                      "段落", "联系", "结构", "边界", "页边", "结论", "疑问", "解释", "比较", "整理"]

    private static func recallQuery(_ i: Int) -> String {
        "\(recallWords[i % recallWords.count])和\(recallWords[(i * 7 + 5) % recallWords.count])的关系"
    }

    private static func syntheticChunk(index: Int, rng: inout SeededGenerator) -> String {
        let subjects = ["读者", "作者", "学生", "老师", "研究者", "图书管理员", "旅行者", "工程师", "园丁", "记录员"]
        let verbs = ["注意到", "反复思考", "写下", "讨论", "比较", "怀疑", "整理", "复述", "追问", "重新阅读"]
        var text = "第\(index)段："
        while text.count < 290 {
            let a = recallWords[Int(rng.next() % UInt64(recallWords.count))]
            let b = recallWords[Int(rng.next() % UInt64(recallWords.count))]
            text += subjects[Int(rng.next() % 10)] + verbs[Int(rng.next() % 10)] + a + "与" + b + "之间的关系，"
        }
        return text + "并记下了编号 \(index)。"
    }

    // MARK: 辅助

    /// 进程物理内存占用（与 Xcode 内存仪表、Jetsam 使用的口径一致）。
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func deviceDescription() -> String {
        #if os(iOS)
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(model) iOS \(UIDevice.current.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// 与阅读器相同的属性字符串，排版首屏（包含 TextKit 布局开销）。
    private static func layoutFirstScreen(_ reader: ReaderModel) {
        #if os(iOS)
        guard let chapter = reader.currentChapter else { return }
        let view = ReaderTextView(chapter: chapter, highlights: reader.highlights, preferences: reader.preferences,
                                  selection: .constant(nil), jump: nil, pageCommand: nil,
                                  onVisibleRange: { _ in }, onMenuAction: { _ in }, onPageBoundary: { _ in })
        let bounds = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
            ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        let tv = UITextView(frame: bounds)
        tv.isEditable = false
        tv.attributedText = view.attributed()
        tv.layoutIfNeeded()
        _ = tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
        #endif
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    private static func waitUntil(timeout: Double, interval: UInt64 = 10_000_000, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: interval)
        }
        return false
    }

    private static func nextRunLoop() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    private static func processStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    private static func write(_ text: String, to name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func append(_ text: String, to name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

/// 本地确定性哈希向量（只用于性能采样，不调用网络）：字符二元组哈希到固定维度后归一化。
struct LocalHashEmbedder: EmbeddingService {
    let profile: EmbeddingProfile
    let maxBatchSize = 64
    init(dimensions: Int) { profile = EmbeddingProfile(model: "perf-local-hash", dimensions: dimensions) }

    func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: profile.dimensions)
        let chars = Array(text.unicodeScalars)
        for i in 0..<max(chars.count - 1, 0) {
            var h: UInt64 = 1469598103934665603
            for u in [chars[i].value, chars[i + 1].value] { h = (h ^ UInt64(u)) &* 1099511628211 }
            v[Int(h % UInt64(profile.dimensions))] += 1
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] { texts.map(vector) }
}

/// 固定种子的伪随机数（SplitMix64），保证每次生成相同的合成语料。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
