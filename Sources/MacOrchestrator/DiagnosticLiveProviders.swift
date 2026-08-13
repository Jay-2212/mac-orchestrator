import Foundation
import Darwin

struct LocalActivationProbeDetails: Equatable, Sendable {
    let exposedTools: Set<String>
    let safeCallSucceeded: Bool

    init(exposedTools: Set<String> = [], safeCallSucceeded: Bool = false) {
        self.exposedTools = exposedTools
        self.safeCallSucceeded = safeCallSucceeded
    }
}

protocol LocalActivationProbeRunning: Sendable {
    func runDetailed(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool
    ) async throws -> LocalActivationProbeDetails

    func runOutcome(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool
    ) async -> LocalActivationProbeOutcome
}

extension LocalActivationProbe: LocalActivationProbeRunning {}

struct CurrentCoreMCPExpectations: Equatable, Sendable {
    let expectedTools: Set<String>
    let expectedCapabilityGroups: Set<String>
    let skippedCapabilityGroups: Set<String>
}

struct CurrentCoreMCPExpectationProvider: Sendable {
    private static let orientationTools: Set<String> = [
        "describe", "get_capabilities", "get_session_state", "play_sound_for_user_prompt"
    ]
    fileprivate static let uiTools: Set<String> = [
        "get_available_apps", "get_screen_size", "get_screen_layout", "get_ui_tree",
        "focus_app", "press_keystroke", "type_text", "mouse_action", "scroll",
        "perform_ui_action", "execute_macro"
    ]
    private static let screenOCRTools: Set<String> = ["get_screen_text"]
    private static let fileReadTools: Set<String> = ["find_file", "read_file", "list_directory", "smart_search"]
    private static let fileWriteTools: Set<String> = ["write_file"]
    private static let shellTools: Set<String> = ["run_terminal_command"]
    private static let clipboardTools: Set<String> = ["clipboard"]
    private static let telegramTools: Set<String> = ["send_file_to_telegram"]

    init() {}

    func expectations(for configuration: AppConfiguration) -> CurrentCoreMCPExpectations {
        var tools = Self.orientationTools
        var groups: Set<String> = ["core.session"]

        add("mac.ui", tools: Self.uiTools, to: &tools, groups: &groups, configuration: configuration)
        add("mac.screenOcr", tools: Self.screenOCRTools, to: &tools, groups: &groups, configuration: configuration)
        add("mac.files.read", tools: Self.fileReadTools, to: &tools, groups: &groups, configuration: configuration)
        add("mac.files.write", tools: Self.fileWriteTools, to: &tools, groups: &groups, configuration: configuration)
        add("mac.shell", tools: Self.shellTools, to: &tools, groups: &groups, configuration: configuration)
        tools.formUnion(Self.clipboardTools)
        if configuration.desiredCapabilities["mac.clipboard.write"] == true {
            groups.insert("mac.clipboard.write")
        }
        add("telegram.send", tools: Self.telegramTools, to: &tools, groups: &groups, configuration: configuration)

        let currentOptionalGroups = [
            "mac.ui", "mac.screenOcr", "mac.files.read", "mac.files.write", "mac.shell",
            "mac.clipboard.write", "telegram.send"
        ]
        let skipped = Set(currentOptionalGroups.filter { configuration.desiredCapabilities[$0] != true })
            .union(["meridian.search", "meridian.telegram", "remote.connector", "cloudflare", "telegram.assistant"])

        return CurrentCoreMCPExpectations(
            expectedTools: tools,
            expectedCapabilityGroups: groups,
            skippedCapabilityGroups: skipped
        )
    }

    private func add(
        _ group: String,
        tools: Set<String>,
        to expectedTools: inout Set<String>,
        groups: inout Set<String>,
        configuration: AppConfiguration
    ) {
        guard configuration.desiredCapabilities[group] == true else { return }
        expectedTools.formUnion(tools)
        groups.insert(group)
    }
}

struct LocalActivationProbeAdapter {
    private let probe: any LocalActivationProbeRunning
    private let keychain: KeychainStore
    private let configuration: AppConfiguration
    private let port: Int
    private let pythonPID: Int32?
    private let expectationsProvider: CurrentCoreMCPExpectationProvider

