import CoreFoundation
import CryptoKit
import Foundation

enum MeridianIndexerError: Error, Equatable, LocalizedError, Sendable {
    case invalidScopeID
    case invalidRootPath
    case invalidRelativePath
    case explicitSelectionRequired
    case invalidInterval
    case invalidDeploymentURL
    case invalidStatePath
    case invalidInvocation
    case invalidAction
    case missingFinalResult
    case invalidControlResult
    case confirmationRequired
    case invalidTool
    case invalidDigest
    case digestMismatch
    case stagingFailed

    var errorDescription: String? {
        switch self {
        case .invalidScopeID: return "Meridian source scope identity is invalid."
        case .invalidRootPath: return "Meridian source root must be an absolute local path."
        case .invalidRelativePath: return "Meridian source selection must be a safe relative path."
        case .explicitSelectionRequired: return "Meridian indexing requires an explicit file or folder selection."
        case .invalidInterval: return "Meridian indexer schedule interval is outside the supported range."
        case .invalidDeploymentURL: return "Meridian Core URL must use HTTPS."
        case .invalidStatePath: return "Meridian index state path must be an absolute local path."
        case .invalidInvocation: return "Meridian indexer invocation is invalid."
        case .invalidAction: return "Meridian control action is invalid."
        case .missingFinalResult: return "Meridian indexer did not return a trusted final result."
        case .invalidControlResult: return "Meridian indexer returned an invalid control result."
        case .confirmationRequired: return "This Meridian data action requires explicit confirmation."
        case .invalidTool: return "The optional Meridian indexer is not a valid owned executable."
        case .invalidDigest: return "The optional Meridian indexer digest is invalid."
        case .digestMismatch: return "The optional Meridian indexer digest did not match."
        case .stagingFailed: return "The optional Meridian indexer could not be promoted safely."
        }
    }
}

struct MeridianSourceScope: Codable, Equatable, Sendable {
    let scopeID: String
    let rootPath: String
    let paths: [String]

    init(scopeID: String, rootPath: String, paths: [String]) {
        self.scopeID = scopeID
        self.rootPath = rootPath
        self.paths = paths
    }

    func validated() throws -> MeridianSourceScope {
        guard scopeID.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil else {
            throw MeridianIndexerError.invalidScopeID
        }
        guard rootPath.hasPrefix("/"),
              !rootPath.hasPrefix("~"),
              !rootPath.contains("\0"),
              !rootPath.contains("\\") else {
            throw MeridianIndexerError.invalidRootPath
        }
        let normalizedRoot = (rootPath as NSString).standardizingPath
        guard normalizedRoot.hasPrefix("/"), normalizedRoot != "/" else {
            throw MeridianIndexerError.invalidRootPath
        }
        guard !paths.isEmpty else { throw MeridianIndexerError.explicitSelectionRequired }
        let normalizedPaths = try paths.map(Self.validateRelativePath)
        return MeridianSourceScope(scopeID: scopeID, rootPath: normalizedRoot, paths: normalizedPaths)
    }

    private static func validateRelativePath(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 512,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.hasPrefix("./"),
              !value.hasSuffix("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              !value.contains("//"),
              !value.contains("://"),
              !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw MeridianIndexerError.invalidRelativePath
        }
        guard value.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else {
            throw MeridianIndexerError.invalidRelativePath
        }
        return value
    }
}

struct MeridianIndexerConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var enabled: Bool
    var scheduleMode: MeridianScheduleMode
    var scopes: [MeridianSourceScope]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        enabled: Bool = false,
        scheduleMode: MeridianScheduleMode = .everySixHours,
        scopes: [MeridianSourceScope] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.scheduleMode = scheduleMode
        self.scopes = scopes
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        enabled: Bool = false,
        intervalMinutes: Int,
        scopes: [MeridianSourceScope] = []
    ) {
        self.init(
            schemaVersion: schemaVersion,
            enabled: enabled,
            scheduleMode: Self.mode(forLegacyInterval: intervalMinutes),
            scopes: scopes
        )
    }

    /// Compatibility accessor for old callers. New persisted configurations
    /// use `scheduleMode`, never a generic interval.
    var intervalMinutes: Int {
        scheduleMode.intervalMinutes ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case scheduleMode
        case intervalMinutes
        case scopes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyInterval = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
        let decodedMode = try container.decodeIfPresent(MeridianScheduleMode.self, forKey: .scheduleMode)
            ?? Self.mode(forLegacyInterval: legacyInterval)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            scheduleMode: decodedMode,
            scopes: try container.decodeIfPresent([MeridianSourceScope].self, forKey: .scopes) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(scheduleMode, forKey: .scheduleMode)
        try container.encode(scopes, forKey: .scopes)
    }

    private static func mode(forLegacyInterval interval: Int?) -> MeridianScheduleMode {
        switch interval {
        case 1_440: return .daily
        case 360: return .everySixHours
        case 0: return .manual
        default: return .everySixHours
        }
    }

    func validated() throws -> MeridianIndexerConfiguration {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MeridianIndexerError.invalidInterval
        }
        if enabled && scopes.isEmpty { throw MeridianIndexerError.explicitSelectionRequired }
        var normalized = self
        normalized.scopes = try scopes.map { try $0.validated() }
        return normalized
    }
}

enum MeridianControlAction: String, Codable, Equatable, Sendable {
    case preview
    case index
    case rebuild
    case probe
    case deleteSource = "delete-source"
    case deleteAll = "delete-all"
}

struct MeridianProbeReadiness: Codable, Equatable, Sendable {
    let version: String
    let diagnostics: String
    let ingest: String
    let search: String
    let cleanup: String

