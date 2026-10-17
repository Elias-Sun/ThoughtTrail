import Foundation
import LibraryCore

/// 带分子分母的指标值（9.2：每项指标同时报告样本数与分母）。
public struct MetricValue: Codable, Hashable, Sendable {
    public var value: Double
    public var numerator: Double
    public var denominator: Double

    public init(numerator: Double, denominator: Double) {
        self.numerator = numerator; self.denominator = denominator
        self.value = denominator == 0 ? 0 : numerator / denominator
    }

    public init(mean values: [Double]) {
        numerator = values.reduce(0, +); denominator = Double(values.count)
        value = values.isEmpty ? 0 : numerator / denominator
    }
}

public enum RetrievalMetrics {
    /// 命中规则：同书同章，且重叠至少覆盖相关区间的 `minOverlap` 比例（或检索区间被相关区间完全包含）。
    public static func matches(_ r: RetrievedSpan, _ rel: RelevantSpan, minOverlap: Double = 0.3) -> Bool {
        guard r.bookID == rel.bookID, r.chapterIndex == rel.chapterIndex,
              let inter = r.range.intersection(rel.range) else { return false }
        return Double(inter.length) >= minOverlap * Double(rel.range.length) || rel.range.contains(r.range)
    }

    /// Recall@K = 被前 K 个结果召回的相关证据数 / 标注相关证据总数（不是“命中任意一条”）。
    public static func recall(at k: Int, retrieved: [RetrievedSpan], relevant: [RelevantSpan]) -> Double {
        guard !relevant.isEmpty else { return 0 }
        let top = retrieved.prefix(k)
        let found = relevant.filter { rel in top.contains { matches($0, rel) } }.count
        return Double(found) / Double(relevant.count)
    }

    /// nDCG@K：增益 2^grade − 1，每个相关证据只计一次。
    public static func ndcg(at k: Int, retrieved: [RetrievedSpan], relevant: [RelevantSpan]) -> Double {
        guard !relevant.isEmpty else { return 0 }
        var used: Set<Int> = []
        var dcg = 0.0
        for (i, r) in retrieved.prefix(k).enumerated() {
            if let j = relevant.indices.filter({ !used.contains($0) && matches(r, relevant[$0]) })
                .max(by: { relevant[$0].grade < relevant[$1].grade }) {
                used.insert(j)
                dcg += (pow(2, Double(relevant[j].grade)) - 1) / log2(Double(i) + 2)
            }
        }
        let ideal = relevant.map(\.grade).sorted(by: >).prefix(k).enumerated()
            .reduce(0.0) { $0 + (pow(2, Double($1.element)) - 1) / log2(Double($1.offset) + 2) }
        return ideal == 0 ? 0 : dcg / ideal
    }
}

/// 混淆矩阵与分类指标（证据复核、记忆、反馈）。
public struct ConfusionMatrix: Codable, Hashable, Sendable {
    public private(set) var labels: [String]
    /// counts[gold][predicted]
    public private(set) var counts: [String: [String: Int]]

    public init(labels: [String]) {
        self.labels = labels
        counts = Dictionary(uniqueKeysWithValues: labels.map { ($0, Dictionary(uniqueKeysWithValues: labels.map { ($0, 0) })) })
    }

    public mutating func add(gold: String, predicted: String) {
        if !labels.contains(gold) { labels.append(gold) }
        if !labels.contains(predicted) { labels.append(predicted) }
        counts[gold, default: [:]][predicted, default: 0] += 1
    }

    public func count(gold: String, predicted: String) -> Int { counts[gold]?[predicted] ?? 0 }
    public var total: Int { counts.values.flatMap(\.values).reduce(0, +) }

