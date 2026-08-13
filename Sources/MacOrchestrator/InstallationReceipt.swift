import Darwin
import Foundation

enum InstallationReceiptError: Error, Equatable, LocalizedError, Sendable {
    case invalidProductVersion
    case invalidDigest(String)
    case invalidManifestURL
    case malformed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidProductVersion:
            return "The installation receipt contains an invalid product version."
        case let .invalidDigest(field):
            return "The installation receipt contains an invalid \(field) digest."
        case .invalidManifestURL:
            return "The installation receipt manifest URL is not an immutable release asset URL."
        case .malformed:
            return "The installation receipt is malformed."
        case .unavailable:
            return "The installation receipt could not be stored safely."
        }
    }
}

struct InstallationReceiptV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let productVersion: String
    let manifestSHA256: String
    let helperPayloadSHA256: String
    let coreRuntimePayloadSHA256: String
    let runtimeLockSHA256: String
    let runtimeSchemaVersion: Int
    let configurationSchemaVersion: Int
    let installedAt: Date
    let manifestURL: URL?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case productVersion
        case manifestSHA256
        case helperPayloadSHA256
        case coreRuntimePayloadSHA256
        case runtimeLockSHA256
        case runtimeSchemaVersion
        case configurationSchemaVersion
        case installedAt
        case manifestURL
    }

    init(
        productVersion: String,
        manifestSHA256: String,
        helperPayloadSHA256: String,
        coreRuntimePayloadSHA256: String,
        runtimeLockSHA256: String,
        runtimeSchemaVersion: Int,
        configurationSchemaVersion: Int,
        installedAt: Date,
        manifestURL: URL? = nil
    ) throws {
        guard (try? SemanticVersion(productVersion)) != nil else {
            throw InstallationReceiptError.invalidProductVersion
        }
        for (field, digest) in [
            ("manifest", manifestSHA256),
            ("helper payload", helperPayloadSHA256),
            ("core runtime payload", coreRuntimePayloadSHA256),
            ("runtime lock", runtimeLockSHA256),
        ] {
            guard Self.isDigest(digest) else {
                throw InstallationReceiptError.invalidDigest(field)
            }
        }
        guard runtimeSchemaVersion > 0, configurationSchemaVersion > 0 else {
            throw InstallationReceiptError.malformed
        }
        if let manifestURL {
            let expectedPath = "/Jay-2212/mac-orchestrator/releases/download/v\(productVersion)/manifest.json"
            guard manifestURL.scheme?.lowercased() == "https",
                  manifestURL.host?.lowercased() == "github.com",
                  manifestURL.path == expectedPath,
                  manifestURL.query == nil,
                  manifestURL.fragment == nil else {
                throw InstallationReceiptError.invalidManifestURL
            }
        }
        self.schemaVersion = 1
        self.productVersion = productVersion
        self.manifestSHA256 = manifestSHA256.lowercased()
        self.helperPayloadSHA256 = helperPayloadSHA256.lowercased()
        self.coreRuntimePayloadSHA256 = coreRuntimePayloadSHA256.lowercased()
        self.runtimeLockSHA256 = runtimeLockSHA256.lowercased()
        self.runtimeSchemaVersion = runtimeSchemaVersion
        self.configurationSchemaVersion = configurationSchemaVersion
        self.installedAt = installedAt
        self.manifestURL = manifestURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == allowed else { throw InstallationReceiptError.malformed }
        self = try InstallationReceiptV1(
            productVersion: try container.decode(String.self, forKey: .productVersion),
            manifestSHA256: try container.decode(String.self, forKey: .manifestSHA256),
            helperPayloadSHA256: try container.decode(String.self, forKey: .helperPayloadSHA256),
            coreRuntimePayloadSHA256: try container.decode(String.self, forKey: .coreRuntimePayloadSHA256),
            runtimeLockSHA256: try container.decode(String.self, forKey: .runtimeLockSHA256),
            runtimeSchemaVersion: try container.decode(Int.self, forKey: .runtimeSchemaVersion),
            configurationSchemaVersion: try container.decode(Int.self, forKey: .configurationSchemaVersion),
            installedAt: try container.decode(Date.self, forKey: .installedAt),
            manifestURL: try container.decodeIfPresent(URL.self, forKey: .manifestURL)
        )
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw InstallationReceiptError.malformed
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> InstallationReceiptV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let receipt = try decoder.decode(InstallationReceiptV1.self, from: data)
            guard receipt.schemaVersion == 1 else { throw InstallationReceiptError.malformed }
            return try InstallationReceiptV1(
                productVersion: receipt.productVersion,
                manifestSHA256: receipt.manifestSHA256,
                helperPayloadSHA256: receipt.helperPayloadSHA256,
                coreRuntimePayloadSHA256: receipt.coreRuntimePayloadSHA256,
                runtimeLockSHA256: receipt.runtimeLockSHA256,
                runtimeSchemaVersion: receipt.runtimeSchemaVersion,
                configurationSchemaVersion: receipt.configurationSchemaVersion,
                installedAt: receipt.installedAt,
                manifestURL: receipt.manifestURL
            )
        } catch let error as InstallationReceiptError {
            throw error
        } catch {
            throw InstallationReceiptError.malformed
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil &&
            value.lowercased() != String(repeating: "0", count: 64)
    }
}

