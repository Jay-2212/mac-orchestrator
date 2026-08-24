import Foundation
import Security

protocol SecureRandomByteGenerating: Sendable {
    func randomBytes(count: Int) throws -> [UInt8]
}

struct SystemSecureRandomByteGenerator: SecureRandomByteGenerating {
    func randomBytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw KeychainStoreError.randomGenerationFailed }
        var bytes = [UInt8](repeating: 0, count: count)
        let status: OSStatus = count == 0
            ? errSecSuccess
            : bytes.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
            }
        guard status == errSecSuccess else {
            throw KeychainStoreError.randomGenerationFailed
        }
        return bytes
    }
}

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
    case invalidConnectorToken
    case concurrentModification
    case readBackMismatch
    case commitAmbiguous
    case operationFailed(Int)
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "The requested Keychain item was not found."
        case .invalidValue:
            return "The requested Keychain item contains invalid data."
        case .invalidConnectorToken:
            return "The connector identity has an invalid format."
        case .concurrentModification:
            return "The Keychain item changed before it could be replaced."
        case .readBackMismatch:
            return "The Keychain item could not be verified after replacement."
        case .commitAmbiguous:
            return "The Keychain replacement result could not be classified safely."
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
    private let random: any SecureRandomByteGenerating

    init(
        client: KeychainClient = SystemKeychainClient(),
        meridianAccount: String = NSUserName(),
        random: any SecureRandomByteGenerating = SystemSecureRandomByteGenerator()
    ) {
        self.client = client
        self.meridianAccount = meridianAccount
        self.random = random
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

        let generated = try generateConnectorToken()
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

    func generateConnectorToken() throws -> String {
        let bytes: [UInt8]
        do {
            bytes = try random.randomBytes(count: 32)
        } catch {
            throw KeychainStoreError.randomGenerationFailed
        }
        guard bytes.count == 32 else {
            throw KeychainStoreError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func replaceConnectorToken(expectedCurrent: String, with newValue: String) throws {
        guard Self.isConnectorToken(newValue) else {
            throw KeychainStoreError.invalidConnectorToken
        }
        guard try value(for: .connectorToken) == expectedCurrent else {
            throw KeychainStoreError.concurrentModification
        }
        try client.update(
            value: newValue,
            service: KeychainItem.connectorToken.service,
            account: KeychainItem.connectorToken.account
        )
        guard try value(for: .connectorToken) == newValue else {
            throw KeychainStoreError.readBackMismatch
        }
    }

    func replaceNgrokAuthtoken(expectedCurrent: String?, with newValue: String) throws {
        guard !newValue.isEmpty,
              newValue == newValue.trimmingCharacters(in: .whitespacesAndNewlines),
              newValue.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw KeychainStoreError.invalidValue
        }

        let item = KeychainItem.ngrokAuthtoken
        let current = try value(for: item)
        switch (expectedCurrent, current) {
        case let (.some(expected), .some(actual)) where expected == actual:
            do {
                try client.update(value: newValue, service: item.service, account: item.account)
            } catch {
                // Keychain APIs do not prove whether an update reached the
                // item when an operation reports an error. Treat the value as
                // potentially canonical and let the caller reconcile.
                throw KeychainStoreError.commitAmbiguous
            }
            guard try value(for: item) == newValue else {
                throw KeychainStoreError.readBackMismatch
            }
        case (.none, .none):
            do {
                try client.create(value: newValue, service: item.service, account: item.account)
            } catch let error as KeychainStoreError {
                if case let .operationFailed(status) = error, status == Int(errSecDuplicateItem) {
                    throw KeychainStoreError.concurrentModification
                }
                throw error
            }
            guard try value(for: item) == newValue else {
                throw KeychainStoreError.readBackMismatch
            }
        default:
            throw KeychainStoreError.concurrentModification
        }
    }

    func deleteNgrokAuthtoken(expectedCurrent: String?) throws {
        let item = KeychainItem.ngrokAuthtoken
        guard try value(for: item) == expectedCurrent else {
            throw KeychainStoreError.concurrentModification
        }
        try client.delete(service: item.service, account: item.account)
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

    func setMeridianIngestToken(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw KeychainStoreError.invalidValue
        }
        try set(normalized, for: meridianIngestItem)
    }

    var meridianIngestItem: KeychainItem {
        .meridianIngestToken(account: meridianAccount)
    }

    private static func isConnectorToken(_ value: String) -> Bool {
        let hexadecimal = Set("0123456789abcdef")
        return value.count == 64 && value.allSatisfy { hexadecimal.contains($0) }
    }
}
