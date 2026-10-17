import SwiftUI
import LibraryCore
import ReadingSessionCore
import RetrievalCore
import ContextEngineering
import AgentRuntime
import LearningCore

/// 自测与复习：按已读范围出题、作答反馈、到期复习（LEARN-01…05）。
struct LearningView: View {
    @Environment(AppModel.self) private var app
    @State private var due: [(QuestionPresentation, ReviewSchedule)] = []
    @State private var upcoming: [(QuestionPresentation, ReviewSchedule)] = []
    @State private var generating = false
    @State private var practicing: QuestionPresentation?

    var body: some View {
        NavigationStack {
            List {
                Section("从已读内容出题") {
                    if app.books.isEmpty { Text("先导入并阅读一本书").foregroundStyle(.secondary) }
                    ForEach(app.books.filter { $0.status == .active }) { book in
                        Button {
                            Task { await generate(for: book) }
                        } label: {
                            HStack {
                                Text("为《\(book.title)》出题")
                                Spacer()
                                if generating { ProgressView() }
                            }
                        }
                        .disabled(generating)
                        .accessibilityIdentifier("learning.generate.\(book.title)")
                    }
                }
                Section("今天到期（\(due.count)）") {
                    if due.isEmpty { Text("没有到期的复习").foregroundStyle(.secondary).accessibilityIdentifier("learning.noneDue") }
                    ForEach(due, id: \.0.id) { item, schedule in
                        Button { practicing = item } label: { QuestionRow(item: item, schedule: schedule, timeZone: app.timeZone) }
                            .accessibilityIdentifier("learning.due")
                    }
                }
                Section("之后的复习") {
                    ForEach(upcoming, id: \.0.id) { item, schedule in
                        Button { practicing = item } label: { QuestionRow(item: item, schedule: schedule, timeZone: app.timeZone) }
                            .accessibilityIdentifier("learning.upcoming")
                    }
                }
            }
            .navigationTitle("自测与复习")
            .sheet(item: $practicing, onDismiss: { Task { await reload() } }) { q in PracticeView(question: q) }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        let c = app.container
        due = (try? await c.learning.dueItems(timeZone: app.timeZone)) ?? []
        let dueIDs = Set(due.map(\.0.id))
        var later: [(QuestionPresentation, ReviewSchedule)] = []
        for s in (try? await c.learningRepository.schedules()) ?? [] where !dueIDs.contains(s.itemID) {
            if let item = try? await c.learningRepository.item(id: s.itemID), item.status == .active { later.append((item.presentation, s)) }
        }
        upcoming = later
    }

    /// 只用已读范围内的原文证据出题。
    private func generate(for book: Book) async {
        let availability = await app.availability(.generateQuiz)
        guard availability.isAvailable else {
            if case .pendingNetwork(let m) = availability { app.banner = .init(message: m, isError: true) }
            if case .notConfigured(let m) = availability { app.banner = .init(message: m, isError: true) }
            return
        }
        generating = true
        defer { generating = false }
        let c = app.container
        guard let model = await c.providers.current().chat,
              let state = try? await c.readingRepository.readState(bookID: book.id, version: book.fingerprint) else { return }
        let scope = RetrievalScope([.readOnly(state)])
        guard scope.scopes.values.first?.hasAccessibleContent == true else {
            app.banner = .init(message: "这本书还没有已读内容，读一些再来出题吧。", isError: true)
            return
        }
        let models = await c.providers.current()
        let retriever = HybridRetriever(chunks: c.retrievalStore, lexical: c.retrievalStore, vectors: c.retrievalStore,
                                        embedder: models.embedding, reranker: nil, config: RetrievalConfig(finalLimit: 4, useRerank: false))
        let chapters = (try? await c.bookRepository.chapters(bookID: book.id)) ?? []
        let readChapters = chapters.filter { state.chapters[$0.index]?.isEmpty == false }
        let query = readChapters.map(\.title).joined(separator: " ")
        let units = await retriever.retrieve(queries: [query.isEmpty ? book.title : query], scope: scope).units
        let evidence = ContextAssembler(budgetTokens: 3_000).assemble(units.map { Evidence.fromRetrieval($0, chapterTitle: nil) }, allowedSources: [.bookText]).evidence
        let budget = TaskBudget(limits: .learning, clock: c.environment.clock)
        let executor = BoundedExecutor(budget: budget, clock: c.environment.clock, trace: c.trace, traceID: UUID().uuidString)
        do {
            let parsed = try await c.learning.generate(bookID: book.id, evidence: evidence, scope: scope, count: 2, model: model, executor: executor,
                                                       timeZone: app.timeZone)
            app.banner = .init(message: "已生成 \(parsed.items.count) 道题\(parsed.rejections.isEmpty ? "" : "（\(parsed.rejections.count) 道未通过校验）")", isError: false)
        } catch LearningError.noReadContent {
            app.banner = .init(message: "已读范围内没有可用的原文证据。", isError: true)
        } catch {
            app.banner = .init(message: "出题失败：\(error)。未保存不完整的题目。", isError: true)
        }
        await reload()
    }
}

extension QuestionPresentation: @retroactive Identifiable {}

struct QuestionRow: View {
    let item: QuestionPresentation
    let schedule: ReviewSchedule
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.prompt).lineLimit(2)
            HStack {
                StatusBadge(text: item.type.displayName, color: .blue)
                Text("到期：\(schedule.dueDay.description)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("learning.dueDate")
            }
        }
    }
}

