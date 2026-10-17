import Foundation
import Security
import AgentRuntime

/// 密钥引用：配置中只保存引用，密钥本身在 Keychain（DATA-03）。
public struct SecretReference: Codable, Hashable, Sendable {
    public var service: String
    public var account: String

    public init(service: String = SecretReference.defaultService, account: String) {
        self.service = service; self.account = account
    }

    public static let defaultService = "app.thoughttrail.secrets"
    public static let chat = SecretReference(account: "chat")
    public static let embedding = SecretReference(account: "embedding")
    public static let rerank = SecretReference(account: "rerank")
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case notFound
    case unexpected(OSStatus)
    case invalidValue
}

public protocol SecretStore: Sendable {
    func read(_ ref: SecretReference) throws -> String
    func write(_ value: String, for ref: SecretReference) throws
    func delete(_ ref: SecretReference) throws
    func exists(_ ref: SecretReference) -> Bool
}

/// 系统 Keychain 实现（kSecClassGenericPassword，仅本设备、解锁后可用）。
public struct KeychainSecretStore: SecretStore {
    public init() {}

    func baseQuery(_ ref: SecretReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: ref.service,
         kSecAttrAccount as String: ref.account]
    }

    public func read(_ ref: SecretReference) throws -> String {
        var query = baseQuery(ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw SecretStoreError.notFound }
        guard status == errSecSuccess, let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.unexpected(status)
        }
        return s
    }

    public func write(_ value: String, for ref: SecretReference) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecretStoreError.invalidValue }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(ref) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(ref)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.unexpected(status) }
    }

    public func delete(_ ref: SecretReference) throws {
        let status = SecItemDelete(baseQuery(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.unexpected(status) }
    }

    public func exists(_ ref: SecretReference) -> Bool { (try? read(ref)) != nil }
}

/// 内存实现（测试、UI 自动化的确定性环境）。
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: String] = [:]

    public init(_ initial: [SecretReference: String] = [:]) { values = initial }

    public func read(_ ref: SecretReference) throws -> String {
        try lock.withLock {
            guard let v = values[ref] else { throw SecretStoreError.notFound }
            return v
        }
    }

    public func write(_ value: String, for ref: SecretReference) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecretStoreError.invalidValue }
        lock.withLock { values[ref] = trimmed }
    }

    public func delete(_ ref: SecretReference) throws { lock.withLock { values[ref] = nil } }
    public func exists(_ ref: SecretReference) -> Bool { lock.withLock { values[ref] != nil } }
}

extension SecretStore {
    /// 设置页显示用：只显示掩码。
    public func maskedValue(_ ref: SecretReference) -> String? {
        (try? read(ref)).map(Redactor.mask)
    }
}