    var allHealthy: Bool {
        version == "ok" && diagnostics == "ok" && ingest == "ok" && search == "ok" && cleanup == "ok"
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case diagnostics
        case ingest
        case search
        case cleanup
    }
}

struct MeridianPreviewSummary: Codable, Equatable, Sendable {
    let discovered: Int
    let supported: Int
    let skipped: Int
    let bytes: Int
    let truncated: Bool
    let complete: Bool
    let uncertain: Bool
}

struct MeridianIndexerControlResult: Equatable, Sendable {
    let controlVersion: String
    let action: MeridianControlAction
    let status: String
    let code: String?
    let exitCode: Int32?
    let counts: [String: Int]
    let readiness: MeridianProbeReadiness?
    let preview: MeridianPreviewSummary?

    var isSuccessful: Bool {
        exitCode == 0 && ["completed", "passed", "ready"].contains(status)
    }

    static func parse(line: String, maximumBytes: Int = 16_384) -> MeridianIndexerControlResult? {
        guard !line.isEmpty,
              line.utf8.count <= maximumBytes,
              !line.localizedCaseInsensitiveContains("bearer "),
              !line.localizedCaseInsensitiveContains("raw_body"),
              !line.localizedCaseInsensitiveContains("document_content"),
              !line.localizedCaseInsensitiveContains("vector") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let controlVersion = dictionary["control_version"] as? String,
              controlVersion == "1.0.0",
              let actionValue = dictionary["action"] as? String,
              let action = MeridianControlAction(rawValue: actionValue),
              let status = dictionary["status"] as? String,
              status.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil else { return nil }

        let allowedBase = Set(["control_version", "action", "status", "code", "exit_code", "counts", "readiness", "skipped", "scan", "purged", "cleanup_source_id", "primary_code"])
        guard Set(dictionary.keys).isSubset(of: allowedBase) else { return nil }
        func strictBoolean(_ value: Any) -> Bool? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        func strictInteger(_ value: Any) -> NSNumber? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            guard number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number
        }
        if let code = dictionary["code"] as? String,
           code.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) == nil { return nil }
        guard let rawExitCode = dictionary["exit_code"],
              let exitCode = strictInteger(rawExitCode),
              [0, 1, 2, 64].contains(exitCode.intValue) else { return nil }
        if let cleanupID = dictionary["cleanup_source_id"] as? String,
           cleanupID.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) == nil { return nil }
        if let primaryCode = dictionary["primary_code"] as? String,
           primaryCode.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) == nil { return nil }

        var counts: [String: Int] = [:]
        if let rawCounts = dictionary["counts"] as? [String: Any] {
            let allowedCounts = Set([
                "discovered", "unchanged", "committed", "skipped", "failed", "cancelled",
                "reconciliation_required", "deleted", "delete_failed", "reconciliation_skipped",
                "matched", "supported", "bytes", "truncated"
            ])
            guard Set(rawCounts.keys).isSubset(of: allowedCounts) else { return nil }
            for (key, value) in rawCounts {
                if key == "truncated" {
                    guard strictBoolean(value) != nil else { return nil }
                    continue
                }
                guard let number = strictInteger(value), number.intValue >= 0, number.intValue <= 1_000_000_000 else {
                    return nil
                }
                counts[key] = number.intValue
            }
        }
        if let rawSkipped = dictionary["skipped"] as? [String: Any] {
            guard rawSkipped.count <= 16 else { return nil }
            for (key, value) in rawSkipped {
                guard key.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil,
                      let number = strictInteger(value),
                      number.intValue >= 0,
                      number.intValue <= 1_000_000_000 else { return nil }
            }
        } else if dictionary["skipped"] != nil {
            return nil
        }
        if let rawScan = dictionary["scan"] as? [String: Any] {
            guard Set(rawScan.keys) == ["complete", "uncertain", "truncated"],
                  strictBoolean(rawScan["complete"] as Any) != nil,
                  strictBoolean(rawScan["uncertain"] as Any) != nil,
                  strictBoolean(rawScan["truncated"] as Any) != nil else { return nil }
        } else if dictionary["scan"] != nil {
            return nil
        }
        var preview: MeridianPreviewSummary?
        if action == .preview {
            guard let rawCounts = dictionary["counts"] as? [String: Any],
                  let discovered = rawCounts["discovered"].flatMap(strictInteger),
                  let supported = rawCounts["supported"].flatMap(strictInteger),
                  let skipped = rawCounts["skipped"].flatMap(strictInteger),
                  let bytes = rawCounts["bytes"].flatMap(strictInteger),
                  let truncated = rawCounts["truncated"].flatMap(strictBoolean),
                  let rawScan = dictionary["scan"] as? [String: Any],
                  let complete = rawScan["complete"].flatMap(strictBoolean),
                  let uncertain = rawScan["uncertain"].flatMap(strictBoolean),
                  discovered.intValue >= 0, discovered.intValue <= 1_000_000_000,
                  supported.intValue >= 0, supported.intValue <= 1_000_000_000,
                  skipped.intValue >= 0, skipped.intValue <= 1_000_000_000,
                  bytes.intValue >= 0, bytes.intValue <= 16_777_216 else { return nil }
            preview = MeridianPreviewSummary(
                discovered: discovered.intValue,
                supported: supported.intValue,
                skipped: skipped.intValue,
                bytes: bytes.intValue,
                truncated: truncated,
                complete: complete,
                uncertain: uncertain
            )
        } else if dictionary["scan"] != nil || dictionary["skipped"] != nil {
            return nil
        }
        var readiness: MeridianProbeReadiness?
        if let rawReadiness = dictionary["readiness"] as? [String: Any] {
            guard Set(rawReadiness.keys) == ["version", "diagnostics", "ingest", "search", "cleanup"],
                  let version = rawReadiness["version"] as? String,
                  let diagnostics = rawReadiness["diagnostics"] as? String,
                  let ingest = rawReadiness["ingest"] as? String,
                  let search = rawReadiness["search"] as? String,
                  let cleanup = rawReadiness["cleanup"] as? String,
                  [version, diagnostics, ingest, search, cleanup].allSatisfy({
                      ["ok", "not_run", "required"].contains($0)
                  }) else { return nil }
            readiness = MeridianProbeReadiness(
                version: version,
                diagnostics: diagnostics,
                ingest: ingest,
                search: search,
                cleanup: cleanup
            )
        }
        if action != .probe, readiness != nil { return nil }
        if let purged = dictionary["purged"], strictBoolean(purged) == nil { return nil }
        if action != .probe,
           dictionary["cleanup_source_id"] != nil || dictionary["primary_code"] != nil {
            return nil
        }
        if action != .deleteAll, dictionary["purged"] != nil { return nil }
        if action == .probe {
            guard readiness != nil else { return nil }
        }
        switch action {
        case .preview:
            guard ["ready", "uncertain"].contains(status),
                  let rawCounts = dictionary["counts"] as? [String: Any],
                  Set(rawCounts.keys).isSubset(of: ["discovered", "supported", "skipped", "bytes", "truncated"]),
                  dictionary["counts"] != nil,
                  dictionary["scan"] != nil else { return nil }
        case .index, .rebuild:
            guard ["completed", "partial_failure", "reconciliation_required", "cancelled"].contains(status),
                  let rawCounts = dictionary["counts"] as? [String: Any],
                  Set(["discovered", "unchanged", "committed", "skipped", "failed", "cancelled", "reconciliation_required"]).isSubset(of: Set(rawCounts.keys)) else { return nil }
        case .probe:
            guard ["passed", "failed", "cleanup_required"].contains(status),
                  dictionary["counts"] == nil else { return nil }
        case .deleteSource:
            guard ["completed", "cleanup_required"].contains(status),
                  let rawCounts = dictionary["counts"] as? [String: Any],
                  Set(rawCounts.keys).isSubset(of: ["matched", "deleted", "failed"]),
                  ["matched", "deleted", "failed"].allSatisfy({ rawCounts[$0] != nil }) else { return nil }
        case .deleteAll:
            guard ["completed", "failed", "cleanup_required"].contains(status),
                  dictionary["counts"] == nil else { return nil }
            if status == "completed" {
                guard strictBoolean(dictionary["purged"] as Any) == true else { return nil }
            }
        }
        return MeridianIndexerControlResult(
            controlVersion: controlVersion,
            action: action,
            status: status,
            code: dictionary["code"] as? String,
            exitCode: (dictionary["exit_code"] as? NSNumber).map { $0.int32Value },
            counts: counts,
            readiness: readiness,
            preview: preview
        )
    }
}

