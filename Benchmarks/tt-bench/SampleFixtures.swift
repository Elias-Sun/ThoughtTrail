import Foundation
import TestSupport
import BenchCore

/// 应用内置示例书（自制文本，可再分发）与异常样本，供 UI 自动化与离线演示使用。
enum SampleFixtures {
    static func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixtures.zhBook().write(to: dir.appendingPathComponent("sample-zh.epub"))
        try Fixtures.enBook().write(to: dir.appendingPathComponent("sample-en.epub"))
        // 损坏样本：ZIP 魔数后跟随无效数据
        try Data([0x50, 0x4B, 0x03, 0x04] + Array("这不是完整的 EPUB 文件".utf8)).write(to: dir.appendingPathComponent("sample-corrupt.epub"))
        print("已生成示例书到 \(dir.path)")
    }
}

enum Compare {
    static func run(baseline: URL, candidate: URL) throws {
        let store = BenchRunStore(directory: baseline.deletingLastPathComponent())
        let a = try store.load(baseline), b = try store.load(candidate)
        for d in try BenchRunStore.compare(baseline: a, candidate: b) {
            print("\(d.metric)\t\(String(format: "%.4f", d.baseline)) → \(String(format: "%.4f", d.candidate))\t(\(String(format: "%+.4f", d.delta)))")
        }
    }
}