    init(
        probe: any LocalActivationProbeRunning,
        keychain: KeychainStore,
        configuration: AppConfiguration,
        port: Int? = nil,
        pythonPID: Int32? = nil,
        expectationsProvider: CurrentCoreMCPExpectationProvider = CurrentCoreMCPExpectationProvider()
    ) {
        self.probe = probe
        self.keychain = keychain
        self.configuration = configuration
        self.port = port ?? configuration.localMCPPort
        self.pythonPID = pythonPID
        self.expectationsProvider = expectationsProvider
    }

    func inspect() async -> LocalMCPFacts {
        let expectations = expectationsProvider.expectations(for: configuration)
        let empty = LocalMCPFacts(
            expectedTools: expectations.expectedTools,
            expectedCapabilityGroups: expectations.expectedCapabilityGroups
        )

        let token: String?
        do {
            token = try keychain.value(for: .connectorToken)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            return empty
        }
        guard let token else { return empty }

        do {
            let outcome = await probe.runOutcome(
                port: port,
                capabilityToken: token,
                requiresInteractiveUI: configuration.desiredCapabilities["mac.ui"] == true
            )
            if let details = outcome.details {
                return LocalMCPFacts(
                    livenessVerified: true,
                    readinessVerified: details.safeCallSucceeded,
                    sessionEstablished: true,
                    safeCallSucceeded: details.safeCallSucceeded,
                    expectedTools: expectations.expectedTools,
                    exposedTools: details.exposedTools,
                    expectedCapabilityGroups: expectations.expectedCapabilityGroups,
                    exposedCapabilityGroups: groups(for: details.exposedTools, expectations: expectations)
                )
            }
            let liveness = outcome.phase != .health || outcome.error.map {
                if case .healthCheckFailed = $0 { return true }
                return false
            } ?? false
            let session = outcome.phase == .initialized || outcome.phase == .toolsList || outcome.phase == .safeCall
            return LocalMCPFacts(
                livenessVerified: liveness,
                readinessVerified: false,
                sessionEstablished: session,
                safeCallSucceeded: false,
                expectedTools: expectations.expectedTools,
                expectedCapabilityGroups: expectations.expectedCapabilityGroups
            )
        }
    }

    private func groups(
        for tools: Set<String>,
        expectations: CurrentCoreMCPExpectations
    ) -> Set<String> {
        var exposed = Set<String>()
        let groupTools: [(String, Set<String>)] = [
            ("core.session", ["describe", "get_capabilities", "get_session_state"]),
            ("mac.ui", CurrentCoreMCPExpectationProvider.uiTools),
            ("mac.screenOcr", ["get_screen_text"]),
            ("mac.files.read", ["find_file", "read_file", "list_directory", "smart_search"]),
            ("mac.files.write", ["write_file"]),
            ("mac.shell", ["run_terminal_command"]),
            ("mac.clipboard.write", ["clipboard"]),
            ("telegram.send", ["send_file_to_telegram"]),
        ]
        for (group, requiredTools) in groupTools {
            guard expectations.expectedCapabilityGroups.contains(group), requiredTools.isSubset(of: tools) else {
                continue
            }
            exposed.insert(group)
        }
        return exposed
    }

}

struct DiagnosticPathSet: Sendable {
    let supportDirectory: URL
    let homeDirectory: URL
    let appURL: URL
    let helperExecutableURL: URL
    let runtimeDirectory: URL
    let runtimePythonURL: URL
    let runtimeScriptURL: URL
    let runtimeMarkerURL: URL
    let pythonDistributionURL: URL
    let ownedProcessesURL: URL
    let ngrokDirectory: URL
    let ngrokBinaryURL: URL
    let ngrokConfigURL: URL
    let launchAgentURL: URL

    init(supportDirectory: URL, homeDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.homeDirectory = homeDirectory
        self.appURL = supportDirectory.appendingPathComponent("app/Mac Orchestrator.app", isDirectory: true)
        self.helperExecutableURL = appURL.appendingPathComponent("Contents/MacOS/MacOrchestrator")
        self.runtimeDirectory = supportDirectory.appendingPathComponent("runtime", isDirectory: true)
        self.runtimePythonURL = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        self.runtimeScriptURL = runtimeDirectory.appendingPathComponent("automac_mcp.py")
        self.runtimeMarkerURL = runtimeDirectory.appendingPathComponent(".release-marker")
        self.pythonDistributionURL = supportDirectory.appendingPathComponent("python/cpython-3.13.14", isDirectory: true)
        self.ownedProcessesURL = supportDirectory.appendingPathComponent("owned-processes.json")
        self.ngrokDirectory = supportDirectory.appendingPathComponent("remote/ngrok", isDirectory: true)
        self.ngrokBinaryURL = ngrokDirectory.appendingPathComponent("ngrok")
        self.ngrokConfigURL = ngrokDirectory.appendingPathComponent("ngrok.yml")
        self.launchAgentURL = homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.jay.mac-orchestrator.plist")
    }

