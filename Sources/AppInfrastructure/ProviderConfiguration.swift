import Foundation
import AgentRuntime
import RetrievalCore
import ModelProviders

/// 模型服务配置（不含密钥）。对话、向量、重排分别配置与检测（DATA-03）。
public struct ProviderConfiguration: Codable, Hashable, Sendable {
    public struct Chat: Codable, Hashable, Sendable {
        public var baseURL: String
        public var model: String
        /// 规划/复核可用不同模型；为空则复用 `model`。
        public var plannerModel: String?
        public var verifierModel: String?
        public var secret: SecretReference
        public var enabled: Bool

        public init(baseURL: String, model: String, plannerModel: String? = nil, verifierModel: String? = nil,
                    secret: SecretReference = .chat, enabled: Bool = true) {
            self.baseURL = baseURL; self.model = model; self.plannerModel = plannerModel
            self.verifierModel = verifierModel; self.secret = secret; self.enabled = enabled
        }
    }

    public struct Embedding: Codable, Hashable, Sendable {
        public var baseURL: String
        public var model: String
        public var dimensions: Int
        public var batchSize: Int
        public var secret: SecretReference
        public var enabled: Bool

        public init(baseURL: String, model: String, dimensions: Int, batchSize: Int = 10, secret: SecretReference = .embedding, enabled: Bool = true) {
            self.baseURL = baseURL; self.model = model; self.dimensions = dimensions; self.batchSize = batchSize
            self.secret = secret; self.enabled = enabled
        }
    }

    public struct Rerank: Codable, Hashable, Sendable {
        public var baseURL: String
        public var model: String
        public var wireProtocol: DashScopeRerankProvider.WireProtocol
        public var secret: SecretReference
        public var enabled: Bool

        public init(baseURL: String, model: String, wireProtocol: DashScopeRerankProvider.WireProtocol = .native,
                    secret: SecretReference = .rerank, enabled: Bool = true) {
            self.baseURL = baseURL; self.model = model; self.wireProtocol = wireProtocol; self.secret = secret; self.enabled = enabled
        }
    }

    public var chat: Chat?
    public var embedding: Embedding?
    public var rerank: Rerank?

    public init(chat: Chat? = nil, embedding: Embedding? = nil, rerank: Rerank? = nil) {
        self.chat = chat; self.embedding = embedding; self.rerank = rerank
    }

    /// 百炼（北京）默认：千问对话 + text-embedding-v4 + qwen3-rerank。对话模型 ID 需在联调时冻结。
    public static func dashscopeDefault(chatModel: String = "qwen-plus") -> ProviderConfiguration {
        ProviderConfiguration(
            chat: Chat(baseURL: ProviderPresets.dashscopeBeijingCompatible.absoluteString, model: chatModel),
            embedding: Embedding(baseURL: ProviderPresets.dashscopeBeijingCompatible.absoluteString,
                                 model: ProviderPresets.defaultEmbeddingModel, dimensions: ProviderPresets.defaultEmbeddingDimensions),
            rerank: Rerank(baseURL: ProviderPresets.dashscopeBeijingNative.absoluteString, model: ProviderPresets.defaultRerankModel))
    }

    public enum ValidationIssue: Equatable, Sendable {
        case insecureURL(String)
        case invalidURL(String)
        case emptyModel(String)
        case invalidDimensions(Int)
        case invalidBatchSize(Int)
    }

    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func checkURL(_ s: String, _ name: String) {
            guard let u = URL(string: s), let scheme = u.scheme, u.host != nil else { issues.append(.invalidURL(name)); return }
            if scheme != "https" { issues.append(.insecureURL(name)) }
        }
        if let c = chat {
            checkURL(c.baseURL, "chat")
            if c.model.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyModel("chat")) }
        }
        if let e = embedding {
            checkURL(e.baseURL, "embedding")
            if e.model.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyModel("embedding")) }
            if !(64...4096).contains(e.dimensions) { issues.append(.invalidDimensions(e.dimensions)) }
            if !(1...64).contains(e.batchSize) { issues.append(.invalidBatchSize(e.batchSize)) }
        }
        if let r = rerank {
            checkURL(r.baseURL, "rerank")
            if r.model.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyModel("rerank")) }
        }
        return issues
    }

    /// 向量配置是否变化（模型或维度变化需要重建向量索引）。
    public func embeddingProfileChanged(from old: ProviderConfiguration) -> Bool {
        embedding.map { EmbeddingProfile(model: $0.model, dimensions: $0.dimensions) }
            != old.embedding.map { EmbeddingProfile(model: $0.model, dimensions: $0.dimensions) }
    }
}

/// 根据配置构造 Provider。密钥按需从 SecretStore 读取，不缓存在内存配置中。
public struct ProviderFactory: Sendable {
    public let secrets: SecretStore
    public let transport: HTTPTransport

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets; self.transport = transport
    }

    func endpoint(_ base: String, model: String, secret: SecretReference) -> ProviderEndpoint? {
        guard let url = URL(string: base) else { return nil }
        let secrets = self.secrets
        return ProviderEndpoint(baseURL: url, model: model) { try secrets.read(secret) }
    }

    public func chatModel(_ config: ProviderConfiguration, role: ChatRoleKind = .generator) -> ChatModel? {
        guard let c = config.chat, c.enabled else { return nil }
        let model: String
        switch role {
        case .generator: model = c.model
        case .planner: model = c.plannerModel?.isEmpty == false ? c.plannerModel! : c.model
        case .verifier: model = c.verifierModel?.isEmpty == false ? c.verifierModel! : c.model
        }
        return endpoint(c.baseURL, model: model, secret: c.secret).map { OpenAICompatibleChatProvider(endpoint: $0, transport: transport) }
    }

    public func embeddingService(_ config: ProviderConfiguration) -> EmbeddingService? {
        guard let e = config.embedding, e.enabled, let ep = endpoint(e.baseURL, model: e.model, secret: e.secret) else { return nil }
        return DashScopeEmbeddingProvider(endpoint: ep, dimensions: e.dimensions, maxBatchSize: e.batchSize, transport: transport)
    }

    public func rerankService(_ config: ProviderConfiguration) -> RerankService? {
        guard let r = config.rerank, r.enabled, let ep = endpoint(r.baseURL, model: r.model, secret: r.secret) else { return nil }
        return DashScopeRerankProvider(endpoint: ep, protocolStyle: r.wireProtocol, transport: transport)
    }

    /// 三类接口分别检测（设置页“检测连接”）。
    public func checkAll(_ config: ProviderConfiguration) async -> [ConnectionCheckResult] {
        var out: [ConnectionCheckResult] = []
        if let chat = chatModel(config) { out.append(await ConnectionChecker.checkChat(chat)) }
        if let emb = embeddingService(config) { out.append(await ConnectionChecker.checkEmbedding(emb)) }
        if let rr = rerankService(config) { out.append(await ConnectionChecker.checkRerank(rr)) }
        return out
    }
}

public enum ChatRoleKind: String, Sendable {
    case generator, planner, verifier
}
