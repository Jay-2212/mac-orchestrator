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
    static let minimumIntervalMinutes = 5
    static let maximumIntervalMinutes = 7 * 24 * 60

    var schemaVersion: Int
    var enabled: Bool
    var intervalMinutes: Int
    var scopes: [MeridianSourceScope]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        enabled: Bool = false,
        intervalMinutes: Int = 60,
        scopes: [MeridianSourceScope] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.scopes = scopes
    }

    func validated() throws -> MeridianIndexerConfiguration {
        guard schemaVersion == Self.currentSchemaVersion,
              (Self.minimumIntervalMinutes...Self.maximumIntervalMinutes).contains(intervalMinutes) else {
            throw MeridianIndexerError.invalidInterval
        }
        if enabled && scopes.isEmpty { throw MeridianIndexerError.explicitSelectionRequired }
        var normalized = self
        normalized.scopes = try scopes.map { try $0.validated() }
        return normalized
    }
}

struct MeridianIndexerInvocation: Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let sourceId: String
        let rootPath: String
        let paths: [String]
        let rebuild: Bool
        let rebuildToken: String?

        private enum CodingKeys: String, CodingKey {
            case sourceId
            case rootPath
            case paths
            case rebuild
            case rebuildToken
        }
    }

    let baseURL: URL
    let stateURL: URL
    let sources: [Source]

    init(
        baseURL: URL,
        stateURL: URL,
        scopes: [MeridianSourceScope],
        rebuild: Bool = false,
        rebuildToken: String? = nil
    ) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.user == nil,
              baseURL.password == nil,
              !baseURL.absoluteString.contains("\0") else {
            throw MeridianIndexerError.invalidDeploymentURL
        }
        guard stateURL.isFileURL, stateURL.path.hasPrefix("/"), !stateURL.path.contains("\0") else {
            throw MeridianIndexerError.invalidStatePath
        }
        let validatedScopes = try scopes.map { try $0.validated() }
        guard !validatedScopes.isEmpty else { throw MeridianIndexerError.explicitSelectionRequired }
        if let rebuildToken,
           rebuildToken.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) == nil {
            throw MeridianIndexerError.invalidInvocation
        }
        self.baseURL = baseURL
        self.stateURL = stateURL
        self.sources = validatedScopes.map {
            Source(
                sourceId: $0.scopeID,
                rootPath: $0.rootPath,
                paths: $0.paths,
                rebuild: rebuild,
                rebuildToken: rebuild ? rebuildToken : nil
            )
        }
    }

    func encoded() throws -> Data {
        struct Payload: Codable {
            let baseUrl: String
            let sources: [Source]
            let statePath: String
        }
        let payload = Payload(
            baseUrl: baseURL.absoluteString,
            sources: sources,
            statePath: stateURL.path
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

    static let zero = MeridianIndexerCounts(
        discovered: 0,
        unchanged: 0,
        committed: 0,
        skipped: 0,
        failed: 0,
        cancelled: 0,
        reconciliationRequired: 0
    )

    private enum CodingKeys: String, CodingKey {
        case discovered
        case unchanged
        case committed
        case skipped
        case failed
        case cancelled
        case reconciliationRequired = "reconciliation_required"
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
        default: return nil
        }
        guard Set(dictionary.keys) == allowed else { return nil }
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
           !["unsupported", "encrypted", "oversized", "permission_denied", "symlink_unsupported", "invalid_utf8", "unavailable", "remote_failed", "index_failed", "state_reconciliation_required", "cancelled"].contains(code) { return nil }
        let boundedCounts = [decoded.expectedChunks, decoded.uploadedChunks, decoded.totalChunks].compactMap { $0 }
        guard boundedCounts.allSatisfy({ (0...1_000_000_000).contains($0) }) else { return nil }
        if let uploadedChunks = decoded.uploadedChunks,
           let totalChunks = decoded.totalChunks,
           uploadedChunks > totalChunks { return nil }
        if let counts = decoded.counts {
            let values = [counts.discovered, counts.unchanged, counts.committed, counts.skipped, counts.failed, counts.cancelled, counts.reconciliationRequired]
            guard values.allSatisfy({ (0...1_000_000_000).contains($0) }),
                  counts.unchanged + counts.committed + counts.skipped + counts.failed + counts.cancelled + counts.reconciliationRequired <= counts.discovered else { return nil }
        }
        return decoded
    }
}

