import Foundation
import Security

protocol KeychainClient {
    func read(service: String, account: String) throws -> String?
    func create(value: String, service: String, account: String) throws
    func update(value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

extension KeychainClient {
    // Phase 2 test doubles that only exercise reads/writes remain source
    // compatible; production and uninstall-capable clients override this.
    func delete(service: String, account: String) throws {
        throw KeychainStoreError.operationFailed(-1)
    }
}

enum KeychainStoreError: Error, Equatable, LocalizedError, Sendable {
    case itemNotFound
    case invalidValue
    case operationFailed(Int)
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "The requested Keychain item was not found."
        case .invalidValue:
            return "The requested Keychain item contains invalid data."
        case let .operationFailed(status):
            return "The Keychain operation failed with status " + String(status) + "."
        case .randomGenerationFailed:
            return "The connector identity could not be generated."
        }
    }
}

struct SystemKeychainClient: KeychainClient {
    func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.operationFailed(Int(status))
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidValue
        }
        return value
    }

    func create(value: String, service: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.operationFailed(Int(status))
        }
    }

    func update(value: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainStoreError.itemNotFound
            }
            throw KeychainStoreError.operationFailed(Int(status))
        }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(Int(status))
        }
    }
}

enum KeychainItem: Codable, Equatable, Hashable, Sendable {
    case connectorToken
    case ngrokAuthtoken
    case telegramSendBotToken
    case telegramSendChatID
    case meridianIngestToken(account: String)
    case meridianIngestTokenAlias
    case meridianTelegramBotToken
    case meridianTelegramWebhookSecret

    static let service = "com.jay.mac-orchestrator"
    static let legacyMeridianIngestService = "com.jay.mac-orchestrator.ingest-token"

    static func key(service: String, account: String) -> String {
        service + "\u{001f}" + account
    }

    var service: String {
        switch self {
        case .connectorToken, .ngrokAuthtoken, .telegramSendBotToken, .telegramSendChatID,
             .meridianIngestTokenAlias, .meridianTelegramBotToken, .meridianTelegramWebhookSecret:
            return Self.service
        case .meridianIngestToken:
            return Self.legacyMeridianIngestService
        }
    }

    var account: String {
        switch self {
        case .connectorToken:
            return "connector-capability-token"
        case .ngrokAuthtoken:
            return "ngrok-agent-authtoken"
        case .telegramSendBotToken:
            return "telegram-send-bot-token"
        case .telegramSendChatID:
            return "telegram-send-chat-id"
        case let .meridianIngestToken(account):
            return account
        case .meridianIngestTokenAlias:
            return "meridian-ingest-token"
        case .meridianTelegramBotToken:
            return "meridian-telegram-bot-token"
        case .meridianTelegramWebhookSecret:
            return "meridian-telegram-webhook-secret"
        }
    }

    var key: String {
        Self.key(service: service, account: account)
    }

    static var currentMeridianIngestToken: KeychainItem {
        .meridianIngestToken(account: NSUserName())
    }
}

struct KeychainStore {
    private let client: KeychainClient
    private let meridianAccount: String

    init(
        client: KeychainClient = SystemKeychainClient(),
        meridianAccount: String = NSUserName()
    ) {
        self.client = client
        self.meridianAccount = meridianAccount
    }

    static func connectorToken() throws -> String {
        try KeychainStore().connectorTokenValue()
    }

    func value(for item: KeychainItem) throws -> String? {
        try client.read(service: item.service, account: item.account)
    }

    func set(_ value: String, for item: KeychainItem) throws {
        guard !value.isEmpty else {
            throw KeychainStoreError.invalidValue
        }
        if try client.read(service: item.service, account: item.account) != nil {
            try client.update(value: value, service: item.service, account: item.account)
            return
        }
        do {
            try client.create(value: value, service: item.service, account: item.account)
        } catch let error as KeychainStoreError {
            if case let .operationFailed(status) = error, status == Int(errSecDuplicateItem) {
                try client.update(value: value, service: item.service, account: item.account)
                return
            }
            throw error
        }
    }

    func delete(_ item: KeychainItem) throws {
        try client.delete(service: item.service, account: item.account)
    }

    func connectorTokenValue() throws -> String {
        if let existing = try value(for: .connectorToken), !existing.isEmpty {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainStoreError.randomGenerationFailed
        }
        let generated = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try set(generated, for: .connectorToken)
            return generated
        } catch let error as KeychainStoreError {
            if case let .operationFailed(status) = error, status == Int(errSecDuplicateItem),
               let existing = try value(for: .connectorToken), !existing.isEmpty {
                return existing
            }
            throw error
        }
    }

    func meridianIngestToken() throws -> String? {
        if let legacy = try value(for: .meridianIngestToken(account: meridianAccount)), !legacy.isEmpty {
            return legacy
        }
        if let alias = try value(for: .meridianIngestTokenAlias), !alias.isEmpty {
            return alias
        }
        return nil
    }

    var meridianIngestItem: KeychainItem {
        .meridianIngestToken(account: meridianAccount)
    }
}