struct MeridianIndexerInvocation: Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let sourceId: String
        let rootPath: String
        let paths: [String]

        private enum CodingKeys: String, CodingKey {
            case sourceId
            case rootPath
            case paths
        }
    }

    let action: MeridianControlAction
    let baseURL: URL
    let stateURL: URL
    let sources: [Source]
    let scopeID: String?
    let confirmation: String?

    init(
        baseURL: URL,
        stateURL: URL,
        scopes: [MeridianSourceScope],
        action: MeridianControlAction = .index,
        scopeID: String? = nil,
        confirmation: String? = nil
    ) throws {
        guard MeridianReadinessEvaluator.fingerprint(for: baseURL.absoluteString) != nil else {
            throw MeridianIndexerError.invalidDeploymentURL
        }
        guard stateURL.isFileURL, stateURL.path.hasPrefix("/"), !stateURL.path.contains("\0") else {
            throw MeridianIndexerError.invalidStatePath
        }
        let validatedScopes = try scopes.map { try $0.validated() }
        if [.index, .rebuild, .preview].contains(action), validatedScopes.isEmpty {
            throw MeridianIndexerError.explicitSelectionRequired
        }
        if [.deleteSource].contains(action),
           scopeID?.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) == nil {
            throw MeridianIndexerError.invalidInvocation
        }
        if action == .deleteAll, confirmation != "PURGE_CORE_DATA" {
            throw MeridianIndexerError.confirmationRequired
        }
        self.baseURL = baseURL
        self.stateURL = stateURL
        self.action = action
        self.scopeID = scopeID
        self.confirmation = confirmation
        self.sources = validatedScopes.map {
            Source(
                sourceId: $0.scopeID,
                rootPath: $0.rootPath,
                paths: $0.paths
            )
        }
    }

    func encoded() throws -> Data {
        struct Payload: Codable {
            let controlVersion: String
            let action: MeridianControlAction
            let baseUrl: String
            let sources: [Source]
            let statePath: String
            let scopeId: String?
            let confirmation: String?

            private enum CodingKeys: String, CodingKey {
                case controlVersion = "control_version"
                case action
                case baseUrl
                case sources
                case statePath
                case scopeId
                case confirmation
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(controlVersion, forKey: .controlVersion)
                try container.encode(action, forKey: .action)
                try container.encode(baseUrl, forKey: .baseUrl)
                try container.encode(sources, forKey: .sources)
                try container.encode(statePath, forKey: .statePath)
                if let scopeId { try container.encode(scopeId, forKey: .scopeId) }
                if let confirmation { try container.encode(confirmation, forKey: .confirmation) }
            }
        }
        let payload = Payload(
            controlVersion: "1.0.0",
            action: action,
            baseUrl: baseURL.absoluteString,
            sources: sources,
            statePath: stateURL.path,
            scopeId: scopeID,
            confirmation: confirmation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}

struct MeridianIndexerCounts: Codable, Equatable, Sendable {
    let discovered: Int
    let unchanged: Int
    let committed: Int
    let skipped: Int
    let failed: Int
    let cancelled: Int
    let reconciliationRequired: Int
    let deleted: Int
    let deleteFailed: Int
    let reconciliationSkipped: Int

    init(
        discovered: Int,
        unchanged: Int,
        committed: Int,
        skipped: Int,
        failed: Int,
        cancelled: Int,
        reconciliationRequired: Int,
        deleted: Int = 0,
        deleteFailed: Int = 0,
        reconciliationSkipped: Int = 0
    ) {
        self.discovered = discovered
        self.unchanged = unchanged
        self.committed = committed
        self.skipped = skipped
        self.failed = failed
        self.cancelled = cancelled
        self.reconciliationRequired = reconciliationRequired
        self.deleted = deleted
        self.deleteFailed = deleteFailed
        self.reconciliationSkipped = reconciliationSkipped
    }

    static let zero = MeridianIndexerCounts(
        discovered: 0,
        unchanged: 0,
        committed: 0,
        skipped: 0,
        failed: 0,
        cancelled: 0,
        reconciliationRequired: 0,
        deleted: 0,
        deleteFailed: 0,
        reconciliationSkipped: 0
    )

    private enum CodingKeys: String, CodingKey {
        case discovered
        case unchanged
        case committed
        case skipped
        case failed
        case cancelled
        case reconciliationRequired = "reconciliation_required"
        case deleted
        case deleteFailed = "delete_failed"
        case reconciliationSkipped = "reconciliation_skipped"
    }
}

struct MeridianIndexerProgressEvent: Codable, Equatable, Sendable {
    let protocolVersion: String?
    let type: String
    let status: String?
    let sourceID: String?
    let relativePath: String?
    let generation: String?
    let code: String?
    let expectedChunks: Int?
    let uploadedChunks: Int?
    let totalChunks: Int?
    let counts: MeridianIndexerCounts?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case status
        case sourceID = "source_id"
        case relativePath = "relative_path"
        case generation
        case code
        case expectedChunks = "expected_chunks"
        case uploadedChunks = "uploaded_chunks"
        case totalChunks = "total_chunks"
        case counts
    }

    static func parse(line: String, maximumBytes: Int = 16_384) -> MeridianIndexerProgressEvent? {
        guard !line.isEmpty, line.utf8.count <= maximumBytes,
              !line.contains("MERIDIAN_CORE_TOKEN"),
              !line.localizedCaseInsensitiveContains("bearer "),
              !line.localizedCaseInsensitiveContains("raw_body"),
              !line.localizedCaseInsensitiveContains("document_content"),
              !line.localizedCaseInsensitiveContains("vector") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else { return nil }

        let allowed: Set<String>
        switch type {
        case "run_started": allowed = ["protocol_version", "type"]
        case "run_finished": allowed = ["protocol_version", "type", "status", "counts"]
        case "file_started", "file_unchanged":
            allowed = ["protocol_version", "type", "source_id", "relative_path"]
        case "file_skipped":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "code"]
        case "source_started":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "generation", "expected_chunks"]
        case "chunk_uploaded":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "generation", "uploaded_chunks", "total_chunks"]
        case "source_committed":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "generation"]
        case "source_failed":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "generation", "code"]
        case "source_cancelled":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "generation"]
        case "source_deleted":
            allowed = ["protocol_version", "type", "source_id", "relative_path"]
        case "source_delete_failed":
            allowed = ["protocol_version", "type", "source_id", "relative_path", "code"]
        case "reconciliation_skipped":
            allowed = ["protocol_version", "type", "source_id", "code"]
        default: return nil
        }
        guard Set(dictionary.keys) == allowed,
              allowed.allSatisfy({ !(dictionary[$0] is NSNull) }) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        guard decoded.protocolVersion == "1.0.0" else { return nil }
        if let status = decoded.status,
           !["completed", "partial_failure", "cancelled", "reconciliation_required"].contains(status) { return nil }
        if let sourceID = decoded.sourceID,
           sourceID.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) == nil { return nil }
        if let relativePath = decoded.relativePath {
            guard (try? MeridianSourceScope(scopeID: "scope", rootPath: "/private", paths: [relativePath]).validated()) != nil else { return nil }
        }
        if let generation = decoded.generation,
           generation.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$", options: .regularExpression) == nil { return nil }
        if let code = decoded.code,
           !["unsupported", "encrypted", "oversized", "permission_denied", "symlink_unsupported", "invalid_utf8", "unavailable", "read_failed", "discovery_failed", "remote_failed", "index_failed", "state_reconciliation_required", "cancelled", "incomplete_scan", "scope_identity_unavailable"].contains(code) { return nil }
        let boundedCounts = [decoded.expectedChunks, decoded.uploadedChunks, decoded.totalChunks].compactMap { $0 }
        guard boundedCounts.allSatisfy({ (0...1_000_000_000).contains($0) }) else { return nil }
        if let uploadedChunks = decoded.uploadedChunks,
           let totalChunks = decoded.totalChunks,
           uploadedChunks > totalChunks { return nil }
        if let counts = decoded.counts {
            guard let countsDictionary = dictionary["counts"] as? [String: Any],
                  Set(["discovered", "unchanged", "committed", "skipped", "failed", "cancelled", "reconciliation_required"]).isSubset(of: Set(countsDictionary.keys)),
                  Set(countsDictionary.keys).isSubset(of: ["discovered", "unchanged", "committed", "skipped", "failed", "cancelled", "reconciliation_required", "deleted", "delete_failed", "reconciliation_skipped"]) else { return nil }
            let values = [counts.discovered, counts.unchanged, counts.committed, counts.skipped, counts.failed, counts.cancelled, counts.reconciliationRequired, counts.deleted, counts.deleteFailed, counts.reconciliationSkipped]
            guard values.allSatisfy({ (0...1_000_000_000).contains($0) }),
                  counts.unchanged + counts.committed + counts.skipped + counts.failed + counts.cancelled + counts.reconciliationRequired <= counts.discovered + counts.reconciliationSkipped + counts.deleteFailed else { return nil }
        }
        return decoded
    }
}

