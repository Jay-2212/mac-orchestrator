import Foundation

enum MigrationError: Error, Equatable, LocalizedError, Sendable {
    case malformedLegacyConfig
    case keychainWriteFailed(String)
    case keychainVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformedLegacyConfig:
            return "The legacy configuration could not be read safely."
        case let .keychainWriteFailed(item):
            return "The legacy secret could not be migrated to Keychain item " + item + "."
        case let .keychainVerificationFailed(item):
            return "The migrated Keychain item could not be verified: " + item + "."
        }
    }
}

enum UserDefaultsMigrator {
    private static let marker = "user-defaults-v1"
    private static let legacyProfileMarker = "legacy-control-profile-v1"

    static func migrate(
        userDefaults: UserDefaults,
        store: ConfigurationStore
    ) throws -> AppConfiguration {
        var configuration = try store.loadOrCreate()
        if configuration.onboarding.migrationMarkers.contains(marker) {
            return configuration
        }

        let legacyKeys = ["serverDesired", "tunnelDesired", "ownerID"]
        let registeredDefaults = userDefaults.volatileDomain(forName: UserDefaults.registrationDomain)
        func persistedLegacyValue(forKey key: String) -> Any? {
            guard registeredDefaults[key] == nil else {
                return nil
            }
            return userDefaults.object(forKey: key)
        }
        let isLegacyInstall = legacyKeys.contains { persistedLegacyValue(forKey: $0) != nil }
        func legacyValue(forKey key: String) -> Any? {
            guard isLegacyInstall else {
                return nil
            }
            return userDefaults.object(forKey: key)
        }
        var changed = false

        if let ownerID = legacyValue(forKey: "ownerID") as? String,
           !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           configuration.ownerID != ownerID {
            configuration.ownerID = ownerID
            changed = true
        }

        if let serverDesired = legacyValue(forKey: "serverDesired") as? Bool,
           configuration.process.serverDesired != serverDesired {
            configuration.process.serverDesired = serverDesired
            changed = true
        }

        if let tunnelDesired = legacyValue(forKey: "tunnelDesired") as? Bool {
            if configuration.process.tunnelDesired != tunnelDesired {
                configuration.process.tunnelDesired = tunnelDesired
                changed = true
            }
            if configuration.desiredCapabilities["remote.connector"] != tunnelDesired {
                configuration.desiredCapabilities["remote.connector"] = tunnelDesired
                changed = true
            }
        }

        if isLegacyInstall, configuration.controlProfile != .full {
            configuration.controlProfile = .full
            changed = true
        }

        if isLegacyInstall {
            for capabilityID in [
                "core.session",
                "mac.ui",
                "mac.screenOcr",
                "mac.files.read",
                "mac.files.write",
                "mac.shell",
                "mac.clipboard.write",
            ] where configuration.desiredCapabilities[capabilityID] != true {
                configuration.desiredCapabilities[capabilityID] = true
                changed = true
            }
            if !configuration.policy.clipboardMutation {
                configuration.policy.clipboardMutation = true
                changed = true
            }
        }

        var markers = Set(configuration.onboarding.migrationMarkers)
        if markers.insert(marker).inserted {
            changed = true
        }
        if isLegacyInstall, markers.insert(legacyProfileMarker).inserted {
            changed = true
        }
        if isLegacyInstall,
           configuration.onboarding.phase2State != .completed,
           configuration.onboarding.phase2State != .legacyMigrated {
            configuration.onboarding.phase2State = .legacyMigrated
            changed = true
        }
        configuration.onboarding.migrationMarkers = markers.sorted()

        if changed {
            return try store.save(configuration)
        }
        return configuration
    }
}

struct LegacySecretMigrationResult: Equatable, Sendable {
    let migratedItems: [String]
    let alreadyPresentItems: [String]
    let pendingCleanup: Bool
    let completed: Bool
}

struct LegacySecretMigrator {
    private static let completionMarker = "legacy-secrets-v1"

    private let legacyURL: URL
    private let keychain: KeychainStore
    private let store: ConfigurationStore

    init(legacyURL: URL, keychain: KeychainStore, store: ConfigurationStore) {
        self.legacyURL = legacyURL
        self.keychain = keychain
        self.store = store
    }

    func migrate() throws -> LegacySecretMigrationResult {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return LegacySecretMigrationResult(
                migratedItems: [],
                alreadyPresentItems: [],
                pendingCleanup: false,
                completed: true
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL))
        } catch {
            throw MigrationError.malformedLegacyConfig
        }
        guard let dictionary = object as? [String: Any] else {
            throw MigrationError.malformedLegacyConfig
        }

        let entries: [(legacyKey: String, item: KeychainItem, value: String)] = [
            ("TELEGRAM_BOT_TOKEN", .telegramSendBotToken),
            ("TELEGRAM_CHAT_ID", .telegramSendChatID),
            ("INGEST_TOKEN", keychain.meridianIngestItem),
        ].compactMap { legacyKey, item in
            guard let value = Self.secretString(dictionary[legacyKey]) else {
                return nil
            }
            return (legacyKey, item, value)
        }

        guard !entries.isEmpty else {
            return LegacySecretMigrationResult(
                migratedItems: [],
                alreadyPresentItems: [],
                pendingCleanup: false,
                completed: true
            )
        }

        let legacyKeys = entries.map(\.legacyKey).sorted()
        _ = try store.update { configuration in
            if !configuration.onboarding.legacyPlaintextCleanupPending {
                configuration.onboarding.legacyPlaintextCleanupPending = true
            }
            configuration.onboarding.legacyPlaintextKeys = Array(
                Set(configuration.onboarding.legacyPlaintextKeys).union(legacyKeys)
            ).sorted()
        }

        var migratedItems: [String] = []
        var alreadyPresentItems: [String] = []
        for entry in entries {
            do {
                if let existing = try keychain.value(for: entry.item), !existing.isEmpty {
                    alreadyPresentItems.append(entry.item.key)
                    continue
                }
                try keychain.set(entry.value, for: entry.item)
                guard let verified = try keychain.value(for: entry.item), verified == entry.value else {
                    throw MigrationError.keychainVerificationFailed(entry.item.key)
                }
                migratedItems.append(entry.item.key)
            } catch let error as MigrationError {
                throw error
            } catch {
                throw MigrationError.keychainWriteFailed(entry.item.key)
            }
        }

        _ = try store.update { configuration in
            var markers = Set(configuration.onboarding.migrationMarkers)
            markers.insert(Self.completionMarker)
            configuration.onboarding.migrationMarkers = markers.sorted()
        }

        return LegacySecretMigrationResult(
            migratedItems: migratedItems,
            alreadyPresentItems: alreadyPresentItems,
            pendingCleanup: true,
            completed: true
        )
    }

    private static func secretString(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            let string = number.stringValue
            return string.isEmpty ? nil : string
        }
        return nil
    }
}
