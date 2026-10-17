import SwiftUI
import LibraryCore
import ReadingSessionCore
import ReflectionCore
import BrainCore

/// 从阅读器打开的讨论（带阅读现场与选段）。
struct DiscussionSheet: View {
    let reader: ReaderModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: DiscussionModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { DiscussionView(model: model) } else { ProgressView() }
            }
            .navigationTitle("阅读讨论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("discussion.close")
                }
            }
        }
        .task {
            guard model == nil else { return }
            let m = DiscussionModel(app: app, book: reader.book)
            model = m
            await m.start(context: await reader.contextSnapshot(), selection: reader.selectionContext())
        }
    }
}

struct DiscussionView: View {
    let model: DiscussionModel
    @State private var confirmWholeBook = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    if let sel = model.selection {
                        Section("选段") { Text(sel.text).font(.callout).foregroundStyle(.secondary) }
                    }
                    ForEach(model.messages) { m in
                        MessageRow(message: m, model: model).id(m.id)
                    }
                    if model.running { liveRow.id("live") }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("discussion.list")
                .onChange(of: model.liveDraft) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
            }
            inputBar
        }
        .alert("切换到全书范围？", isPresented: $confirmWholeBook) {
            Button("切换") { Task { await model.setScope(.wholeBook) } }.accessibilityIdentifier("scope.confirmWhole")
            Button("取消", role: .cancel) {}
        } message: {
            Text("全书范围会检索尚未读到的内容，可能包含剧透。切换会记录在讨论中。")
        }
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let s = model.liveStatus { MessageStatusBadge(status: s) }
                ProgressView().controlSize(.small)
            }
            if !model.liveDraft.isEmpty {
                Text(model.liveDraft).accessibilityIdentifier("discussion.liveDraft")
            }
            if let p = model.livePolicy {
                Text("范围：\(p.scopeMode == .readOnly ? "仅已读" : "全书") · 证据 \(model.liveEvidence.count) 条\(p.usedModelPlan ? "" : " · 规则策略")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discussion.live")
    }

    private var inputBar: some View {
        @Bindable var model = model
        return VStack(spacing: 6) {
            HStack {
                Menu {
                    Button("仅已读内容（默认）") { Task { await model.setScope(.readOnly) } }
                    Button("全书（可能剧透）") { confirmWholeBook = true }
                        .accessibilityIdentifier("scope.whole")
                } label: {
                    Label(model.scopeMode == .readOnly ? "范围：已读" : "范围：全书", systemImage: "scope").font(.caption)
                }
                .accessibilityIdentifier("discussion.scope")
                Spacer()
                if !model.app.isOnline {
                    Label("离线：发送后可在联网时重试", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
                }
            }
            HStack(alignment: .bottom) {
                TextField("提出问题或追问…", text: $model.input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("discussion.input")
                if model.running {
                    Button("取消") { Task { await model.cancel() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("discussion.cancel")
                } else {
                    Button("发送") { model.send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("discussion.send")
                }
            }
        }
        .padding(12)
        .background(.bar)
    }
}

struct MessageStatusBadge: View {
    let status: MessageStatus

    var color: Color {
        switch status {
        case .verified: return .green
        case .needsAttention, .insufficientEvidence: return .orange
        case .verificationUnavailable: return .gray
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .blue
        }
    }

    var body: some View {
        StatusBadge(text: status.displayName, color: color)
            .accessibilityIdentifier("status.\(status.rawValue)")
    }
}

struct MessageRow: View {
    let message: Message
    let model: DiscussionModel
    @State private var showChecks = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("message.user")
            }
            .listRowSeparator(.hidden)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MessageStatusBadge(status: message.status)
                    if message.scopeMode == .wholeBook { StatusBadge(text: "全书范围", color: .purple) }
                    if message.truncated { StatusBadge(text: "不完整", color: .orange) }
                }
                if !message.text.isEmpty {
                    Text(message.text).textSelection(.enabled).accessibilityIdentifier("message.assistant")
                }
                if let err = message.errorDescription {
                    Text(err).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("message.error")
                }
                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.citations, id: \.label) { c in
                            Button { model.openCitation(c) } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(c.label).font(.caption.bold())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(kindName(c.kind) + (c.structurallyValid ? "" : " · 未通过结构校验")).font(.caption2).foregroundStyle(.secondary)
                                        Text(c.quote).font(.caption).lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!c.structurallyValid || c.bookID == nil)
                            .accessibilityIdentifier("citation.\(c.label)")
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                if !message.claimChecks.isEmpty {
                    DisclosureGroup("核查明细（\(message.claimChecks.count) 条陈述）", isExpanded: $showChecks) {
                        ForEach(Array(message.claimChecks.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.claim).font(.caption)
                                Text("\(verdictName(c.verdict))：\(c.reason)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("message.checks")
                }
                actions
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if message.status == .failed || message.status == .cancelled {
                Button("重试") { model.retry(message) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("message.retry")
            }
            if [.verified, .needsAttention].contains(message.status) && model.proposals[message.id] == nil {
                Button("提出记忆建议") { Task { await model.proposeMemories(for: message) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("message.propose")
            }
        }
        if let err = model.proposalError, model.proposals[message.id] == nil || model.proposals[message.id]?.isEmpty == true {
            Text(err).font(.caption).foregroundStyle(.secondary)
        }
        if let props = model.proposals[message.id] {
            ForEach(props) { p in ProposalCard(proposal: p) { confirm in Task { await model.decide(p, confirm: confirm, messageID: message.id) } } }
        }
    }

    func kindName(_ k: EvidenceSourceKind) -> String {
        switch k {
        case .bookText: return "原文"
        case .annotation: return "批注"
        case .reflection: return "个人反思"
        case .memory: return "长期记忆"
        case .history: return "讨论历史"
        }
    }

    func verdictName(_ v: ClaimVerdictLabel) -> String {
        switch v {
        case .supported: return "支持"
        case .insufficient: return "证据不足"
        case .contradicted: return "存在矛盾"
        case .unknown: return "无法判断"
        }
    }
}

/// 记忆提议卡片：确认/拒绝。
struct ProposalCard: View {
    let proposal: MemoryProposal
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("记忆建议").font(.caption.bold())
                StatusBadge(text: statusName, color: proposal.status == .confirmed ? .green : (proposal.status == .pending ? .blue : .gray))
                    .accessibilityIdentifier("proposal.status.\(proposal.status.rawValue)")
            }
            Text(proposal.action.summary).font(.callout)
            if !proposal.issues.isEmpty { Text("校验：\(proposal.issues.joined(separator: "、"))").font(.caption2).foregroundStyle(.orange) }
            if proposal.status == .pending {
                HStack {
                    Button("确认写入") { decide(true) }.buttonStyle(.borderedProminent).accessibilityIdentifier("proposal.confirm")
                    Button("拒绝") { decide(false) }.buttonStyle(.bordered).accessibilityIdentifier("proposal.reject")
                }
            }
        }
        .padding(8)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    var statusName: String {
        switch proposal.status {
        case .pending: return "待确认"
        case .confirmed: return "已写入"
        case .rejected: return "已拒绝"
        case .invalid: return "未通过校验"
        }
    }
}