enum MeridianIndexerRunStatus: String, Codable, Equatable, Sendable {
    case disabled
    case paused
    case scheduled
    case running
    case cancelling
    case completed
    case partialFailure = "partial_failure"
    case cancelled
    case reconciliationRequired = "reconciliation_required"
    case unavailable
    case failed
}

struct MeridianIndexerSnapshot: Codable, Equatable, Sendable {
    var desired = false
    var status: MeridianIndexerRunStatus = .disabled
    var paused = false
    var scheduleMode: MeridianScheduleMode = .everySixHours
    var lastRunAt: Date?
    var nextRunAt: Date?
    var lastErrorCode: String?
    var lastControlStatus: String?
    var preview: MeridianPreviewSummary?
    var counts = MeridianIndexerCounts.zero
    var generation: UInt64 = 0
}

enum MeridianIndexerRunBeginResult: Equatable, Sendable {
    case started
    case alreadyRunning
}

final class MeridianIndexerRunController {
    private(set) var isRunning = false
    private(set) var isCancellationRequested = false
    private(set) var lastStatus: MeridianIndexerRunStatus?

    func beginRun() -> MeridianIndexerRunBeginResult {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        isCancellationRequested = false
        lastStatus = .running
        return .started
    }

    func cancelRequested() {
        guard isRunning else { return }
        isCancellationRequested = true
    }

