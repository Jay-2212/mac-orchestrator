import Darwin
import Foundation

enum FilesystemUpdateError: Error, Equatable, LocalizedError, Sendable {
    case unsafePath
    case missingPayload(String)
    case payloadDigestMismatch(String)
    case archiveInspectionFailed(String)
    case extractionFailed(String)
    case structuralValidationFailed(String)
    case backupFailed
    case promotionFailed
    case launchAgentFailed

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The update path is outside the project-owned root or is symlinked."
        case let .missingPayload(name): return "The staged update is missing payload \(name)."
        case let .payloadDigestMismatch(name): return "The staged update payload \(name) changed after hashing."
        case let .archiveInspectionFailed(name): return "The update archive \(name) failed path inspection."
        case let .extractionFailed(name): return "The update archive \(name) could not be extracted safely."
        case let .structuralValidationFailed(name): return "The promoted update failed structural validation: \(name)."
        case .backupFailed: return "The current installation could not be backed up safely."
        case .promotionFailed: return "The staged installation could not be promoted safely."
        case .launchAgentFailed: return "The managed LaunchAgent could not be installed safely."
        }
    }
}

struct FilesystemUpdateTransactionDriver: UpdateTransactionDriver {
    let supportDirectory: URL
    let installDirectory: URL
    let configurationURL: URL
    let launchAgentURL: URL
    let fetcher: UpdateAssetFetcher
    let commandRunner: MaintenanceCommandRunner
    let fileManager: FileManager

    init(
        supportDirectory: URL,
        fetcher: UpdateAssetFetcher,
        commandRunner: MaintenanceCommandRunner = SystemMaintenanceCommandRunner(),
        fileManager: FileManager = .default,
        launchAgentURL: URL? = nil
    ) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.installDirectory = self.supportDirectory.appendingPathComponent("install", isDirectory: true)
        self.configurationURL = self.supportDirectory.appendingPathComponent("config.json", isDirectory: false)
        self.launchAgentURL = (launchAgentURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.jay.mac-orchestrator.plist", isDirectory: false)).standardizedFileURL
        self.fetcher = fetcher
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func stage(candidate: UpdateCandidate, transactionID: UUID) throws -> StagedUpdate {
        let root = installDirectory.appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(transactionID.uuidString.lowercased(), isDirectory: true)
        let payloadDirectory = root.appendingPathComponent("payloads", isDirectory: true)
        let candidateDirectory = root.appendingPathComponent("candidate", isDirectory: true)
        try createOwnedDirectory(payloadDirectory)
        try createOwnedDirectory(candidateDirectory)
        try createOwnedDirectory(candidateDirectory.appendingPathComponent("app", isDirectory: true))
        try createOwnedDirectory(candidateDirectory.appendingPathComponent("runtime", isDirectory: true))
        try createOwnedDirectory(candidateDirectory.appendingPathComponent("runtime/bin", isDirectory: true))
        try createOwnedDirectory(candidateDirectory.appendingPathComponent("remote/ngrok", isDirectory: true))

        try writeOwned(candidate.rawManifest, to: root.appendingPathComponent("manifest.json"))
        if let rawSignature = candidate.rawSignature {
            try writeOwned(rawSignature, to: root.appendingPathComponent("manifest.sig"))
        }

        let helperArchive = try fetchAndStore(
            name: "helper",
            url: candidate.manifest.helper.url,
            expectedSHA256: candidate.manifest.helper.sha256,
            directory: payloadDirectory,
            fileName: "Mac-Orchestrator-arm64.zip"
        )
        let bootstrap = try fetchAndStore(
            name: "bootstrap",
            url: candidate.manifest.bootstrap.url,
            expectedSHA256: candidate.manifest.bootstrap.sha256,
            directory: payloadDirectory,
            fileName: "bootstrap.sh"
        )
        let uv = try fetchAndStore(
            name: "uv",
            url: candidate.manifest.runtime.uv.url,
            expectedSHA256: candidate.manifest.runtime.uv.sha256,
            directory: payloadDirectory,
            fileName: "uv-arm64"
        )
        let core = try fetchAndStore(
            name: "core payload",
            url: candidate.manifest.runtime.corePayload.url,
            expectedSHA256: candidate.manifest.runtime.corePayload.sha256,
            directory: payloadDirectory,
            fileName: "core-payload.tar.gz"
        )
        let ngrok = try fetchAndStore(
            name: "ngrok",
            url: candidate.manifest.ngrok.archiveUrl,
            expectedSHA256: candidate.manifest.ngrok.archiveSha256,
            directory: payloadDirectory,
            fileName: "ngrok-arm64.zip"
        )

        try inspectZip(helperArchive, named: "helper")
        try inspectTar(core, named: "core payload")
        try inspectZip(ngrok, named: "ngrok")
        try extractZip(helperArchive, to: candidateDirectory.appendingPathComponent("app", isDirectory: true), named: "helper")
        try extractTar(core, to: candidateDirectory.appendingPathComponent("runtime", isDirectory: true), named: "core payload")
        try fileManager.copyItem(at: uv, to: candidateDirectory.appendingPathComponent("runtime/bin/uv"))
        try extractZip(ngrok, to: candidateDirectory.appendingPathComponent("remote/ngrok", isDirectory: true), named: "ngrok")
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bootstrap.path)

        return StagedUpdate(
            transactionID: transactionID,
            rootURL: root,
            candidateHelperURL: helperArchive
        )
    }

