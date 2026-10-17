import Foundation

// tt-bench：固定评测与夹具生成命令行入口。
//   tt-bench fixtures <outDir>            生成应用内置示例书与损坏样本
//   tt-bench corpus <outDir>              生成评测语料 EPUB（自制可再分发文本）
//   tt-bench eval <evaluationDir> <out>   运行离线评测套件（检索/边界/复核/记忆/自测），输出 JSON 与 Markdown 报告
//   tt-bench compare <baseline.json> <candidate.json>

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("用法：tt-bench fixtures|corpus|eval|compare …")
    exit(2)
}

do {
    switch command {
    case "fixtures":
        try SampleFixtures.write(to: URL(fileURLWithPath: args.count > 1 ? args[1] : "App/Resources/Samples"))
    case "corpus":
        try CorpusBuilder.write(to: URL(fileURLWithPath: args.count > 1 ? args[1] : "Evaluation/corpus"))
    case "eval":
        let evalDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "Evaluation")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Evaluation/results")
        try await EvalRunner.run(evaluationDir: evalDir, outputDir: outDir)
    case "compare":
        guard args.count == 3 else { print("用法：tt-bench compare <baseline.json> <candidate.json>"); exit(2) }
        try Compare.run(baseline: URL(fileURLWithPath: args[1]), candidate: URL(fileURLWithPath: args[2]))
    default:
        print("未知命令：\(command)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(1)
}
