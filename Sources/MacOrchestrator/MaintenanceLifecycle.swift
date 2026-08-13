import CryptoKit
import Darwin
import Foundation

struct MaintenanceQuiesceReceipt: Codable, Equatable, Sendable {
    let ownerID: String
    let remoteStopped: Bool
    let localServerStopped: Bool
    let quiescedAt: Date

    init(ownerID: String, remoteStopped: Bool, localServerStopped: Bool, quiescedAt: Date = Date()) {
        self.ownerID = ownerID
        self.remoteStopped = remoteStopped
        self.localServerStopped = localServerStopped
        self.quiescedAt = quiescedAt
    }
}

protocol MaintenanceLifecycleAdapter {
    func quiesce() throws -> MaintenanceQuiesceReceipt
    func restore() throws
    func removeManagedLaunchAgent() throws
}

extension MaintenanceLifecycleAdapter {
    func removeManagedLaunchAgent() throws {
        // Adapters without a loaded LaunchAgent have nothing to unload. The
        // production LaunchAgent adapter supplies the real action.
    }
}

enum MaintenanceLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case ownershipNotProven
    case actionNotConfigured
    case remoteQuiesceFailed
    case localQuiesceFailed
    case restoreFailed

    var errorDescription: String? {
        switch self {
        case .ownershipNotProven: return "Ownership of the managed maintenance service could not be proven."
        case .actionNotConfigured: return "The maintenance action has no integration-owned implementation and will fail closed."
        case .remoteQuiesceFailed: return "The remote connector could not be quiesced safely."
        case .localQuiesceFailed: return "The local managed server could not be quiesced safely."
        case .restoreFailed: return "The managed services could not be restored safely."
        }
    }
}

protocol MaintenanceServiceController {
    func verifyOwnership(ownerID: String) throws -> Bool
    func stopRemote() throws
    func stopLocalServer() throws
    func unloadManagedService() throws
    func restore() throws
}

struct ExternalMaintenanceLifecycleAdapter: MaintenanceLifecycleAdapter {
    private let ownerID: String
    private let controller: MaintenanceServiceController

    init(ownerID: String = String(getuid()), controller: MaintenanceServiceController) {
        self.ownerID = ownerID
        self.controller = controller
    }

    func quiesce() throws -> MaintenanceQuiesceReceipt {
        guard try controller.verifyOwnership(ownerID: ownerID) else {
            throw MaintenanceLifecycleError.ownershipNotProven
        }
        do {
            // Remote ingress is stopped first so no new external work can
            // arrive while the local server is being drained.
            try controller.stopRemote()
        } catch {
            throw MaintenanceLifecycleError.remoteQuiesceFailed
        }
        do {
            try controller.stopLocalServer()
        } catch {
            // Remote ingress may already be stopped. Best-effort recovery
            // prevents a partial quiesce from stranding desired services.
            try? controller.restore()
            throw MaintenanceLifecycleError.localQuiesceFailed
        }
        return MaintenanceQuiesceReceipt(ownerID: ownerID, remoteStopped: true, localServerStopped: true)
    }

    func restore() throws {
        do {
            try controller.restore()
        } catch {
            throw MaintenanceLifecycleError.restoreFailed
        }
    }

    func removeManagedLaunchAgent() throws {
        try controller.unloadManagedService()
    }
}

struct ProcessCommandResult: Sendable {
    let status: Int32
    let output: String
}

protocol MaintenanceCommandRunner {
    func run(executable: URL, arguments: [String]) throws -> ProcessCommandResult
}

struct SystemMaintenanceCommandRunner: MaintenanceCommandRunner {
    func run(executable: URL, arguments: [String]) throws -> ProcessCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ProcessCommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

struct LaunchAgentMaintenanceController: MaintenanceServiceController {
    let runner: MaintenanceCommandRunner
    let launchctlURL: URL
    let launchAgentLabel: String
    let launchAgentURL: URL
    let launchAgentContract: ManagedLaunchAgentContract
    let remoteStop: () throws -> Void
    let localStop: () throws -> Void
    let unloadService: () throws -> Void
    let restoreServices: () throws -> Void

