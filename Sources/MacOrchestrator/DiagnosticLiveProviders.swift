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
            // The canonical probe only establishes liveness after the health
            // response has passed. A health failure is not a live service,
            // even when the endpoint returned an HTTP response.
            let liveness = outcome.phase != .health
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
    private let authoritativeDeveloperIDTrusted: Bool?

    init(
        paths: DiagnosticPathSet,
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        fileManager: FileManager = .default,
        authoritativeDeveloperIDTrusted: Bool? = nil
    ) {
        self.paths = paths
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.authoritativeDeveloperIDTrusted = authoritativeDeveloperIDTrusted
    }

    init(
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        fileManager: FileManager = .default,
        authoritativeDeveloperIDTrusted: Bool? = nil
    ) {
        self.init(
            paths: .defaultPaths(fileManager: fileManager),
            commandRunner: commandRunner,
            fileManager: fileManager,
            authoritativeDeveloperIDTrusted: authoritativeDeveloperIDTrusted
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
        let receipt = loadInstallationReceipt()
        let receiptAvailable = receipt != nil
        let receiptIntegrityAvailable = receipt.map {
            $0.productVersion == releaseVersion
                && $0.runtimeSchemaVersion > 0
                && $0.configurationSchemaVersion > 0
        } ?? false
        let helper = CodeSignFacts(
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String,
            architecture: helperArchitecture,
            isSigned: verify.status == 0,
            isAdHoc: details.localizedCaseInsensitiveContains("adhoc") || details.localizedCaseInsensitiveContains("ad hoc"),
            developerIDTrusted: authoritativeDeveloperIDTrusted,
            receiptAvailable: receiptAvailable,
            integrityAvailable: receiptIntegrityAvailable
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

    private func loadInstallationReceipt() -> InstallationReceiptV1? {
        let store = InstallationReceiptStore(
            directoryURL: paths.supportDirectory.appendingPathComponent("install", isDirectory: true),
            fileManager: fileManager
        )
        guard !isSymlink(store.receiptURL),
              let attributes = try? fileManager.attributesOfItem(atPath: store.receiptURL.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() else {
            return nil
        }
        return try? store.load()
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
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
    private let serverDesired: Bool
    private let remoteDesired: Bool
    private let commandRunner: any DiagnosticCommandRunning
    private let processRunner: any DiagnosticProcessRunning
    private let fileManager: FileManager

    init(
        paths: DiagnosticPathSet,
        label: String = "com.jay.mac-orchestrator",
        ownerID: String,
        serverDesired: Bool = true,
        remoteDesired: Bool = true,
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        processRunner: any DiagnosticProcessRunning = SystemDiagnosticProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.label = label
        self.ownerID = ownerID
        self.serverDesired = serverDesired
        self.remoteDesired = remoteDesired
        self.commandRunner = commandRunner
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    init(
        ownerID: String,
        label: String = "com.jay.mac-orchestrator",
        serverDesired: Bool = true,
        remoteDesired: Bool = true,
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        processRunner: any DiagnosticProcessRunning = SystemDiagnosticProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.init(
            paths: .defaultPaths(fileManager: fileManager),
            label: label,
            ownerID: ownerID,
            serverDesired: serverDesired,
            remoteDesired: remoteDesired,
            commandRunner: commandRunner,
            processRunner: processRunner,
            fileManager: fileManager
        )
    }

    func inspect() throws -> LifecycleFacts {
        let launchAgentPathSafe = DiagnosticPathSafety.isSafe(paths.launchAgentURL)
        let launchAgentPresent = launchAgentPathSafe && fileManager.fileExists(atPath: paths.launchAgentURL.path)
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
        let helperProcesses = runningProcesses.filter {
            let command = $0.commandLine
            let executable = paths.helperExecutableURL.path
            return command == executable
                || command.hasPrefix(executable + " ")
                || command.hasPrefix(executable + "\t")
        }
        let duplicateHelperInstances = helperProcesses.count > 1
        let serverPID = state?.serverPID
        let tunnelPID = state?.tunnelPID
        let stateOwnerMatches = state?.ownerID == ownerID
        let duplicateAssignment = serverPID != nil && serverPID == tunnelPID
        let serverAssignmentValid = serverPID.map { pid in
            serverProcesses.count == 1 && serverProcesses[0].pid == pid
        } ?? !serverDesired
        let tunnelAssignmentValid = tunnelPID.map { pid in
            tunnelProcesses.count == 1 && tunnelProcesses[0].pid == pid
        } ?? !remoteDesired
        let missingExpectedAssignment = (serverDesired && serverPID == nil)
            || (remoteDesired && tunnelPID == nil)
        let unexpectedServerState = !serverDesired && (serverPID != nil || !serverProcesses.isEmpty)
        let unexpectedTunnelState = !remoteDesired && (tunnelPID != nil || !tunnelProcesses.isEmpty)
        let pidReuse = stateResult.malformed
            || (state != nil && !stateOwnerMatches)
            || missingExpectedAssignment
            || unexpectedServerState
            || unexpectedTunnelState
            || !serverAssignmentValid
            || !tunnelAssignmentValid
            || (state == nil && (!serverProcesses.isEmpty || !tunnelProcesses.isEmpty))
            || (serverDesired && !serverProcesses.isEmpty && state?.serverPID == nil)
            || (remoteDesired && !tunnelProcesses.isEmpty && state?.tunnelPID == nil)
        let duplicateOwnedProcesses = duplicateAssignment
            || serverProcesses.count > 1
            || tunnelProcesses.count > 1
            || duplicateHelperInstances
            || runningProcesses.contains {
                matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .server, ownerID: ownerID)
                    && matchesExactOwnershipMarker(commandLine: $0.commandLine, component: .tunnel, ownerID: ownerID)
            }
        let ownedCount = serverProcesses.count + tunnelProcesses.count
        let ownershipMarkerPresent = state != nil
            && stateOwnerMatches
            && serverAssignmentValid
            && tunnelAssignmentValid
            && serverProcesses.count == (serverDesired ? 1 : 0)
            && tunnelProcesses.count == (remoteDesired ? 1 : 0)
            && !pidReuse
            && !duplicateOwnedProcesses
        return LifecycleFacts(
            serverDesired: serverDesired,
            remoteDesired: remoteDesired,
            launchAgentPresent: launchAgentPresent,
            launchAgentValid: launchAgentValid,
            serviceRunning: serviceRunning,
            ownedProcessCount: ownedCount,
            serverPID: serverPID,
            tunnelPID: tunnelPID,
            ownershipMarkerPresent: ownershipMarkerPresent,
            duplicateOwnedProcesses: duplicateOwnedProcesses,
            duplicateHelperInstances: duplicateHelperInstances,
            pidReuseDetected: pidReuse
        )
    }

    private func launchAgentIsValid() -> Bool {
        guard DiagnosticPathSafety.isSafe(paths.launchAgentURL),
              label == Self.expectedLabel,
              hasCanonicalPermissions(),
              let data = try? Data(contentsOf: paths.launchAgentURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }

        let contract = ManagedLaunchAgentContract(
            homeDirectory: paths.homeDirectory,
            executableURL: paths.helperExecutableURL
        )
        return contract.matches(object)
    }

    private func hasCanonicalPermissions() -> Bool {
        var fileInfo = stat()
        guard lstat(paths.launchAgentURL.path, &fileInfo) == 0,
              UInt32(fileInfo.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
              fileInfo.st_uid == getuid(),
              UInt32(fileInfo.st_mode) & 0o777 == 0o600 else { return false }

        let parent = paths.launchAgentURL.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              UInt32(parentInfo.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              parentInfo.st_uid == getuid(),
              UInt32(parentInfo.st_mode) & 0o777 == 0o700 else { return false }
        return true
    }

    private func isSymlink(at url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFLNK)
    }

    private func readOwnedState() -> (state: OwnedProcessState?, malformed: Bool) {
        guard DiagnosticPathSafety.isSafe(paths.ownedProcessesURL),
              fileManager.fileExists(atPath: paths.ownedProcessesURL.path) else {
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
        if result.status == 1,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // lsof uses exit 1 for a successful no-match query. That is a
            // verified free-port observation, not an inspection failure.
            return PortFacts(port: port, inspectionAvailable: true)
        }
        guard result.status == 0 else {
            return PortFacts(port: port, inspectionAvailable: false)
        }
        let tokens = result.stdout.split(whereSeparator: \.isWhitespace)
        guard tokens.allSatisfy({ Int32($0) != nil }) else {
            return PortFacts(port: port, inspectionAvailable: false)
        }
        let pids = tokens.compactMap { Int32($0) }
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

private struct DiagnosticNgrokEndpointResponse: Decodable {
    let endpoints: [NgrokEndpoint]
}

struct ReadOnlyRemoteConnectorFactsProvider: RemoteConnectorFactsProviding {
    private let desired: Bool
    private let pathsSafe: Bool
    private let binaryPresent: Bool
    private let binaryArchitecture: String?
    private let originalVendorSigning: Bool?
    private let configurationPresent: Bool
    private let ownershipMarkerPresent: Bool
    private let target: String
    private let providerCredentialState: RemoteProviderCredentialState
    private let httpRunner: any DiagnosticHTTPRunning
    private let keychainPresenceProvider: any SelectiveKeychainPresenceProviding
    private let ownerID: String?
    private let processRunner: (any DiagnosticProcessRunning)?
    private let expectedBinaryPath: String?

    init(
        desired: Bool,
        binaryPresent: Bool,
        configurationPresent: Bool,
        target: String,
        ownershipMarkerPresent: Bool = false,
        providerCredentialState: RemoteProviderCredentialState = .notObserved,
        httpRunner: any DiagnosticHTTPRunning,
        keychainPresenceProvider: any SelectiveKeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        binaryArchitecture: String? = nil,
        originalVendorSigning: Bool? = nil,
        ownerID: String? = nil,
        processRunner: (any DiagnosticProcessRunning)? = nil,
        expectedBinaryPath: String? = nil,
        pathsSafe: Bool = true
    ) {
        self.desired = desired
        self.pathsSafe = pathsSafe
        self.binaryPresent = binaryPresent
        self.binaryArchitecture = binaryArchitecture
        self.originalVendorSigning = originalVendorSigning
        self.configurationPresent = configurationPresent
        self.ownershipMarkerPresent = ownershipMarkerPresent
        self.target = target
        self.providerCredentialState = providerCredentialState
        self.httpRunner = httpRunner
        self.keychainPresenceProvider = keychainPresenceProvider
        self.ownerID = ownerID
        self.processRunner = processRunner
        self.expectedBinaryPath = expectedBinaryPath
    }

    init(
        desired: Bool,
        binaryURL: URL,
        configurationURL: URL,
        target: String,
        ownershipMarkerPresent: Bool = false,
        providerCredentialState: RemoteProviderCredentialState = .notObserved,
        httpRunner: any DiagnosticHTTPRunning,
        fileManager: FileManager = .default,
        keychainPresenceProvider: any SelectiveKeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        ownerID: String? = nil,
        processRunner: (any DiagnosticProcessRunning)? = nil
    ) {
        let binaryPathSafe = DiagnosticPathSafety.isSafe(binaryURL)
        let configurationPathSafe = DiagnosticPathSafety.isSafe(configurationURL)
        let pathsSafe = binaryPathSafe && configurationPathSafe
        let binaryPresent = pathsSafe && fileManager.isExecutableFile(atPath: binaryURL.path)
        let binaryFacts = Self.inspectBinary(at: binaryURL, present: binaryPresent, commandRunner: commandRunner)
        self.init(
            desired: desired,
            binaryPresent: binaryPresent,
            configurationPresent: pathsSafe && fileManager.fileExists(atPath: configurationURL.path),
            target: target,
            ownershipMarkerPresent: ownershipMarkerPresent,
            providerCredentialState: providerCredentialState,
            httpRunner: httpRunner,
            keychainPresenceProvider: keychainPresenceProvider,
            binaryArchitecture: binaryFacts.architecture,
            originalVendorSigning: binaryFacts.originalVendorSigning,
            ownerID: ownerID,
            processRunner: processRunner,
            expectedBinaryPath: binaryPathSafe ? binaryURL.path : "",
            pathsSafe: pathsSafe
        )
    }

    init(
        desired: Bool,
        paths: DiagnosticPathSet,
        target: String,
        ownershipMarkerPresent: Bool = false,
        providerCredentialState: RemoteProviderCredentialState = .notObserved,
        httpRunner: any DiagnosticHTTPRunning,
        fileManager: FileManager = .default,
        keychainPresenceProvider: any SelectiveKeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        ownerID: String? = nil,
        processRunner: (any DiagnosticProcessRunning)? = nil
    ) {
        self.init(
            desired: desired,
            binaryURL: paths.ngrokBinaryURL,
            configurationURL: paths.ngrokConfigURL,
            target: target,
            ownershipMarkerPresent: ownershipMarkerPresent,
            providerCredentialState: providerCredentialState,
            httpRunner: httpRunner,
            fileManager: fileManager,
            keychainPresenceProvider: keychainPresenceProvider,
            commandRunner: commandRunner,
            ownerID: ownerID,
            processRunner: processRunner
        )
    }

    init(
        desired: Bool,
        target: String,
        providerCredentialState: RemoteProviderCredentialState = .notObserved,
        httpRunner: any DiagnosticHTTPRunning,
        fileManager: FileManager = .default,
        keychainPresenceProvider: any SelectiveKeychainPresenceProviding = ReadOnlySystemKeychainPresenceProvider(),
        commandRunner: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
        ownerID: String? = nil,
        processRunner: (any DiagnosticProcessRunning)? = nil
    ) {
        self.init(
            desired: desired,
            paths: .defaultPaths(fileManager: fileManager),
            target: target,
            providerCredentialState: providerCredentialState,
            httpRunner: httpRunner,
            fileManager: fileManager,
            keychainPresenceProvider: keychainPresenceProvider,
            commandRunner: commandRunner,
            ownerID: ownerID,
            processRunner: processRunner
        )
    }

    func inspect() throws -> RemoteConnectorFacts {
        try inspectDetailed().facts
    }

    func inspectDetailed() throws -> RemoteConnectorInspection {
        guard desired else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(desired: false), ngrokAuthtokenPresence: nil)
        }
        let authPresence = inspectAuthPresence()
        guard pathsSafe else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: false,
                configurationPresent: false,
                ownershipMarkerPresent: false,
                providerCredentialState: providerCredentialState
            ), ngrokAuthtokenPresence: authPresence)
        }
        let processState = inspectProcessState()
        guard !ownershipInspectionConfigured || processState == .owned else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: binaryPresent,
                configurationPresent: configurationPresent,
                ownershipMarkerPresent: false,
                binaryArchitecture: binaryArchitecture,
                originalVendorSigning: originalVendorSigning,
                providerCredentialState: providerCredentialState,
                managedProcessState: processState
            ), ngrokAuthtokenPresence: authPresence)
        }
        let url = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        guard let response = try? httpRunner.get(url), response.status == 200, response.url == url else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: binaryPresent,
                configurationPresent: configurationPresent,
                ownershipMarkerPresent: processState == .owned || (!ownershipInspectionConfigured && ownershipMarkerPresent),
                binaryArchitecture: binaryArchitecture,
                originalVendorSigning: originalVendorSigning,
                providerCredentialState: providerCredentialState,
                managedProcessState: processState,
                agentAPIState: .unavailable
            ), ngrokAuthtokenPresence: authPresence)
        }
        guard let endpointResponse = try? JSONDecoder().decode(
            DiagnosticNgrokEndpointResponse.self,
            from: response.body
        ) else {
            return RemoteConnectorInspection(facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: binaryPresent,
                configurationPresent: configurationPresent,
                ownershipMarkerPresent: processState == .owned || (!ownershipInspectionConfigured && ownershipMarkerPresent),
                binaryArchitecture: binaryArchitecture,
                originalVendorSigning: originalVendorSigning,
                providerCredentialState: providerCredentialState,
                managedProcessState: processState,
                agentAPIState: .malformed
            ), ngrokAuthtokenPresence: authPresence)
        }
        let matchingUpstreamEndpoints = endpointResponse.endpoints.filter { endpoint in
            normalizedAddress(endpoint.upstream.url) == normalizedAddress(target)
        }
        let matchingEndpoints = matchingUpstreamEndpoints.filter { endpoint in
            isValidPublicHTTPSURL(endpoint.url)
        }
        let endpointState: RemoteEndpointState
        switch matchingEndpoints.count {
        case 0:
            endpointState = matchingUpstreamEndpoints.isEmpty && !endpointResponse.endpoints.isEmpty
                ? .foreignOnly
                : .noExpectedUpstream
        case 1:
            endpointState = .established
        default:
            endpointState = .ambiguous
        }
        let endpointAvailable = endpointState == .established
        let ownershipMarker = processState == .owned || (!ownershipInspectionConfigured && ownershipMarkerPresent)
        return RemoteConnectorInspection(
            facts: RemoteConnectorFacts(
                desired: true,
                binaryPresent: binaryPresent,
                configurationPresent: configurationPresent,
                endpointAvailable: endpointAvailable,
                endpointCount: endpointResponse.endpoints.count,
                ownershipMarkerPresent: ownershipMarker,
                binaryArchitecture: binaryArchitecture,
                originalVendorSigning: originalVendorSigning,
                providerCredentialState: providerCredentialState,
                managedProcessState: processState,
                agentAPIState: .available,
                endpointState: endpointState
            ),
            ngrokAuthtokenPresence: authPresence
        )
    }

    private func inspectAuthPresence() -> KeychainPresence {
        return (try? keychainPresenceProvider.inspect(items: [.ngrokAuthtoken]))?.presence(for: .ngrokAuthtoken) ?? .inaccessible
    }

    private func inspectProcessState() -> RemoteManagedProcessState {
        guard let ownerID, let processRunner else {
            return ownershipMarkerPresent ? .owned : .notObserved
        }
        let candidates = processRunner.snapshot().filter { process in
            process.running
                && (expectedBinaryPath == nil || process.commandLine.split { $0 == " " || $0 == "\t" }.map(String.init).contains(expectedBinaryPath!))
        }
        let matches = candidates.filter { process in
            matchesExactOwnershipMarker(commandLine: process.commandLine, component: .tunnel, ownerID: ownerID)
        }
        if matches.count == 1, candidates.count == 1 {
            return .owned
        }
        if candidates.isEmpty {
            return .missing
        }
        return .ambiguous
    }

    private var ownershipInspectionConfigured: Bool {
        ownerID != nil && processRunner != nil
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

    private func isValidPublicHTTPSURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil
    }

    private func normalizedAddress(_ address: String) -> String {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.string ?? address
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