    init(supportDirectory: URL) {
        self.init(
            supportDirectory: supportDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func defaultPaths(fileManager: FileManager = .default) -> DiagnosticPathSet {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Orchestrator", isDirectory: true)
        return DiagnosticPathSet(supportDirectory: support, fileManager: fileManager)
    }

    init(supportDirectory: URL, fileManager: FileManager) {
        self.init(
            supportDirectory: supportDirectory,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
    }
}

struct DiagnosticCommandRequest: Hashable, Sendable {
    let executable: String
    let arguments: [String]
}

struct DiagnosticCommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

protocol DiagnosticCommandRunning: Sendable {
    func run(_ request: DiagnosticCommandRequest) -> DiagnosticCommandResult
}

struct SystemDiagnosticCommandRunner: DiagnosticCommandRunning {
    func run(_ request: DiagnosticCommandRequest) -> DiagnosticCommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            return DiagnosticCommandResult(
                status: process.terminationStatus,
                stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        } catch {
            return DiagnosticCommandResult(status: -1, stdout: "", stderr: "")
        }
    }
}

struct DiagnosticProcessRecord: Equatable, Sendable {
    let pid: Int32
    let commandLine: String
    let running: Bool
}

protocol DiagnosticProcessRunning: Sendable {
    func snapshot() -> [DiagnosticProcessRecord]
}

struct SystemDiagnosticProcessRunner: DiagnosticProcessRunning {
    private let commandRunner: any DiagnosticCommandRunning

    init(commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func snapshot() -> [DiagnosticProcessRecord] {
        let result = commandRunner.run(DiagnosticCommandRequest(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        ))
        guard result.status == 0 else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            let pieces = text.split(separator: " ", maxSplits: 1).map(String.init)
            guard let pidText = pieces.first, let pid = Int32(pidText), pieces.count == 2 else { return nil }
            return DiagnosticProcessRecord(pid: pid, commandLine: pieces[1], running: true)
        }
    }
}

private enum DiagnosticOwnershipComponent {
    case server
    case tunnel
}

private func matchesExactOwnershipMarker(
    commandLine: String,
    component: DiagnosticOwnershipComponent,
    ownerID: String
) -> Bool {
    let tokens = commandLine.split { character in
        character == " " || character == "\t" || character == "\r" || character == "\n"
    }.map(String.init)
    switch component {
    case .server:
        let markerIndices = tokens.indices.filter { tokens[$0] == "--managed-owner" }
        guard markerIndices.count == 1,
              !tokens.contains(where: { $0.hasPrefix("--managed-owner=") }),
              let markerIndex = markerIndices.first else { return false }
        let ownerIndex = tokens.index(after: markerIndex)
        return ownerIndex < tokens.endIndex && tokens[ownerIndex] == ownerID
    case .tunnel:
        let markerPrefix = "mac-orchestrator-owner="
        let markerTokens = tokens.filter { $0.contains(markerPrefix) }
        return markerTokens.count == 1 && markerTokens[0] == "\(markerPrefix)\(ownerID)"
    }
}

struct DiagnosticHTTPResponse: Sendable {
    let status: Int
    let url: URL
    let body: Data
}

protocol DiagnosticHTTPRunning: Sendable {
    func get(_ url: URL) throws -> DiagnosticHTTPResponse
}

struct SystemDiagnosticHTTPRunner: DiagnosticHTTPRunning {
    func get(_ url: URL) throws -> DiagnosticHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<DiagnosticHTTPResponse, Error> = .failure(DiagnosticProviderError.unavailable)
        NoRedirectURLSession.make().dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(DiagnosticProviderError.unreadable)
                return
            }
            result = .success(DiagnosticHTTPResponse(status: http.statusCode, url: http.url ?? url, body: data))
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}

struct ReadOnlyInstalledReleaseFactsProvider: InstalledReleaseFactsProviding {
    private let paths: DiagnosticPathSet
    private let commandRunner: any DiagnosticCommandRunning
    private let fileManager: FileManager

