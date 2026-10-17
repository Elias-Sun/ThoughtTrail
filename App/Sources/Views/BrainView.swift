import SwiftUI
import LibraryCore
import ReflectionCore
import BrainCore

/// 思考与记忆：观点、问题、记忆；待确认提议；来源、关系与修订历史（MEM-01…05）。
struct BrainView: View {
    @Environment(AppModel.self) private var app
    @State private var kind: BrainItemKind = .memory
    @State private var items: [BrainItem] = []
    @State private var pending: [MemoryProposal] = []
    @State private var drafts: [Reflection] = []
    @State private var reflections: [Reflection] = []
    @State private var search = ""
    @State private var creating = false
    @State private var newContent = ""
    @State private var resumeDraft: Reflection?

    var body: some View {
        NavigationStack {
            List {
                if !pending.isEmpty {
                    Section("待确认的记忆建议") {
                        ForEach(pending) { p in
                            ProposalCard(proposal: p) { confirm in Task { await decide(p, confirm) } }
                        }
                    }
                }
                if !drafts.isEmpty {
                    Section("未完成的反思草稿") {
                        ForEach(drafts) { d in
                            Button {
                                resumeDraft = d
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(d.text.isEmpty ? "（空草稿）" : d.text).lineLimit(2)
                                    Text("《\(d.context.bookTitle)》").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("draft.row")
                        }
                    }
                }
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(BrainItemKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("brain.kind")
                }
                Section(kind.displayName) {
                    if items.isEmpty { Text("暂无条目").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        NavigationLink {
                            BrainItemDetail(itemID: item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.content).lineLimit(3)
                                HStack(spacing: 6) {
                                    if item.origin == .confirmedProposal { StatusBadge(text: "来自确认的建议", color: .blue) }
                                    if item.hasInvalidEvidence { StatusBadge(text: "来源失效", color: .orange) }
                                    Text("r\(item.revision)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("brain.item")
                    }
                }
                if !reflections.isEmpty {
                    Section("反思记录") {
                        ForEach(reflections) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.text).lineLimit(3)
                                Text("《\(r.context.bookTitle)》\(r.context.chapterTitle.map { " · \($0)" } ?? "")\(r.sourceUnavailable ? " · 来源不可访问" : "")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("reflection.row")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索观点、问题与记忆")
            .navigationTitle("思考与记忆")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Label("新建", systemImage: "plus") }.accessibilityIdentifier("brain.new")
                }
            }
            .alert("新建\(kind.displayName)", isPresented: $creating) {
                TextField("内容", text: $newContent).accessibilityIdentifier("brain.newField")
                Button("保存") { Task { await create() } }.accessibilityIdentifier("brain.newSave")
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $resumeDraft, onDismiss: { Task { await reload() } }) { d in
                ReflectionSheet(reader: nil, existingDraft: d)
            }
            .task(id: kind) { await reload() }
            .onChange(of: search) { _, _ in Task { await reload() } }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        let c = app.container
        items = (try? await c.brain.search(search, kinds: [kind])) ?? []
        pending = (try? await c.brain.pendingProposals()) ?? []
        drafts = (try? await c.reflections.pendingDrafts()) ?? []
        reflections = (try? await c.reflections.reflections(bookID: nil)) ?? []
    }

    private func decide(_ p: MemoryProposal, _ confirm: Bool) async {
        do {
            _ = confirm ? try await app.container.brain.confirm(proposalID: p.id) : try await app.container.brain.reject(proposalID: p.id)
        } catch {
            app.banner = .init(message: "无法处理提议：\(error)", isError: true)
        }
        await reload()
    }

    private func create() async {
        do {
            _ = try await app.container.brain.create(kind: kind, content: newContent)
            newContent = ""
        } catch {
            app.banner = .init(message: "无法保存：内容不能为空", isError: true)
        }
        await reload()
    }
}

struct BrainItemDetail: View {
    let itemID: String
    @Environment(AppModel.self) private var app
    @State private var item: BrainItem?
    @State private var revisions: [Revision] = []
    @State private var relations: [Relation] = []
    @State private var related: [String: BrainItem] = [:]
    @State private var editing = false
    @State private var editText = ""
    @State private var editReason = ""

    var body: some View {
        List {
            if let item {
                Section(item.kind.displayName) {
                    Text(item.content).accessibilityIdentifier("brainDetail.content")
                    HStack {
                        Text(item.origin == .confirmedProposal ? "来源：确认的模型建议" : "来源：我自己")
                        Spacer()
                        Text("版本 r\(item.revision)").accessibilityIdentifier("brainDetail.revision")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("证据") {
                    if item.evidence.isEmpty { Text("没有关联证据（个人想法）").foregroundStyle(.secondary) }
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, e in
                        Button {
                            if let b = e.bookID, e.kind == .bookText, e.isValid, let ch = e.chapterIndex, let r = e.range {
                                app.openRequest = .init(bookID: b, locator: .init(bookID: b, bookVersion: e.bookVersion ?? "", chapterIndex: ch,
                                                                                   chapterHref: "", range: r,
                                                                                   anchor: .init(prefix: "", exact: e.quote, suffix: ""), progression: 0))
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.kind == .bookText ? "原文" : (e.kind == .reflection ? "反思" : "讨论")).font(.caption2).foregroundStyle(.secondary)
                                Text(e.quote).font(.callout).lineLimit(3)
                                if !e.isValid { Text("来源已失效：\(e.invalidReason ?? "")").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                        .disabled(!e.isValid || e.kind != .bookText)
                        .accessibilityIdentifier("brainDetail.evidence")
                    }
                }
                if !relations.isEmpty {
                    Section("关系") {
                        ForEach(relations) { r in
                            let otherID = r.fromID == itemID ? r.toID : r.fromID
                            VStack(alignment: .leading) {
                                Text("\(r.type.displayName)（\(r.origin == .user ? "我建立" : "建议")）").font(.caption)
                                Text(related[otherID]?.content ?? otherID).lineLimit(2)
                            }
                        }
                    }
                }
                Section("修订历史") {
                    if revisions.isEmpty { Text("尚无修订").foregroundStyle(.secondary) }
                    ForEach(revisions) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("r\(r.number) · \(r.at.formatted(date: .abbreviated, time: .shortened)) · \(r.reason)").font(.caption)
                            Text("之前：\(r.before)").font(.caption2).foregroundStyle(.secondary)
                            Text("之后：\(r.after)").font(.caption2)
                        }
                        .accessibilityIdentifier("brainDetail.revisionRow")
                    }
                }
            }
        }
        .navigationTitle("详情")
        .toolbar {
            Button("修订") { editText = item?.content ?? ""; editReason = ""; editing = true }.accessibilityIdentifier("brainDetail.edit")
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    Section("新内容") {
                        TextField("新内容", text: $editText, axis: .vertical).lineLimit(2...8).accessibilityIdentifier("brainDetail.editText")
                    }
                    Section("修订原因") {
                        TextField("例如：读到了新的证据", text: $editReason).accessibilityIdentifier("brainDetail.editReason")
                    }
                }
                .navigationTitle("修订")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await save(); editing = false } }.accessibilityIdentifier("brainDetail.editSave")
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .task { await reload() }
    }

    private func reload() async {
        let c = app.container
        item = try? await c.brainRepository.item(id: itemID)
        revisions = (try? await c.brain.revisions(itemID: itemID)) ?? []
        relations = (try? await c.brain.relations(itemID: itemID)) ?? []
        for r in relations {
            let other = r.fromID == itemID ? r.toID : r.fromID
            related[other] = try? await c.brainRepository.item(id: other)
        }
    }

    private func save() async {
        guard let item else { return }
        do {
            _ = try await app.container.brain.edit(itemID: item.id, expectedRevision: item.revision, newContent: editText, reason: editReason)
        } catch BrainError.revisionConflict {
            app.banner = .init(message: "内容已在别处被修改，请刷新后再修订。", isError: true)
        } catch {
            app.banner = .init(message: "修订失败：\(error)", isError: true)
        }
        await reload()
    }
}
