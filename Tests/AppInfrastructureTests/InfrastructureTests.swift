import Testing
import Foundation
@testable import AppInfrastructure
import LibraryCore
import ReadingSessionCore
import ReflectionCore
import SpeechCore
import RetrievalCore
import BrainCore
import AgentRuntime
import ReaderAgent
import ModelProviders
import EvidenceVerificationCore
import Persistence
import TestSupport

private func testEnvironment(overrides: ProviderOverrides? = nil, secrets: SecretStore = InMemorySecretStore(),
                             transport: HTTPTransport = StubTransport()) -> AppEnvironment {
    AppEnvironment(databaseURL: nil, booksDirectory: nil, secrets: secrets, transport: transport, clock: ManualClock(),
                   ids: SequentialIDGenerator(), timeZone: { TimeZone(identifier: "UTC")! }, fallbackJudge: nil, overrides: overrides)
}

@Suite("M14 凭据与配置")
struct ConfigurationTests {
    @Test("DATA-03 内存密钥存储读写删除，空值被拒绝，设置页只显示掩码")
    func inMemorySecrets() throws {
        let s = InMemorySecretStore()
        #expect(throws: SecretStoreError.invalidValue) { try s.write("  ", for: .chat) }
        try s.write(" sk-abcdefgh12345678 ", for: .chat)
        #expect(try s.read(.chat) == "sk-abcdefgh12345678")
        #expect(s.maskedValue(.chat) == "••••••••5678")
        try s.delete(.chat)
        #expect(throws: SecretStoreError.notFound) { try s.read(.chat) }
        #expect(!s.exists(.chat))
    }

    @Test("DATA-03 系统 Keychain 存储往返（本机钥匙串）")
    func keychainRoundTrip() throws {
        let store = KeychainSecretStore()
        let ref = SecretReference(service: "app.thoughttrail.tests", account: "t-\(UUID().uuidString)")
        defer { try? store.delete(ref) }
        try store.write("sk-keychain-test-0001", for: ref)
        #expect(try store.read(ref) == "sk-keychain-test-0001")
        try store.write("sk-keychain-test-0002", for: ref)
        #expect(try store.read(ref) == "sk-keychain-test-0002")
        try store.delete(ref)
        #expect(!store.exists(ref))
    }

    @Test("DATA-03 配置校验：必须 HTTPS、模型非空、维度合理")
    func validation() {
        var c = ProviderConfiguration.dashscopeDefault()
        #expect(c.validate().isEmpty)
        c.chat?.baseURL = "http://insecure.example.com/v1"
        c.embedding?.dimensions = 3
        c.rerank?.model = " "
        #expect(c.validate() == [.insecureURL("chat"), .invalidDimensions(3), .emptyModel("rerank")])
        c.chat?.baseURL = "not a url"
        #expect(c.validate().contains(.invalidURL("chat")))
    }

    @Test("RAG-05 判断向量模型/维度是否变化")
    func profileChange() {
        let a = ProviderConfiguration.dashscopeDefault()
        var b = a
        b.chat?.model = "qwen-max"
        #expect(!b.embeddingProfileChanged(from: a))
        b.embedding?.dimensions = 512
        #expect(b.embeddingProfileChanged(from: a))
    }

