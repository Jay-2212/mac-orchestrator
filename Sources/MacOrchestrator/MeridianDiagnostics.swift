import Foundation

struct MeridianDiagnosticFacts: Equatable, Sendable {
    let enabled: Bool
    let configurationValid: Bool
    let sourcesSelected: Bool
    let deploymentValid: Bool
    let toolInstalled: Bool
    let toolTrusted: Bool
    let toolMatches: Bool
    let coreVersionVerified: Bool
    let diagnosticsVerified: Bool
    let migrationsCompatible: Bool
    let lastSuccessfulIndexVerified: Bool
    let semanticReadinessVerified: Bool
    let schedulerConfigured: Bool
    let paused: Bool
    let running: Bool
    let noOverlap: Bool
    let reconciliationRequired: Bool

    static let disabled = MeridianDiagnosticFacts(
        enabled: false,
        configurationValid: false,
        sourcesSelected: false,
        deploymentValid: false,
        toolInstalled: false,
        toolTrusted: false,
        toolMatches: false,
        coreVersionVerified: false,
        diagnosticsVerified: false,
        migrationsCompatible: false,
        lastSuccessfulIndexVerified: false,
        semanticReadinessVerified: false,
        schedulerConfigured: false,
        paused: false,
        running: false,
        noOverlap: true,
        reconciliationRequired: false
    )
}

protocol MeridianDiagnosticProviding {
    func inspect(configuration: AppConfiguration?) throws -> MeridianDiagnosticFacts
}

struct SystemMeridianDiagnosticProvider: MeridianDiagnosticProviding {
    let supportDirectory: URL
    let snapshot: MeridianIndexerSnapshot?
    let fileManager: FileManager

    init(
        supportDirectory: URL = DiagnosticPathSet.defaultPaths().supportDirectory,
        snapshot: MeridianIndexerSnapshot? = nil,
        fileManager: FileManager = .default
    ) {
        self.supportDirectory = supportDirectory
        self.snapshot = snapshot
        self.fileManager = fileManager
    }

    func inspect(configuration: AppConfiguration?) throws -> MeridianDiagnosticFacts {
        guard let configuration else { return .disabled }
        let indexer = configuration.integration.meridianIndexer
        let enabled = indexer.enabled && configuration.desiredCapabilities["meridian.search"] == true
        guard enabled else { return .disabled }

        let configurationValid = (try? configuration.validated()) != nil
        let sourcesSelected = !indexer.scopes.isEmpty
        let deploymentValid = configuration.integration.meridianDeploymentURL.flatMap {
            MeridianReadinessEvaluator.fingerprint(for: $0)
        } != nil
        let meridianDirectory = supportDirectory.appendingPathComponent("meridian", isDirectory: true)
        let installer = MeridianIndexerToolInstaller(rootURL: meridianDirectory, fileManager: fileManager)
        let toolInstalled = MeridianIndexerToolInstaller.isValidOwnedExecutable(
            at: installer.installedURL,
            fileManager: fileManager
        )
        let receipt = installer.receipt()
        let currentDigest = installer.currentDigest()
        let toolTrusted = receipt?.isValid == true
        let toolMatches = toolTrusted && receipt?.digest.lowercased() == currentDigest?.lowercased()
        let readinessReceipt = FileMeridianReadinessReceiptStore(
            url: meridianDirectory.appendingPathComponent("readiness-receipt.json"),
            fileManager: fileManager
        ).load()
        let probe = readinessReceipt?.lastProbe
        let deploymentFingerprint = configuration.integration.meridianDeploymentURL.flatMap {
            MeridianReadinessEvaluator.fingerprint(for: $0)
        }
        let currentProbe = probe?.at.map { $0 <= Date() } == true
            && probe?.deploymentFingerprint == deploymentFingerprint
            && probe?.toolDigest?.lowercased() == currentDigest?.lowercased()
        let coreVersionVerified = currentProbe && probe?.apiVersion == "1.0.0"
        let diagnosticsVerified = currentProbe && probe?.schemaVersion == 2
        let migrationsCompatible = currentProbe && probe?.schemaVersion == 2
        let lastSuccessfulIndexVerified = readinessReceipt?.lastSuccessfulIndexAt != nil
            && readinessReceipt?.lastSuccessfulIndexAt.map { $0 <= Date() } == true
            && readinessReceipt?.lastSuccessfulIndexAction.map { ["index", "rebuild"].contains($0) } == true
            && readinessReceipt?.deploymentFingerprint == deploymentFingerprint
            && readinessReceipt?.toolDigest?.lowercased() == currentDigest?.lowercased()
            && toolMatches
        let semanticReadinessVerified = currentProbe
            && probe?.passed == true
            && lastSuccessfulIndexVerified
            && toolMatches

        let selectedSnapshot = snapshot
        return MeridianDiagnosticFacts(
            enabled: true,
            configurationValid: configurationValid,
            sourcesSelected: sourcesSelected,
            deploymentValid: deploymentValid,
            toolInstalled: toolInstalled,
            toolTrusted: toolTrusted,
            toolMatches: toolMatches,
            coreVersionVerified: coreVersionVerified,
            diagnosticsVerified: diagnosticsVerified,
            migrationsCompatible: migrationsCompatible,
            lastSuccessfulIndexVerified: lastSuccessfulIndexVerified,
            semanticReadinessVerified: semanticReadinessVerified,
            schedulerConfigured: indexer.scheduleMode == .manual
                || selectedSnapshot?.nextRunAt != nil
                || selectedSnapshot == nil,
            paused: selectedSnapshot?.paused == true,
            running: selectedSnapshot?.status == .running || selectedSnapshot?.status == .cancelling,
            noOverlap: true,
            reconciliationRequired: selectedSnapshot?.status == .reconciliationRequired
                || readinessReceipt?.lastResult == .reconciliationRequired
        )
    }
}