    init(
        runner: MaintenanceCommandRunner = SystemMaintenanceCommandRunner(),
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        launchAgentLabel: String = "gui/\(getuid())/com.jay.mac-orchestrator",
        launchAgentURL: URL? = nil,
        contract: ManagedLaunchAgentContract? = nil,
        remoteStop: (() throws -> Void)? = nil,
        localStop: (() throws -> Void)? = nil,
        restoreServices: (() throws -> Void)? = nil
    ) {
        self.runner = runner
        self.launchctlURL = launchctlURL
        self.launchAgentLabel = launchAgentLabel
        let resolvedContract = contract ?? ManagedLaunchAgentContract()
        self.launchAgentContract = resolvedContract
        let resolvedLaunchAgentURL = (launchAgentURL ?? resolvedContract.launchAgentURL).standardizedFileURL
        self.launchAgentURL = resolvedLaunchAgentURL

        let stopLoadedService: () throws -> Void = {
            let result = try runner.run(executable: launchctlURL, arguments: ["bootout", launchAgentLabel])
            guard result.status == 0 else {
                let printResult = try runner.run(executable: launchctlURL, arguments: ["print", launchAgentLabel])
                guard printResult.status != 0 else {
                    throw MaintenanceLifecycleError.remoteQuiesceFailed
                }
                return
            }
        }
        let verifyStopped: () throws -> Void = {
            let result = try runner.run(executable: launchctlURL, arguments: ["print", launchAgentLabel])
            guard result.status != 0 else { throw MaintenanceLifecycleError.localQuiesceFailed }
        }
        let restoreLoadedService: () throws -> Void = {
            guard LaunchAgentMaintenanceController.isSafeLaunchAgentPath(resolvedLaunchAgentURL),
                  LaunchAgentMaintenanceController.matchesCanonicalContract(
                      resolvedLaunchAgentURL,
                      contract: resolvedContract
                  ) else {
                throw MaintenanceLifecycleError.restoreFailed
            }
            let domain = launchAgentLabel.split(separator: "/").dropLast().joined(separator: "/")
            let result = try runner.run(
                executable: launchctlURL,
                arguments: ["bootstrap", domain, resolvedLaunchAgentURL.path]
            )
            guard result.status == 0 else {
                let printResult = try runner.run(executable: launchctlURL, arguments: ["print", launchAgentLabel])
                guard printResult.status == 0 else { throw MaintenanceLifecycleError.restoreFailed }
                return
            }
        }
        self.remoteStop = remoteStop ?? stopLoadedService
        self.localStop = localStop ?? verifyStopped
        self.unloadService = stopLoadedService
        self.restoreServices = restoreServices ?? restoreLoadedService
    }

    func verifyOwnership(ownerID: String) throws -> Bool {
        guard ownerID == String(getuid()),
              launchAgentURL == launchAgentContract.launchAgentURL,
              Self.matchesCanonicalContract(launchAgentURL, contract: launchAgentContract) else {
            return false
        }
        let result = try runner.run(executable: launchctlURL, arguments: ["print", launchAgentLabel])
        return result.status == 0 && result.output.contains("com.jay.mac-orchestrator")
    }

    func stopRemote() throws { try remoteStop() }

    func stopLocalServer() throws { try localStop() }

    func unloadManagedService() throws { try unloadService() }

    func restore() throws { try restoreServices() }

