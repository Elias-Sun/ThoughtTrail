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

    /// 重开书籍、本地保存、取消响应各采样 `samples` 次，写入 suite.json。
    static func runSuite(app: AppModel, samples: Int = 30) async {
        guard let book = app.books.first else { write(#"{"error":"no book"}"#, to: "suite.json"); return }
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

        let result: [String: Any] = [
            "samples": samples, "book": book.title, "chapter_utf16": chapter.length,
            "reopen_ms": reopen, "highlight_save_ms": highlight, "reflection_save_ms": reflection,
            "cancel_ms": cancel, "cancel_late_state_changes": lateChanges,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            write(String(decoding: data, as: UTF8.self), to: "suite.json")
        }
    }

    // MARK: 辅助

    /// 与阅读器相同的属性字符串，排版首屏（包含 TextKit 布局开销）。
    private static func layoutFirstScreen(_ reader: ReaderModel) {
        #if os(iOS)
        guard let chapter = reader.currentChapter else { return }
        let view = ReaderTextView(chapter: chapter, highlights: reader.highlights, preferences: reader.preferences,
                                  selection: .constant(nil), jump: nil, pageCommand: nil,
                                  onVisibleRange: { _ in }, onMenuAction: { _ in }, onPageBoundary: { _ in })
        let tv = UITextView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
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