extension DiagnosticChecks {
    static func meridianConfiguration(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.configuration", "Meridian configuration", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        guard facts.configurationValid, facts.deploymentValid else {
            return result("meridian.configuration", "Meridian configuration", .fail, "Meridian configuration or HTTPS deployment is invalid.")
        }
        return result("meridian.configuration", "Meridian configuration", .pass, "Verified.")
    }

    static func meridianSources(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.sources", "Meridian source selection", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        return facts.sourcesSelected
            ? result("meridian.sources", "Meridian source selection", .pass, "Explicit source selection is present.")
            : result("meridian.sources", "Meridian source selection", .fail, "Choose at least one explicit Meridian source before indexing.")
    }

    static func keychainMeridian(_ facts: KeychainPresenceFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else {
            return result("meridian.credential", "Meridian Core credential", .skip, "Meridian is disabled; no credential query was required.")
        }
        guard let facts else {
            return result("meridian.credential", "Meridian Core credential", .warn, "Keychain credential presence could not be determined.")
        }
        switch facts.presence(for: .meridianIngestToken) {
        case .present:
            return result("meridian.credential", "Meridian Core credential", .pass, "Credential presence verified; secret value was not read.")
        case .absent, nil:
            return result("meridian.credential", "Meridian Core credential", .fail, "Meridian is enabled but its Core credential is absent.")
        case .inaccessible:
            return result("meridian.credential", "Meridian Core credential", .warn, "Meridian Core credential presence is inaccessible.")
        }
    }

    static func meridianTool(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.tool", "Meridian indexer trust", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        guard facts.toolInstalled else {
            return result("meridian.tool", "Meridian indexer trust", .fail, "The optional Meridian indexer is not installed as a valid executable.")
        }
        guard facts.toolTrusted, facts.toolMatches else {
            return result("meridian.tool", "Meridian indexer trust", .fail, "The optional Meridian indexer digest or trust receipt is invalid.")
        }
        return result("meridian.tool", "Meridian indexer trust", .pass, "Pinned executable and digest are verified.")
    }

    static func meridianCompatibility(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.compatibility", "Meridian Core compatibility", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        guard facts.coreVersionVerified else {
            return result("meridian.compatibility", "Meridian Core compatibility", .warn, "Core version compatibility has not been verified by the Meridian probe.")
        }
        guard facts.diagnosticsVerified, facts.migrationsCompatible else {
            return result("meridian.compatibility", "Meridian Core compatibility", .fail, "Authenticated Core diagnostics or migrations are not healthy.")
        }
        return result("meridian.compatibility", "Meridian Core compatibility", .pass, "Core version, diagnostics, and migrations are compatible.")
    }

    static func meridianLastIndex(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.last-index", "Meridian last successful index", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        return facts.lastSuccessfulIndexVerified
            ? result("meridian.last-index", "Meridian last successful index", .pass, "A user-selected successful indexing result is recorded.")
            : result("meridian.last-index", "Meridian last successful index", .warn, "No successful user-selected indexing result is recorded.")
    }

    static func meridianSemanticReadiness(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.semantic-readiness", "Meridian semantic readiness", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        return facts.semanticReadinessVerified
            ? result("meridian.semantic-readiness", "Meridian semantic readiness", .pass, "The Meridian-owned semantic readiness probe passed.")
            : result("meridian.semantic-readiness", "Meridian semantic readiness", .warn, "The Meridian-owned semantic readiness probe has not passed.")
    }

    static func meridianScheduler(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.scheduler", "Meridian scheduler", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        if facts.paused { return result("meridian.scheduler", "Meridian scheduler", .warn, "Meridian indexing is paused.") }
        return facts.schedulerConfigured
            ? result("meridian.scheduler", "Meridian scheduler", .pass, "Meridian schedule is bounded and configured.")
            : result("meridian.scheduler", "Meridian scheduler", .warn, "Meridian schedule state is not currently observed.")
    }

    static func meridianRunState(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("meridian.run-state", "Meridian run state", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        if facts.reconciliationRequired {
            return result("meridian.run-state", "Meridian run state", .warn, "Meridian reported that reconciliation is required.")
        }
        if facts.running {
            return result("meridian.run-state", "Meridian run state", .pass, "One Meridian run is currently active; overlap is prevented.")
        }
        return facts.noOverlap
            ? result("meridian.run-state", "Meridian run state", .pass, "No overlapping Meridian run is observed.")
            : result("meridian.run-state", "Meridian run state", .fail, "Meridian run overlap could not be ruled out.")
    }

    static func meridianAggregate(_ facts: MeridianDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, facts.enabled else {
            return result("capability.meridian", "Meridian capability", .skip, "Meridian is disabled; dependent checks are skipped.")
        }
        let checks = [
            facts.configurationValid && facts.sourcesSelected && facts.deploymentValid,
            facts.toolInstalled && facts.toolTrusted && facts.toolMatches,
            facts.lastSuccessfulIndexVerified && facts.semanticReadinessVerified,
        ]
        if checks.allSatisfy({ $0 }) {
            return result("capability.meridian", "Meridian capability", .pass, "Meridian capability readiness is verified.")
        }
        return result("capability.meridian", "Meridian capability", .warn, "Meridian is enabled but readiness evidence is incomplete.")
    }
}