enum MeridianIndexerRunStatus: String, Codable, Equatable, Sendable {
    case disabled
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
    var lastRunAt: Date?
    var nextRunAt: Date?
    var lastErrorCode: String?
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

    static func isValidOwnedExecutable(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              fileManager.isExecutableFile(atPath: url.path),
              (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
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
            return installedURL
        } catch let error as MeridianIndexerError {
            throw error
        } catch {
            throw MeridianIndexerError.stagingFailed
        }
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
    private var process: (any MeridianIndexerProcessHandle)?
    private var scheduleHandle: LifecycleScheduledHandle?
    private var configuration: MeridianIndexerConfiguration?
    private var baseURL: URL?
    private var token: String?
    private var rebuildOnNextRun = false
    private var cancellationRequested = false
    private var generation: UInt64 = 0
    private var outputBuffer = Data()
    private var resultStatus: MeridianIndexerRunStatus?

    private(set) var snapshot = MeridianIndexerSnapshot()
    var onSnapshot: ((MeridianIndexerSnapshot) -> Void)?

    init(
        scheduler: any LifecycleSchedulerProtocol,
        launcher: (any MeridianIndexerProcessLaunching)? = nil,
        supportDirectory: URL
    ) {
        self.scheduler = scheduler
        self.launcher = launcher ?? SystemMeridianIndexerProcessLauncher()
        let meridianDirectory = supportDirectory.appendingPathComponent("meridian", isDirectory: true)
        self.stateURL = meridianDirectory.appendingPathComponent("index-state.json", isDirectory: false)
        self.toolURL = meridianDirectory.appendingPathComponent("indexer", isDirectory: false)
    }

    func reconcile(configuration: AppConfiguration, contract: ManagedRuntimeLaunchContract) {
        let indexer = configuration.integration.meridianIndexer
        guard (try? indexer.validated()) != nil, indexer.enabled else {
            stop()
            publish(desired: false, status: .disabled)
            return
        }
        self.configuration = indexer
        guard let deployment = configuration.integration.meridianDeploymentURL,
              let url = URL(string: deployment),
              url.scheme?.lowercased() == "https" else {
            stop()
            publish(desired: true, status: .unavailable, error: "remote_url_invalid")
            return
        }
        self.baseURL = url
        self.token = contract.meridianIndexerToken
        guard contract.meridianIndexerToken != nil else {
            stop()
            publish(desired: true, status: .unavailable, error: "core_token_missing")
            return
        }
        publish(desired: true, status: process == nil ? .scheduled : .running)
        if process == nil, scheduleHandle == nil {
            scheduleNext(at: scheduler.now)
        }
    }

    func cancel() {
        guard process != nil else { return }
        cancellationRequested = true
        publish(desired: true, status: .cancelling)
        process?.terminate()
    }

    func retry(rebuild: Bool = false) {
        rebuildOnNextRun = rebuild
        scheduleHandle?.cancel()
        scheduleHandle = nil
        if process == nil {
            scheduleNext(at: scheduler.now)
        }
    }

    func stop() {
        generation &+= 1
        scheduleHandle?.cancel()
        scheduleHandle = nil
        cancellationRequested = true
        process?.terminate()
        process = nil
        configuration = nil
        baseURL = nil
        token = nil
        rebuildOnNextRun = false
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func scheduleNext(at date: Date, preserveStatus: Bool = false) {
        guard let configuration else { return }
        let next = scheduler.schedule(at: date, label: "meridian-indexer") { [weak self] in
            self?.scheduleHandle = nil
            self?.startRun()
        }
        scheduleHandle = next
        snapshot.nextRunAt = date
        if !preserveStatus { snapshot.status = .scheduled }
        snapshot.desired = true
        publish()
        _ = configuration
    }

    private func startRun() {
        guard process == nil,
              let configuration,
              let baseURL,
              let token,
              let invocation = try? MeridianIndexerInvocation(
                baseURL: baseURL,
                stateURL: stateURL,
                scopes: configuration.scopes,
                rebuild: rebuildOnNextRun,
                rebuildToken: rebuildOnNextRun ? UUID().uuidString.lowercased() : nil
              ),
              let input = try? invocation.encoded() else {
            publish(desired: true, status: .unavailable, error: "configuration_unavailable")
            return
        }
        guard MeridianIndexerToolInstaller.isValidOwnedExecutable(at: toolURL) else {
            publish(desired: true, status: .unavailable, error: "optional_indexer_unavailable")
            return
        }
        generation &+= 1
        let runGeneration = generation
        cancellationRequested = false
        resultStatus = nil
        outputBuffer.removeAll(keepingCapacity: true)
        rebuildOnNextRun = false
        var environment = ["MERIDIAN_CORE_TOKEN": token]
        for name in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = ProcessInfo.processInfo.environment[name] {
                environment[name] = value
            }
        }
        do {
            process = try launcher.launch(
                executableURL: toolURL,
                environment: environment,
                input: input,
                output: { [weak self] data in self?.receive(data, generation: runGeneration) },
                termination: { [weak self] exitCode in self?.finish(exitCode: exitCode, generation: runGeneration) }
            )
            publish(desired: true, status: .running)
        } catch {
            process = nil
            publish(desired: true, status: .failed, error: "process_launch_failed")
            scheduleRetry(after: configuration.intervalMinutes)
        }
    }

    private func receive(_ data: Data, generation: UInt64) {
        guard generation == self.generation, process != nil else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= 32_768 else {
            outputBuffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let event = MeridianIndexerProgressEvent.parse(line: line) else { continue }
            if event.type == "run_finished" {
                resultStatus = event.status.flatMap(MeridianIndexerRunStatus.init(rawValue:))
                if let counts = event.counts { snapshot.counts = counts }
            } else if event.type == "source_failed" {
                snapshot.lastErrorCode = event.code
            }
        }
    }

    private func finish(exitCode: Int32, generation: UInt64) {
        guard generation == self.generation else { return }
        if !outputBuffer.isEmpty,
           let line = String(data: outputBuffer, encoding: .utf8),
           let event = MeridianIndexerProgressEvent.parse(line: line),
           event.type == "run_finished" {
            resultStatus = event.status.flatMap(MeridianIndexerRunStatus.init(rawValue:))
            if let counts = event.counts { snapshot.counts = counts }
        }
        outputBuffer.removeAll(keepingCapacity: false)
        process = nil
        let status: MeridianIndexerRunStatus
        if cancellationRequested || resultStatus == .cancelled {
            status = .cancelled
        } else if exitCode == 0 {
            status = resultStatus ?? .completed
        } else if exitCode == 2 {
            status = .partialFailure
        } else {
            status = .failed
        }
        snapshot.lastRunAt = scheduler.now
        snapshot.nextRunAt = nil
        let errorCode = status == .failed
            ? (snapshot.lastErrorCode ?? "process_failed")
            : snapshot.lastErrorCode
        publish(desired: true, status: status, error: errorCode)
        if let configuration {
            scheduleRetry(after: configuration.intervalMinutes, preserveStatus: status == .cancelled)
        }
    }

    private func scheduleRetry(after minutes: Int, preserveStatus: Bool = false) {
        scheduleHandle?.cancel()
        scheduleHandle = nil
        scheduleNext(
            at: scheduler.now.addingTimeInterval(TimeInterval(minutes * 60)),
            preserveStatus: preserveStatus
        )
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