    func validateCandidate(_ candidate: UpdateCandidate, staged: StagedUpdate) throws {
        let app = staged.rootURL.appendingPathComponent("candidate/app/Mac Orchestrator.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/MacOS/MacOrchestrator", isDirectory: false)
        let runtime = staged.rootURL.appendingPathComponent("candidate/runtime", isDirectory: true)
        let remote = staged.rootURL.appendingPathComponent("candidate/remote/ngrok/ngrok", isDirectory: false)
        let requiredRuntimeFiles = ["automac_mcp.py", "pyproject.toml", "uv.lock", "bin/uv"]
        try validateCandidateHelper(app: app, binary: helper, candidate: candidate)
        guard fileManager.isExecutableFile(atPath: helper.path) else {
            throw FilesystemUpdateError.structuralValidationFailed("candidate helper")
        }
        for file in requiredRuntimeFiles where !fileManager.fileExists(atPath: runtime.appendingPathComponent(file).path) {
            throw FilesystemUpdateError.structuralValidationFailed("candidate runtime \(file)")
        }
        guard fileManager.isExecutableFile(atPath: remote.path) else {
            throw FilesystemUpdateError.structuralValidationFailed("candidate ngrok")
        }
        try validateNgrokBinary(remote, candidate: candidate)
        let payloads: [(String, URL, String)] = [
            ("helper", staged.rootURL.appendingPathComponent("payloads/Mac-Orchestrator-arm64.zip"), candidate.manifest.helper.sha256),
            ("bootstrap", staged.rootURL.appendingPathComponent("payloads/bootstrap.sh"), candidate.manifest.bootstrap.sha256),
            ("uv", staged.rootURL.appendingPathComponent("payloads/uv-arm64"), candidate.manifest.runtime.uv.sha256),
            ("core payload", staged.rootURL.appendingPathComponent("payloads/core-payload.tar.gz"), candidate.manifest.runtime.corePayload.sha256),
            ("ngrok", staged.rootURL.appendingPathComponent("payloads/ngrok-arm64.zip"), candidate.manifest.ngrok.archiveSha256),
        ]
        for (name, path, digest) in payloads {
            guard try MaintenanceDigest.sha256(file: path).caseInsensitiveCompare(digest) == .orderedSame else {
                throw FilesystemUpdateError.payloadDigestMismatch(name)
            }
        }
        for path in [
            staged.rootURL.appendingPathComponent("candidate/app", isDirectory: true),
            staged.rootURL.appendingPathComponent("candidate/runtime", isDirectory: true),
            staged.rootURL.appendingPathComponent("candidate/remote", isDirectory: true),
        ] where containsSymlinkInTree(path) {
            throw FilesystemUpdateError.unsafePath
        }
    }