    init(
        paths: DiagnosticPathSet,
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    init(
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.init(
            paths: .defaultPaths(fileManager: fileManager),
            commandRunner: commandRunner,
            fileManager: fileManager
        )
    }

    func inspect() throws -> InstalledReleaseFacts {
        let appLayoutSafe = appLayoutIsSafe()
        let runtimeLayoutSafe = runtimeLayoutIsSafe()
        let infoURL = paths.appURL.appendingPathComponent("Contents/Info.plist")
        let info = appLayoutSafe ? infoDictionary(at: infoURL) : nil
        let bundleIdentifier = (info?["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleVersion = (info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableBundleMetadata = appLayoutSafe
            && isNonEmptyRegularNonSymlinkFile(at: infoURL)
            && bundleIdentifier?.isEmpty == false
            && bundleVersion?.isEmpty == false
        let helperPresent = appLayoutSafe
            && isExecutableRegularFile(at: paths.helperExecutableURL)
            && usableBundleMetadata
        let markerFilePresent = runtimeLayoutSafe
            && isNonEmptyRegularNonSymlinkFile(at: paths.runtimeMarkerURL)
        let runtimePresent = runtimeLayoutSafe && isExecutableRegularFile(at: paths.runtimePythonURL)
        let payloadPresent = runtimeLayoutSafe && isNonEmptyRegularNonSymlinkFile(at: paths.runtimeScriptURL)
        let releaseVersion = runtimeLayoutSafe && markerFilePresent
            ? (try? String(contentsOf: paths.runtimeMarkerURL, encoding: .utf8)).flatMap {
                let version = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return version.isEmpty ? nil : version
            }
            : nil
        let markerPresent = releaseVersion?.isEmpty == false
        let unavailable = DiagnosticCommandResult(status: -1, stdout: "", stderr: "")
        let file = appLayoutSafe
            ? commandRunner.run(DiagnosticCommandRequest(
                executable: "/usr/bin/file",
                arguments: ["-b", paths.helperExecutableURL.path]
            ))
            : unavailable
        let signature = appLayoutSafe
            ? commandRunner.run(DiagnosticCommandRequest(
                executable: "/usr/bin/codesign",
                arguments: ["-dv", "--verbose=4", paths.appURL.path]
            ))
            : unavailable
        let verify = appLayoutSafe
            ? commandRunner.run(DiagnosticCommandRequest(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", paths.appURL.path]
            ))
            : unavailable
        let runtimeFile = appLayoutSafe && runtimeLayoutSafe
            ? commandRunner.run(DiagnosticCommandRequest(
                executable: "/usr/bin/file",
                arguments: ["-b", paths.runtimePythonURL.path]
            ))
            : unavailable
        let runtimeVersion = appLayoutSafe && runtimeLayoutSafe && runtimePresent
            ? commandRunner.run(DiagnosticCommandRequest(
                executable: paths.runtimePythonURL.path,
                arguments: ["--version"]
            ))
            : unavailable
        let helperArchitecture = architecture(from: file.stdout)
        let runtimeArchitecture = architecture(from: runtimeFile.stdout)
        let parsedRuntimeVersion = pythonVersion(from: runtimeVersion.stdout + runtimeVersion.stderr)
        let details = signature.stderr + signature.stdout
        let helper = CodeSignFacts(
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String,
            architecture: helperArchitecture,
            isSigned: verify.status == 0,
            isAdHoc: details.localizedCaseInsensitiveContains("adhoc") || details.localizedCaseInsensitiveContains("ad hoc"),
            developerIDTrusted: details.contains("Developer ID Application"),
            receiptAvailable: appLayoutSafe
                && fileManager.fileExists(atPath: paths.appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            integrityAvailable: appLayoutSafe
                && fileManager.fileExists(atPath: paths.appURL.appendingPathComponent("Contents/_CodeSignature/CodeResources").path)
        )
        let runtime = RuntimeFacts(
            runtimePresent: runtimePresent,
            architecture: runtimeArchitecture,
            version: parsedRuntimeVersion ?? releaseVersion,
            markerPresent: markerPresent,
            payloadPresent: payloadPresent,
            structurallyValid: helperPresent
                && runtimePresent
                && markerPresent
                && payloadPresent
                && file.status == 0
                && helperArchitecture != nil
                && runtimeFile.status == 0
                && runtimeVersion.status == 0
                && runtimeArchitecture != nil
                && parsedRuntimeVersion != nil
        )
        return InstalledReleaseFacts(
            releaseVersion: releaseVersion,
            helper: helper,
            runtime: runtime,
            helperPresent: helperPresent,
            ownershipMarkerPresent: appLayoutSafe && markerPresent
        )
    }

    private func appLayoutIsSafe() -> Bool {
        [
            paths.supportDirectory,
            paths.appURL.deletingLastPathComponent(),
            paths.appURL,
            paths.appURL.appendingPathComponent("Contents", isDirectory: true),
            paths.appURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
        ].allSatisfy(isRegularNonSymlinkDirectory(at:))
    }

    private func runtimeLayoutIsSafe() -> Bool {
        [
            paths.supportDirectory,
            paths.runtimeDirectory,
            paths.runtimePythonURL.deletingLastPathComponent(),
            paths.runtimePythonURL.deletingLastPathComponent().deletingLastPathComponent(),
        ].allSatisfy(isRegularNonSymlinkDirectory(at:))
    }

    private func infoDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private func isRegularNonSymlinkFile(at url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        let mode = UInt32(metadata.st_mode)
        return mode & UInt32(S_IFMT) == UInt32(S_IFREG)
    }

    private func isNonEmptyRegularNonSymlinkFile(at url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        let mode = UInt32(metadata.st_mode)
        return mode & UInt32(S_IFMT) == UInt32(S_IFREG) && metadata.st_size > 0
    }

    private func isRegularNonSymlinkDirectory(at url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        let mode = UInt32(metadata.st_mode)
        return mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }

    private func isExecutableRegularFile(at url: URL) -> Bool {
        isNonEmptyRegularNonSymlinkFile(at: url) && fileManager.isExecutableFile(atPath: url.path)
    }

    private func architecture(from output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("arm64") { return "arm64" }
        if lower.contains("x86_64") { return "x86_64" }
        return nil
    }

    private func pythonVersion(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let prefix = "Python "
        guard line.hasPrefix(prefix) else { return nil }
        let version = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}

struct ReadOnlyLifecycleFactsProvider: LifecycleFactsProviding {
    private static let expectedLabel = "com.jay.mac-orchestrator"
    private let paths: DiagnosticPathSet
    private let label: String
    private let ownerID: String
    private let commandRunner: any DiagnosticCommandRunning
    private let processRunner: any DiagnosticProcessRunning
    private let fileManager: FileManager

    init(
        paths: DiagnosticPathSet,
        label: String = "com.jay.mac-orchestrator",
        ownerID: String,
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        processRunner: any DiagnosticProcessRunning = SystemDiagnosticProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.label = label
        self.ownerID = ownerID
        self.commandRunner = commandRunner
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    init(
        ownerID: String,
        label: String = "com.jay.mac-orchestrator",
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        processRunner: any DiagnosticProcessRunning = SystemDiagnosticProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.init(
            paths: .defaultPaths(fileManager: fileManager),
            label: label,
            ownerID: ownerID,
            commandRunner: commandRunner,
            processRunner: processRunner,
            fileManager: fileManager
        )
    }

    func inspect() throws -> LifecycleFacts {
        let launchAgentPresent = fileManager.fileExists(atPath: paths.launchAgentURL.path)
        let launchAgentValid = launchAgentPresent && launchAgentIsValid()
        let serviceRunning: Bool
        if label == Self.expectedLabel {
            serviceRunning = commandRunner.run(DiagnosticCommandRequest(
                executable: "/bin/launchctl",
                arguments: ["print", "gui/\(getuid())/\(Self.expectedLabel)"]
            )).status == 0
        } else {
            serviceRunning = false
        }
        let stateResult = readOwnedState()
        let state = stateResult.state
        let processes = processRunner.snapshot()
        let runningProcesses = processes.filter(\.running)
        let serverProcesses = runningProcesses.filter {
            matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .server, ownerID: ownerID)
        }
        let tunnelProcesses = runningProcesses.filter {
            matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .tunnel, ownerID: ownerID)
        }
        let serverPID = state?.serverPID
        let tunnelPID = state?.tunnelPID
        let stateOwnerMatches = state?.ownerID == ownerID
        let stateHasCompletePIDs = serverPID != nil && tunnelPID != nil
        let stateHasPartialPIDs = state != nil && !stateHasCompletePIDs
        let duplicateAssignment = serverPID != nil && serverPID == tunnelPID
        let serverAssignmentValid = serverPID.map { pid in
            serverProcesses.count == 1 && serverProcesses[0].pid == pid
        } ?? true
        let tunnelAssignmentValid = tunnelPID.map { pid in
            tunnelProcesses.count == 1 && tunnelProcesses[0].pid == pid
        } ?? true
        let pidReuse = stateResult.malformed
            || stateHasPartialPIDs
            || (state != nil && !stateOwnerMatches)
            || !serverAssignmentValid
            || !tunnelAssignmentValid
            || (state == nil && (!serverProcesses.isEmpty || !tunnelProcesses.isEmpty))
            || (!serverProcesses.isEmpty && state?.serverPID == nil)
            || (!tunnelProcesses.isEmpty && state?.tunnelPID == nil)
        let duplicateOwnedProcesses = duplicateAssignment
            || serverProcesses.count > 1
            || tunnelProcesses.count > 1
            || runningProcesses.contains {
                matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .server, ownerID: ownerID)
                    && matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .tunnel, ownerID: ownerID)
            }
        let ownedCount = serverProcesses.count + tunnelProcesses.count
        let ownershipMarkerPresent = state != nil
            && stateOwnerMatches
            && stateHasCompletePIDs
            && serverAssignmentValid
            && tunnelAssignmentValid
            && !pidReuse
            && !duplicateOwnedProcesses
        return LifecycleFacts(
            launchAgentPresent: launchAgentPresent,
            launchAgentValid: launchAgentValid,
            serviceRunning: serviceRunning,
            ownedProcessCount: ownedCount,
            serverPID: serverPID,
            tunnelPID: tunnelPID,
            ownershipMarkerPresent: ownershipMarkerPresent,
            duplicateOwnedProcesses: duplicateOwnedProcesses,
            pidReuseDetected: pidReuse
        )
    }

    private func launchAgentIsValid() -> Bool {
        guard !isSymlink(at: paths.launchAgentURL.deletingLastPathComponent()),
              !isSymlink(at: paths.launchAgentURL),
              label == Self.expectedLabel,
              let data = try? Data(contentsOf: paths.launchAgentURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any] else { return false }

        let baseKeys: Set<String> = [
            "Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "LimitLoadToSessionType",
        ]
        let distributionKeys = baseKeys.union([
            "ThrottleInterval", "ProcessType", "StandardOutPath", "StandardErrorPath"
        ])
        guard let arguments = plist["ProgramArguments"] as? [String],
              arguments.count == 1,
              plist["Label"] as? String == label,
              plist["RunAtLoad"] as? Bool == true,
              plist["LimitLoadToSessionType"] as? String == "Aqua",
              let keepAlive = plist["KeepAlive"] as? [String: Any],
              keepAlive.count == 1,
              keepAlive["SuccessfulExit"] as? Bool == false else { return false }

        let isBootstrapContract = arguments == [paths.helperExecutableURL.path]
        let distributionExecutable = "/Applications/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator"
        let isDistributionContract = arguments == [distributionExecutable]
        guard isBootstrapContract || isDistributionContract else { return false }
        if isBootstrapContract {
            return Set(plist.keys) == baseKeys
        }

        guard Set(plist.keys) == distributionKeys,
              plist["ThrottleInterval"] as? Int == 5,
              plist["ProcessType"] as? String == "Interactive",
              plist["StandardOutPath"] as? String == launcherLogPath,
              plist["StandardErrorPath"] as? String == launcherLogPath else { return false }
        return true
    }

    private var launcherLogPath: String {
        paths.homeDirectory.appendingPathComponent("Library/Logs/Mac Orchestrator/launcher.log").path
    }

    private func isSymlink(at url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFLNK)
    }

    private func readOwnedState() -> (state: OwnedProcessState?, malformed: Bool) {
        guard fileManager.fileExists(atPath: paths.ownedProcessesURL.path) else {
            return (nil, false)
        }
        guard let data = try? Data(contentsOf: paths.ownedProcessesURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["ownerID", "serverPID", "tunnelPID"]),
              let state = try? JSONDecoder().decode(OwnedProcessState.self, from: data) else {
            return (nil, true)
        }
        return (state, false)
    }
}

struct ReadOnlyPortFactsProvider: PortFactsProviding {
    private let port: Int
    private let ownerID: String?
    private let commandRunner: any DiagnosticCommandRunning
    private let processRunner: any DiagnosticProcessRunning