    func finish(status: MeridianIndexerRunStatus, exitCode: Int32) {
        _ = exitCode
        isRunning = false
        lastStatus = status
    }
}

struct MeridianIndexerToolInstaller {
    let rootURL: URL
    let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var installedURL: URL { rootURL.appendingPathComponent("indexer", isDirectory: false) }
    var previousURL: URL { rootURL.appendingPathComponent("indexer.previous", isDirectory: false) }
    var receiptURL: URL { rootURL.appendingPathComponent("tool-receipt.json", isDirectory: false) }

    static func isValidOwnedExecutable(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              fileManager.isExecutableFile(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o022 == 0,
              permissions & 0o111 != 0
        else { return false }
        return true
    }

    @discardableResult
    func install(candidateURL: URL, expectedSHA256: String) throws -> URL {
        guard expectedSHA256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            throw MeridianIndexerError.invalidDigest
        }
        guard Self.isValidOwnedExecutable(at: candidateURL, fileManager: fileManager),
              let data = try? Data(contentsOf: candidateURL),
              MaintenanceDigest.sha256(data: data).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            if let data = try? Data(contentsOf: candidateURL),
               MaintenanceDigest.sha256(data: data).caseInsensitiveCompare(expectedSHA256) != .orderedSame {
                throw MeridianIndexerError.digestMismatch
            }
            throw MeridianIndexerError.invalidTool
        }

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            let staging = rootURL.appendingPathComponent(".indexer-staging-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: candidateURL, to: staging)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            guard let stagedData = try? Data(contentsOf: staging),
                  MaintenanceDigest.sha256(data: stagedData).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw MeridianIndexerError.digestMismatch
            }

            if fileManager.fileExists(atPath: previousURL.path) {
                try fileManager.removeItem(at: previousURL)
            }
            if fileManager.fileExists(atPath: installedURL.path) {
                try fileManager.moveItem(at: installedURL, to: previousURL)
            }
            do {
                try fileManager.moveItem(at: staging, to: installedURL)
            } catch {
                if fileManager.fileExists(atPath: previousURL.path), !fileManager.fileExists(atPath: installedURL.path) {
                    try? fileManager.moveItem(at: previousURL, to: installedURL)
                }
                throw MeridianIndexerError.stagingFailed
            }
            let receipt = MeridianToolReceipt(
                digest: expectedSHA256,
                controlVersion: "1.0.0",
                trusted: true,
                installedAt: Date()
            )
            if fileManager.fileExists(atPath: receiptURL.path),
               (try? fileManager.destinationOfSymbolicLink(atPath: receiptURL.path)) != nil {
                throw MeridianIndexerError.stagingFailed
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(receipt).write(to: receiptURL, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
            return installedURL
        } catch let error as MeridianIndexerError {
            throw error
        } catch {
            throw MeridianIndexerError.stagingFailed
        }
    }

