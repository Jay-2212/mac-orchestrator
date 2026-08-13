import CryptoKit
import Foundation

enum ManifestAuthenticationError: Error, Equatable, LocalizedError, Sendable {
    case malformedEnvelope
    case unsupportedSchema(Int)
    case unsupportedAlgorithm(String)
    case unknownKeyID(String)
    case invalidBase64
    case invalidPublicKey(String)
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .malformedEnvelope:
            return "The detached manifest signature envelope is malformed."
        case let .unsupportedSchema(version):
            return "The detached manifest signature schema version \(version) is unsupported."
        case let .unsupportedAlgorithm(algorithm):
            return "The detached manifest signature algorithm \(algorithm) is unsupported."
        case let .unknownKeyID(keyID):
            return "The detached manifest signature key ID \(keyID) is not trusted."
        case .invalidBase64:
            return "The detached manifest signature is not valid base64."
        case let .invalidPublicKey(keyID):
            return "The trusted manifest public key \(keyID) is invalid."
        case .invalidSignature:
            return "The detached manifest signature does not authenticate the exact manifest bytes."
        }
    }
}

struct ManifestSignatureEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let algorithm: String
    let keyID: String
    let signature: String

    init(schemaVersion: Int, algorithm: String, keyID: String, signature: String) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyID = keyID
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == allowed else {
            throw ManifestAuthenticationError.malformedEnvelope
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        keyID = try container.decode(String.self, forKey: .keyID)
        signature = try container.decode(String.self, forKey: .signature)
        guard !keyID.isEmpty, !signature.isEmpty else {
            throw ManifestAuthenticationError.malformedEnvelope
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case algorithm
        case keyID
        case signature
    }
}

struct ManifestSignatureVerifier: Sendable {
    let publicKeys: [String: Data]

    init(rawPublicKeys: [String: Data]) throws {
        guard !rawPublicKeys.isEmpty else {
            throw ManifestAuthenticationError.invalidPublicKey("none")
        }
        for (keyID, rawKey) in rawPublicKeys {
            guard !keyID.isEmpty, rawKey.count == 32 else {
                throw ManifestAuthenticationError.invalidPublicKey(keyID)
            }
            do {
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
            } catch {
                throw ManifestAuthenticationError.invalidPublicKey(keyID)
            }
        }
        self.publicKeys = rawPublicKeys
    }

    func verify(manifestBytes: Data, signatureBytes: Data) throws {
        let envelope: ManifestSignatureEnvelope
        do {
            envelope = try JSONDecoder().decode(ManifestSignatureEnvelope.self, from: signatureBytes)
        } catch let error as ManifestAuthenticationError {
            throw error
        } catch {
            throw ManifestAuthenticationError.malformedEnvelope
        }
        guard envelope.schemaVersion == 1 else {
            throw ManifestAuthenticationError.unsupportedSchema(envelope.schemaVersion)
        }
        guard envelope.algorithm == "ed25519" else {
            throw ManifestAuthenticationError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard let rawPublicKey = publicKeys[envelope.keyID] else {
            throw ManifestAuthenticationError.unknownKeyID(envelope.keyID)
        }
        guard let signature = Data(base64Encoded: envelope.signature) else {
            throw ManifestAuthenticationError.invalidBase64
        }
        guard signature.count == 64 else {
            throw ManifestAuthenticationError.invalidSignature
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        } catch {
            throw ManifestAuthenticationError.invalidPublicKey(envelope.keyID)
        }
        guard publicKey.isValidSignature(signature, for: manifestBytes) else {
            throw ManifestAuthenticationError.invalidSignature
        }
    }

    static let production: ManifestSignatureVerifier = {
        // This is a public verification key only. The matching release signing
        // key is maintained outside the repository and is never loaded here.
        let publicKey = Data(base64Encoded: "yk0nGavhXyRMJfuvH/lMxvixLCla3kH8z9harjNfVVM=")!
        return try! ManifestSignatureVerifier(rawPublicKeys: ["production-v1": publicKey])
    }()
}

enum SemanticVersionError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(value):
            return "Invalid semantic version: \(value)."
        }
    }
}