    func prepareMigration(
        candidate: UpdateCandidate,
        staged: StagedUpdate,
        registry: ConfigurationMigrationRegistry
    ) throws -> PreparedConfigurationMigration? {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        let source = try Data(contentsOf: configurationURL)
        guard let object = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
              let sourceSchema = object["schemaVersion"] as? Int else {
            throw ConfigurationMigrationError.candidateInvalid
        }
        let targetSchema = max(sourceSchema, registry.steps.map(\.targetSchema).max() ?? sourceSchema)
        let plan = try registry.plan(sourceSchema: sourceSchema, targetSchema: targetSchema)
        return try ConfigurationMigrationEngine.prepare(
            rawConfiguration: source,
            plan: plan,
            candidateValidator: { data in
                guard let migrated = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let schema = migrated["schemaVersion"] as? Int,
                      schema == targetSchema else {
                    throw ConfigurationMigrationError.candidateInvalid
                }
            }
        )
    }

    func backupCurrentState(transactionID: UUID) throws {
        let root = transactionRoot(transactionID).appendingPathComponent("previous", isDirectory: true)
        do {
            try createOwnedDirectory(root)
            var presence: [String: Bool] = [:]
            for (name, url) in activePaths {
                let present = fileManager.fileExists(atPath: url.path)
                presence[name] = present
                if present {
                    guard isSafeOwnedItem(url, directory: url.hasDirectoryPath) else {
                        throw FilesystemUpdateError.unsafePath
                    }
                    try fileManager.copyItem(at: url, to: root.appendingPathComponent(name, isDirectory: url.hasDirectoryPath))
                }
            }
            let receiptURL = installDirectory.appendingPathComponent(InstallationReceiptStore.receiptFileName, isDirectory: false)
            let receiptPresent = fileManager.fileExists(atPath: receiptURL.path)
            presence["receipt"] = receiptPresent
            if receiptPresent {
                guard !containsSymlink(receiptURL), isOwned(receiptURL) else { throw FilesystemUpdateError.unsafePath }
                try fileManager.copyItem(at: receiptURL, to: root.appendingPathComponent("receipt.json", isDirectory: false))
            }
            let launchAgentPresent = fileManager.fileExists(atPath: launchAgentURL.path)
            presence["launchAgent"] = launchAgentPresent
            if launchAgentPresent {
                guard !containsSymlink(launchAgentURL),
                      isOwned(launchAgentURL),
                      isOwned(launchAgentURL.deletingLastPathComponent()) else {
                    throw FilesystemUpdateError.unsafePath
                }
                try fileManager.copyItem(at: launchAgentURL, to: root.appendingPathComponent("launch-agent.plist", isDirectory: false))
            }
            let data = try JSONSerialization.data(withJSONObject: presence, options: [.sortedKeys])
            try writeOwned(data, to: root.appendingPathComponent("presence.json"))
        } catch let error as FilesystemUpdateError {
            throw error
        } catch {
            throw FilesystemUpdateError.backupFailed
        }
    }

    func promote(
        candidate: UpdateCandidate,
        staged: StagedUpdate,
        preparedMigration: PreparedConfigurationMigration?,
        transactionID: UUID
    ) throws {
        let candidateRoot = staged.rootURL.appendingPathComponent("candidate", isDirectory: true)
        do {
            for (name, active) in activePaths where name != "config.json" {
                let replacement = candidateRoot.appendingPathComponent(name, isDirectory: true)
                if !fileManager.fileExists(atPath: replacement.path) { continue }
                try replaceDirectory(replacement, at: active)
            }
            if let preparedMigration {
                try writeOwned(preparedMigration.candidate, to: configurationURL)
            }
        } catch let error as FilesystemUpdateError {
            throw error
        } catch {
            throw FilesystemUpdateError.promotionFailed
        }
    }

