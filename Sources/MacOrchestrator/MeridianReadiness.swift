import CryptoKit
import Foundation

enum MeridianScheduleMode: String, Codable, Equatable, Sendable {
    case manual
    case everySixHours = "every_6_hours"
    case daily

    var intervalMinutes: Int? {
        switch self {
        case .manual: return nil
        case .everySixHours: return 6 * 60
        case .daily: return 24 * 60
        }
    }
}

enum MeridianProbeStatus: String, Codable, Equatable, Sendable {
    case notRun = "not_run"
    case passed
    case failed
    case cleanupRequired = "cleanup_required"
}

struct MeridianToolReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let digest: String
    let controlVersion: String
    let trusted: Bool
    let installedAt: Date?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        digest: String,
        controlVersion: String,
        trusted: Bool,
        installedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.digest = digest.lowercased()
        self.controlVersion = controlVersion
        self.trusted = trusted
        self.installedAt = installedAt
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            && controlVersion == "1.0.0"
            && trusted
    }
}

struct MeridianProbeReceipt: Codable, Equatable, Sendable {
    let status: MeridianProbeStatus
    let at: Date?
    let deploymentFingerprint: String?
    let toolDigest: String?
    let apiVersion: String?
    let schemaVersion: Int?

    init(
        status: MeridianProbeStatus,
        at: Date?,
        deploymentFingerprint: String? = nil,
        toolDigest: String? = nil,
        apiVersion: String?,
        schemaVersion: Int?
    ) {
        self.status = status
        self.at = at
        self.deploymentFingerprint = deploymentFingerprint
        self.toolDigest = toolDigest
        self.apiVersion = apiVersion
        self.schemaVersion = schemaVersion
    }

    var passed: Bool {
        status == .passed
            && apiVersion == "1.0.0"
            && schemaVersion == 2
            && at != nil
    }
}

struct MeridianReadinessReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var deploymentFingerprint: String?
    var toolDigest: String?
    var lastSuccessfulIndexAt: Date?
    var lastSuccessfulIndexAction: String?
    var lastProbe: MeridianProbeReceipt?
    var lastResult: MeridianIndexerRunStatus?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        deploymentFingerprint: String? = nil,
        toolDigest: String? = nil,
        lastSuccessfulIndexAt: Date? = nil,
        lastSuccessfulIndexAction: String? = nil,
        lastProbe: MeridianProbeReceipt? = nil,
        lastResult: MeridianIndexerRunStatus? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.deploymentFingerprint = deploymentFingerprint
        self.toolDigest = toolDigest
        self.lastSuccessfulIndexAt = lastSuccessfulIndexAt
        self.lastSuccessfulIndexAction = lastSuccessfulIndexAction
        self.lastProbe = lastProbe
        self.lastResult = lastResult
    }

    var isBounded: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              (deploymentFingerprint == nil || deploymentFingerprint?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil),
              (toolDigest == nil || toolDigest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil),
              (lastSuccessfulIndexAction == nil || ["index", "rebuild"].contains(lastSuccessfulIndexAction)) else {
            return false
        }
        if let probe = lastProbe {
            guard (probe.deploymentFingerprint == nil || probe.deploymentFingerprint?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil),
                  (probe.toolDigest == nil || probe.toolDigest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil),
                  (probe.apiVersion == nil || probe.apiVersion == "1.0.0"),
                  (probe.schemaVersion == nil || probe.schemaVersion == 2) else {
                return false
            }
        }
        return true
    }
}

protocol MeridianReadinessReceiptStoring: Sendable {
    func load() -> MeridianReadinessReceipt?
    func save(_ receipt: MeridianReadinessReceipt) throws
}

