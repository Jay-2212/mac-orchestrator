import CryptoKit
import Foundation

struct ReleaseDiscoveryRecord: Codable, Equatable, Sendable {
    let version: String
    let tag: String
    let manifestURL: URL
    let signatureURL: URL
    let draft: Bool
    let prerelease: Bool

    var semanticVersion: SemanticVersion? { try? SemanticVersion(version) }
}

protocol UpdateReleaseDiscoverer {
    func discover() throws -> [ReleaseDiscoveryRecord]
}

protocol UpdateAssetFetcher {
    func fetch(url: URL) throws -> Data
}

enum UpdateNetworkError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case requestFailed(String)
    case nonHTTPResponse
    case unexpectedStatus(Int)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The update asset URL is invalid or not HTTPS."
        case let .requestFailed(message): return "The update asset request failed: \(message)"
        case .nonHTTPResponse: return "The update asset response was not HTTP."
        case let .unexpectedStatus(status): return "The update asset request returned HTTP status \(status)."
        case .responseTooLarge: return "The update asset exceeded the bounded update response size."
        }
    }
}

struct URLSessionUpdateAssetFetcher: UpdateAssetFetcher {
    let timeout: TimeInterval
    let maxBytes: Int

    init(timeout: TimeInterval = 60, maxBytes: Int = 64 * 1024 * 1024) {
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    func fetch(url: URL) throws -> Data {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            throw UpdateNetworkError.invalidURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = NoRedirectURLSession.make(configuration: configuration)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(UpdateNetworkError.requestFailed("request did not complete"))
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(UpdateNetworkError.requestFailed(error.localizedDescription))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(UpdateNetworkError.nonHTTPResponse)
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                result = .failure(UpdateNetworkError.unexpectedStatus(response.statusCode))
                return
            }
            guard let data, data.count <= self.maxBytes else {
                result = .failure(UpdateNetworkError.responseTooLarge)
                return
            }
            result = .success(data)
        }
        task.resume()
        semaphore.wait()
        session.invalidateAndCancel()
        return try result.get()
    }
}

struct GitHubReleaseDiscoverer: UpdateReleaseDiscoverer {
    let repositoryOwner: String
    let repositoryName: String
    let fetcher: UpdateAssetFetcher

    init(
        repositoryOwner: String = "Jay-2212",
        repositoryName: String = "mac-orchestrator",
        fetcher: UpdateAssetFetcher = URLSessionUpdateAssetFetcher()
    ) {
        self.repositoryOwner = repositoryOwner
        self.repositoryName = repositoryName
        self.fetcher = fetcher
    }