    @Test("DATA-03 Provider 按需从密钥存储读取密钥；三类接口分别构造")
    func factoryUsesSecrets() async throws {
        let secrets = InMemorySecretStore([.chat: "sk-chat-1234567890", .embedding: "sk-emb-1234567890"])
        let t = StubTransport([.response(200, #"{"choices":[{"message":{"content":"好"},"finish_reason":"stop"}]}"#, [:])])
        let f = ProviderFactory(secrets: secrets, transport: t)
        let config = ProviderConfiguration.dashscopeDefault()
        let chat = try #require(f.chatModel(config))
        _ = try await chat.complete(ChatRequest(messages: [.user("hi")]))
        #expect(t.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-chat-1234567890")
        #expect(f.embeddingService(config)?.profile == EmbeddingProfile(model: "text-embedding-v4", dimensions: 1024))
        let rerank = try #require(f.rerankService(config))
        await #expect(throws: ProviderError.notConfigured("API 密钥")) { try await rerank.rerank(query: "q", documents: ["a", "b"], topN: 1) }
    }

    @Test("DATA-03 规划/复核模型可单独指定；关闭的接口不构造")
    func roles() {
        var c = ProviderConfiguration.dashscopeDefault(chatModel: "qwen-plus")
        c.chat?.verifierModel = "qwen-max"
        c.rerank?.enabled = false
        let f = ProviderFactory(secrets: InMemorySecretStore(), transport: StubTransport())
        #expect(f.chatModel(c, role: .verifier)?.modelID == "qwen-max")
        #expect(f.chatModel(c, role: .planner)?.modelID == "qwen-plus")
        #expect(f.rerankService(c) == nil)
    }

    @Test("DATA-03 保存配置不包含密钥；非法配置被拒绝；向量维度变化提示重建")
    func providerHub() async throws {
        let container = try AppContainer(environment: testEnvironment())
        let hub = container.providers
        #expect(try await hub.save(.dashscopeDefault()) == true)
        var bad = ProviderConfiguration.dashscopeDefault(); bad.chat?.baseURL = "http://x.com"
        await #expect(throws: ConfigurationError.self) { try await hub.save(bad) }
        var changed = ProviderConfiguration.dashscopeDefault(); changed.embedding?.dimensions = 768
        #expect(try await hub.save(changed) == true)
        #expect(try await hub.save(changed) == false)
        let raw = try #require(try await container.runtimeStore.setting("provider_config"))
        #expect(!raw.contains("sk-"))
        #expect(await hub.configuration().embedding?.dimensions == 768)
    }
}

@Suite("M14 装配、生命周期与策略")
struct ContainerTests {
    @Test("10.3 启动恢复：结束遗留会话、标记中断任务、进行中回答标记失败")
    func launchRecovery() async throws {
        let c = try AppContainer(environment: testEnvironment())
        try await c.readingRepository.saveSession(ReadingSession(id: "s", bookID: "b", startedAt: Date()))
        _ = try await c.tasks.begin(kind: .discussion, idempotencyKey: "k")
        let book = try await c.library.importBook(data: Fixtures.enBook(), fileName: "en.epub").book
        let ctx = ReadingContextSnapshot(bookID: book.id, bookVersion: book.fingerprint, bookTitle: book.title, chapterIndex: nil,
                                         chapterTitle: nil, locator: nil, selectedText: nil, sessionID: nil, capturedAt: Date())
        let conv = try await c.conversations.startConversation(context: ctx)
        try await c.reflectionRepository.save(Message(id: "m", conversationID: conv.id, role: .assistant, text: "草稿", status: .drafting,
                                                     createdAt: Date(), updatedAt: Date()))
        let r = try await c.recoverOnLaunch()
        #expect(r == LaunchRecovery(endedSessions: 1, interruptedTasks: 1, failedMessages: 1))
        #expect(try await c.reflectionRepository.message(id: "m")?.text == "草稿")
    }

    @Test("LIB-04 删除书籍后记忆中的原文证据被标记失效")
    func lifecycleBridge() async throws {
        let c = try AppContainer(environment: testEnvironment())
        await c.registerLifecycleObservers()
        let book = try await c.library.importBook(data: Fixtures.zhBook(), fileName: "zh.epub").book
        let item = try await c.brain.create(kind: .memory, content: "间隔复习",
                                            evidence: [.book(book.id, version: book.fingerprint, chapter: 1, range: TextSpan(start: 0, end: 5), quote: "q")])
        try await c.library.delete(bookID: book.id, policy: .removeFileKeepNotes)
        #expect(try await c.brainRepository.item(id: item.id)?.evidence.first?.isValid == false)
    }

    @Test("DATA-04 离线时本地操作可用，在线模型操作显示待处理；未配置时显示不可用")
    func offlinePolicy() {
        #expect(OfflinePolicy.availability(of: .annotate, online: false, chatConfigured: false, embeddingConfigured: false) == .available)
        #expect(OfflinePolicy.availability(of: .reflectText, online: false, chatConfigured: true, embeddingConfigured: true).isAvailable)
        if case .pendingNetwork = OfflinePolicy.availability(of: .discuss, online: false, chatConfigured: true, embeddingConfigured: true) {} else { Issue.record("应待联网") }
        if case .notConfigured = OfflinePolicy.availability(of: .generateQuiz, online: true, chatConfigured: false, embeddingConfigured: true) {} else { Issue.record("应未配置") }
        if case .notConfigured = OfflinePolicy.availability(of: .embedIndex, online: true, chatConfigured: true, embeddingConfigured: false) {} else { Issue.record("应未配置") }
    }

    @Test("REF-03 权限状态映射为用户指引，始终允许文字降级")
    func permissionMapping() {
        let denied = PermissionMapper.microphone(.denied)
        #expect(denied.opensSettings && !denied.canRequest && denied.allowsTextFallback)
        #expect(PermissionMapper.microphone(.notDetermined).canRequest)
        #expect(PermissionMapper.speech(.restricted).message.contains("文字输入"))
        #expect([PermissionState.granted, .denied, .notDetermined, .restricted].allSatisfy { PermissionMapper.speech($0).allowsTextFallback })
    }

    @Test("7.3 数据处理说明覆盖云向量、讨论上传与密钥存放")
    func dataNotice() {
        #expect(DataProcessingNotice.text.contains("已读文本会发送"))
        #expect(DataProcessingNotice.text.contains("钥匙串"))
    }

    @Test("CHAT-01 装配的讨论编排器使用当前（覆盖的）模型配置完成一次讨论")
    func orchestratorWiring() async throws {
        let model = ScriptedChatModel(fallback: .text("精读与泛读各有用处[E1, E2, E3]。"))
        let c = try AppContainer(environment: AppEnvironment(databaseURL: nil, booksDirectory: nil, secrets: InMemorySecretStore(),
                                                             clock: ManualClock(), ids: SequentialIDGenerator(), fallbackJudge: HeuristicClaimJudge(),
                                                             overrides: ProviderOverrides(chat: model, embedding: nil, rerank: nil)))
        let book = try await c.library.importBook(data: Fixtures.zhBook(), fileName: "zh.epub").book
        try await c.indexing.ensureLexical(bookID: book.id, profile: nil)
        try await c.readingRepository.addReadRange(bookID: book.id, version: book.fingerprint, chapterIndex: 0, range: TextSpan(start: 0, end: 200))
        let ctx = ReadingContextSnapshot(bookID: book.id, bookVersion: book.fingerprint, bookTitle: book.title, chapterIndex: 0, chapterTitle: nil,
                                         locator: nil, selectedText: nil, sessionID: nil, capturedAt: Date())
        let conv = try await c.conversations.startConversation(context: ctx)
        let user = try await c.conversations.addUserMessage(conversationID: conv.id, text: "精读与泛读有什么用处？")
        let m = try await c.makeOrchestrator().run(DiscussionRequest(conversationID: conv.id, userMessageID: user.id))
        #expect(m.status == .verified)
        #expect(!(try await c.runtimeStore.traceEvents(traceID: m.traceID!)).isEmpty)
    }

    @Test("7.3 索引协调：只对已读范围向量化，同一本书并发触发只执行一次")
    func indexingCoordinator() async throws {
        let c = try AppContainer(environment: testEnvironment())
        let book = try await c.library.importBook(data: Fixtures.zhBook(), fileName: "zh.epub").book
        try await c.readingRepository.addReadRange(bookID: book.id, version: book.fingerprint, chapterIndex: 0, range: TextSpan(start: 0, end: 500))
        let emb = HashEmbeddingService(dimensions: 16)
        async let a = c.indexing.embedReadContent(bookID: book.id, service: emb)
        async let b = c.indexing.embedReadContent(bookID: book.id, service: emb)
        let results = try await [a, b]
        #expect(results.compactMap { $0 }.count >= 1)
        let embedded = try await c.retrievalStore.embeddedChildIDs(bookID: book.id, profile: emb.profile)
        let ch0 = try await c.retrievalStore.children(bookID: book.id).filter { $0.chapterIndex == 0 }
        #expect(embedded == Set(ch0.map(\.id)))
    }

    @Test("DATA-02 Markdown 导出汇总全部书籍与记录")
    func markdownExport() async throws {
        let c = try AppContainer(environment: testEnvironment())
        _ = try await c.library.importBook(data: Fixtures.zhBook(), fileName: "zh.epub")
        _ = try await c.brain.create(kind: .question, content: "如何安排精读？")
        let md = try await c.exportMarkdown()
        #expect(md.contains("《阅读之道》") && md.contains("如何安排精读？"))
    }
}