final class InstallationReceiptStore {
    static let receiptFileName = "receipt.json"
    static let previousReceiptFileName = "receipt.previous.json"

    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    var receiptURL: URL {
        directoryURL.appendingPathComponent(Self.receiptFileName, isDirectory: false)
    }

    var previousReceiptURL: URL {
        directoryURL.appendingPathComponent(Self.previousReceiptFileName, isDirectory: false)
    }

    func load() throws -> InstallationReceiptV1? {
        guard fileManager.fileExists(atPath: receiptURL.path) else { return nil }
        guard !isSymlink(receiptURL) else { throw InstallationReceiptError.unavailable }
        do {
            return try InstallationReceiptV1.decode(Data(contentsOf: receiptURL))
        } catch let error as InstallationReceiptError {
            throw error
        } catch {
            throw InstallationReceiptError.unavailable
        }
    }

    func save(_ receipt: InstallationReceiptV1) throws {
        do {
            try ensureDirectory()
            if fileManager.fileExists(atPath: receiptURL.path) {
                guard !isSymlink(receiptURL) else { throw InstallationReceiptError.unavailable }
                let current = try Data(contentsOf: receiptURL)
                try write(current, to: previousReceiptURL)
            }
            try write(try receipt.encoded(), to: receiptURL)
        } catch let error as InstallationReceiptError {
            throw error
        } catch {
            throw InstallationReceiptError.unavailable
        }
    }

    func restorePrevious() throws {
        guard fileManager.fileExists(atPath: previousReceiptURL.path) else {
            throw InstallationReceiptError.unavailable
        }
        guard !containsSymlinkInPath(previousReceiptURL), !containsSymlinkInPath(receiptURL), isOwned(previousReceiptURL) else {
            throw InstallationReceiptError.unavailable
        }
        let previous = try Data(contentsOf: previousReceiptURL)
        try write(previous, to: receiptURL)
    }

    func removeCurrent() throws {
        guard fileManager.fileExists(atPath: receiptURL.path) else { return }
        guard !isSymlink(receiptURL), isOwned(receiptURL) else {
            throw InstallationReceiptError.unavailable
        }
        try fileManager.removeItem(at: receiptURL)
    }

    private func ensureDirectory() throws {
        guard !containsSymlinkInPath(directoryURL) else { throw InstallationReceiptError.unavailable }
        var ancestor = directoryURL.standardizedFileURL
        while ancestor.path != "/" && !fileManager.fileExists(atPath: ancestor.path) {
            guard !isSymlink(ancestor) else { throw InstallationReceiptError.unavailable }
            ancestor.deleteLastPathComponent()
        }
        guard ancestor.path != "/",
              !isSymlink(ancestor),
              isOwned(ancestor) else {
            throw InstallationReceiptError.unavailable
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        guard isOwned(directoryURL), !isSymlink(directoryURL) else {
            throw InstallationReceiptError.unavailable
        }
    }

    private func write(_ data: Data, to destination: URL) throws {
        guard !containsSymlinkInPath(destination), !containsSymlinkInPath(directoryURL), isOwned(directoryURL) else {
            throw InstallationReceiptError.unavailable
        }
        if fileManager.fileExists(atPath: destination.path), !isOwned(destination) {
            throw InstallationReceiptError.unavailable
        }
        let temporary = directoryURL.appendingPathComponent(".receipt.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func containsSymlinkInPath(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if isSymlink(current) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    private func isOwned(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber else {
            return false
        }
        return owner.uint32Value == getuid()
    }
}