    private static func isSafeLaunchAgentPath(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0,
              UInt32(fileInfo.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
              fileInfo.st_uid == getuid(),
              UInt32(fileInfo.st_mode) & 0o777 == 0o600 else { return false }
        let parent = url.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              UInt32(parentInfo.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              parentInfo.st_uid == getuid(),
              UInt32(parentInfo.st_mode) & 0o777 == 0o700 else { return false }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil
    }

    private static func matchesCanonicalContract(
        _ url: URL,
        contract: ManagedLaunchAgentContract
    ) -> Bool {
        guard isSafeLaunchAgentPath(url),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        return contract.matches(object)
    }
}

struct CandidateHelperMaintenanceHandoff: Codable, Equatable, Sendable {
    let candidateURL: URL
    let candidateSHA256: String
    let candidateVersion: String
    let ownerID: String
    let verifiedAt: Date
}

enum CandidateHelperHandoffError: Error, Equatable, LocalizedError, Sendable {
    case candidateMissing
    case candidateDigestMismatch
    case candidateVersionMismatch
    case ownershipNotProven
    case revalidationFailed

    var errorDescription: String? {
        switch self {
        case .candidateMissing: return "The staged candidate helper is missing."
        case .candidateDigestMismatch: return "The staged candidate helper digest changed."
        case .candidateVersionMismatch: return "The staged candidate helper version changed."
        case .ownershipNotProven: return "The candidate helper did not prove maintenance ownership."
        case .revalidationFailed: return "The candidate helper handoff could not be re-verified."
        }
    }
}

protocol CandidateHelperMaintenanceAdapter {
    func prepareHandoff(candidateURL: URL, candidateVersion: String, expectedSHA256: String) throws -> CandidateHelperMaintenanceHandoff
    func reverifyHandoff(_ handoff: CandidateHelperMaintenanceHandoff) throws
}

struct LocalCandidateHelperMaintenanceAdapter: CandidateHelperMaintenanceAdapter {
    let ownerID: String
    let digest: (URL) throws -> String
    let exists: (URL) -> Bool
    let isSafeCandidate: (URL) -> Bool

    init(
        ownerID: String = String(getuid()),
        digest: @escaping (URL) throws -> String = { url in try MaintenanceDigest.sha256(file: url) },
        exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isSafeCandidate: @escaping (URL) -> Bool = { LocalCandidateHelperMaintenanceAdapter.defaultIsSafeCandidate($0) }
    ) {
        self.ownerID = ownerID
        self.digest = digest
        self.exists = exists
        self.isSafeCandidate = isSafeCandidate
    }

    private static func defaultIsSafeCandidate(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0 else { return false }
            guard UInt32(metadata.st_mode) & UInt32(S_IFMT) != UInt32(S_IFLNK),
                  metadata.st_uid == getuid() else { return false }
            current.deleteLastPathComponent()
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
              metadata.st_uid == getuid() else { return false }
        return true
    }

    func prepareHandoff(candidateURL: URL, candidateVersion: String, expectedSHA256: String) throws -> CandidateHelperMaintenanceHandoff {
        guard exists(candidateURL), isSafeCandidate(candidateURL) else { throw CandidateHelperHandoffError.candidateMissing }
        guard try digest(candidateURL).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw CandidateHelperHandoffError.candidateDigestMismatch
        }
        guard !candidateVersion.isEmpty else { throw CandidateHelperHandoffError.candidateVersionMismatch }
        let handoff = CandidateHelperMaintenanceHandoff(
            candidateURL: candidateURL,
            candidateSHA256: expectedSHA256.lowercased(),
            candidateVersion: candidateVersion,
            ownerID: ownerID,
            verifiedAt: Date()
        )
        return handoff
    }

    func reverifyHandoff(_ handoff: CandidateHelperMaintenanceHandoff) throws {
        guard exists(handoff.candidateURL), isSafeCandidate(handoff.candidateURL), !handoff.candidateVersion.isEmpty else {
            throw CandidateHelperHandoffError.candidateMissing
        }
        guard try digest(handoff.candidateURL).caseInsensitiveCompare(handoff.candidateSHA256) == .orderedSame else {
            throw CandidateHelperHandoffError.candidateDigestMismatch
        }
        guard handoff.ownerID == ownerID else { throw CandidateHelperHandoffError.ownershipNotProven }
    }
}

enum MaintenanceDigest {
    static func sha256(file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return sha256(data: data)
    }

    static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