    func receipt() -> MeridianToolReceipt? {
        guard fileManager.fileExists(atPath: receiptURL.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: receiptURL.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: receiptURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o077 == 0,
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(MeridianToolReceipt.self, from: data),
              receipt.isValid else { return nil }
        return receipt
    }

    func currentDigest() -> String? {
        guard Self.isValidOwnedExecutable(at: installedURL, fileManager: fileManager),
              let data = try? Data(contentsOf: installedURL) else { return nil }
        return MaintenanceDigest.sha256(data: data).lowercased()
    }
}

@MainActor
protocol MeridianIndexerProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

@MainActor
protocol MeridianIndexerProcessLaunching: AnyObject {
    func launch(
        executableURL: URL,
        environment: [String: String],
        input: Data,
        output: @escaping (Data) -> Void,
        termination: @escaping (Int32) -> Void
    ) throws -> any MeridianIndexerProcessHandle
}

@MainActor
final class SystemMeridianIndexerProcess: MeridianIndexerProcessHandle {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

@MainActor
final class SystemMeridianIndexerProcessLauncher: MeridianIndexerProcessLaunching {
    func launch(
        executableURL: URL,
        environment: [String: String],
        input: Data,
        output: @escaping (Data) -> Void,
        termination: @escaping (Int32) -> Void
    ) throws -> any MeridianIndexerProcessHandle {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = []
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in output(data) }
        }
        process.terminationHandler = { terminated in
            Task { @MainActor in termination(terminated.terminationStatus) }
        }
        try process.run()
        stdin.fileHandleForWriting.write(input)
        stdin.fileHandleForWriting.closeFile()
        return SystemMeridianIndexerProcess(process: process)
    }
}

@MainActor
final class MeridianIndexerCoordinator {
    private let scheduler: any LifecycleSchedulerProtocol
    private let launcher: any MeridianIndexerProcessLaunching
    private let stateURL: URL
    private let toolURL: URL
    private let toolInstaller: MeridianIndexerToolInstaller
    private let readinessReceiptStore: MeridianReadinessReceiptStoring
    private var process: (any MeridianIndexerProcessHandle)?
    private var scheduleHandle: LifecycleScheduledHandle?
    private var configuration: MeridianIndexerConfiguration?
    private var baseURL: URL?
    private var token: String?
    private var pendingAction: MeridianControlAction?
    private var pendingScopeID: String?
    private var pendingConfirmation: String?
    private var cancellationRequested = false
    private var generation: UInt64 = 0
    private var outputBuffer = Data()
    private var finalResult: MeridianIndexerControlResult?
    private var currentAction: MeridianControlAction = .index
    private var currentScopeID: String?
    private var currentDeploymentFingerprint: String?

    private(set) var snapshot = MeridianIndexerSnapshot()
    var onSnapshot: ((MeridianIndexerSnapshot) -> Void)?
    var onReadinessEvidenceChanged: (() -> Void)?

    init(
        scheduler: any LifecycleSchedulerProtocol,
        launcher: (any MeridianIndexerProcessLaunching)? = nil,
        supportDirectory: URL,
        readinessReceiptStore: MeridianReadinessReceiptStoring? = nil
    ) {
        self.scheduler = scheduler
        self.launcher = launcher ?? SystemMeridianIndexerProcessLauncher()
        let meridianDirectory = supportDirectory.appendingPathComponent("meridian", isDirectory: true)
        self.stateURL = meridianDirectory.appendingPathComponent("index-state.json", isDirectory: false)
        self.toolURL = meridianDirectory.appendingPathComponent("indexer", isDirectory: false)
        self.toolInstaller = MeridianIndexerToolInstaller(rootURL: meridianDirectory)
        self.readinessReceiptStore = readinessReceiptStore ?? FileMeridianReadinessReceiptStore(
            url: meridianDirectory.appendingPathComponent("readiness-receipt.json", isDirectory: false)
        )
    }

    var toolReceipt: MeridianToolReceipt? { toolInstaller.receipt() }
    var currentToolDigest: String? { toolInstaller.currentDigest() }
    var readinessReceipt: MeridianReadinessReceipt? { readinessReceiptStore.load() }
    var isRunning: Bool { process != nil }

    func reconcile(configuration: AppConfiguration, contract: ManagedRuntimeLaunchContract) {
        let indexer = configuration.integration.meridianIndexer
        guard (try? indexer.validated()) != nil,
              indexer.enabled,
              configuration.desiredCapabilities["meridian.search"] == true else {
            stop()
            snapshot.scheduleMode = indexer.scheduleMode
            publish(desired: false, status: .disabled)
            return
        }
        self.configuration = indexer
        snapshot.scheduleMode = indexer.scheduleMode
        guard let deployment = configuration.integration.meridianDeploymentURL,
              let url = URL(string: deployment),
              MeridianReadinessEvaluator.fingerprint(for: deployment) != nil else {
            stop()
            snapshot.scheduleMode = indexer.scheduleMode
            publish(desired: true, status: .unavailable, error: "remote_url_invalid")
            return
        }
        self.baseURL = url
        self.currentDeploymentFingerprint = MeridianReadinessEvaluator.fingerprint(for: deployment)
        self.token = contract.meridianIndexerToken
        guard contract.meridianIndexerToken != nil else {
            stop()
            snapshot.scheduleMode = indexer.scheduleMode
            publish(desired: true, status: .unavailable, error: "core_token_missing")
            return
        }
        guard !snapshot.paused else {
            cancelSchedule()
            publish(desired: true, status: .paused)
            return
        }
        if process != nil {
            publish(desired: true, status: .running)
            return
        }
        if pendingAction != nil {
            scheduleNow()
            return
        }
        guard indexer.scheduleMode.intervalMinutes != nil else {
            cancelSchedule()
            snapshot.nextRunAt = nil
            publish(desired: true, status: .scheduled)
            return
        }
        if scheduleHandle == nil {
            scheduleNext(at: scheduler.now.addingTimeInterval(scheduleInterval(for: indexer)))
        }
    }

    func scanNow() {
        pendingAction = .index
        pendingScopeID = nil
        cancelSchedule()
        if process == nil { scheduleNow() } else { requestCancellation(forPendingAction: true) }
    }