    init(
        port: Int,
        ownerID: String? = nil,
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        processRunner: any DiagnosticProcessRunning = SystemDiagnosticProcessRunner()
    ) {
        self.port = port
        self.ownerID = ownerID
        self.commandRunner = commandRunner
        self.processRunner = processRunner
    }

    func inspect() throws -> PortFacts {
        guard (1...65535).contains(port) else { return PortFacts(port: port) }
        let result = commandRunner.run(DiagnosticCommandRequest(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        ))
        let pids = result.status == 0 ? result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) } : []
        guard pids.count == 1, let pid = pids.first else {
            guard !pids.isEmpty else { return PortFacts(port: port) }
            return PortFacts(port: port, listenerPresent: true)
        }
        let process = processRunner.snapshot().first(where: { $0.pid == pid })
        let owned = ownerID.map { owner in
            process.map {
                $0.running && matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .server, ownerID: owner)
            } ?? false
        } ?? false
        let pidReuse = ownerID != nil && process != nil && !owned
        return PortFacts(
            port: port,
            listenerPresent: true,
            listenerOwned: owned,
            listenerPID: pid,
            pidReuseDetected: pidReuse
        )
    }
}

struct RemoteConnectorInspection: Equatable, Sendable {
    let facts: RemoteConnectorFacts
    let ngrokAuthtokenPresence: KeychainPresence?
}