/// 作答页：提交前不显示参考答案；提交后显示反馈、证据与下一次复习时间。
struct PracticeView: View {
    let question: QuestionPresentation
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var answer = ""
    @State private var rating: SelfRating = .good
    @State private var result: (Feedback, ReviewSchedule)?
    @State private var submitting = false
    @State private var key = UUID().uuidString
    @State private var mastery: MasteryRecord?

    var body: some View {
        NavigationStack {
            Form {
                Section("题目") { Text(question.prompt).accessibilityIdentifier("practice.prompt") }
                if let (fb, schedule) = result {
                    Section("反馈") {
                        switch fb.grade {
                        case .scored(let s): Text("得分：\(Int(s * 100))").accessibilityIdentifier("practice.score")
                        case .uncertain(let why): Text("评分不确定：\(why)").foregroundStyle(.orange).accessibilityIdentifier("practice.score")
                        }
                        if !fb.correctPoints.isEmpty { Text("答对：\(fb.correctPoints.joined(separator: "；"))") }
                        if !fb.missingPoints.isEmpty { Text("遗漏：\(fb.missingPoints.joined(separator: "；"))").accessibilityIdentifier("practice.missing") }
                        Text(fb.rationale).font(.caption).foregroundStyle(.secondary)
                    }
                    Section("证据") {
                        ForEach(Array(fb.evidence.enumerated()), id: \.offset) { _, e in
                            Text(e.quote).font(.callout).lineLimit(4).accessibilityIdentifier("practice.evidence")
                        }
                    }
                    Section("复习安排") {
                        Text("下次复习：\(schedule.dueDay.description)").accessibilityIdentifier("practice.nextDue")
                        if let mastery { Text("掌握程度：\(mastery.level.displayName)（共 \(mastery.attempts) 次作答）").accessibilityIdentifier("practice.mastery") }
                    }
                } else {
                    Section("你的答案") {
                        TextField("写下你的理解", text: $answer, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityIdentifier("practice.answer")
                    }
                    Section("自评") {
                        Picker("自评", selection: $rating) {
                            ForEach(SelfRating.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .accessibilityIdentifier("practice.rating")
                    }
                }
            }
            .navigationTitle("自测")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.accessibilityIdentifier("practice.close") }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("提交") { Task { await submit() } }
                            .disabled(submitting)
                            .accessibilityIdentifier("practice.submit")
                    }
                }
            }
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        let c = app.container
        let grader: AnswerGrading
        if let model = await c.providers.current().chat, !app.launch.deterministic {
            let budget = TaskBudget(limits: .learning, clock: c.environment.clock)
            grader = LLMAnswerGrader(model: model, executor: BoundedExecutor(budget: budget, clock: c.environment.clock, trace: c.trace, traceID: key))
        } else {
            grader = HeuristicAnswerGrader()
        }
        do {
            let (_, fb, schedule) = try await c.learning.submit(itemID: question.id, answer: answer, selfRating: rating, idempotencyKey: key,
                                                                grader: grader, timeZone: app.timeZone)
            result = (fb, schedule)
            if let item = try await c.learningRepository.item(id: question.id) {
                mastery = try await c.learningRepository.mastery(knowledgePoint: item.knowledgePoint, bookID: item.bookID)
            }
        } catch {
            app.banner = .init(message: "评分失败：\(error)。答案未提交，可重试。", isError: true)
        }
    }
}
