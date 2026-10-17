import Foundation
import CryptoKit

// 共享基础类型：时钟、ID、指纹与 UTF-16 文本区间。
// 所有模块都依赖 LibraryCore，因此这些与书籍生命周期紧密相关的基础类型放在这里。

/// 可注入的墙上时钟。测试与评测使用 `ManualClock` 固定时间。
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// 线程安全的手动时钟，用于确定性测试与评测。
public final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock(); current = date; lock.unlock()
    }
}

/// 稳定 ID 生成。生产使用 UUID；测试使用顺序 ID 保证可复现。
public protocol IDGenerating: Sendable {
    func make(_ prefix: String) -> String
}

public struct UUIDGenerator: IDGenerating {
    public init() {}
    public func make(_ prefix: String) -> String { "\(prefix)_\(UUID().uuidString.lowercased())" }
}

public final class SequentialIDGenerator: IDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    public init(start: Int = 0) { counter = start }
    public func make(_ prefix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "\(prefix)_\(counter)"
    }
}

/// 内容指纹（SHA-256 十六进制）。
public enum Fingerprint {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func of(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// 截短指纹，用于可读 ID。
    public static func short(_ text: String, length: Int = 12) -> String {
        String(of(text).prefix(length))
    }
}

/// UTF-16 偏移的半开区间 [start, end)。与 NSRange / UITextView 选择范围一致。
public struct TextSpan: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public init(_ range: Range<Int>) {
        self.init(start: range.lowerBound, end: range.upperBound)
    }

    public var length: Int { end - start }
    public var isEmpty: Bool { end <= start }
    public var description: String { "[\(start),\(end))" }

    public func contains(_ offset: Int) -> Bool { offset >= start && offset < end }
    public func contains(_ other: TextSpan) -> Bool { other.start >= start && other.end <= end }
    public func overlaps(_ other: TextSpan) -> Bool { start < other.end && other.start < end }
    /// 重叠或首尾相接。
    public func touches(_ other: TextSpan) -> Bool { start <= other.end && other.start <= end }

    public func intersection(_ other: TextSpan) -> TextSpan? {
        let s = max(start, other.start), e = min(end, other.end)
        return s < e ? TextSpan(start: s, end: e) : nil
    }

    public func union(_ other: TextSpan) -> TextSpan {
        TextSpan(start: min(start, other.start), end: max(end, other.end))
    }

    public func clamped(toLength length: Int) -> TextSpan {
        TextSpan(start: Swift.max(0, Swift.min(start, length)), end: Swift.max(0, Swift.min(end, length)))
    }

    public static func < (lhs: TextSpan, rhs: TextSpan) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }
}

extension String {
    /// UTF-16 长度。
    public var utf16Length: Int { utf16.count }

    /// 按 UTF-16 区间截取（越界时裁剪）。
    public func substring(utf16 range: TextSpan) -> String {
        let u = utf16
        let count = u.count
        let r = range.clamped(toLength: count)
        guard !r.isEmpty else { return "" }
        let s = u.index(u.startIndex, offsetBy: r.start)
        let e = u.index(s, offsetBy: r.length)
        return String(self[s..<e])
    }

    /// 查找子串所有出现位置（UTF-16 偏移）。
    public func utf16Ranges(of needle: String) -> [TextSpan] {
        guard !needle.isEmpty else { return [] }
        let ns = self as NSString
        var result: [TextSpan] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: needle, options: [.literal], range: searchRange)
            if found.location == NSNotFound { break }
            result.append(TextSpan(start: found.location, end: found.location + found.length))
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return result
    }

    /// 合并空白，用于比较与去重。
    public var normalizedForComparison: String {
        let lowered = lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasSpace = false
        for ch in lowered {
            if ch.isWhitespace || ch.isPunctuation {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// 统一的日期日历工具：存储使用 UTC `Date`，按用户时区计算日历日。
public struct DayKey: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    public init(date: Date, timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (l: DayKey, r: DayKey) -> Bool {
        (l.year, l.month, l.day) < (r.year, r.month, r.day)
    }

    /// 该日在指定时区的开始时刻。
    public func startDate(in timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> DayKey {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let d = cal.date(byAdding: .day, value: days, to: startDate(in: utc))!
        return DayKey(date: d, timeZone: utc)
    }

    /// 两个日历日之间的天数差（other - self）。
    public func days(to other: DayKey) -> Int {
        let utc = TimeZone(identifier: "UTC")!
        let a = startDate(in: utc), b = other.startDate(in: utc)
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }
}