struct ReadOnlyRemoteConnectorFactsProvider: RemoteConnectorFactsProviding {
    private let desired: Bool
    private let binaryPresent: Bool
    private let binaryArchitecture: String?
    private let originalVendorSigning: Bool?
    private let configurationPresent: Bool
    private let ownershipMarkerPresent: Bool
    private let target: String
    private let httpRunner: any DiagnosticHTTPRunning
    private let keychainPresenceProvider: any KeychainPresenceProviding

    init(
        desired: Bool,
        binaryPresent: Bool,
        configurationPresent: Bool,
        target: String,
        ownershipMarkerPresent: Bool = false,
        httpRunner: any DiagnosticHTTPRunning,
        keychainPresenceProvider: any KeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        binaryArchitecture: String? = nil,
        originalVendorSigning: Bool? = nil
    ) {
        self.desired = desired
        self.binaryPresent = binaryPresent
        self.binaryArchitecture = binaryArchitecture
        self.originalVendorSigning = originalVendorSigning
        self.configurationPresent = configurationPresent
        self.ownershipMarkerPresent = ownershipMarkerPresent
        self.target = target
        self.httpRunner = httpRunner
        self.keychainPresenceProvider = keychainPresenceProvider
    }

    init(
        desired: Bool,
        binaryURL: URL,
        configurationURL: URL,
        target: String,
        ownershipMarkerPresent: Bool = false,
        httpRunner: any DiagnosticHTTPRunning,
        fileManager: FileManager = .default,
        keychainPresenceProvider: any KeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner()
    ) {
        let binaryPresent = fileManager.isExecutableFile(atPath: binaryURL.path)
        let binaryFacts = Self.inspectBinary(at: binaryURL, present: binaryPresent, commandRunner: commandRunner)
        self.init(
            desired: desired,
            binaryPresent: binaryPresent,
            configurationPresent: fileManager.fileExists(atPath: configurationURL.path),
            target: target,
            ownershipMarkerPresent: ownershipMarkerPresent,
            httpRunner: httpRunner,
            keychainPresenceProvider: keychainPresenceProvider,
            binaryArchitecture: binaryFacts.architecture,
            originalVendorSigning: binaryFacts.originalVendorSigning
        )
    }

