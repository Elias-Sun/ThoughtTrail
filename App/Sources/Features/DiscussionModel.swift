import SwiftUI
import Observation
import LibraryCore
import ReadingSessionCore
import ReflectionCore
import ContextEngineering
import BrainCore
import AgentRuntime
import ReaderAgent
import EvidenceVerificationCore

/// 讨论页状态：消息、流式草稿、核查状态、范围、取消与重试。
@MainActor
@Observable
final class DiscussionModel {
    let app: AppModel
    let book: Book
    var conversation: Conversation?
    var messages: [Message] = []
    var input = ""
    var running = false
    var liveStatus: MessageStatus?
    var liveDraft = ""
    var liveEvidence: [Evidence] = []
    var livePolicy: PolicySummary?
    var scopeMode: ScopeMode = .readOnly
    var proposals: [String: [MemoryProposal]] = [:]
    var proposalError: String?
    var selection: SelectionContext?
    private var orchestrator: DiscussionOrchestrator?
    private var currentKey: String?
    private var runTask: Task<Void, Never>?

    init(app: AppModel, book: Book) {
        self.app = app
        self.book = book
    }

    func start(context: ReadingContextSnapshot, selection: SelectionContext?, existing: Conversation? = nil) async {
        self.selection = selection
        orchestrator = await app.container.makeOrchestrator()
        if let existing {
            conversation = existing
            scopeMode = existing.scopeMode
            await reload()
        } else {
            conversation = try? await app.container.conversations.startConversation(context: context)
        }
    }

    func reload() async {
        guard let c = conversation else { return }
        messages = (try? await app.container.reflectionRepository.messages(conversationID: c.id)) ?? []
    }

    /// 切换范围（界面与执行记录均可见）。
    func setScope(_ mode: ScopeMode) async {
        guard let c = conversation else { return }
        conversation = try? await app.container.conversations.setScope(conversationID: c.id, mode: mode)
        scopeMode = mode
    }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !running, let c = conversation else { return }
        input = ""
        runTask = Task {
            do {
                let user = try await app.container.conversations.addUserMessage(conversationID: c.id, text: question)
                await reload()
                await execute(userMessageID: user.id)
            } catch {
                app.banner = .init(message: "无法发送：\(error.localizedDescription)", isError: true)
            }
        }
    }

    func retry(_ failed: Message) {
        guard let userID = failed.replyTo, !running else { return }
        runTask = Task { await execute(userMessageID: userID) }
    }

    private func execute(userMessageID: String) async {
        guard let c = conversation, let orchestrator else { return }
        running = true
        liveStatus = .preparing
        liveDraft = ""
        liveEvidence = []
        let request = DiscussionRequest(conversationID: c.id, userMessageID: userMessageID, selection: selection)
        currentKey = request.requestKey
        do {
            _ = try await orchestrator.run(request) { [weak self] event in
                await MainActor.run { self?.apply(event) }
            }
        } catch {
            app.banner = .init(message: "讨论未能开始：\(error)", isError: true)
        }
        selection = nil
        running = false
        liveStatus = nil
        currentKey = nil
        await reload()
    }

    private func apply(_ event: DiscussionEvent) {
        switch event {
        case .started: break
        case .status(let s): liveStatus = s
        case .policy(let p): livePolicy = p
        case .evidence(let e): liveEvidence = e
        case .delta(let d): liveDraft += d
        case .revised(let t): liveDraft = t
        case .verification: break
        case .finished: break
        }
    }

    /// 取消：界面立即退出等待状态；草稿保留（10.1）。
    func cancel() async {
        guard let key = currentKey, let orchestrator else { return }
        _ = await orchestrator.cancel(requestKey: key)
        running = false
        liveStatus = nil
        await reload()
    }

    func proposeMemories(for message: Message) async {
        guard let orchestrator else { return }
        proposalError = nil
        do {
            proposals[message.id] = try await orchestrator.proposeMemories(messageID: message.id)
            if proposals[message.id]?.isEmpty == true { proposalError = "这次讨论没有需要记住的新内容。" }
        } catch let e as ProviderError {
            proposalError = "生成记忆建议失败：\(e.userMessage)（可重试）"
        } catch {
            proposalError = "生成记忆建议失败：\(error.localizedDescription)（可重试）"
        }
    }

    func decide(_ proposal: MemoryProposal, confirm: Bool, messageID: String) async {
        do {
            let updated = confirm ? try await app.container.brain.confirm(proposalID: proposal.id) : try await app.container.brain.reject(proposalID: proposal.id)
            if let i = proposals[messageID]?.firstIndex(where: { $0.id == proposal.id }) { proposals[messageID]?[i] = updated }
            app.banner = .init(message: confirm ? "已写入长期记忆" : "已拒绝，不会写入", isError: false)
        } catch {
            app.banner = .init(message: "无法处理提议：\(error)", isError: true)
            if let fresh = try? await app.container.brainRepository.proposal(id: proposal.id),
               let i = proposals[messageID]?.firstIndex(where: { $0.id == proposal.id }) { proposals[messageID]?[i] = fresh }
        }
    }

    func openCitation(_ c: CitationSnapshot) {
        guard let bookID = c.bookID, c.structurallyValid else { return }
        app.openRequest = .init(bookID: bookID, locator: c.locator)
    }
}
