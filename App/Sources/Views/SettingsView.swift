import SwiftUI
import UniformTypeIdentifiers
import AgentRuntime
import ModelProviders
import Persistence
import AppInfrastructure

/// 设置与数据：模型配置、密钥、连接检测、导出/恢复、诊断（DATA-02/03、RUN-03）。
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var config = ProviderConfiguration()
    @State private var chatKey = ""
    @State private var embeddingKey = ""
    @State private var rerankKey = ""
    @State private var checks: [ConnectionCheckResult] = []
    @State private var checking = false
    @State private var exportURL: URL?
    @State private var markdownURL: URL?
    @State private var showRestore = false
    @State private var traces: [TraceEvent] = []
    /// 当前正在编辑的密钥框；保存前先结束编辑，确保 SecureField 的输入已提交到绑定值
    @FocusState private var editingKey: String?
    /// 已保存密钥的掩码（显式状态：密钥存储本身不被 SwiftUI 观察，保存后需主动刷新）
    @State private var maskedKeys: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(DataProcessingNotice.text).font(.caption).foregroundStyle(.secondary)
                } header: { Text("数据处理说明") }

                Section("对话模型（讨论、规划、复核、出题）") {
                    TextField("接口地址", text: binding(\.chat, default: .init(baseURL: ProviderPresets.dashscopeBeijingCompatible.absoluteString, model: "qwen-plus"), \.baseURL))
                        .textInputAutocapitalization(.never).keyboardType(.URL).accessibilityIdentifier("settings.chat.url")
                    TextField("模型 ID", text: binding(\.chat, default: .init(baseURL: ProviderPresets.dashscopeBeijingCompatible.absoluteString, model: "qwen-plus"), \.model))
                        .textInputAutocapitalization(.never).accessibilityIdentifier("settings.chat.model")
                    keyField("对话密钥", text: $chatKey, ref: .chat)
                }
                Section("文本向量（text-embedding-v4）") {
                    TextField("接口地址", text: binding(\.embedding, default: .init(baseURL: ProviderPresets.dashscopeBeijingCompatible.absoluteString, model: ProviderPresets.defaultEmbeddingModel, dimensions: 1024), \.baseURL))
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("模型 ID", text: binding(\.embedding, default: .init(baseURL: ProviderPresets.dashscopeBeijingCompatible.absoluteString, model: ProviderPresets.defaultEmbeddingModel, dimensions: 1024), \.model))
                        .textInputAutocapitalization(.never)
                    keyField("向量密钥", text: $embeddingKey, ref: .embedding)
                }
                Section("重排（qwen3-rerank）") {
                    TextField("接口地址", text: binding(\.rerank, default: .init(baseURL: ProviderPresets.dashscopeBeijingNative.absoluteString, model: ProviderPresets.defaultRerankModel), \.baseURL))
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("模型 ID", text: binding(\.rerank, default: .init(baseURL: ProviderPresets.dashscopeBeijingNative.absoluteString, model: ProviderPresets.defaultRerankModel), \.model))
                        .textInputAutocapitalization(.never)
                    keyField("重排密钥", text: $rerankKey, ref: .rerank)
                }
                Section {
                    Button("使用百炼默认配置（北京）") { config = .dashscopeDefault() }
                    Button("保存配置") { Task { await save() } }.accessibilityIdentifier("settings.save")
                    Button {
                        Task { await check() }
                    } label: {
                        HStack { Text("检测连接"); if checking { ProgressView() } }
                    }
                    .accessibilityIdentifier("settings.check")
                    ForEach(checks, id: \.kind) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.kind.rawValue)：\(r.ok ? "可用" : "失败") · \(r.model) · \(r.latencyMs) ms").font(.callout)
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("settings.check.\(r.kind.rawValue)")
                    }
                } footer: { Text("密钥只保存在系统钥匙串中，配置与导出包里不包含密钥。更换向量模型或维度后，旧向量索引会失效并按已读范围重建。") }

                Section("数据") {
                    Button("导出结构化备份（不含密钥、音频；含 EPUB）") { Task { await exportBackup() } }
                        .accessibilityIdentifier("settings.exportBackup")
                    if let exportURL {
                        ShareLink("分享备份文件", item: exportURL).accessibilityIdentifier("settings.shareBackup")
                    }
                    Button("恢复备份…") { showRestore = true }.accessibilityIdentifier("settings.restore")
                    if app.launch.deterministic, let last = app.lastBackupURL {
                        // 自动化测试无法操作系统文件选择器：直接恢复最近导出的文件
                        Button("恢复刚才导出的备份") { Task { await restore(last) } }.accessibilityIdentifier("settings.restoreLast")
                    }
                    Button("导出 Markdown（便于阅读）") { Task { await exportMarkdown() } }
                    if let markdownURL { ShareLink("分享 Markdown", item: markdownURL) }
                }
                Section("诊断") {
                    NavigationLink("最近的执行记录") { DiagnosticsView(traces: traces) }
                        .accessibilityIdentifier("settings.diagnostics")
                    if let r = app.recovery, r.failedMessages + r.interruptedTasks + r.endedSessions > 0 {
                        Text("上次未正常结束：结束会话 \(r.endedSessions)，中断任务 \(r.interruptedTasks)，回答标记失败 \(r.failedMessages)").font(.caption)
                    }
                    LabeledContent("网络", value: app.isOnline ? "在线" : "离线")
                    if app.launch.deterministic { Text("确定性测试/演示模式：模型响应由本地规则生成，不代表真实模型效果。").font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("设置")
            .task { await load() }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result { Task { await restore(url) } }
            }
        }
    }

    private func keyField(_ title: String, text: Binding<String>, ref: SecretReference) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SecureField(title, text: text)
                .textInputAutocapitalization(.never)
                .focused($editingKey, equals: ref.account)
                .submitLabel(.done)
                .accessibilityIdentifier("settings.key.\(ref.account)")
            if let masked = maskedKeys[ref.account] {
                Text("已保存：\(masked)").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("settings.masked.\(ref.account)")
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<ProviderConfiguration, T?>, default value: T, _ field: WritableKeyPath<T, String>) -> Binding<String> {
        Binding(
            get: { config[keyPath: key]?[keyPath: field] ?? "" },
            set: { newValue in
                var section = config[keyPath: key] ?? value
                section[keyPath: field] = newValue
                config[keyPath: key] = section
            })
    }

    private func refreshMasks() {
        let secrets = app.container.environment.secrets
        var out: [String: String] = [:]
        for ref in [SecretReference.chat, .embedding, .rerank] { out[ref.account] = secrets.maskedValue(ref) }
        maskedKeys = out
    }

    private func load() async {
        refreshMasks()
        config = await app.container.providers.configuration()
        traces = (try? await app.container.runtimeStore.recentTraceEvents(limit: 100)) ?? []
    }

    private func save() async {
        editingKey = nil
        try? await Task.sleep(nanoseconds: 150_000_000)
        let secrets = app.container.environment.secrets
        do {
            var updated: [String] = []
            for (value, ref, name) in [(chatKey, SecretReference.chat, "对话"), (embeddingKey, .embedding, "向量"), (rerankKey, .rerank, "重排")]
            where !value.trimmingCharacters(in: .whitespaces).isEmpty {
                try secrets.write(value, for: ref)
                updated.append(name)
            }
            chatKey = ""; embeddingKey = ""; rerankKey = ""
            refreshMasks()
            let reembed = try await app.container.providers.save(config)
            var message = "已保存配置"
            if !updated.isEmpty { message += "；已更新\(updated.joined(separator: "、"))密钥" }
            if reembed { message += "。向量模型已变化，旧向量将在下次索引时重建" }
            app.banner = .init(message: message, isError: false)
            if reembed { for b in app.books { await app.buildIndex(b) } }
        } catch ConfigurationError.invalid(let issues) {
            app.banner = .init(message: "配置无效：\(issues.map { "\($0)" }.joined(separator: "，"))", isError: true)
        } catch {
            app.banner = .init(message: "保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func check() async {
        checking = true
        checks = await app.container.providers.checkConnections()
        checking = false
        if checks.isEmpty { app.banner = .init(message: "尚未配置任何模型服务", isError: true) }
    }

    private func exportBackup() async {
        do {
            let data = try await app.container.backup.export(includeEPUB: true, now: Date())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtTrail-\(Int(Date().timeIntervalSince1970)).ttbackup.json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            app.lastBackupURL = url
            app.banner = .init(message: "备份已生成（\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))）", isError: false)
        } catch {
            app.banner = .init(message: "导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func exportMarkdown() async {
        do {
            let md = try await app.container.exportMarkdown()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtTrail.md")
            try md.write(to: url, atomically: true, encoding: .utf8)
            markdownURL = url
        } catch {
            app.banner = .init(message: "导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    func restore(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let report = try await app.container.backup.restore(try Data(contentsOf: url))
            app.banner = .init(message: report.alreadyRestored ? "这份备份之前已恢复过，记录未重复。"
                               : "已恢复 \(report.books) 本书（\(report.booksMissingSource) 本缺少原文件）、\(report.reflections) 条反思、\(report.brainItems) 条记忆", isError: false)
            await app.reloadBooks()
        } catch let e as BackupError {
            app.banner = .init(message: "备份无法恢复：\(e)。现有数据未改变。", isError: true)
        } catch {
            app.banner = .init(message: "恢复失败：\(error.localizedDescription)。现有数据未改变。", isError: true)
        }
    }
}

/// 执行记录：阶段、模型、耗时、用量（实际/估算/未知）、降级与错误。默认不显示正文。
struct DiagnosticsView: View {
    let traces: [TraceEvent]

    var body: some View {
        List(Array(traces.enumerated()), id: \.offset) { _, e in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(e.stage) · \(e.name) · \(e.outcome.rawValue)").font(.callout)
                Text("trace \(e.traceID.prefix(10)) · \(Int(e.duration * 1000)) ms · \(e.model ?? "-") · 用量 \(usage(e))").font(.caption2).foregroundStyle(.secondary)
                if let d = e.degradation, !d.isEmpty { Text("降级：\(d)").font(.caption2).foregroundStyle(.orange) }
                if let err = e.errorCode { Text("错误：\(err)").font(.caption2).foregroundStyle(.red) }
            }
        }
        .navigationTitle("执行记录")
    }

    func usage(_ e: TraceEvent) -> String {
        guard let u = e.usage else { return e.name == "model_call" ? "未知" : "-" }
        return "\(u.totalTokens)（\(u.source == .reported ? "实际" : "估算")）"
    }
}