    func preview() {
        pendingAction = .preview
        pendingScopeID = nil
        cancelSchedule()
        if process == nil { scheduleNow() } else { requestCancellation(forPendingAction: true) }
    }

    func deleteSource(scopeID: String) {
        pendingAction = .deleteSource
        pendingScopeID = scopeID
        pendingConfirmation = nil
        cancelSchedule()
        if process == nil { scheduleNow() } else { requestCancellation(forPendingAction: true) }
    }

    func deleteAllData() {
        pendingAction = .deleteAll
        pendingScopeID = nil
        pendingConfirmation = "PURGE_CORE_DATA"
        cancelSchedule()
        if process == nil { scheduleNow() } else { requestCancellation(forPendingAction: true) }
    }

    func cancel() {
        guard process != nil else {
            cancelSchedule()
            snapshot.nextRunAt = nil
            publish(status: .cancelled, error: "cancelled")
            return
        }
        requestCancellation(forPendingAction: false)
    }

    func retry(rebuild: Bool = false) {
        pendingAction = rebuild ? .rebuild : .index
        pendingScopeID = nil
        pendingConfirmation = nil
        cancelSchedule()
        if process == nil { scheduleNow() } else { requestCancellation(forPendingAction: true) }
    }

    func pause() {
        snapshot.paused = true
        cancelSchedule()
        snapshot.nextRunAt = nil
        publish(status: .paused)
    }

    func resume() {
        snapshot.paused = false
        guard configuration != nil else { return }
        if process == nil { scheduleFromSafePoint() }
        publish(status: process == nil ? .scheduled : .running)
    }

    func handleWake() {
        guard !snapshot.paused, process == nil, let configuration,
              configuration.scheduleMode.intervalMinutes != nil else { return }
        if let nextRunAt = snapshot.nextRunAt, nextRunAt <= scheduler.now {
            cancelSchedule()
            scheduleNow()
            return
        }
        if scheduleHandle == nil { scheduleFromSafePoint() }
    }

    func stop() {
        generation &+= 1
        cancelSchedule()
        snapshot.paused = false
        cancellationRequested = true
        process?.terminate()
        process = nil
        configuration = nil
        baseURL = nil
        token = nil
        pendingAction = nil
        pendingScopeID = nil
        pendingConfirmation = nil
        outputBuffer.removeAll(keepingCapacity: false)
        finalResult = nil
    }

    private func requestCancellation(forPendingAction: Bool) {
        guard process != nil else { return }
        cancellationRequested = true
        if !forPendingAction {
            pendingAction = nil
            pendingScopeID = nil
            pendingConfirmation = nil
        }
        publish(desired: true, status: .cancelling, error: "cancelling")
        process?.terminate()
    }

    private func scheduleInterval(for configuration: MeridianIndexerConfiguration) -> TimeInterval {
        TimeInterval((configuration.scheduleMode.intervalMinutes ?? 360) * 60)
    }

    private func scheduleFromSafePoint() {
        guard let configuration,
              let interval = configuration.scheduleMode.intervalMinutes else {
            snapshot.nextRunAt = nil
            return
        }
        scheduleNext(at: scheduler.now.addingTimeInterval(TimeInterval(interval * 60)))
    }

    private func scheduleNow() {
        scheduleNext(at: scheduler.now, action: pendingAction ?? .index)
    }

    private func scheduleNext(
        at date: Date,
        action: MeridianControlAction? = nil,
        preserveStatus: Bool = false
    ) {
        guard configuration != nil, !snapshot.paused else { return }
        cancelSchedule()
        let callbackGeneration = generation &+ 1
        generation = callbackGeneration
        let scheduledAction = action
        scheduleHandle = scheduler.schedule(at: date, label: "meridian-indexer") { [weak self] in
            guard let self, self.generation == callbackGeneration, !self.snapshot.paused else { return }
            self.scheduleHandle = nil
            self.startRun(action: scheduledAction ?? .index, generation: callbackGeneration)
        }
        snapshot.nextRunAt = date
        if !preserveStatus { snapshot.status = .scheduled }
        snapshot.desired = true
        publish()
    }

