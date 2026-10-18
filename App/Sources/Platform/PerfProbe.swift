import Foundation
import LibraryCore
import ReaderCore
import ReflectionCore
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
            "reopen_ms": reopen, "highlight_save_ms": highlight, "reflection_save_ms": reflection,
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
        var cycles = 0, discussions = 0, cancels = 0, highlights = 0, reflections = 0, backups = 0, failures = 0
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
                if (try? await app.container.reflections.commit(id: d.id, commitKey: "soak-\(d.id)")) != nil { reflections += 1 } else { failures += 1 }
            }
            // 讨论：完成一次（含检索、生成、核查）；每 3 轮取消一次慢速回答
            let discussion = DiscussionModel(app: app, book: book)
            await discussion.start(context: await reader.contextSnapshot(), selection: nil)
            if cycles.isMultiple(of: 3) {
                discussion.input = "请慢慢讲讲复习的间隔"
                discussion.send()
                if await waitUntil(timeout: 10, { discussion.liveStatus == .drafting && !discussion.liveDraft.isEmpty }) {
                    await discussion.cancel(); cancels += 1
                } else { failures += 1 }
            } else {
                discussion.input = "这一章讲了什么？"
                discussion.send()
                if await waitUntil(timeout: 30, { !discussion.running && discussion.messages.count >= 2 }) { discussions += 1 } else { failures += 1 }
            }
            // 备份导出（含 EPUB），每 10 轮一次
            if cycles.isMultiple(of: 10) {
                if let data = try? await app.container.backup.export(includeEPUB: true, now: Date()) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("soak-backup.json")
                    try? data.write(to: url, options: .atomic)
                    backups += 1
                } else { failures += 1 }
            }
            if Date().timeIntervalSince(lastSample) >= 10 { sample() }
            // 每轮间隔 3 秒，接近连续使用的节奏；不间断循环会让数据量的增长掩盖内存是否泄漏
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        sample()
        await reader.close()
        let summary: [String: Any] = [
            "minutes": minutes, "elapsed_s": Date().timeIntervalSince(started), "cycles": cycles, "discussions_completed": discussions,
            "cancels": cancels, "highlights": highlights, "reflections": reflections, "backups": backups, "failures": failures,
            "book": book.title, "device": deviceDescription(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            write(String(decoding: data, as: UTF8.self), to: "soak-summary.json")
        }
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

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
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