    init(
        desired: Bool,
        paths: DiagnosticPathSet,
        target: String,
        ownershipMarkerPresent: Bool = false,
        httpRunner: any DiagnosticHTTPRunning,
        fileManager: FileManager = .default,
        keychainPresenceProvider: any KeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner()
    ) {
        self.init(
            desired: desired,
            binaryURL: paths.ngrokBinaryURL,
            configurationURL: paths.ngrokConfigURL,
            target: target,
            ownershipMarkerPresent: ownershipMarkerPresent,
            httpRunner: httpRunner,
            fileManager: fileManager,
            keychainPresenceProvider: keychainPresenceProvider,
            commandRunner: commandRunner
        )
    }

    init(
        desired: Bool,
        target: String,
        httpRunner: any DiagnosticHTTPRunning,
        fileManager: FileManager = .default,
        keychainPresenceProvider: any KeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner()
    ) {
        self.init(
            desired: desired,
            paths: .defaultPaths(fileManager: fileManager),
            target: target,
            httpRunner: httpRunner,
            fileManager: fileManager,
            keychainPresenceProvider: keychainPresenceProvider,
            commandRunner: commandRunner
        )
    }

    func inspect() throws -> RemoteConnectorFacts {
        try inspectDetailed().facts
    }

    func inspectDetailed() throws -> RemoteConnectorInspection {
        guard desired else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(desired: false), ngrokAuthtokenPresence: nil)
        }
        let authPresence = (try? keychainPresenceProvider.inspect())?.presence(for: .ngrokAuthtoken) ?? .inaccessible
        let url = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        guard let response = try? httpRunner.get(url), response.status == 200, response.url == url else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: binaryPresent,
                configurationPresent: configurationPresent,
                ownershipMarkerPresent: ownershipMarkerPresent,
                binaryArchitecture: binaryArchitecture,
                originalVendorSigning: originalVendorSigning
            ), ngrokAuthtokenPresence: authPresence)
        }
        let endpointCount = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            .flatMap { $0["endpoints"] as? [[String: Any]] }?.count ?? 0
        let endpointAvailable = endpointCount > 0
            && NgrokEndpointParser.publicURL(from: response.body, matching: target) != nil
        return RemoteConnectorInspection(
            facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: binaryPresent,
                configurationPresent: configurationPresent,
                endpointAvailable: endpointAvailable,
                endpointCount: endpointCount,
                ownershipMarkerPresent: ownershipMarkerPresent,
                binaryArchitecture: binaryArchitecture,
                originalVendorSigning: originalVendorSigning
            ),
            ngrokAuthtokenPresence: authPresence
        )
    }

    private static func inspectBinary(
        at url: URL,
        present: Bool,
        commandRunner: any DiagnosticCommandRunning
    ) -> (architecture: String?, originalVendorSigning: Bool?) {
        guard present else { return (nil, nil) }
        let file = commandRunner.run(DiagnosticCommandRequest(
            executable: "/usr/bin/file",
            arguments: ["-b", url.path]
        ))
        let signature = commandRunner.run(DiagnosticCommandRequest(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", url.path]
        ))
        let architecture = Self.architecture(from: file.stdout)
        guard signature.status == 0 else {
            return (architecture, nil)
        }
        let details = (signature.stderr + signature.stdout).lowercased()
        let vendorSigned = details.contains("authority=developer id application: ngrok")
            || details.contains("authority=developer id application: ngrok, inc.")
        return (architecture, vendorSigned)
    }

    private static func architecture(from output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("arm64") { return "arm64" }
        if lower.contains("x86_64") { return "x86_64" }
        return nil
    }
}

