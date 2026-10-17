import SwiftUI
import LibraryCore
import ReaderCore
import ReflectionCore

struct ReaderView: View {
    let book: Book
    @Environment(AppModel.self) private var app
    @State private var model: ReaderModel?
    @State private var sheet: Sheet?
    @State private var noteDraft = ""

    enum Sheet: Identifiable {
        case toc, annotations, appearance, note, discussion, reflection
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView("正在打开…")
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if model == nil {
                let m = ReaderModel(book: book, app: app)
                model = m
                let initial = app.openRequest?.bookID == book.id ? app.openRequest?.locator : nil
                await m.load(initial: initial)
                if app.openRequest?.bookID == book.id { app.openRequest = nil }
            }
        }
        .onChange(of: app.openRequest) { _, request in
            guard let request, request.bookID == book.id, let model else { return }
            sheet = nil
            if let l = request.locator { Task { await model.open(l) } }
            app.openRequest = nil
        }
        .onDisappear { if let model { Task { await model.close() } } }
    }

    @ViewBuilder
    private func content(_ model: ReaderModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                EmptyStateView(title: "无法阅读", message: error, systemImage: "exclamationmark.triangle")
            } else if let chapter = model.currentChapter {
                ReaderTextView(chapter: chapter, highlights: model.highlights, preferences: model.preferences, selection: $model.selection,
                               jump: model.jump, pageCommand: model.pageCommand,
                               onVisibleRange: { model.visibleRangeChanged($0) },
                               onMenuAction: { handleMenu($0, model) },
                               onPageBoundary: { forward in forward ? model.nextChapter() : model.previousChapter() })
                    .background(ReaderPalette.background(model.preferences.theme))
                bottomBar(model, chapter: chapter)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .toc } label: { Label("目录", systemImage: "list.bullet") }
                    .accessibilityIdentifier("reader.toc")
                Button { Task { await model.toggleBookmark() } } label: {
                    Label("书签", systemImage: model.isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .accessibilityIdentifier("reader.bookmark")
                Menu {
                    Button("字体与主题", systemImage: "textformat.size") { sheet = .appearance }
                        .accessibilityIdentifier("reader.appearance")
                    Button("批注列表", systemImage: "highlighter") { sheet = .annotations }
                        .accessibilityIdentifier("reader.annotations")
                    Button("选择本页首段", systemImage: "text.cursor") { model.selectFirstParagraphOnPage() }
                        .accessibilityIdentifier("reader.selectParagraph")
                    Button("将本页记为已读", systemImage: "checkmark.circle") { Task { await model.markPageRead() } }
                        .accessibilityIdentifier("reader.markRead")
                    Divider()
                    Button("讨论这一章", systemImage: "bubble.left.and.text.bubble.right") { sheet = .discussion }
                        .accessibilityIdentifier("reader.discussChapter")
                    Button("记录反思", systemImage: "square.and.pencil") { sheet = .reflection }
                        .accessibilityIdentifier("reader.reflect")
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("reader.more")
            }
        }
        .safeAreaInset(edge: .top) {
            if model.selection != nil { selectionBar(model) }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .toc: TOCSheet(model: model) { sheet = nil }
            case .annotations: AnnotationListSheet(model: model) { sheet = nil }
            case .appearance: AppearanceSheet(model: model)
            case .note: noteSheet(model)
            case .discussion: DiscussionSheet(reader: model)
            case .reflection: ReflectionSheet(reader: model)
            }
        }
    }

    private func handleMenu(_ action: ReaderTextView.MenuAction, _ model: ReaderModel) {
        switch action {
        case .highlight: Task { await model.addHighlight() }
        case .note: noteDraft = ""; sheet = .note
        case .ask: sheet = .discussion
        case .reflect: sheet = .reflection
        }
    }

    /// 选区操作条（菜单之外的可访问入口）。
    private func selectionBar(_ model: ReaderModel) -> some View {
        HStack {
            Button("高亮") { Task { await model.addHighlight() } }.accessibilityIdentifier("selection.highlight")
            Button("批注") { noteDraft = ""; sheet = .note }.accessibilityIdentifier("selection.note")
            Button("提问") { sheet = .discussion }.accessibilityIdentifier("selection.ask")
            Button("反思") { sheet = .reflection }.accessibilityIdentifier("selection.reflect")
            Spacer()
            Button { model.selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("取消选择")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func bottomBar(_ model: ReaderModel, chapter: Chapter) -> some View {
        HStack {
            Button { model.pageCommand = .init(forward: false) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("上一页")
                .accessibilityIdentifier("reader.prevPage")
            Spacer()
            VStack(spacing: 2) {
                Text(chapter.title).font(.caption).lineLimit(1).accessibilityIdentifier("reader.chapterTitle")
                Text("\(chapter.index + 1)/\(model.chapters.count)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.pageCommand = .init(forward: true) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("下一页")
                .accessibilityIdentifier("reader.nextPage")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func noteSheet(_ model: ReaderModel) -> some View {
        NavigationStack {
            Form {
                if let sel = model.selection, let ch = model.currentChapter {
                    Section("选中的原文") { Text(ch.text.substring(utf16: sel)).font(.callout) }
                }
                Section("笔记") {
                    TextField("写下你的批注", text: $noteDraft, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("note.field")
                }
            }
            .navigationTitle("批注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await model.addHighlight(note: noteDraft); sheet = nil }
                    }
                    .accessibilityIdentifier("note.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct TOCSheet: View {
    let model: ReaderModel
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("目录") {
                    ForEach(Array(model.toc.enumerated()), id: \.offset) { _, entry in
                        Button {
                            model.go(to: entry); dismiss()
                        } label: {
                            Text(entry.title).padding(.leading, CGFloat(entry.level) * 16)
                        }
                        .disabled(entry.chapterIndex == nil)
                    }
                }
                if !model.bookmarks.isEmpty {
                    Section("书签") {
                        ForEach(model.bookmarks) { b in
                            Button(b.title) {
                                Task { await model.open(b.locator, select: false) }
                                dismiss()
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("toc.list")
            .navigationTitle("目录与书签")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: dismiss) } }
        }
    }
}

struct AnnotationListSheet: View {
    let model: ReaderModel
    let dismiss: () -> Void
    @State private var editing: Annotation?
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                if model.annotations.isEmpty {
                    Text("还没有批注。选中文字后点“高亮”或“批注”。").foregroundStyle(.secondary)
                }
                ForEach(model.annotations) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.quote).font(.callout).lineLimit(3)
                        if let note = a.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        Text(model.chapters.first { $0.index == a.locator.chapterIndex }?.title ?? "").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await model.open(a.locator) }
                        dismiss()
                    }
                    .accessibilityIdentifier("annotation.row")
                    .swipeActions {
                        Button("删除", role: .destructive) { Task { await model.deleteAnnotation(a) } }
                            .accessibilityIdentifier("annotation.delete")
                        Button("编辑") { editing = a; text = a.note ?? "" }
                            .accessibilityIdentifier("annotation.edit")
                    }
                }
            }
            .navigationTitle("批注")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: dismiss) } }
            .sheet(item: $editing) { e in
                NavigationStack {
                    Form {
                        Section("原文") { Text(e.quote).font(.callout) }
                        Section("笔记") {
                            TextField("笔记", text: $text, axis: .vertical)
                                .lineLimit(2...8)
                                .accessibilityIdentifier("annotation.editField")
                        }
                    }
                    .navigationTitle("编辑笔记")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                Task { await model.updateNote(e, note: text); editing = nil }
                            }
                            .accessibilityIdentifier("annotation.editSave")
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

struct AppearanceSheet: View {
    let model: ReaderModel

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("字号") {
                    HStack {
                        Button { model.preferences.decreaseFont(); model.savePreferences() } label: { Image(systemName: "textformat.size.smaller") }
                            .accessibilityIdentifier("appearance.smaller")
                            .accessibilityLabel("减小字号")
                        Spacer()
                        Text("\(Int(model.preferences.fontSize)) pt").accessibilityIdentifier("appearance.fontSize")
                        Spacer()
                        Button { model.preferences.increaseFont(); model.savePreferences() } label: { Image(systemName: "textformat.size.larger") }
                            .accessibilityIdentifier("appearance.larger")
                            .accessibilityLabel("增大字号")
                    }
                    .buttonStyle(.bordered)
                }
                Section("主题") {
                    Picker("主题", selection: $model.preferences.theme) {
                        Text("明亮").tag(ReaderTheme.light)
                        Text("护眼").tag(ReaderTheme.sepia)
                        Text("深色").tag(ReaderTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearance.theme")
                    .onChange(of: model.preferences.theme) { _, _ in model.savePreferences() }
                }
            }
            .navigationTitle("字体与主题")
        }
        .presentationDetents([.medium])
    }
}