    func discover() throws -> [ReleaseDiscoveryRecord] {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases") else {
            throw UpdateNetworkError.invalidURL
        }
        let data = try fetcher.fetch(url: apiURL)
        let releases: [GitHubRelease] = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases.compactMap { release in
            guard let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : nil,
                  let semanticVersion = try? SemanticVersion(version),
                  let manifest = release.assets.first(where: { $0.name == "manifest.json" }),
                  let signature = release.assets.first(where: { $0.name == "manifest.sig" }),
                  let manifestURL = URL(string: manifest.browserDownloadURL),
                  let signatureURL = URL(string: signature.browserDownloadURL),
                  semanticVersion.description == version,
                  manifestURL.scheme?.lowercased() == "https",
                  signatureURL.scheme?.lowercased() == "https" else {
                return nil
            }
            return ReleaseDiscoveryRecord(
                version: version,
                tag: release.tagName,
                manifestURL: manifestURL,
                signatureURL: signatureURL,
                draft: release.draft,
                prerelease: release.prerelease
            )
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease = "prerelease"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

enum UpdateCandidateTrust: String, Codable, Equatable, Sendable {
    case detachedSignature
    case externallyPinnedManifestSHA256
}

struct UpdateCandidate: Equatable, Sendable {
    let discovery: ReleaseDiscoveryRecord
    let rawManifest: Data
    let rawSignature: Data?
    let manifest: ReleaseManifestV1
    let manifestSHA256: String
    let trust: UpdateCandidateTrust
}

enum UpdateEngineError: Error, Equatable, LocalizedError, Sendable {
    case noStableUpdate
    case discoveryVersionInvalid
    case discoveryURLInvalid
    case manifestDecodeFailed
    case manifestDigestMismatch
    case signatureRequired
    case migrationUnavailable
    case transactionDriverUnavailable
    case updateNotAuthenticated
    case transactionFailed(String)
    case postflightFailed(String)

    var errorDescription: String? {
        switch self {
        case .noStableUpdate: return "No authenticated stable update is available."
        case .discoveryVersionInvalid: return "The release discovery version is invalid."
        case .discoveryURLInvalid: return "The release discovery URLs are not immutable release assets."
        case .manifestDecodeFailed: return "The authenticated release manifest could not be decoded."
        case .manifestDigestMismatch: return "The pinned manifest digest did not match the exact downloaded bytes."
        case .signatureRequired: return "The update manifest signature is required for this path."
        case .migrationUnavailable: return "The candidate release did not provide compatible migration logic."
        case .transactionDriverUnavailable: return "No safe update transaction driver is configured."
        case .updateNotAuthenticated: return "The update candidate is not authenticated."
        case let .transactionFailed(message): return "The update transaction failed: \(message)"
        case let .postflightFailed(message): return "The structural update committed, but postflight did not complete: \(message)"
        }
    }
}

enum UpdateRollbackMode: String, Codable, Equatable, Sendable {
    case transactionalFailure
    case explicitlyAuthorizedPersistentDowngrade
}

struct PersistentDowngradeCompatibilityProof: Codable, Equatable, Sendable {
    let sourceVersion: String
    let targetVersion: String
    let runtimeSchemaVersion: Int
    let configurationSchemaVersion: Int
    let targetManifestAuthenticated: Bool
    let explicitlyRequested: Bool
    let mode: UpdateRollbackMode
}

enum PersistentDowngradeError: Error, Equatable, LocalizedError, Sendable {
    case notExplicitlyRequested
    case targetIsNotOlder
    case manifestNotAuthenticated
    case schemaIncompatible

    var errorDescription: String? {
        switch self {
        case .notExplicitlyRequested: return "A persistent downgrade requires an explicit user request."
        case .targetIsNotOlder: return "The persistent downgrade target is not older than the installed version."
        case .manifestNotAuthenticated: return "A persistent downgrade target must be authenticated before use."
        case .schemaIncompatible: return "The persistent downgrade target is not schema-compatible with the installed state."
        }
    }
}

enum UpdateRollbackPolicy {
    static func provePersistentDowngrade(
        from source: InstallationReceiptV1,
        to target: InstallationReceiptV1,
        targetManifestAuthenticated: Bool,
        explicitlyRequested: Bool
    ) throws -> PersistentDowngradeCompatibilityProof {
        guard explicitlyRequested else { throw PersistentDowngradeError.notExplicitlyRequested }
        let sourceVersion = try SemanticVersion(source.productVersion)
        let targetVersion = try SemanticVersion(target.productVersion)
        guard targetVersion < sourceVersion else { throw PersistentDowngradeError.targetIsNotOlder }
        guard targetManifestAuthenticated else { throw PersistentDowngradeError.manifestNotAuthenticated }
        guard source.runtimeSchemaVersion == target.runtimeSchemaVersion,
              source.configurationSchemaVersion == target.configurationSchemaVersion else {
            throw PersistentDowngradeError.schemaIncompatible
        }
        return PersistentDowngradeCompatibilityProof(
            sourceVersion: source.productVersion,
            targetVersion: target.productVersion,
            runtimeSchemaVersion: target.runtimeSchemaVersion,
            configurationSchemaVersion: target.configurationSchemaVersion,
            targetManifestAuthenticated: true,
            explicitlyRequested: true,
            mode: .explicitlyAuthorizedPersistentDowngrade
        )
    }
}

protocol CandidateMigrationProvider {
    func registry(for candidate: UpdateCandidate) throws -> ConfigurationMigrationRegistry
}

struct NoConfigurationMigrationProvider: CandidateMigrationProvider {
    func registry(for candidate: UpdateCandidate) throws -> ConfigurationMigrationRegistry {
        ConfigurationMigrationRegistry(steps: [])
    }
}

struct StagedUpdate: Equatable, Sendable {
    let transactionID: UUID
    let rootURL: URL
    let candidateHelperURL: URL
}

protocol UpdateTransactionDriver {
    func stage(candidate: UpdateCandidate, transactionID: UUID) throws -> StagedUpdate
    func validateCandidate(_ candidate: UpdateCandidate, staged: StagedUpdate) throws
    func prepareMigration(
        candidate: UpdateCandidate,
        staged: StagedUpdate,
        registry: ConfigurationMigrationRegistry
    ) throws -> PreparedConfigurationMigration?
    func backupCurrentState(transactionID: UUID) throws
    func promote(
        candidate: UpdateCandidate,
        staged: StagedUpdate,
        preparedMigration: PreparedConfigurationMigration?,
        transactionID: UUID
    ) throws
    func validateStructuralState(candidate: UpdateCandidate, transactionID: UUID) throws
    func installLaunchAgent(candidate: UpdateCandidate, transactionID: UUID) throws
    func commit(candidate: UpdateCandidate, staged: StagedUpdate, transactionID: UUID) throws -> InstallationReceiptV1
    func postflight(candidate: UpdateCandidate, transactionID: UUID) throws
    func rollback(transactionID: UUID) throws
}

struct UpdateApplyResult: Sendable {
    let transaction: MaintenanceTransactionRecord
    let receipt: InstallationReceiptV1
}

final class UpdateEngine {
    private let currentVersion: SemanticVersion
    private let currentConfigurationSchema: Int
    private let currentRuntimeSchema: Int
    private let architecture: String
    private let operatingSystem: SemanticVersion
    private let discoverer: UpdateReleaseDiscoverer
    private let fetcher: UpdateAssetFetcher
    private let verifier: ManifestSignatureVerifier
    private let ledger: MaintenanceTransactionLedger
    private let driver: UpdateTransactionDriver
    private let lifecycle: MaintenanceLifecycleAdapter
    private let candidateHelper: CandidateHelperMaintenanceAdapter
    private let migrationProvider: CandidateMigrationProvider
    private let faultInjector: MaintenanceFaultInjector

    init(
        currentVersion: SemanticVersion,
        currentConfigurationSchema: Int = AppConfiguration.currentSchemaVersion,
        currentRuntimeSchema: Int = 1,
        architecture: String = "arm64",
        operatingSystem: SemanticVersion,
        discoverer: UpdateReleaseDiscoverer,
        fetcher: UpdateAssetFetcher,
        verifier: ManifestSignatureVerifier = .production,
        ledger: MaintenanceTransactionLedger,
        driver: UpdateTransactionDriver,
        lifecycle: MaintenanceLifecycleAdapter,
        candidateHelper: CandidateHelperMaintenanceAdapter = LocalCandidateHelperMaintenanceAdapter(),
        migrationProvider: CandidateMigrationProvider = NoConfigurationMigrationProvider(),
        faultInjector: MaintenanceFaultInjector = NoMaintenanceFaultInjector()
    ) {
        self.currentVersion = currentVersion
        self.currentConfigurationSchema = currentConfigurationSchema
        self.currentRuntimeSchema = currentRuntimeSchema
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.discoverer = discoverer
        self.fetcher = fetcher
        self.verifier = verifier
        self.ledger = ledger
        self.driver = driver
        self.lifecycle = lifecycle
        self.candidateHelper = candidateHelper
        self.migrationProvider = migrationProvider
        self.faultInjector = faultInjector
    }

    func checkForUpdate() throws -> UpdateCandidate {
        let records = try discoverer.discover()
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { record -> (ReleaseDiscoveryRecord, SemanticVersion)? in
                guard let version = record.semanticVersion else { return nil }
                return (record, version)
            }
            .filter { $0.1 > currentVersion }
            .sorted { $0.1 > $1.1 }
        guard let (record, version) = records.first else { throw UpdateEngineError.noStableUpdate }
        return try authenticate(record: record, expectedVersion: version, requiredSignature: true)
    }

    func checkPinned(
        manifestURL: URL,
        manifestSHA256: String,
        releaseVersion: SemanticVersion,
        signatureURL: URL? = nil,
        signatureSHA256: String? = nil
    ) throws -> UpdateCandidate {
        guard manifestURL.scheme?.lowercased() == "https" else { throw UpdateEngineError.discoveryURLInvalid }
        let rawManifest = try fetcher.fetch(url: manifestURL)
        guard MaintenanceDigest.sha256(data: rawManifest).caseInsensitiveCompare(manifestSHA256) == .orderedSame else {
            throw UpdateEngineError.manifestDigestMismatch
        }
        let rawSignature: Data?
        if let signatureURL {
            let signature = try fetcher.fetch(url: signatureURL)
            rawSignature = signature
            if let signatureSHA256,
               MaintenanceDigest.sha256(data: signature).caseInsensitiveCompare(signatureSHA256) != .orderedSame {
                throw UpdateEngineError.manifestDigestMismatch
            }
            try verifier.verify(manifestBytes: rawManifest, signatureBytes: signature)
        } else {
            rawSignature = nil
        }
        return try decodeCandidate(
            record: ReleaseDiscoveryRecord(
                version: releaseVersion.description,
                tag: "pinned-\(releaseVersion)",
                manifestURL: manifestURL,
                signatureURL: signatureURL ?? manifestURL,
                draft: false,
                prerelease: false
            ),
            rawManifest: rawManifest,
            rawSignature: rawSignature,
            expectedVersion: releaseVersion,
            trust: rawSignature == nil ? .externallyPinnedManifestSHA256 : .detachedSignature
        )
    }

    func apply(_ candidate: UpdateCandidate) throws -> UpdateApplyResult {
        guard candidate.trust == .detachedSignature || candidate.trust == .externallyPinnedManifestSHA256 else {
            throw UpdateEngineError.updateNotAuthenticated
        }
        try revalidateCandidate(candidate)
        let transaction = try ledger.begin(
            targetVersion: candidate.manifest.product.version,
            manifestSHA256: candidate.manifestSHA256,
            manifestURL: candidate.discovery.manifestURL
        )
        var committed = false
        var servicesQuiesced = false
        var handoff: CandidateHelperMaintenanceHandoff?
        do {
            try faultInjector.check(.beforeManifestAuthentication)
            if let rawSignature = candidate.rawSignature {
                try verifier.verify(manifestBytes: candidate.rawManifest, signatureBytes: rawSignature)
            }
            try faultInjector.check(.afterManifestAuthentication)
            try ledger.advance(transaction.id, to: .manifestAuthenticated)

            try faultInjector.check(.beforeCandidateStage)
            let staged = try driver.stage(candidate: candidate, transactionID: transaction.id)
            handoff = try candidateHelper.prepareHandoff(
                candidateURL: staged.candidateHelperURL,
                candidateVersion: candidate.manifest.product.version,
                expectedSHA256: candidate.manifest.helper.sha256
            )
            try faultInjector.check(.afterCandidateStage)
            try ledger.advance(transaction.id, to: .candidateStaged)

            try faultInjector.check(.beforeCandidateValidation)
            try driver.validateCandidate(candidate, staged: staged)
            try faultInjector.check(.afterCandidateValidation)
            try ledger.advance(transaction.id, to: .candidateValidated)

            let registry = try migrationProvider.registry(for: candidate)
            try faultInjector.check(.beforeMigrationPreparation)
            let prepared = try driver.prepareMigration(candidate: candidate, staged: staged, registry: registry)
            // Phase 3 validates and stages candidate bytes in the current
            // helper, but does not execute an extracted candidate helper.
            // Refuse schema-changing migrations until the bounded
            // candidate-helper execution handoff exists; same-schema updates
            // remain safe and truthful.
            if let prepared, prepared.plan.sourceSchema != prepared.plan.targetSchema {
                throw UpdateEngineError.migrationUnavailable
            }
            try faultInjector.check(.afterMigrationPreparation)
            try ledger.advance(transaction.id, to: .migrationPrepared)

            try faultInjector.check(.beforeCurrentStateBackup)
            try driver.backupCurrentState(transactionID: transaction.id)
            try faultInjector.check(.afterCurrentStateBackup)
            try ledger.advance(transaction.id, to: .currentStateBackedUp)

            if let handoff { try candidateHelper.reverifyHandoff(handoff) }
            try faultInjector.check(.beforeServicesQuiesce)
            _ = try lifecycle.quiesce()
            servicesQuiesced = true
            try faultInjector.check(.afterServicesQuiesce)
            try ledger.advance(transaction.id, to: .servicesQuiesced)

            try faultInjector.check(.beforePromotion)
            try driver.promote(candidate: candidate, staged: staged, preparedMigration: prepared, transactionID: transaction.id)
            try faultInjector.check(.afterPromotion)
            try ledger.advance(transaction.id, to: .promoting)

            try faultInjector.check(.beforeStructuralValidation)
            try driver.validateStructuralState(candidate: candidate, transactionID: transaction.id)
            try faultInjector.check(.afterStructuralValidation)
            try ledger.advance(transaction.id, to: .structurallyValidated)

            try faultInjector.check(.beforeLaunchAgentInstall)
            try driver.installLaunchAgent(candidate: candidate, transactionID: transaction.id)
            try faultInjector.check(.afterLaunchAgentInstall)
            try ledger.advance(transaction.id, to: .launchAgentInstalled)

            try faultInjector.check(.beforeCommit)
            let receipt = try driver.commit(candidate: candidate, staged: staged, transactionID: transaction.id)
            try faultInjector.check(.afterCommit)
            try ledger.advance(transaction.id, to: .committed)
            committed = true

            // TCC/human onboarding is post-commit. A failure here is surfaced
            // as postflight, never as a filesystem rollback.
            try ledger.advance(transaction.id, to: .postflight)
            var postflightFailures: [String] = []
            do {
                try faultInjector.check(.postflight)
                try driver.postflight(candidate: candidate, transactionID: transaction.id)
            } catch {
                postflightFailures.append(error.localizedDescription)
            }
            if servicesQuiesced {
                do {
                    try lifecycle.restore()
                    servicesQuiesced = false
                } catch {
                    postflightFailures.append("maintenance restore failed: \(error.localizedDescription)")
                }
            }
            if !postflightFailures.isEmpty {
                throw UpdateEngineError.postflightFailed(postflightFailures.joined(separator: "; "))
            }
            let final = try ledger.load(transaction.id) ?? transaction
            return UpdateApplyResult(transaction: final, receipt: receipt)
        } catch {
            var failureToRecord: Error = error
            if !committed {
                do {
                    try faultInjector.check(.beforeRollback)
                    try driver.rollback(transactionID: transaction.id)
                    try faultInjector.check(.afterRollback)
                } catch {
                    failureToRecord = UpdateEngineError.transactionFailed(
                        "update failed: \(failureToRecord.localizedDescription); rollback failed: \(error.localizedDescription)"
                    )
                }
                try? lifecycle.restore()
                servicesQuiesced = false
                _ = try? ledger.markFailure(transaction.id, error: failureToRecord)
            } else if servicesQuiesced {
                // A committed transaction is never rolled back for postflight
                // or TCC failure, but the maintenance seam must still close.
                try? lifecycle.restore()
                servicesQuiesced = false
            }
            if let updateError = failureToRecord as? UpdateEngineError { throw updateError }
            throw UpdateEngineError.transactionFailed(failureToRecord.localizedDescription)
        }
    }

    private func authenticate(
        record: ReleaseDiscoveryRecord,
        expectedVersion: SemanticVersion,
        requiredSignature: Bool
    ) throws -> UpdateCandidate {
        try validateAutomaticDiscoveryURLs(record, version: expectedVersion)
        let rawManifest = try fetcher.fetch(url: record.manifestURL)
        let rawSignature = try fetcher.fetch(url: record.signatureURL)
        if requiredSignature {
            try verifier.verify(manifestBytes: rawManifest, signatureBytes: rawSignature)
        }
        return try decodeCandidate(
            record: record,
            rawManifest: rawManifest,
            rawSignature: rawSignature,
            expectedVersion: expectedVersion,
            trust: .detachedSignature
        )
    }

    private func revalidateCandidate(_ candidate: UpdateCandidate) throws {
        let actualDigest = MaintenanceDigest.sha256(data: candidate.rawManifest)
        guard actualDigest.caseInsensitiveCompare(candidate.manifestSHA256) == .orderedSame else {
            throw UpdateEngineError.manifestDigestMismatch
        }

        let expectedVersion: SemanticVersion
        do {
            expectedVersion = try SemanticVersion(candidate.discovery.version)
        } catch {
            throw UpdateEngineError.discoveryVersionInvalid
        }

        switch candidate.trust {
        case .detachedSignature:
            guard let rawSignature = candidate.rawSignature else {
                throw UpdateEngineError.signatureRequired
            }
            try verifier.verify(manifestBytes: candidate.rawManifest, signatureBytes: rawSignature)
        case .externallyPinnedManifestSHA256:
            if let rawSignature = candidate.rawSignature {
                try verifier.verify(manifestBytes: candidate.rawManifest, signatureBytes: rawSignature)
            }
        }

        let decoded = try decodeCandidate(
            record: candidate.discovery,
            rawManifest: candidate.rawManifest,
            rawSignature: candidate.rawSignature,
            expectedVersion: expectedVersion,
            trust: candidate.trust
        )
        guard decoded.manifest == candidate.manifest,
              decoded.manifestSHA256.caseInsensitiveCompare(candidate.manifestSHA256) == .orderedSame else {
            throw UpdateEngineError.manifestDecodeFailed
        }
    }

    private func validateAutomaticDiscoveryURLs(_ record: ReleaseDiscoveryRecord, version: SemanticVersion) throws {
        let base = "/Jay-2212/mac-orchestrator/releases/download/v\(version)"
        guard record.manifestURL.scheme?.lowercased() == "https",
              record.signatureURL.scheme?.lowercased() == "https",
              record.manifestURL.host?.lowercased() == "github.com",
              record.signatureURL.host?.lowercased() == "github.com",
              record.manifestURL.path == base + "/manifest.json",
              record.signatureURL.path == base + "/manifest.sig",
              record.manifestURL.query == nil,
              record.manifestURL.fragment == nil,
              record.signatureURL.query == nil,
              record.signatureURL.fragment == nil else {
            throw UpdateEngineError.discoveryURLInvalid
        }
    }

    private func decodeCandidate(
        record: ReleaseDiscoveryRecord,
        rawManifest: Data,
        rawSignature: Data?,
        expectedVersion: SemanticVersion,
        trust: UpdateCandidateTrust
    ) throws -> UpdateCandidate {
        guard hasStrictManifestShape(rawManifest) else { throw UpdateEngineError.manifestDecodeFailed }
        let manifest: ReleaseManifestV1
        do {
            manifest = try JSONDecoder().decode(ReleaseManifestV1.self, from: rawManifest)
        } catch {
            throw UpdateEngineError.manifestDecodeFailed
        }
        do {
            _ = try manifest.validated(
                expectedVersion: expectedVersion,
                currentVersion: currentVersion,
                currentConfigurationSchema: currentConfigurationSchema,
                currentRuntimeSchema: currentRuntimeSchema,
                architecture: architecture,
                operatingSystem: operatingSystem
            )
        } catch {
            throw error
        }
        let expectedManifestPath = "/Jay-2212/mac-orchestrator/releases/download/v\(manifest.product.version)/manifest.json"
        guard record.manifestURL.host?.lowercased() == "github.com",
              record.manifestURL.path == expectedManifestPath,
              record.manifestURL.query == nil,
              record.manifestURL.fragment == nil else {
            throw UpdateEngineError.discoveryURLInvalid
        }
        guard record.version == manifest.product.version else { throw UpdateEngineError.discoveryVersionInvalid }
        return UpdateCandidate(
            discovery: record,
            rawManifest: rawManifest,
            rawSignature: rawSignature,
            manifest: manifest,
            manifestSHA256: MaintenanceDigest.sha256(data: rawManifest),
            trust: trust
        )
    }

    private func hasStrictManifestShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = object as? [String: Any],
              strictObject(root, allowed: ["$schema", "schemaVersion", "product", "bootstrap", "platform", "helper", "runtime", "ngrok", "compatibility"], required: ["schemaVersion", "product", "bootstrap", "platform", "helper", "runtime", "ngrok", "compatibility"]) else {
            return false
        }
        if let schema = root["$schema"] as? String, schema != "./manifest.schema.json" {
            return false
        }
        guard let product = root["product"] as? [String: Any],
              strictObject(product, allowed: ["name", "version"], required: ["name", "version"]),
              let bootstrap = root["bootstrap"] as? [String: Any],
              strictObject(bootstrap, allowed: ["version", "url", "sha256"], required: ["version", "url", "sha256"]),
              let platform = root["platform"] as? [String: Any],
              strictObject(platform, allowed: ["architecture", "minimumMacOS"], required: ["architecture", "minimumMacOS"]),
              let helper = root["helper"] as? [String: Any],
              strictObject(helper, allowed: ["url", "sha256", "architecture", "bundleIdentifier", "version", "signing"], required: ["url", "sha256", "architecture", "bundleIdentifier", "version", "signing"]),
              let signing = helper["signing"] as? [String: Any],
              strictObject(signing, allowed: ["mode"], required: ["mode"]),
              let runtime = root["runtime"] as? [String: Any],
              strictObject(runtime, allowed: ["schemaVersion", "uv", "python", "lockSha256", "corePayload"], required: ["schemaVersion", "uv", "python", "lockSha256", "corePayload"]),
              let uv = runtime["uv"] as? [String: Any],
              strictObject(uv, allowed: ["version", "url", "sha256"], required: ["version", "url", "sha256"]),
              let python = runtime["python"] as? [String: Any],
              strictObject(python, allowed: ["managedVersion"], required: ["managedVersion"]),
              let core = runtime["corePayload"] as? [String: Any],
              strictObject(core, allowed: ["url", "sha256", "format", "files"], required: ["url", "sha256", "format", "files"]),
              let ngrok = root["ngrok"] as? [String: Any],
              strictObject(ngrok, allowed: ["version", "archiveUrl", "archiveSha256", "archiveFormat", "executableName", "developerIdAuthority", "developerIdTeam", "agentApiVersion"], required: ["version", "archiveUrl", "archiveSha256", "archiveFormat", "executableName", "developerIdAuthority", "developerIdTeam", "agentApiVersion"]),
              let compatibility = root["compatibility"] as? [String: Any],
              strictObject(compatibility, allowed: ["runtimeSchema", "configurationSchema"], required: ["runtimeSchema", "configurationSchema"]),
              let runtimeSchema = compatibility["runtimeSchema"] as? [String: Any],
              strictObject(runtimeSchema, allowed: ["minimum", "maximum"], required: ["minimum", "maximum"]),
              let configurationSchema = compatibility["configurationSchema"] as? [String: Any],
              strictObject(configurationSchema, allowed: ["minimum", "maximum"], required: ["minimum", "maximum"]) else {
            return false
        }
        return true
    }

    private func strictObject(_ object: [String: Any], allowed: [String], required: [String]) -> Bool {
        let keys = Set(object.keys)
        return keys.isSubset(of: Set(allowed)) && Set(required).isSubset(of: keys)
    }
}