    /// 以一组标签为“正类”（例如 insufficient+contradicted 视为需处理）计算 Precision/Recall。
    /// 预测为 unknown 的正类样本计入未检出（9.2：不能删掉难例）。
    public func binary(positive: Set<String>) -> (precision: MetricValue, recall: MetricValue) {
        var tp = 0, fp = 0, fn = 0
        for (gold, row) in counts {
            for (pred, n) in row {
                let g = positive.contains(gold), p = positive.contains(pred)
                if g && p { tp += n } else if !g && p { fp += n } else if g && !p { fn += n }
            }
        }
        return (MetricValue(numerator: Double(tp), denominator: Double(tp + fp)), MetricValue(numerator: Double(tp), denominator: Double(tp + fn)))
    }

    public func accuracy() -> MetricValue {
        let correct = labels.reduce(0) { $0 + count(gold: $1, predicted: $1) }
        return MetricValue(numerator: Double(correct), denominator: Double(total))
    }
}

/// 失败样本（报告代表性失败案例）。
public struct FailureCase: Codable, Hashable, Sendable {
    public var caseID: String
    public var detail: String

    public init(caseID: String, detail: String) { self.caseID = caseID; self.detail = detail }
}

/// 一次评测运行结果。
public struct BenchRunResult: Codable, Hashable, Sendable {
    public var runID: String
    public var suite: String
    public var datasetName: String
    public var datasetVersion: String
    public var datasetSHA256: String
    public var annotationStatus: DatasetManifest.AnnotationStatus
    public var configuration: [String: String]
    public var createdAt: Date
    public var sampleCount: Int
    public var metrics: [String: MetricValue]
    public var confusion: ConfusionMatrix?
    public var failures: [FailureCase]

    public init(runID: String, suite: String, datasetName: String, datasetVersion: String, datasetSHA256: String,
                annotationStatus: DatasetManifest.AnnotationStatus, configuration: [String: String], createdAt: Date, sampleCount: Int,
                metrics: [String: MetricValue], confusion: ConfusionMatrix?, failures: [FailureCase]) {
        self.runID = runID; self.suite = suite; self.datasetName = datasetName; self.datasetVersion = datasetVersion
        self.datasetSHA256 = datasetSHA256; self.annotationStatus = annotationStatus; self.configuration = configuration
        self.createdAt = createdAt; self.sampleCount = sampleCount; self.metrics = metrics; self.confusion = confusion; self.failures = failures
    }

    public var configurationHash: String {
        Fingerprint.short(configuration.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"), length: 16)
    }
}

public enum BenchCompareError: Error, Equatable, Sendable {
    case datasetMismatch(String, String)
    case suiteMismatch(String, String)
}

public struct MetricDelta: Codable, Hashable, Sendable {
    public var metric: String
    public var baseline: Double
    public var candidate: Double
    public var delta: Double
}

/// 结果保存与比较：不同数据版本之间拒绝比较；重复运行保存为不同 runID。
public struct BenchRunStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func save(_ result: BenchRunResult) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(result.suite)-\(result.runID).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(result).write(to: url, options: .atomic)
        return url
    }

    public func load(_ url: URL) throws -> BenchRunResult {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(BenchRunResult.self, from: Data(contentsOf: url))
    }

    public func all(suite: String? = nil) throws -> [BenchRunResult] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? load($0) }
            .filter { suite == nil || $0.suite == suite }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public static func compare(baseline: BenchRunResult, candidate: BenchRunResult) throws -> [MetricDelta] {
        guard baseline.suite == candidate.suite else { throw BenchCompareError.suiteMismatch(baseline.suite, candidate.suite) }
        guard baseline.datasetSHA256 == candidate.datasetSHA256 else {
            throw BenchCompareError.datasetMismatch(baseline.datasetVersion, candidate.datasetVersion)
        }
        return Set(baseline.metrics.keys).intersection(candidate.metrics.keys).sorted().map {
            MetricDelta(metric: $0, baseline: baseline.metrics[$0]!.value, candidate: candidate.metrics[$0]!.value,
                        delta: candidate.metrics[$0]!.value - baseline.metrics[$0]!.value)
        }
    }
}