struct SemanticVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]
    let build: [String]

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SemanticVersionError.invalid(value) }

        let buildParts = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { throw SemanticVersionError.invalid(value) }
        let withoutBuild = String(buildParts[0])
        let build = buildParts.count == 2
            ? String(buildParts[1]).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard build.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" } }) else {
            throw SemanticVersionError.invalid(value)
        }

        let preParts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(preParts[0])
        let prerelease = preParts.count == 2
            ? String(preParts[1]).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" } }) else {
            throw SemanticVersionError.invalid(value)
        }

        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw SemanticVersionError.invalid(value)
        }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == 3 else { throw SemanticVersionError.invalid(value) }
        if components.enumerated().contains(where: { index, component in
            component.count > 1 && component.first == "0" && numbers[index] != 0
        }) {
            throw SemanticVersionError.invalid(value)
        }
        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers[2]
        self.prerelease = prerelease
        self.build = build
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { value += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { value += "+" + build.joined(separator: ".") }
        return value
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct SchemaRange: Codable, Equatable, Sendable {
    let minimum: Int
    let maximum: Int

    init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }

    func contains(_ value: Int) -> Bool {
        minimum <= value && value <= maximum
    }
}

struct ReleaseManifestV1: Codable, Equatable, Sendable {
    struct Product: Codable, Equatable, Sendable {
        var name: String
        var version: String
    }

    struct Bootstrap: Codable, Equatable, Sendable {
        var version: String
        var url: URL
        var sha256: String
    }

    struct Platform: Codable, Equatable, Sendable {
        var architecture: String
        var minimumMacOS: String
    }

    struct Signing: Codable, Equatable, Sendable {
        var mode: String
    }

    struct Helper: Codable, Equatable, Sendable {
        var url: URL
        var sha256: String
        var architecture: String
        var bundleIdentifier: String
        var version: String
        var signing: Signing
    }

    struct UV: Codable, Equatable, Sendable {
        var version: String
        var url: URL
        var sha256: String
    }

    struct Python: Codable, Equatable, Sendable {
        var managedVersion: String
    }

    struct CorePayload: Codable, Equatable, Sendable {
        var url: URL
        var sha256: String
        var format: String
        var files: [String]
    }