    func validateStructuralState(candidate: UpdateCandidate, transactionID: UUID) throws {
        let runtime = supportDirectory.appendingPathComponent("runtime", isDirectory: true)
        let app = supportDirectory.appendingPathComponent("app/Mac Orchestrator.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/MacOS/MacOrchestrator", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: helper.path) else {
            throw FilesystemUpdateError.structuralValidationFailed("installed helper")
        }
        try validateInstalledHelper(app: app, binary: helper, candidate: candidate)
        for file in ["automac_mcp.py", "pyproject.toml", "uv.lock", "bin/uv"] where !fileManager.fileExists(atPath: runtime.appendingPathComponent(file).path) {
            throw FilesystemUpdateError.structuralValidationFailed("installed runtime \(file)")
        }
        let installedNgrok = supportDirectory.appendingPathComponent("remote/ngrok/ngrok", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: installedNgrok.path),
              !containsSymlinkInTree(supportDirectory.appendingPathComponent("app", isDirectory: true)),
              !containsSymlinkInTree(supportDirectory.appendingPathComponent("runtime", isDirectory: true)),
              !containsSymlinkInTree(supportDirectory.appendingPathComponent("remote", isDirectory: true)) else {
            throw FilesystemUpdateError.structuralValidationFailed("installed remote payload")
        }
        try validateNgrokBinary(installedNgrok, candidate: candidate)
        guard try MaintenanceDigest.sha256(file: runtime.appendingPathComponent("uv.lock"))
            .caseInsensitiveCompare(candidate.manifest.runtime.lockSha256) == .orderedSame else {
            throw FilesystemUpdateError.structuralValidationFailed("runtime lock")
        }
    }

