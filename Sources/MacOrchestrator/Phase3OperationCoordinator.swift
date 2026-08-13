import Foundation

enum Phase3OperationError: Error, LocalizedError, Sendable {
    case unavailable
    case noActionableRepair

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This maintenance operation could not be completed safely. Run Doctor for details."
        case .noActionableRepair:
            return "Doctor found no bounded repair that is safe to run automatically."
        }
    }
}

struct Phase3DoctorOperationResult: Sendable {
    let report: DoctorReport
    let primaryRepair: RepairActionDescriptor?
}

struct Phase3RepairOperationResult: Sendable {
    let descriptor: RepairActionDescriptor
    let before: DoctorReport
    let outcome: RepairOutcome
    let after: DoctorReport
}

struct Phase3SupportBundlePreviewResult: Sendable {
    let plan: SupportBundlePlan
    let collectedFileCount: Int
}

struct Phase3SupportBundleCreationResult: Sendable {
    let plan: SupportBundlePlan
    let archiveURL: URL
}

enum Phase3UpdateState: Equatable, Sendable {
    case current(version: String)
    case available(version: String)
    case applied(version: String)
    case manualActionRequired(version: String)
    case failed
}

struct Phase3UpdateOperationResult: Equatable, Sendable {
    let state: Phase3UpdateState
    let message: String

    var succeeded: Bool {
        switch state {
        case .failed, .manualActionRequired:
            return false
        case .current, .available, .applied:
            return true
        }
    }
}

struct Phase3RemovalPlanOperationResult: Sendable {
    let plan: RemovalPlan
}

extension DoctorReport {
    /// Selects the exact descriptor emitted by Doctor. Failure beats warning;
    /// within a status, the stable diagnostic priority table beats report
    /// ordering, with the diagnostic ID as the final deterministic tie-break.
    func primaryRepairDescriptor() -> RepairActionDescriptor? {
        results
            .filter { ($0.status == .fail || $0.status == .warn) && $0.repair != nil }
            .sorted { lhs, rhs in
                let lhsStatus = lhs.status == .fail ? 0 : 1
                let rhsStatus = rhs.status == .fail ? 0 : 1
                if lhsStatus != rhsStatus { return lhsStatus < rhsStatus }
                let lhsPriority = Self.repairPriority[lhs.id] ?? 10_000
                let rhsPriority = Self.repairPriority[rhs.id] ?? 10_000
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                return lhs.title < rhs.title
            }
            .first?
            .repair
    }

    private static let repairPriority: [String: Int] = [
        "configuration.read": 0,
        "configuration.permissions": 1,
        "configuration.schema": 2,
        "configuration.recovery": 3,
        "configuration.backup": 4,
        "configuration.generation": 5,
        "configuration.migration": 6,
        "installation.integrity": 10,
        "installation.helper": 11,
        "installation.runtime": 12,
        "installation.helper-architecture": 13,
        "installation.runtime-architecture": 14,
        "installation.helper-bundle-id": 15,
        "installation.version-match": 16,
        "trust.codesign": 17,
        "permissions.requester": 20,
        "port.selected": 30,
        "mcp.liveness": 40,
        "mcp.readiness": 41,
        "mcp.inventory": 42,
        "lifecycle.launch-agent": 50,
        "lifecycle.process-ownership": 51,
        "remote.ngrok": 60,
        "remote.ngrok-architecture": 61,
        "remote.ngrok-signing": 62,
        "remote.endpoint": 63,
        "update.availability": 70,
        "disk.free-space": 80,
        "filesystem.critical-paths": 81,
        "filesystem.log-directory-permissions": 82,
    ]
}

struct Phase3OperationCoordinator: Sendable {
    init() {}

    static func mapUpdateCheckError(
        _ error: Error,
        currentVersion: String
    ) -> Phase3UpdateOperationResult {
        if let updateError = error as? UpdateEngineError,
           updateError == .noStableUpdate {
            return Phase3UpdateOperationResult(
                state: .current(version: currentVersion),
                message: "Mac Orchestrator is up to date (version \(currentVersion))."
            )
        }
        return Phase3UpdateOperationResult(
            state: .failed,
            message: "Authenticated update check failed safely; no update was applied."
        )
    }

    func runDoctor() async throws -> Phase3DoctorOperationResult {
        do {
            let engine = try TerminalCommand.makeDoctorEngine()
            let report = await engine.run()
            return Phase3DoctorOperationResult(
                report: report,
                primaryRepair: report.primaryRepairDescriptor()
            )
        } catch {
            throw Phase3OperationError.unavailable
        }
    }