    struct Runtime: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var uv: UV
        var python: Python
        var lockSha256: String
        var corePayload: CorePayload
    }

    struct Ngrok: Codable, Equatable, Sendable {
        var version: String
        var archiveUrl: URL
        var archiveSha256: String
        var archiveFormat: String
        var executableName: String
        var developerIdAuthority: String
        var developerIdTeam: String
        var agentApiVersion: String
    }

    struct Compatibility: Codable, Equatable, Sendable {
        var runtimeSchema: SchemaRange
        var configurationSchema: SchemaRange
    }

    var schemaVersion: Int
    var product: Product
    var bootstrap: Bootstrap
    var platform: Platform
    var helper: Helper
    var runtime: Runtime
    var ngrok: Ngrok
    var compatibility: Compatibility

    func validated(
        expectedVersion: SemanticVersion,
        currentVersion: SemanticVersion,
        currentConfigurationSchema: Int,
        currentRuntimeSchema: Int,
        architecture: String,
        operatingSystem: SemanticVersion
    ) throws -> ReleaseManifestV1 {
        guard schemaVersion == 1 else { throw ReleaseManifestValidationError.unsupportedManifestSchema(schemaVersion) }
        guard product.name == "Mac Orchestrator" else { throw ReleaseManifestValidationError.productMismatch }
        guard let version = try? SemanticVersion(product.version), version == expectedVersion else {
            throw ReleaseManifestValidationError.versionMismatch
        }
        guard expectedVersion > currentVersion else { throw ReleaseManifestValidationError.notNewer }
        guard !expectedVersion.isPrerelease else { throw ReleaseManifestValidationError.prereleaseRejected }
        guard platform.architecture == architecture, helper.architecture == architecture else {
            throw ReleaseManifestValidationError.unsupportedArchitecture
        }
        guard let minimumMacOS = try? SemanticVersion(platform.minimumMacOS), minimumMacOS <= operatingSystem else {
            throw ReleaseManifestValidationError.unsupportedOperatingSystem
        }
        guard helper.version == product.version else { throw ReleaseManifestValidationError.versionMismatch }
        guard helper.bundleIdentifier == "com.jay.mac-orchestrator", helper.signing.mode == "adhoc" else {
            throw ReleaseManifestValidationError.helperIdentityMismatch
        }
        guard runtime.schemaVersion >= 1,
              compatibility.runtimeSchema.minimum <= compatibility.runtimeSchema.maximum,
              compatibility.runtimeSchema.contains(currentRuntimeSchema),
              compatibility.runtimeSchema.contains(runtime.schemaVersion) else {
            throw ReleaseManifestValidationError.incompatibleRuntimeSchema
        }
        guard compatibility.configurationSchema.minimum <= compatibility.configurationSchema.maximum,
              compatibility.configurationSchema.contains(currentConfigurationSchema) else {
            throw ReleaseManifestValidationError.incompatibleConfigurationSchema
        }
        guard runtime.uv.version == "0.12.3",
              runtime.python.managedVersion == "3.13.14",
              runtime.corePayload.format == "tar.gz",
              runtime.corePayload.files == ["automac_mcp.py", "pyproject.toml", "uv.lock"],
              ngrok.archiveFormat == "zip",
              ngrok.executableName == "ngrok",
              ngrok.agentApiVersion == "v3" else {
            throw ReleaseManifestValidationError.payloadMetadataMismatch
        }
        try validateDigest(bootstrap.sha256, field: "bootstrap")
        try validateDigest(helper.sha256, field: "helper")
        try validateDigest(runtime.uv.sha256, field: "uv")
        try validateDigest(runtime.lockSha256, field: "runtime lock")
        try validateDigest(runtime.corePayload.sha256, field: "core payload")
        try validateDigest(ngrok.archiveSha256, field: "ngrok")
        try validateVersionedAssetURL(bootstrap.url, version: product.version, filename: "bootstrap.sh", field: "bootstrap")
        try validateVersionedAssetURL(helper.url, version: product.version, filename: "Mac-Orchestrator-arm64.zip", field: "helper")
        try validateVersionedAssetURL(runtime.uv.url, version: product.version, filename: "uv-arm64", field: "uv")
        try validateVersionedAssetURL(runtime.corePayload.url, version: product.version, filename: "core-payload.tar.gz", field: "core payload")
        guard ngrok.archiveUrl.scheme?.lowercased() == "https",
              ngrok.archiveUrl.host?.lowercased() == "bin.equinox.io" else {
            throw ReleaseManifestValidationError.invalidNgrokURL
        }
        guard ngrok.developerIdTeam.count == 10,
              ngrok.developerIdTeam.allSatisfy({ $0.isNumber || ($0 >= "A" && $0 <= "Z") }) else {
            throw ReleaseManifestValidationError.invalidNgrokTeam
        }
        return self
    }

    private func validateDigest(_ value: String, field: String) throws {
        guard value.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              value.lowercased() != String(repeating: "0", count: 64) else {
            throw ReleaseManifestValidationError.invalidDigest(field)
        }
    }

    private func validateVersionedAssetURL(_ url: URL, version: String, filename: String, field: String) throws {
        let expected = "/Jay-2212/mac-orchestrator/releases/download/v\(version)/\(filename)"
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.path == expected,
              url.query == nil,
              url.fragment == nil else {
            throw ReleaseManifestValidationError.mutableAssetURL(field)
        }
    }
}

enum ReleaseManifestValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedManifestSchema(Int)
    case productMismatch
    case versionMismatch
    case notNewer
    case prereleaseRejected
    case unsupportedArchitecture
    case unsupportedOperatingSystem
    case helperIdentityMismatch
    case incompatibleRuntimeSchema
    case incompatibleConfigurationSchema
    case payloadMetadataMismatch
    case invalidDigest(String)
    case mutableAssetURL(String)
    case invalidNgrokURL
    case invalidNgrokTeam

    var errorDescription: String? {
        switch self {
        case let .unsupportedManifestSchema(version): return "Unsupported release manifest schema \(version)."
        case .productMismatch: return "Release manifest product identity mismatch."
        case .versionMismatch: return "Release manifest version metadata mismatch."
        case .notNewer: return "The release is not newer than the installed version."
        case .prereleaseRejected: return "Prerelease releases are not accepted on the stable channel."
        case .unsupportedArchitecture: return "The release does not support this architecture."
        case .unsupportedOperatingSystem: return "The release does not support this macOS version."
        case .helperIdentityMismatch: return "The release helper identity or signing mode is invalid."
        case .incompatibleRuntimeSchema: return "The release runtime schema is incompatible."
        case .incompatibleConfigurationSchema: return "The release configuration schema is incompatible."
        case .payloadMetadataMismatch: return "The release payload metadata is invalid."
        case let .invalidDigest(field): return "The release \(field) digest is invalid."
        case let .mutableAssetURL(field): return "The release \(field) URL is not an immutable versioned asset URL."
        case .invalidNgrokURL: return "The release ngrok URL is not the vendor URL."
        case .invalidNgrokTeam: return "The release ngrok Developer ID team is invalid."
        }
    }
}