    private func startRun(action: MeridianControlAction, generation: UInt64) {
        guard generation == self.generation,
              process == nil,
              let configuration,
              let baseURL,
              let token,
              let invocation = try? MeridianIndexerInvocation(
                baseURL: baseURL,
                stateURL: stateURL,
                scopes: action == .deleteSource || action == .deleteAll || action == .probe ? [] : configuration.scopes,
                action: action,
                scopeID: pendingScopeID,
                confirmation: pendingConfirmation
              ),
              let input = try? invocation.encoded() else {
            publish(desired: true, status: .unavailable, error: "configuration_unavailable")
            return
        }
        guard MeridianIndexerToolInstaller.isValidOwnedExecutable(at: toolURL) else {
            publish(desired: true, status: .unavailable, error: "optional_indexer_unavailable")
            return
        }
        let runGeneration = generation
        self.currentAction = action
        self.currentScopeID = pendingScopeID
        self.cancellationRequested = false
        self.finalResult = nil
        self.outputBuffer.removeAll(keepingCapacity: true)
        self.pendingAction = nil
        self.pendingScopeID = nil
        self.pendingConfirmation = nil
        self.snapshot.nextRunAt = nil
        var environment = ["MERIDIAN_CORE_TOKEN": token]
        for name in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = ProcessInfo.processInfo.environment[name] { environment[name] = value }
        }
        do {
            process = try launcher.launch(
                executableURL: toolURL,
                environment: environment,
                input: input,
                output: { [weak self] data in self?.receive(data, generation: runGeneration) },
                termination: { [weak self] exitCode in self?.finish(exitCode: exitCode, generation: runGeneration) }
            )
            publish(desired: true, status: .running, error: nil)
        } catch {
            process = nil
            publish(desired: true, status: .failed, error: "process_launch_failed")
            scheduleFromSafePoint()
        }
    }

    private func receive(_ data: Data, generation: UInt64) {
        guard generation == self.generation, process != nil else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= 64 * 1024 else {
            outputBuffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            parseLine(Data(lineData))
        }
    }

    private func parseLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else { return }
        if let result = MeridianIndexerControlResult.parse(line: line) {
            finalResult = result
            snapshot.lastControlStatus = result.status
            if let preview = result.preview { snapshot.preview = preview }
            if let counts = makeCounts(from: result.counts, action: result.action) { snapshot.counts = counts }
            return
        }
        guard let event = MeridianIndexerProgressEvent.parse(line: line) else { return }
        if let counts = event.counts { snapshot.counts = counts }
        if event.type == "source_failed" || event.type == "source_delete_failed" {
            snapshot.lastErrorCode = event.code
        }
    }

    private func makeCounts(
        from raw: [String: Int],
        action: MeridianControlAction? = nil
    ) -> MeridianIndexerCounts? {
        guard let discovered = raw["discovered"],
              let unchanged = raw["unchanged"],
              let committed = raw["committed"],
              let skipped = raw["skipped"],
              let failed = raw["failed"],
              let cancelled = raw["cancelled"],
              let reconciliationRequired = raw["reconciliation_required"] else {
            guard action == .deleteSource,
                  let matched = raw["matched"],
                  let deleted = raw["deleted"],
                  let deleteFailed = raw["failed"] else { return nil }
            return MeridianIndexerCounts(
                discovered: matched,
                unchanged: 0,
                committed: 0,
                skipped: 0,
                failed: deleteFailed,
                cancelled: 0,
                reconciliationRequired: deleteFailed,
                deleted: deleted,
                deleteFailed: deleteFailed
            )
        }
        return MeridianIndexerCounts(
            discovered: discovered,
            unchanged: unchanged,
            committed: committed,
            skipped: skipped,
            failed: failed,
            cancelled: cancelled,
            reconciliationRequired: reconciliationRequired,
            deleted: raw["deleted"] ?? 0,
            deleteFailed: raw["delete_failed"] ?? 0,
            reconciliationSkipped: raw["reconciliation_skipped"] ?? 0
        )
    }

    private func finish(exitCode: Int32, generation: UInt64) {
        guard generation == self.generation else { return }
        if !outputBuffer.isEmpty {
            parseLine(outputBuffer)
        }
        outputBuffer.removeAll(keepingCapacity: false)
        process = nil
        let result = finalResult
        finalResult = nil
        let status: MeridianIndexerRunStatus
        if cancellationRequested {
            status = .cancelled
        } else if let result,
                  result.action == currentAction,
                  result.exitCode == exitCode,
                  result.isSuccessful {
            status = .completed
        } else if let result,
                  result.action == currentAction,
                  result.exitCode == exitCode,
                  result.status == "partial_failure" {
            status = .partialFailure
        } else if let result,
                  currentAction == .preview,
                  result.action == currentAction,
                  result.exitCode == exitCode,
                  result.status == "uncertain" {
            status = .partialFailure
        } else if let result,
                  result.action == currentAction,
                  result.exitCode == exitCode,
                  result.status == "reconciliation_required" {
            status = .reconciliationRequired
        } else if let result,
                  result.action == currentAction,
                  result.exitCode == exitCode,
                  result.status == "cancelled" {
            status = .cancelled
        } else {
            status = .failed
        }
        snapshot.lastRunAt = scheduler.now
        snapshot.nextRunAt = nil
        snapshot.lastControlStatus = result?.status
        let errorCode: String?
        if cancellationRequested || status == .cancelled {
            errorCode = "cancelled"
        } else if result == nil || result?.action != currentAction {
            errorCode = "missing_final_result"
        } else if result?.exitCode != exitCode {
            errorCode = "control_exit_mismatch"
        } else if status == .failed {
            errorCode = result?.code ?? "control_failed"
        } else if currentAction == .preview, status == .partialFailure {
            errorCode = result?.code ?? "preview_uncertain"
        } else {
            errorCode = result?.code
        }
        publish(desired: true, status: status, error: errorCode)
        if status == .completed, [.index, .rebuild].contains(currentAction) {
            recordSuccessfulIndex(action: currentAction)
        }
        if let pendingAction {
            self.pendingAction = pendingAction
            scheduleNow()
        } else if !snapshot.paused {
            scheduleFromSafePoint()
        }
    }

    private func recordSuccessfulIndex(action: MeridianControlAction) {
        guard let currentDeploymentFingerprint else { return }
        var receipt = readinessReceiptStore.load() ?? MeridianReadinessReceipt()
        receipt.deploymentFingerprint = currentDeploymentFingerprint
        receipt.toolDigest = currentToolDigest
        receipt.lastSuccessfulIndexAt = scheduler.now
        receipt.lastSuccessfulIndexAction = action.rawValue
        receipt.lastResult = .completed
        try? readinessReceiptStore.save(receipt)
        onReadinessEvidenceChanged?()
    }

    private func cancelSchedule() {
        scheduleHandle?.cancel()
        scheduleHandle = nil
    }

    private func publish(
        desired: Bool? = nil,
        status: MeridianIndexerRunStatus? = nil,
        error: String? = nil
    ) {
        if let desired { snapshot.desired = desired }
        if let status { snapshot.status = status }
        snapshot.lastErrorCode = error
        snapshot.generation = generation
        onSnapshot?(snapshot)
    }
}
