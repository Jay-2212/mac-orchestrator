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
    let remoteStop: () throws -> Void
    let localStop: () throws -> Void
    let restoreServices: () throws -> Void

    init(
        runner: MaintenanceCommandRunner = SystemMaintenanceCommandRunner(),
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        launchAgentLabel: String = "gui/\(getuid())/com.jay.mac-orchestrator",
        remoteStop: @escaping () throws -> Void = { throw MaintenanceLifecycleError.actionNotConfigured },
        localStop: @escaping () throws -> Void = { throw MaintenanceLifecycleError.actionNotConfigured },
        restoreServices: @escaping () throws -> Void = { throw MaintenanceLifecycleError.actionNotConfigured }
    ) {
        self.runner = runner
        self.launchctlURL = launchctlURL
        self.launchAgentLabel = launchAgentLabel
        self.remoteStop = remoteStop
        self.localStop = localStop
        self.restoreServices = restoreServices
    }

    func verifyOwnership(ownerID: String) throws -> Bool {
        guard ownerID == String(getuid()) else { return false }
        let result = try runner.run(executable: launchctlURL, arguments: ["print", launchAgentLabel])
        return result.status == 0 && result.output.contains("com.jay.mac-orchestrator")
    }

    func stopRemote() throws { try remoteStop() }

    func stopLocalServer() throws { try localStop() }

    func restore() throws { try restoreServices() }
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
        isSafeCandidate: @escaping (URL) -> Bool = { url in
            let fileManager = FileManager.default
            guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular,
                  let owner = attributes[.ownerAccountID] as? NSNumber else {
                return false
            }
            return owner.uint32Value == getuid()
        }
    ) {
        self.ownerID = ownerID
        self.digest = digest
        self.exists = exists
        self.isSafeCandidate = isSafeCandidate
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