struct FileMeridianReadinessReceiptStore: MeridianReadinessReceiptStoring, @unchecked Sendable {
    let url: URL
    let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() -> MeridianReadinessReceipt? {
        guard fileManager.fileExists(atPath: url.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(MeridianReadinessReceipt.self, from: data),
              receipt.isBounded else {
            return nil
        }
        return receipt
    }

    func save(_ receipt: MeridianReadinessReceipt) throws {
        guard receipt.isBounded else { throw MeridianIndexerError.invalidInvocation }
        if fileManager.fileExists(atPath: url.path),
           (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw MeridianIndexerError.invalidInvocation
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct MeridianReadinessEvaluationInput: Equatable, Sendable {
    let desired: Bool
    let enabled: Bool
    let deploymentURL: String?
    let tokenPresent: Bool
    let tool: MeridianToolReceipt?
    let currentToolDigest: String?
    let lastSuccessfulIndexAt: Date?
    let lastSuccessfulIndexAction: String?
    let lastSuccessfulIndexDeploymentFingerprint: String?
    let lastSuccessfulIndexToolDigest: String?
    let lastProbe: MeridianProbeReceipt?
    let now: Date

    init(
        desired: Bool,
        enabled: Bool,
        deploymentURL: String?,
        tokenPresent: Bool,
        tool: MeridianToolReceipt?,
        currentToolDigest: String?,
        lastSuccessfulIndexAt: Date?,
        lastSuccessfulIndexAction: String? = "index",
        lastSuccessfulIndexDeploymentFingerprint: String?,
        lastSuccessfulIndexToolDigest: String?,
        lastProbe: MeridianProbeReceipt?,
        now: Date
    ) {
        self.desired = desired
        self.enabled = enabled
        self.deploymentURL = deploymentURL
        self.tokenPresent = tokenPresent
        self.tool = tool
        self.currentToolDigest = currentToolDigest
        self.lastSuccessfulIndexAt = lastSuccessfulIndexAt
        self.lastSuccessfulIndexAction = lastSuccessfulIndexAction
        self.lastSuccessfulIndexDeploymentFingerprint = lastSuccessfulIndexDeploymentFingerprint
        self.lastSuccessfulIndexToolDigest = lastSuccessfulIndexToolDigest
        self.lastProbe = lastProbe
        self.now = now
    }
}

struct MeridianReadinessEvidence: Equatable, Sendable {
    let desired: Bool
    let enabled: Bool
    let deploymentValid: Bool
    let tokenPresent: Bool
    let toolTrusted: Bool
    let toolMatches: Bool
    let indexEvidence: Bool
    let probeEvidence: Bool
}

struct MeridianReadinessEvaluation: Equatable, Sendable {
    let ready: Bool
    let reason: String
    let evidence: MeridianReadinessEvidence
}

enum MeridianReadinessEvaluator {
    static func evaluate(_ input: MeridianReadinessEvaluationInput) -> MeridianReadinessEvaluation {
        let deploymentFingerprint = input.deploymentURL.flatMap(fingerprint(for:))
        let deploymentValid = input.deploymentURL.flatMap(validatedURL(for:)) != nil
        let toolTrusted = input.tool?.isValid == true
        let toolMatches = toolTrusted
            && input.currentToolDigest != nil
            && input.currentToolDigest?.lowercased() == input.tool?.digest.lowercased()
        let indexIdentityMatches = input.lastSuccessfulIndexDeploymentFingerprint == deploymentFingerprint
            && input.lastSuccessfulIndexToolDigest?.lowercased() == input.currentToolDigest?.lowercased()
            && deploymentFingerprint != nil
            && input.currentToolDigest != nil
        let indexEvidence = indexIdentityMatches
            && (input.lastSuccessfulIndexAt.map { $0 <= input.now } ?? false)
            && ["index", "rebuild"].contains(input.lastSuccessfulIndexAction)
        let probeEvidence: Bool = {
            guard let probe = input.lastProbe,
                  probe.passed,
                  probe.at.map({ $0 <= input.now }) == true,
                  probe.deploymentFingerprint == deploymentFingerprint,
                  probe.toolDigest?.lowercased() == input.currentToolDigest?.lowercased() else {
                return false
            }
            return true
        }()
        let evidence = MeridianReadinessEvidence(
            desired: input.desired,
            enabled: input.enabled,
            deploymentValid: deploymentValid,
            tokenPresent: input.tokenPresent,
            toolTrusted: toolTrusted,
            toolMatches: toolMatches,
            indexEvidence: indexEvidence,
            probeEvidence: probeEvidence
        )

        let checks: [(Bool, String)] = [
            (input.desired, "Meridian Search is not enabled."),
            (input.enabled, "Meridian indexing is not configured."),
            (deploymentValid, "Meridian deployment URL is invalid."),
            (input.tokenPresent, "Meridian Core credential is not available."),
            (toolTrusted, "The pinned Meridian indexer is not trusted."),
            (toolMatches, "The installed Meridian indexer does not match its trusted receipt."),
            (indexEvidence, "A successful user-selected indexing run has not been verified."),
            (probeEvidence, "Meridian semantic readiness has not been verified end-to-end."),
        ]
        if let failed = checks.first(where: { !$0.0 }) {
            return MeridianReadinessEvaluation(ready: false, reason: failed.1, evidence: evidence)
        }
        return MeridianReadinessEvaluation(ready: true, reason: "Meridian Search readiness is verified.", evidence: evidence)
    }

    static func fingerprint(for deploymentURL: String) -> String? {
        guard let url = validatedURL(for: deploymentURL) else { return nil }
        let host = (url.host ?? "").lowercased()
        let port = url.port.map(String.init) ?? ""
        let canonical = "https://\(host):\(port)\(url.path == "/" ? "" : url.path)"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatedURL(for value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              !trimmed.contains("\0") else {
            return nil
        }
        _ = url.port
        return url
    }
}

@MainActor
protocol MeridianReadinessProbing: AnyObject {
    func probe(
        baseURL: URL,
        stateURL: URL,
        toolURL: URL,
        token: String,
        currentToolDigest: String?
    ) async -> MeridianProbeReceipt
}

@MainActor
final class SystemMeridianReadinessProbe: MeridianReadinessProbing {
    private let launcher: any MeridianIndexerProcessLaunching
    private let timeout: TimeInterval

    init(
        launcher: (any MeridianIndexerProcessLaunching)? = nil,
        timeout: TimeInterval = 35
    ) {
        self.launcher = launcher ?? SystemMeridianIndexerProcessLauncher()
        self.timeout = min(max(timeout, 5), 120)
    }

    func probe(
        baseURL: URL,
        stateURL: URL,
        toolURL: URL,
        token: String,
        currentToolDigest: String?
    ) async -> MeridianProbeReceipt {
        let now = Date()
        guard MeridianIndexerToolInstaller.isValidOwnedExecutable(at: toolURL),
              let invocation = try? MeridianIndexerInvocation(
                baseURL: baseURL,
                stateURL: stateURL,
                scopes: [],
                action: .probe
              ),
              let input = try? invocation.encoded() else {
            return MeridianProbeReceipt(
                status: .failed,
                at: now,
                deploymentFingerprint: MeridianReadinessEvaluator.fingerprint(for: baseURL.absoluteString),
                toolDigest: currentToolDigest,
                apiVersion: nil,
                schemaVersion: nil
            )
        }

        let outcome = await execute(toolURL: toolURL, token: token, input: input)
        let result = outcome?.output
            .split(whereSeparator: { $0.isNewline })
            .reversed()
            .compactMap { MeridianIndexerControlResult.parse(line: String($0)) }
            .first
        guard let result,
              result.action == .probe else {
            return MeridianProbeReceipt(
                status: .failed,
                at: now,
                deploymentFingerprint: MeridianReadinessEvaluator.fingerprint(for: baseURL.absoluteString),
                toolDigest: currentToolDigest,
                apiVersion: nil,
                schemaVersion: nil
            )
        }
        let passed = result.status == "passed"
            && outcome?.exitCode == 0
            && result.exitCode == 0
            && result.readiness?.allHealthy == true
        return MeridianProbeReceipt(
            status: passed ? .passed : (result.status == "cleanup_required" ? .cleanupRequired : .failed),
            at: now,
            deploymentFingerprint: MeridianReadinessEvaluator.fingerprint(for: baseURL.absoluteString),
            toolDigest: currentToolDigest,
            apiVersion: result.readiness?.version == "ok" ? "1.0.0" : nil,
            schemaVersion: result.readiness?.diagnostics == "ok" ? 2 : nil
        )
    }

    private func execute(toolURL: URL, token: String, input: Data) async -> (output: String, exitCode: Int32)? {
        await withCheckedContinuation { continuation in
            var output = Data()
            var completed = false
            var process: (any MeridianIndexerProcessHandle)?
            var environment = ["MERIDIAN_CORE_TOKEN": token]
            for name in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] {
                if let value = ProcessInfo.processInfo.environment[name] { environment[name] = value }
            }

            func finish(_ result: (String, Int32)?) {
                guard !completed else { return }
                completed = true
                continuation.resume(returning: result.map { (output: $0.0, exitCode: $0.1) })
            }

            do {
                process = try launcher.launch(
                    executableURL: toolURL,
                    environment: environment,
                    input: input,
                    output: { data in
                        guard !completed, output.count < 64 * 1024 else { return }
                        output.append(data.prefix(64 * 1024 - output.count))
                    },
                    termination: { exitCode in
                        guard let line = String(data: output, encoding: .utf8) else {
                            finish(nil)
                            return
                        }
                        finish((line, exitCode))
                    }
                )
            } catch {
                finish(nil)
                return
            }

            Task { @MainActor in
                let nanoseconds = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !completed else { return }
                process?.terminate()
                finish(nil)
            }
        }
    }
}