    func runDoctorBlocking() throws -> Phase3DoctorOperationResult {
        let box = Phase3OperationResultBox<Phase3DoctorOperationResult>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.store(.success(try await runDoctor()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success,
              let result = box.load() else {
            throw Phase3OperationError.unavailable
        }
        return try result.get()
    }

    func executeRepair(
        descriptor: RepairActionDescriptor,
        before: DoctorReport
    ) async throws -> Phase3RepairOperationResult {
        let outcome: RepairOutcome
        do {
            outcome = try TerminalCommand.runRepair(descriptor.id)
        } catch {
            throw Phase3OperationError.unavailable
        }
        let after = try await runDoctor()
        return Phase3RepairOperationResult(
            descriptor: descriptor,
            before: before,
            outcome: outcome,
            after: after.report
        )
    }

    func previewSupportBundle() async throws -> Phase3SupportBundlePreviewResult {
        let doctor = try await runDoctor()
        let engine = TerminalCommand.makeSupportBundleEngine(report: doctor.report)
        return Phase3SupportBundlePreviewResult(
            plan: engine.preview(),
            collectedFileCount: 0
        )
    }

    func previewSupportBundleBlocking() throws -> Phase3SupportBundlePreviewResult {
        let box = Phase3OperationResultBox<Phase3SupportBundlePreviewResult>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.store(.success(try await previewSupportBundle()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success,
              let result = box.load() else {
            throw Phase3OperationError.unavailable
        }
        return try result.get()
    }

    func createSupportBundle(output: String? = nil) async throws -> Phase3SupportBundleCreationResult {
        let doctor = try await runDoctor()
        let engine = TerminalCommand.makeSupportBundleEngine(report: doctor.report)
        let plan = engine.preview()
        let destinationPath = output.map { NSString(string: $0).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent("Mac-Orchestrator-support-\(Int(Date().timeIntervalSince1970)).zip")
                .path
        let archiveURL = try engine.create(plan: plan, to: URL(fileURLWithPath: destinationPath))
        return Phase3SupportBundleCreationResult(plan: plan, archiveURL: archiveURL)
    }

    func createSupportBundleBlocking(output: String? = nil) throws -> Phase3SupportBundleCreationResult {
        let box = Phase3OperationResultBox<Phase3SupportBundleCreationResult>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.store(.success(try await createSupportBundle(output: output)))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success,
              let result = box.load() else {
            throw Phase3OperationError.unavailable
        }
        return try result.get()
    }

    func checkForUpdates() throws -> Phase3UpdateOperationResult {
        let currentVersion = try currentInstallationVersion()
        do {
            let candidate = try TerminalCommand.makeUpdateEngine().checkForUpdate()
            return Phase3UpdateOperationResult(
                state: .available(version: candidate.manifest.product.version),
                message: "Authenticated update available: version \(candidate.manifest.product.version)."
            )
        } catch UpdateEngineError.noStableUpdate {
            return Self.mapUpdateCheckError(UpdateEngineError.noStableUpdate, currentVersion: currentVersion)
        } catch {
            return Phase3UpdateOperationResult(
                state: .failed,
                message: "Authenticated update check failed safely; no update was applied."
            )
        }
    }

    func applyUpdate() throws -> Phase3UpdateOperationResult {
        let currentVersion = try currentInstallationVersion()
        let engine: UpdateEngine
        do {
            engine = try TerminalCommand.makeUpdateEngine()
        } catch {
            return Phase3UpdateOperationResult(
                state: .failed,
                message: "Authenticated update check failed safely; no update was applied."
            )
        }

        let candidate: UpdateCandidate
        do {
            candidate = try engine.checkForUpdate()
        } catch UpdateEngineError.noStableUpdate {
            return Self.mapUpdateCheckError(UpdateEngineError.noStableUpdate, currentVersion: currentVersion)
        } catch {
            return Phase3UpdateOperationResult(
                state: .failed,
                message: "Authenticated update check failed safely; no update was applied."
            )
        }

        do {
            _ = try engine.apply(candidate)
            return Phase3UpdateOperationResult(
                state: .applied(version: candidate.manifest.product.version),
                message: "Update to version \(candidate.manifest.product.version) succeeded; postflight completed."
            )
        } catch UpdateEngineError.postflightFailed {
            return Phase3UpdateOperationResult(
                state: .manualActionRequired(version: candidate.manifest.product.version),
                message: "Update to version \(candidate.manifest.product.version) committed; manual postflight action is required."
            )
        } catch {
            return Phase3UpdateOperationResult(
                state: .failed,
                message: "Authenticated update transaction failed safely; no unverified update was applied."
            )
        }
    }

    func planRemoval(options: RemovalOptions = RemovalOptions()) throws -> Phase3RemovalPlanOperationResult {
        do {
            let engine = try TerminalCommand.makeUninstallEngine()
            return Phase3RemovalPlanOperationResult(plan: try engine.plan(options: options))
        } catch {
            throw Phase3OperationError.unavailable
        }
    }

    private func currentInstallationVersion() throws -> String {
        let installDirectory = ConfigurationStore.defaultDirectoryURL()
            .appendingPathComponent("install", isDirectory: true)
        guard let receipt = try InstallationReceiptStore(directoryURL: installDirectory).load() else {
            throw Phase3OperationError.unavailable
        }
        return receipt.productVersion
    }
}

private final class Phase3OperationResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