struct ReadOnlyDiskSpaceProvider: DiskSpaceProviding {
    private let filesystemURL: URL
    private let criticalPaths: [URL]
    private let thresholdBytes: Int64?

    init(filesystemURL: URL, criticalPaths: [URL] = [], thresholdBytes: Int64? = nil) {
        self.filesystemURL = filesystemURL
        self.criticalPaths = criticalPaths
        self.thresholdBytes = thresholdBytes
    }

    func inspect() throws -> DiskSpaceFacts {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: filesystemURL.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        var symlinkCount = 0
        for url in criticalPaths {
            var metadata = stat()
            if lstat(url.path, &metadata) == 0,
               UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFLNK) {
                symlinkCount += 1
            }
        }
        return DiskSpaceFacts(
            filesystemAccessible: true,
            availableBytes: available,
            thresholdBytes: thresholdBytes,
            criticalPathSymlinkCount: symlinkCount
        )
    }
}

typealias SystemInstalledReleaseFactsProvider = ReadOnlyInstalledReleaseFactsProvider
typealias SystemLifecycleFactsProvider = ReadOnlyLifecycleFactsProvider
typealias SystemPortFactsProvider = ReadOnlyPortFactsProvider
typealias SystemRemoteConnectorFactsProvider = ReadOnlyRemoteConnectorFactsProvider
typealias SystemDiskSpaceProvider = ReadOnlyDiskSpaceProvider