    func installLaunchAgent(candidate: UpdateCandidate, transactionID: UUID) throws {
        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: launchAgentsDirectory.path) {
            try createOwnedDirectory(launchAgentsDirectory)
        }
        guard !containsSymlink(launchAgentsDirectory), isOwned(launchAgentsDirectory) else { throw FilesystemUpdateError.unsafePath }
        let helper = supportDirectory.appendingPathComponent("app/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator")
        do {
            let contract = ManagedLaunchAgentContract(
                homeDirectory: fileManager.homeDirectoryForCurrentUser,
                executableURL: helper
            )
            let data = try contract.propertyListData()
            try writeOwned(data, to: launchAgentURL)
        } catch let error as FilesystemUpdateError {
            throw error
        } catch {
            throw FilesystemUpdateError.launchAgentFailed
        }
    }

    func commit(candidate: UpdateCandidate, staged: StagedUpdate, transactionID: UUID) throws -> InstallationReceiptV1 {
        let configurationSchema = try activeConfigurationSchema(candidate: candidate)
        let receipt = try InstallationReceiptV1(
            productVersion: candidate.manifest.product.version,
            manifestSHA256: candidate.manifestSHA256,
            helperPayloadSHA256: candidate.manifest.helper.sha256,
            coreRuntimePayloadSHA256: candidate.manifest.runtime.corePayload.sha256,
            runtimeLockSHA256: candidate.manifest.runtime.lockSha256,
            runtimeSchemaVersion: candidate.manifest.runtime.schemaVersion,
            configurationSchemaVersion: configurationSchema,
            installedAt: Date(),
            manifestURL: candidate.discovery.manifestURL
        )
        try InstallationReceiptStore(directoryURL: installDirectory).save(receipt)
        return receipt
    }

    func postflight(candidate: UpdateCandidate, transactionID: UUID) throws {
        // Permission/TCC onboarding is an external post-commit concern. The
        // structural transaction is already committed when this hook runs.
    }

    func rollback(transactionID: UUID) throws {
        let previous = transactionRoot(transactionID).appendingPathComponent("previous", isDirectory: true)
        guard isSafeOwnedItem(previous, directory: true),
              let data = try? Data(contentsOf: previous.appendingPathComponent("presence.json")),
              let presence = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
              Set(presence.keys) == Set(activePaths.map(\.0) + ["receipt", "launchAgent"]) else {
            throw FilesystemUpdateError.backupFailed
        }
        for (name, _) in activePaths where presence[name] == true {
            guard isSafeOwnedItem(
                previous.appendingPathComponent(name, isDirectory: name != "config.json"),
                directory: name != "config.json"
            ) else {
                throw FilesystemUpdateError.unsafePath
            }
        }
        if presence["receipt"] == true {
            guard isSafeOwnedItem(previous.appendingPathComponent("receipt.json"), directory: false) else {
                throw FilesystemUpdateError.unsafePath
            }
        }
        if presence["launchAgent"] == true {
            guard isSafeOwnedItem(previous.appendingPathComponent("launch-agent.plist"), directory: false) else {
                throw FilesystemUpdateError.unsafePath
            }
        }
        do {
            for (name, active) in activePaths where name != "config.json" {
                if fileManager.fileExists(atPath: active.path) {
                    guard isSafeOwnedItem(active, directory: true) else {
                        throw FilesystemUpdateError.unsafePath
                    }
                    try fileManager.removeItem(at: active)
                }
                if presence[name] == true {
                    let saved = previous.appendingPathComponent(name, isDirectory: true)
                    try fileManager.moveItem(at: saved, to: active)
                }
            }
            if presence["config.json"] == true {
                let saved = previous.appendingPathComponent("config.json", isDirectory: false)
                try writeOwned(try Data(contentsOf: saved), to: configurationURL)
            } else if fileManager.fileExists(atPath: configurationURL.path) {
                guard isSafeOwnedItem(configurationURL, directory: false) else {
                    throw FilesystemUpdateError.unsafePath
                }
                try fileManager.removeItem(at: configurationURL)
            }
            let receiptURL = installDirectory.appendingPathComponent(InstallationReceiptStore.receiptFileName, isDirectory: false)
            if fileManager.fileExists(atPath: receiptURL.path) {
                guard isSafeOwnedItem(receiptURL, directory: false) else {
                    throw FilesystemUpdateError.unsafePath
                }
                try fileManager.removeItem(at: receiptURL)
            }
            if presence["receipt"] == true {
                let saved = previous.appendingPathComponent("receipt.json", isDirectory: false)
                try fileManager.copyItem(at: saved, to: receiptURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
            }
            if fileManager.fileExists(atPath: launchAgentURL.path) {
                guard isSafeOwnedItem(launchAgentURL, directory: false) else {
                    throw FilesystemUpdateError.unsafePath
                }
                try fileManager.removeItem(at: launchAgentURL)
            }
            if presence["launchAgent"] == true {
                let saved = previous.appendingPathComponent("launch-agent.plist", isDirectory: false)
                guard !containsSymlink(launchAgentURL.deletingLastPathComponent()),
                      isOwned(launchAgentURL.deletingLastPathComponent()),
                      isSafeOwnedItem(saved, directory: false) else {
                    throw FilesystemUpdateError.unsafePath
                }
                try fileManager.copyItem(at: saved, to: launchAgentURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchAgentURL.path)
            }
        } catch let error as FilesystemUpdateError {
            throw error
        } catch {
            throw FilesystemUpdateError.promotionFailed
        }
    }

    private var activePaths: [(String, URL)] {
        [
            ("app", supportDirectory.appendingPathComponent("app", isDirectory: true)),
            ("runtime", supportDirectory.appendingPathComponent("runtime", isDirectory: true)),
            ("remote", supportDirectory.appendingPathComponent("remote", isDirectory: true)),
            ("config.json", configurationURL),
        ]
    }

    private func transactionRoot(_ id: UUID) -> URL {
        installDirectory.appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func fetchAndStore(name: String, url: URL, expectedSHA256: String, directory: URL, fileName: String) throws -> URL {
        let data = try fetcher.fetch(url: url)
        guard MaintenanceDigest.sha256(data: data).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw FilesystemUpdateError.payloadDigestMismatch(name)
        }
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try writeOwned(data, to: destination)
        return destination
    }

    private func inspectZip(_ archive: URL, named name: String) throws {
        let result: ProcessCommandResult
        do { result = try commandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", archive.path]) } catch {
            throw FilesystemUpdateError.archiveInspectionFailed(name)
        }
        guard result.status == 0 else { throw FilesystemUpdateError.archiveInspectionFailed(name) }
        for entry in result.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let value = String(entry)
            guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
                  !value.split(separator: "/").contains(where: { $0 == ".." }) else {
                throw FilesystemUpdateError.archiveInspectionFailed(name)
            }
        }
        let details: ProcessCommandResult
        do { details = try commandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z", "-v", archive.path]) } catch {
            throw FilesystemUpdateError.archiveInspectionFailed(name)
        }
        guard details.status == 0 else { throw FilesystemUpdateError.archiveInspectionFailed(name) }
        for line in details.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let value = String(line)
            guard let colon = value.firstIndex(of: ":"), value.contains("Unix file attributes") else { continue }
            let attributes = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let first = attributes.first, first == "-" || first == "d" else {
                throw FilesystemUpdateError.archiveInspectionFailed(name)
            }
        }
    }

    private func inspectTar(_ archive: URL, named name: String) throws {
        let result: ProcessCommandResult
        do { result = try commandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tzf", archive.path]) } catch {
            throw FilesystemUpdateError.archiveInspectionFailed(name)
        }
        guard result.status == 0 else { throw FilesystemUpdateError.archiveInspectionFailed(name) }
        for entry in result.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let value = String(entry)
            guard !value.isEmpty, !value.hasPrefix("/"), !value.split(separator: "/").contains(where: { $0 == ".." }) else {
                throw FilesystemUpdateError.archiveInspectionFailed(name)
            }
        }
        let details: ProcessCommandResult
        do { details = try commandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tvzf", archive.path]) } catch {
            throw FilesystemUpdateError.archiveInspectionFailed(name)
        }
        guard details.status == 0 else { throw FilesystemUpdateError.archiveInspectionFailed(name) }
        for line in details.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let first = line.first, first == "-" || first == "d" else {
                throw FilesystemUpdateError.archiveInspectionFailed(name)
            }
        }
    }

    private func extractZip(_ archive: URL, to directory: URL, named name: String) throws {
        do {
            let result = try commandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, directory.path])
            guard result.status == 0 else { throw FilesystemUpdateError.extractionFailed(name) }
        } catch let error as FilesystemUpdateError {
            throw error
        } catch {
            throw FilesystemUpdateError.extractionFailed(name)
        }
    }

    private func extractTar(_ archive: URL, to directory: URL, named name: String) throws {
        do {
            let result = try commandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", directory.path])
            guard result.status == 0 else { throw FilesystemUpdateError.extractionFailed(name) }
        } catch let error as FilesystemUpdateError {
            throw error
        } catch {
            throw FilesystemUpdateError.extractionFailed(name)
        }
    }

    private func replaceDirectory(_ replacement: URL, at destination: URL) throws {
        guard !containsSymlink(replacement),
              !containsSymlink(destination),
              !containsSymlink(destination.deletingLastPathComponent()),
              isOwned(replacement),
              isOwned(destination.deletingLastPathComponent()),
              (!fileManager.fileExists(atPath: destination.path) || isOwned(destination)) else {
            throw FilesystemUpdateError.unsafePath
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: replacement, to: destination)
    }

    private func createOwnedDirectory(_ url: URL) throws {
        guard !containsSymlink(url.deletingLastPathComponent()) else { throw FilesystemUpdateError.unsafePath }
        if fileManager.fileExists(atPath: url.deletingLastPathComponent().path),
           !isOwned(url.deletingLastPathComponent()) {
            throw FilesystemUpdateError.unsafePath
        }
        if fileManager.fileExists(atPath: url.path) {
            guard !containsSymlink(url), fileManager.fileExists(atPath: url.path), isOwned(url) else {
                throw FilesystemUpdateError.unsafePath
            }
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeOwned(_ data: Data, to destination: URL) throws {
        guard !containsSymlink(destination), !containsSymlink(destination.deletingLastPathComponent()) else { throw FilesystemUpdateError.unsafePath }
        if fileManager.fileExists(atPath: destination.deletingLastPathComponent().path),
           !isOwned(destination.deletingLastPathComponent()) {
            throw FilesystemUpdateError.unsafePath
        }
        if fileManager.fileExists(atPath: destination.path), !isOwned(destination) {
            throw FilesystemUpdateError.unsafePath
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".update-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func activeConfigurationSchema(candidate: UpdateCandidate) throws -> Int {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return candidate.manifest.compatibility.configurationSchema.minimum
        }
        guard !containsSymlink(configurationURL), isOwned(configurationURL),
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL)) as? [String: Any],
              let schema = object["schemaVersion"] as? Int,
              candidate.manifest.compatibility.configurationSchema.contains(schema) else {
            throw FilesystemUpdateError.structuralValidationFailed("configuration schema")
        }
        return schema
    }

    private func validateCandidateHelper(app: URL, binary: URL, candidate: UpdateCandidate) throws {
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw FilesystemUpdateError.structuralValidationFailed("candidate helper executable")
        }
        let bundleVerification = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", app.path]
        )
        guard bundleVerification?.status == 0 else {
            throw FilesystemUpdateError.structuralValidationFailed("candidate helper code signature")
        }
        let details = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", app.path]
        )
        guard details?.status == 0,
              details?.output.contains("Identifier=\(candidate.manifest.helper.bundleIdentifier)") == true,
              details?.output.contains("Signature=adhoc") == true else {
            throw FilesystemUpdateError.structuralValidationFailed("candidate helper identity")
        }
        let architectures = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", binary.path]
        )
        guard architectures?.status == 0,
              architectures?.output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).contains(Substring(candidate.manifest.helper.architecture)) == true else {
            throw FilesystemUpdateError.structuralValidationFailed("candidate helper architecture")
        }
    }

    private func validateInstalledHelper(app: URL, binary: URL, candidate: UpdateCandidate) throws {
        try validateCandidateHelper(app: app, binary: binary, candidate: candidate)
    }

    private func validateNgrokBinary(_ binary: URL, candidate: UpdateCandidate) throws {
        let signature = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", binary.path]
        )
        guard signature?.status == 0 else {
            throw FilesystemUpdateError.structuralValidationFailed("ngrok signature")
        }
        let details = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", binary.path]
        )
        guard details?.status == 0,
              details?.output.contains("Authority=\(candidate.manifest.ngrok.developerIdAuthority)") == true,
              details?.output.contains("TeamIdentifier=\(candidate.manifest.ngrok.developerIdTeam)") == true else {
            throw FilesystemUpdateError.structuralValidationFailed("ngrok Developer ID identity")
        }
        let architectures = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", binary.path]
        )
        guard architectures?.status == 0,
              architectures?.output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
                .contains(Substring(candidate.manifest.platform.architecture)) == true else {
            throw FilesystemUpdateError.structuralValidationFailed("ngrok architecture")
        }
    }

    private func containsSymlink(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    private func containsSymlinkInTree(_ url: URL) -> Bool {
        guard !containsSymlink(url) else { return true }
        guard fileManager.fileExists(atPath: url.path) else { return false }
        var stack = [url.standardizedFileURL]
        while let current = stack.popLast() {
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0 else { return true }
            let type = UInt32(metadata.st_mode) & UInt32(S_IFMT)
            if type == UInt32(S_IFLNK) { return true }
            guard type == UInt32(S_IFDIR) else { continue }
            guard let children = try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil,
                options: []
            ) else { return true }
            stack.append(contentsOf: children)
        }
        return false
    }

    private func isSafeOwnedItem(_ url: URL, directory: Bool) -> Bool {
        guard fileManager.fileExists(atPath: url.path), isOwned(url) else { return false }
        return directory ? !containsSymlinkInTree(url) : !containsSymlink(url)
    }

    private func isOwned(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }
}
