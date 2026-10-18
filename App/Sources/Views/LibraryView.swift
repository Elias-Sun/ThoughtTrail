import SwiftUI
import UniformTypeIdentifiers
import LibraryCore

extension UTType {
    static let epub = UTType(importedAs: "org.idpf.epub-container", conformingTo: .data)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var pendingDelete: Book?
    @State private var path: [BookID] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Group {
                if model.books.isEmpty && model.librarySearch.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(title: "书库是空的", message: "导入一本 EPUB，开始阅读与思考。", systemImage: "book.closed")
                        Button("导入 EPUB") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("library.empty.import")
                        if model.launch.deterministic {
                            sampleMenu
                        }
                    }
                } else {
                    List {
                        ForEach(model.books) { book in
                            NavigationLink(value: book.id) { BookRow(book: book, indexStatus: model.indexing[book.id]) }
                                .accessibilityIdentifier("library.book.\(book.title)")
                                .swipeActions {
                                    Button("删除", role: .destructive) { pendingDelete = book }
                                        .accessibilityIdentifier("library.delete")
                                }
                                .contextMenu {
                                    Button("删除…", systemImage: "trash", role: .destructive) { pendingDelete = book }
                                }
                        }
                    }
                    .accessibilityIdentifier("library.list")
                    .searchable(text: $model.librarySearch, prompt: "搜索书名或作者")
                    .onChange(of: model.librarySearch) { _, _ in Task { await model.reloadBooks() } }
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $model.librarySort) {
                            Text("最近打开").tag(LibrarySort.recentlyOpened)
                            Text("书名").tag(LibrarySort.title)
                            Text("作者").tag(LibrarySort.author)
                            Text("进度").tag(LibrarySort.progress)
                            Text("导入时间").tag(LibrarySort.importedAt)
                        }
                    } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                    .onChange(of: model.librarySort) { _, _ in Task { await model.reloadBooks() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Label("导入", systemImage: "plus") }
                        .accessibilityIdentifier("library.import")
                }
                if model.launch.deterministic && !model.books.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { sampleMenu }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await model.importEPUB(at: url) }
                }
            }
            .confirmationDialog("删除《\(pendingDelete?.title ?? "")》", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("仅删除阅读文件（保留笔记）") {
                    if let b = pendingDelete { Task { await model.delete(b, policy: .removeFileKeepNotes) } }
                }
                .accessibilityIdentifier("library.delete.keepNotes")
                Button("彻底删除（含批注、反思、讨论与索引）", role: .destructive) {
                    if let b = pendingDelete { Task { await model.delete(b, policy: .purgeEverything) } }
                }
                .accessibilityIdentifier("library.delete.purge")
            } message: {
                Text("保留笔记时，原文引用会标记为“来源不可访问”。重新导入同一文件可以恢复。")
            }
            .navigationDestination(for: BookID.self) { id in
                if let book = model.books.first(where: { $0.id == id }) {
                    ReaderView(book: book)
                }
            }
            .onChange(of: model.openRequest) { _, request in
                guard let request else { return }
                path = [request.bookID]
            }
            .onChange(of: model.closeReaderRequest) { _, request in
                if request != nil { path = [] }
            }
        }
    }

    /// 内置示例书（仅确定性/演示模式）：用于自动化测试与离线演示。
    private var sampleMenu: some View {
        Menu("示例书") {
            Button("导入《阅读之道》") { Task { await model.importBundled("sample-zh") } }
                .accessibilityIdentifier("sample.zh")
            Button("导入 The Lighthouse Keeper") { Task { await model.importBundled("sample-en") } }
                .accessibilityIdentifier("sample.en")
            Button("导入损坏的 EPUB") { Task { await model.importBundled("sample-corrupt") } }
                .accessibilityIdentifier("sample.corrupt")
        }
        .accessibilityIdentifier("library.samples")
    }
}

struct BookRow: View {
    let book: Book
    let indexStatus: String?
    @Environment(AppModel.self) private var model
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.accentColor.opacity(0.15)
                        Text(String(book.title.prefix(1))).font(.title2.bold()).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.authorLine).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ProgressView(value: book.displayProgress).frame(maxWidth: 120)
                    Text("\(Int(book.displayProgress * 100))%").font(.caption).foregroundStyle(.secondary)
                    if book.status == .sourceUnavailable {
                        StatusBadge(text: "来源不可访问", color: .orange)
                    }
                }
                if let indexStatus {
                    Text(indexStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: book.id) {
            if book.hasCover, let data = try? await model.container.files.loadCover(for: book.id) { cover = UIImage(data: data) }
        }
    }
}
