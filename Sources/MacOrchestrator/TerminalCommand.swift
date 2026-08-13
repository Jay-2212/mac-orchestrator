import Darwin
import Foundation
import Security

private final class TerminalProbeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func store(_ error: Error) {
        lock.lock()
        value = error
        lock.unlock()
    }

    func load() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class TerminalDoctorResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DoctorReport?

    func store(_ value: DoctorReport) { lock.lock(); self.value = value; lock.unlock() }
    func load() -> DoctorReport? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class TerminalRepairResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RepairOutcome?

    func store(_ value: RepairOutcome) { lock.lock(); self.value = value; lock.unlock() }
    func load() -> RepairOutcome? { lock.lock(); defer { lock.unlock() }; return value }
}

enum TerminalCommandError: Error, LocalizedError, Sendable {
    case invalidArguments(String)
    case tokenInputUnavailable
    case tokenMissing
    case agentRequestFailed(String)
    case noLiveConnector

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case .tokenInputUnavailable:
            return "Could not read an ngrok authtoken from the terminal."
        case .tokenMissing:
            return "No ngrok authtoken is stored in Keychain. Store it before enabling remote access."
        case let .agentRequestFailed(message):
            return "Could not query the local ngrok Agent API: \(message)"
        case .noLiveConnector:
            return "No live HTTPS ngrok endpoint currently targets the managed local MCP port."
        }
    }
}

enum TerminalMaintenanceIntent: Equatable, Sendable {
    case doctor(json: Bool, repair: RepairActionID?)
    case supportBundle(preview: Bool, output: String?)
}

private struct TerminalUnavailableLocalMCPProvider: LocalMCPDiagnosticProviding {
    func inspect() throws -> LocalMCPFacts { throw DiagnosticProviderError.unavailable }
}

private struct TerminalUnavailableUpdateProvider: UpdateAvailabilityProviding {
    func inspect() throws -> UpdateAvailabilityFacts { throw DiagnosticProviderError.unavailable }
}

private struct TerminalUpdateAvailabilityProvider: UpdateAvailabilityProviding {
    let currentVersion: String
    let check: () throws -> UpdateCandidate

    func inspect() throws -> UpdateAvailabilityFacts {
        do {
            let candidate = try check()
            return UpdateAvailabilityFacts(
                status: .available,
                currentVersion: currentVersion,
                availableVersion: candidate.manifest.product.version
            )
        } catch UpdateEngineError.noStableUpdate {
            return UpdateAvailabilityFacts(status: .current, currentVersion: currentVersion)
        } catch {
            throw DiagnosticProviderError.unavailable
        }
    }
}

private struct TerminalLaunchctlLifecycleRetryer: LifecycleRetrying, @unchecked Sendable {
    let runner: MaintenanceCommandRunner = SystemMaintenanceCommandRunner()
    let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")
    let label = "gui/\(getuid())/com.jay.mac-orchestrator"

    func retry(_ target: LifecycleRepairTarget) async -> RepairAdapterResult {
        guard (try? runner.run(executable: launchctlURL, arguments: ["print", label]))?.status == 0 else {
            return .refused
        }
        let result = try? runner.run(executable: launchctlURL, arguments: ["kickstart", "-k", label])
        return result?.status == 0 ? .repaired : .failed
    }
}

private struct TerminalPortOccupancy: LocalPortOccupancyChecking, @unchecked Sendable {
    let ownerID: String

    func inspect(port: Int) async -> LocalPortOccupancy {
        LocalPortAllocator.isOccupied(port) ? .occupiedUnrelated : .free
    }
}

private struct TerminalLaunchAgentReloader: ManagedLaunchAgentReloading, @unchecked Sendable {
    let runner: MaintenanceCommandRunner = SystemMaintenanceCommandRunner()
    let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")

    func reloadManagedLaunchAgent(_ contract: ManagedLaunchAgentContract) async -> RepairAdapterResult {
        let label = "gui/\(getuid())/\(ManagedLaunchAgentContract.label)"
        _ = try? runner.run(executable: launchctlURL, arguments: ["bootout", label])
        guard let result = try? runner.run(
            executable: launchctlURL,
            arguments: ["bootstrap", "gui/\(getuid())", contract.launchAgentURL.path]
        ), result.status == 0 else { return .failed }
        return .repaired
    }
}

enum TerminalCommand {
    static func parseMaintenanceCommand(arguments: [String]) throws -> TerminalMaintenanceIntent {
        guard let command = arguments.first else {
            throw TerminalCommandError.invalidArguments("A terminal command is required.")
        }
        switch command {
        case "doctor":
            var index = 1
            var json = false
            var repair: RepairActionID?
            while index < arguments.count {
                switch arguments[index] {
                case "--json":
                    guard !json else { throw TerminalCommandError.invalidArguments("Use --json at most once.") }
                    json = true
                    index += 1
                case "--repair":
                    guard repair == nil, index + 1 < arguments.count,
                          let action = RepairActionID(rawValue: arguments[index + 1]) else {
                        throw TerminalCommandError.invalidArguments("Usage: doctor [--json] [--repair ACTION].")
                    }
                    repair = action
                    index += 2
                default:
                    throw TerminalCommandError.invalidArguments("Usage: doctor [--json] [--repair ACTION].")
                }
            }
            guard !(json && repair != nil) else {
                throw TerminalCommandError.invalidArguments("Choose either --json or --repair.")
            }
            return .doctor(json: json, repair: repair)
        case "support-bundle":
            var index = 1
            var preview = false
            var create = false
            var output: String?
            while index < arguments.count {
                switch arguments[index] {
                case "--preview":
                    guard !preview else { throw TerminalCommandError.invalidArguments("Use --preview at most once.") }
                    preview = true
                    index += 1
                case "--create":
                    guard !create else { throw TerminalCommandError.invalidArguments("Use --create at most once.") }
                    create = true
                    index += 1
                case "--output":
                    guard output == nil, index + 1 < arguments.count,
                          !arguments[index + 1].hasPrefix("--") else {
                        throw TerminalCommandError.invalidArguments("Missing value for --output.")
                    }
                    output = arguments[index + 1]
                    index += 2
                default:
                    throw TerminalCommandError.invalidArguments("Usage: support-bundle --preview|--create [--output PATH].")
                }
            }
            guard preview != create else {
                throw TerminalCommandError.invalidArguments("Usage: support-bundle --preview|--create [--output PATH].")
            }
            guard !preview || output == nil else {
                throw TerminalCommandError.invalidArguments("--output is only valid with --create.")
            }
            return .supportBundle(preview: preview, output: output)
        default:
            throw TerminalCommandError.invalidArguments("Unknown maintenance command: \(command)")
        }
    }

    static func run(arguments: [String]) -> Int32? {
        guard let command = arguments.first else { return nil }

        do {
            switch command {
            case "--help", "-h":
                printHelp()
                return 0
            case "--store-ngrok-token":
                guard arguments.count == 1 else {
                    throw TerminalCommandError.invalidArguments(
                        "--store-ngrok-token does not accept a token argument; use hidden stdin input."
                    )
                }
                let token = try readToken()
                try KeychainStore().set(token, for: .ngrokAuthtoken)
                print("ngrok authtoken stored in Keychain.")
                return 0
            case "--clear-ngrok-token-if-matches":
                guard arguments.count == 1 else {
                    throw TerminalCommandError.invalidArguments(
                        "--clear-ngrok-token-if-matches reads the candidate value from hidden stdin input."
                    )
                }
                let candidate = try readToken()
                let removed = try clearNgrokToken(ifMatching: candidate)
                print(removed ? "Matching ngrok token removed from Keychain." : "No matching ngrok token was removed.")
                return 0
            case "--set-profile":
                guard arguments.count >= 2, let profile = ControlProfile(rawValue: arguments[1]) else {
                    throw TerminalCommandError.invalidArguments(
                        "Usage: --set-profile guided|full [--confirm-full-control]"
                    )
                }
                if profile == .full {
                    guard arguments.contains("--confirm-full-control") else {
                        throw TerminalCommandError.invalidArguments(
                            "Full Control is materially more powerful. Repeat with --confirm-full-control after reviewing the warning."
                        )
                    }
                    print("Warning: Full Control enables the broader local automation surface.")
                }
                _ = try ConfigurationStore().update { configuration in
                    configuration.controlProfile = profile
                }
                _ = try restartRunningSupervisorIfLoaded()
                print("Control profile set to \(profile.rawValue).")
                return 0
            case "--enable-remote":
                let keychain = KeychainStore()
                guard let token = try keychain.value(for: .ngrokAuthtoken),
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TerminalCommandError.tokenMissing
                }
                _ = try ConfigurationStore().update { configuration in
                    configuration.process.serverDesired = true
                    configuration.process.tunnelDesired = true
                    configuration.desiredCapabilities["remote.connector"] = true
                }
                if try restartRunningSupervisorIfLoaded() {
                    try waitForRemoteConnector()
                } else {
                    print("Remote connector enabled; it will start after local activation succeeds.")
                }
                return 0
            case "--disable-remote":
                _ = try ConfigurationStore().update { configuration in
                    configuration.process.tunnelDesired = false
                    configuration.desiredCapabilities["remote.connector"] = false
                }
                _ = try restartRunningSupervisorIfLoaded()
                try waitForRemoteConnectorToDisappear()
                return 0
            case "--print-connector-url":
                try printConnectorURL()
                return 0
            case "--wait-for-local-activation":
                guard arguments.count == 1 else {
                    throw TerminalCommandError.invalidArguments(
                        "--wait-for-local-activation does not accept additional arguments."
                    )
                }
                try waitForLocalActivation()
                return 0
            case "--print-local-connector-url":
                guard arguments.count == 1 else {
                    throw TerminalCommandError.invalidArguments(
                        "--print-local-connector-url does not accept additional arguments."
                    )
                }
                try waitForLocalActivation()
                return 0
            case "--wait-for-remote-connector":
                guard arguments.count == 1 else {
                    throw TerminalCommandError.invalidArguments(
                        "--wait-for-remote-connector does not accept additional arguments."
                    )
                }
                try waitForRemoteConnector()
                return 0
            case "update":
                return try runUpdate(arguments: Array(arguments.dropFirst()))
            case "uninstall":
                return try runUninstall(arguments: Array(arguments.dropFirst()))
            case "doctor":
                let intent = try parseMaintenanceCommand(arguments: arguments)
                guard case let .doctor(json, repair) = intent else { throw TerminalCommandError.invalidArguments("Invalid doctor command.") }
                return try runDoctor(json: json, repair: repair)
            case "support-bundle":
                let intent = try parseMaintenanceCommand(arguments: arguments)
                guard case let .supportBundle(preview, output) = intent else { throw TerminalCommandError.invalidArguments("Invalid support-bundle command.") }
                return try runSupportBundle(preview: preview, output: output)
            default:
                if command.hasPrefix("-") {
                    throw TerminalCommandError.invalidArguments("Unknown Mac Orchestrator command: \(command)")
                }
                return nil
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func printHelp() {
        print(
            """
            Mac Orchestrator terminal commands:
              --store-ngrok-token       Read an authtoken from hidden stdin input and store it in Keychain.
              --clear-ngrok-token-if-matches Remove only a matching token read from hidden stdin input.
              --set-profile guided      Select the default Guided Control profile.
              --set-profile full        Select Full Control with --confirm-full-control.
              --enable-remote            Opt in to the ngrok connector after storing a token.
              --disable-remote           Stop requesting remote ingress.
              --print-connector-url      Confirm the live connector without printing its credential-bearing URL.
              --wait-for-local-activation Wait for the authenticated local MCP activation oracle.
              --print-local-connector-url Confirm activation without printing the credential-bearing URL.
              --wait-for-remote-connector Wait for a confirmed live HTTPS connector without printing its URL.
              update [--check|--apply] Check or apply an authenticated release update.
              doctor [--json] [--repair ACTION] Run read-only diagnostics or one explicit bounded repair.
              support-bundle --preview|--create [--output PATH] Review or create a redacted support bundle.
              update --pinned --manifest URL --manifest-sha256 SHA --version VERSION
              uninstall --plan [removal options] Preview an explicit uninstall plan.
              uninstall --apply --confirm-uninstall [removal options] Apply that plan.
              Removal options: --remove-app --remove-owned-processes --remove-runtime --remove-remote --remove-caches --remove-logs --remove-launch-agent --remove-config --delete-credentials.
            """
        )
    }

    private static func runUpdate(arguments: [String]) throws -> Int32 {
        let effectiveArguments = arguments.isEmpty ? ["--check"] : arguments
        let checking = effectiveArguments.contains("--check")
        let applying = effectiveArguments.contains("--apply")
        guard checking || applying || effectiveArguments.contains("--pinned") else {
            throw TerminalCommandError.invalidArguments(
                "Usage: update [--check|--apply] or update --pinned --manifest URL --manifest-sha256 SHA --version VERSION"
            )
        }
        guard !(checking && applying) else {
            throw TerminalCommandError.invalidArguments("Choose only one of --check or --apply.")
        }
        let fetcher = URLSessionUpdateAssetFetcher()
        let installDirectory = ConfigurationStore.defaultDirectoryURL()
            .appendingPathComponent("install", isDirectory: true)
        let receiptStore = InstallationReceiptStore(directoryURL: installDirectory)
        guard let receipt = try receiptStore.load(),
              let currentVersion = try? SemanticVersion(receipt.productVersion) else {
            throw TerminalCommandError.invalidArguments(
                "No authenticated InstallationReceiptV1 exists; use the externally pinned Phase 2 recovery path first."
            )
        }
        let lifecycle = ExternalMaintenanceLifecycleAdapter(controller: LaunchAgentMaintenanceController())
        let driver = FilesystemUpdateTransactionDriver(
            supportDirectory: ConfigurationStore.defaultDirectoryURL(),
            fetcher: fetcher
        )
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let operatingSystem = try SemanticVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        let engine = UpdateEngine(
            currentVersion: currentVersion,
            operatingSystem: operatingSystem,
            discoverer: GitHubReleaseDiscoverer(fetcher: fetcher),
            fetcher: fetcher,
            ledger: MaintenanceTransactionLedger(directoryURL: installDirectory.appendingPathComponent("transactions", isDirectory: true)),
            driver: driver,
            lifecycle: lifecycle
        )

        let candidate: UpdateCandidate
        if effectiveArguments.contains("--pinned") {
            let manifestURL = try requiredURL(effectiveArguments, flag: "--manifest")
            let manifestSHA = try requiredValue(effectiveArguments, flag: "--manifest-sha256")
            let versionFlag = effectiveArguments.contains("--version") ? "--version" : "--release-version"
            let version = try SemanticVersion(requiredValue(effectiveArguments, flag: versionFlag))
            var signatureURL: URL?
            if effectiveArguments.contains("--signature") {
                signatureURL = try requiredURL(effectiveArguments, flag: "--signature")
            }
            candidate = try engine.checkPinned(
                manifestURL: manifestURL,
                manifestSHA256: manifestSHA,
                releaseVersion: version,
                signatureURL: signatureURL
            )
        } else {
            candidate = try engine.checkForUpdate()
        }
        print("Authenticated update candidate: \(candidate.manifest.product.version)")
        print("Manifest SHA-256: \(candidate.manifestSHA256)")
        guard applying else { return 0 }
        let result = try engine.apply(candidate)
        print("Update committed: transaction \(result.transaction.id.uuidString)")
        return 0
    }

    private static func runUninstall(arguments: [String]) throws -> Int32 {
        let apply = arguments.contains("--apply")
        if apply && !arguments.contains("--confirm-uninstall") {
            throw TerminalCommandError.invalidArguments(
                "uninstall --apply requires --confirm-uninstall after reviewing uninstall --plan."
            )
        }
        let options = RemovalOptions(
            removeApplication: arguments.contains("--remove-app"),
            removeOwnedProcesses: arguments.contains("--remove-owned-processes"),
            removeManagedRuntime: arguments.contains("--remove-runtime"),
            removeManagedRemote: arguments.contains("--remove-remote"),
            removeCaches: arguments.contains("--remove-caches"),
            removeLogsAndSupport: arguments.contains("--remove-logs"),
            removeLaunchAgent: arguments.contains("--remove-launch-agent"),
            removeConfiguration: arguments.contains("--remove-config"),
            deleteCredentials: arguments.contains("--delete-credentials")
        )
        let support = ConfigurationStore.defaultDirectoryURL()
        let engine = try UninstallEngine(
            supportDirectory: support,
            logsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true),
            keychain: KeychainStore(),
            lifecycle: ExternalMaintenanceLifecycleAdapter(controller: LaunchAgentMaintenanceController()),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let plan = try engine.plan(options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(plan), as: UTF8.self))
        guard apply else { return 0 }
        let receipt = engine.apply(plan)
        print(String(decoding: try receipt.encoded(), as: UTF8.self))
        return receipt.outcomes.contains { $0.status == UninstallOutcomeStatus.failedManualActionRequired } ? 1 : 0
    }

    private static func runDoctor(json: Bool, repair: RepairActionID?) throws -> Int32 {
        let engine = try makeDoctorEngine()
        let report = try runDoctorReport(engine)
        if json {
            print(String(decoding: try report.encodedJSON(), as: UTF8.self))
            return report.summary.fail == 0 ? 0 : 1
        }

        printDoctorReport(report)
        if let repair {
            let outcome = try runRepair(repair)
            print("Repair \(repair.rawValue): \(outcome.status.rawValue) — \(outcome.safeReason)")
            let after = try runDoctorReport(engine)
            print("After repair:")
            printDoctorReport(after)
            return after.summary.fail == 0 && outcome.status != .failed && outcome.status != .refused ? 0 : 1
        }
        return report.summary.fail == 0 ? 0 : 1
    }

    private static func runSupportBundle(preview: Bool, output: String?) throws -> Int32 {
        let doctor = try makeDoctorEngine()
        let report = try runDoctorReport(doctor)
        let engine = makeSupportBundleEngine(report: report)
        let plan = engine.preview()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print("Support bundle preview (no files collected):")
        print(String(decoding: try encoder.encode(plan), as: UTF8.self))
        guard !preview else { return 0 }

        let destinationPath = output.map { NSString(string: $0).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent("Mac-Orchestrator-support-\(Int(Date().timeIntervalSince1970)).zip")
                .path
        let destination = URL(fileURLWithPath: destinationPath)
        let archive = try engine.create(plan: plan, to: destination)
        print("Redacted support bundle created: \(archive.path)")
        return 0
    }

    private static func runDoctorReport(_ engine: DoctorEngine) throws -> DoctorReport {
        let box = TerminalDoctorResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.store(await engine.run())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success,
              let report = box.load() else {
            throw TerminalCommandError.agentRequestFailed("Doctor timed out")
        }
        return report
    }

    private static func printDoctorReport(_ report: DoctorReport) {
        for result in report.results {
            print("[\(result.status.rawValue.uppercased())] \(result.title): \(result.reason)")
        }
        print("Summary: PASS \(report.summary.pass), WARN \(report.summary.warn), FAIL \(report.summary.fail), SKIP \(report.summary.skip)")
    }

    private static func makeDoctorEngine() throws -> DoctorEngine {
        let fileManager = FileManager.default
        let support = ConfigurationStore.defaultDirectoryURL()
        let paths = DiagnosticPathSet.defaultPaths(fileManager: fileManager)
        let configurationProvider = ReadOnlyDoctorConfigurationContextProvider(
            directoryURL: support,
            fileManager: fileManager
        )
        let configuration = (try? configurationProvider.inspect())?.validatedConfiguration
        let serverDesired = configuration?.process.serverDesired == true
        let remoteDesired = configuration?.process.tunnelDesired == true
            || configuration?.desiredCapabilities["remote.connector"] == true
        let ownerID = configuration?.ownerID ?? ""
        let port = configuration?.localMCPPort ?? 0

        let updateProvider: any UpdateAvailabilityProviding
        if let receipt = try? InstallationReceiptStore(
            directoryURL: support.appendingPathComponent("install", isDirectory: true),
            fileManager: fileManager
        ).load(), (try? SemanticVersion(receipt.productVersion)) != nil {
            let updateEngine = try makeUpdateEngine()
            updateProvider = TerminalUpdateAvailabilityProvider(
                currentVersion: receipt.productVersion,
                check: { try updateEngine.checkForUpdate() }
            )
        } else {
            updateProvider = TerminalUnavailableUpdateProvider()
        }

        return DoctorEngine(dependencies: DoctorDependencies(
            configurationContextProvider: configurationProvider,
            installedReleaseProvider: ReadOnlyInstalledReleaseFactsProvider(
                paths: paths,
                fileManager: fileManager
            ),
            keychainPresenceProvider: SystemDoctorKeychainPresenceProvider(),
            portProvider: ReadOnlyPortFactsProvider(port: port, ownerID: ownerID),
            localMCPProvider: TerminalUnavailableLocalMCPProvider(),
            lifecycleProvider: ReadOnlyLifecycleFactsProvider(
                paths: paths,
                ownerID: ownerID,
                serverDesired: serverDesired,
                remoteDesired: remoteDesired,
                fileManager: fileManager
            ),
            remoteConnectorProvider: ReadOnlyRemoteConnectorFactsProvider(
                desired: remoteDesired,
                paths: paths,
                target: "http://127.0.0.1:\(port)",
                httpRunner: SystemDiagnosticHTTPRunner(),
                ownerID: ownerID,
                processRunner: SystemDiagnosticProcessRunner()
            ),
            diskSpaceProvider: ReadOnlyDiskSpaceProvider(
                filesystemURL: fileManager.homeDirectoryForCurrentUser,
                criticalPaths: [support, paths.launchAgentURL]
            ),
            logDirectoryProvider: ReadOnlyLogDirectoryPermissionsProvider(
                directoryURL: fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
            ),
            updateProvider: updateProvider
        ))
    }

    private static func runRepair(_ action: RepairActionID) throws -> RepairOutcome {
        let fileManager = FileManager.default
        let support = ConfigurationStore.defaultDirectoryURL()
        let paths = DiagnosticPathSet.defaultPaths(fileManager: fileManager)
        let configuration = try? ReadOnlyDoctorConfigurationContextProvider(directoryURL: support).inspect().validatedConfiguration
        var portRepair: (any LocalPortReassigning)?
        if let configuration,
           let candidate = try? LocalPortAllocator.select(
               preferred: configuration.localMCPPort,
               isOccupied: LocalPortAllocator.isOccupied
           ) {
            portRepair = SafeLocalPortReassigner(
                request: LocalPortReassignmentRequest(
                    currentPort: configuration.localMCPPort,
                    candidatePort: candidate,
                    expectedOwnerID: configuration.ownerID
                ),
                occupancy: TerminalPortOccupancy(ownerID: configuration.ownerID),
                configuration: ConfigurationStorePortUpdater(store: ConfigurationStore())
            )
        }
        let contract = ManagedLaunchAgentContract(
            homeDirectory: paths.homeDirectory,
            executableURL: paths.helperExecutableURL
        )
        let launchAgentRepairer = ManagedLaunchAgentRepairer(
            contract: contract,
            ownership: FileSystemLaunchAgentOwnershipInspector(fileManager: fileManager),
            writer: FileSystemManagedLaunchAgentWriter(
                fileManager: fileManager,
                reloader: TerminalLaunchAgentReloader()
            )
        )
        let backupRestorer: (any ConfigurationBackupRestoring)? = configuration.map {
            ConfigurationStoreBackupRestorer(
                store: ConfigurationStore(),
                expectedOwnerID: $0.ownerID
            )
        }
        let outcomeBox = TerminalRepairResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            outcomeBox.store(await RepairEngine(dependencies: RepairDependencies(
                lifecycleRetrying: TerminalLaunchctlLifecycleRetryer(),
                configurationBackupRestoring: backupRestorer,
                localPortReassigning: portRepair,
                launchAgentRepairing: launchAgentRepairer
            )).execute(action))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success,
              let outcome = outcomeBox.load() else {
            throw TerminalCommandError.agentRequestFailed("Repair timed out")
        }
        return outcome
    }

    private static func makeSupportBundleEngine(report: DoctorReport) -> SupportBundleEngine {
        let reportData = (try? report.encodedJSON()) ?? Data("{}".utf8)
        let support = ConfigurationStore.defaultDirectoryURL()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let receiptURL = support.appendingPathComponent("install/receipt.json")
        let receiptData = (try? Data(contentsOf: receiptURL)) ?? Data("{\"available\":false}".utf8)
        let entries = [
            Phase3SupportBundleSource.Entry(
                plan: SupportBundleEntryPlan(
                    sourceID: "phase3", logicalID: "doctor-report", archivePath: "doctor/report.json",
                    category: "diagnostic", reason: "read-only Doctor report", expectedRedaction: "canonical redaction"
                ), data: { reportData }
            ),
            Phase3SupportBundleSource.Entry(
                plan: SupportBundleEntryPlan(
                    sourceID: "phase3", logicalID: "installation-receipt", archivePath: "installation/receipt.json",
                    category: "installation", reason: "nonsecret receipt integrity metadata", expectedRedaction: "canonical redaction"
                ), data: { receiptData }
            ),
            Phase3SupportBundleSource.Entry(
                plan: SupportBundleEntryPlan(
                    sourceID: "phase3", logicalID: "bounded-logs", archivePath: "logs/bounded.log",
                    category: "logs", reason: "bounded product-owned log excerpt", expectedRedaction: "canonical redaction"
                ), data: { try readBoundedLogs(at: home.appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)) }
            ),
            Phase3SupportBundleSource.Entry(
                plan: SupportBundleEntryPlan(
                    sourceID: "phase3", logicalID: "maintenance-transactions", archivePath: "maintenance/transactions.json",
                    category: "maintenance", reason: "bounded update transaction and recovery summary", expectedRedaction: "canonical redaction"
                ), data: { try readBoundedTransactions(at: support.appendingPathComponent("install/transactions", isDirectory: true)) }
            )
        ]
        return SupportBundleEngine(
            sources: [Phase3SupportBundleSource(entries: entries)],
            redactor: SensitiveDataRedactor(exactSecrets: [], homeDirectory: home.path)
        )
    }

    private static func readBoundedLogs(at directory: URL) throws -> Data {
        guard !pathHasSymlinkComponent(directory) else { return Data() }
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) == 0,
           ((directoryInfo.st_mode & S_IFMT) != S_IFDIR || directoryInfo.st_uid != getuid()) {
            return Data()
        }
        var combined = ""
        let names = ["app.log", "server.log", "tunnel.log", "launcher.log"]
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { continue }
            guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == getuid() else { continue }
            let data = try Data(contentsOf: url)
            let bounded = data.suffix(16 * 1024)
            combined += "## \(name)\n\(String(decoding: bounded, as: UTF8.self))\n"
        }
        return Data(combined.utf8)
    }

    private static func readBoundedTransactions(at directory: URL) throws -> Data {
        var directoryInfo = stat()
        guard !pathHasSymlinkComponent(directory),
              lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid() else {
            return Data("{\"available\":false}\n".utf8)
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            .filter { $0.lastPathComponent.hasPrefix("transaction-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(10)
        var values: [[String: Any]] = []
        for url in urls {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == getuid() else { continue }
            let bounded = Data(try Data(contentsOf: url).suffix(16 * 1024))
            if let object = try? JSONSerialization.jsonObject(with: bounded) as? [String: Any] {
                values.append(object)
            }
        }
        return try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    }

    private static func pathHasSymlinkComponent(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    private static func makeUpdateEngine() throws -> UpdateEngine {
        let fileManager = FileManager.default
        let support = ConfigurationStore.defaultDirectoryURL()
        let installDirectory = support.appendingPathComponent("install", isDirectory: true)
        let receipt = try InstallationReceiptStore(directoryURL: installDirectory, fileManager: fileManager).load()
        guard let receipt, let currentVersion = try? SemanticVersion(receipt.productVersion) else {
            throw TerminalCommandError.invalidArguments("No authenticated InstallationReceiptV1 exists; use the externally pinned Phase 2 recovery path first.")
        }
        let fetcher = URLSessionUpdateAssetFetcher()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let operatingSystem = try SemanticVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        return UpdateEngine(
            currentVersion: currentVersion,
            operatingSystem: operatingSystem,
            discoverer: GitHubReleaseDiscoverer(fetcher: fetcher),
            fetcher: fetcher,
            ledger: MaintenanceTransactionLedger(directoryURL: installDirectory.appendingPathComponent("transactions", isDirectory: true)),
            driver: FilesystemUpdateTransactionDriver(supportDirectory: support, fetcher: fetcher),
            lifecycle: ExternalMaintenanceLifecycleAdapter(controller: LaunchAgentMaintenanceController())
        )
    }

    private static func requiredValue(_ arguments: [String], flag: String) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else {
            throw TerminalCommandError.invalidArguments("Missing value for \(flag).")
        }
        return arguments[index + 1]
    }

    private static func requiredURL(_ arguments: [String], flag: String) throws -> URL {
        guard let url = URL(string: try requiredValue(arguments, flag: flag)) else {
            throw TerminalCommandError.invalidArguments("Invalid URL for \(flag).")
        }
        return url
    }

    private static func restartRunningSupervisorIfLoaded() throws -> Bool {
        if ProcessInfo.processInfo.environment["MAC_ORCHESTRATOR_SKIP_SUPERVISOR_RELOAD"] == "1" {
            return false
        }
        let label = "gui/\(getuid())/com.jay.mac-orchestrator"
        let printProcess = Process()
        printProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        printProcess.arguments = ["print", label]
        printProcess.standardOutput = FileHandle.nullDevice
        printProcess.standardError = FileHandle.nullDevice
        do {
            try printProcess.run()
            printProcess.waitUntilExit()
        } catch {
            return false
        }
        guard printProcess.terminationStatus == 0 else { return false }

        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        restart.arguments = ["kickstart", "-k", label]
        restart.standardOutput = FileHandle.nullDevice
        restart.standardError = FileHandle.nullDevice
        do {
            try restart.run()
            restart.waitUntilExit()
        } catch {
            throw TerminalCommandError.agentRequestFailed("could not reload the managed supervisor")
        }
        guard restart.terminationStatus == 0 else {
            throw TerminalCommandError.agentRequestFailed("could not reload the managed supervisor")
        }
        return true
    }

    private static func readToken() throws -> String {
        let token: String
        if isatty(STDIN_FILENO) == 1 {
            var original = termios()
            guard tcgetattr(STDIN_FILENO, &original) == 0 else {
                throw TerminalCommandError.tokenInputUnavailable
            }
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
                throw TerminalCommandError.tokenInputUnavailable
            }
            defer {
                var restored = original
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
                fputs("\n", stderr)
            }
            fputs("ngrok authtoken: ", stderr)
            guard let line = readLine(strippingNewline: true) else {
                throw TerminalCommandError.tokenInputUnavailable
            }
            token = line
        } else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8) else {
                throw TerminalCommandError.tokenInputUnavailable
            }
            token = value
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalCommandError.tokenInputUnavailable
        }
        return trimmed
    }

    private static func printConnectorURL() throws {
        _ = try currentConnectorURL()
        print("Remote connector confirmed. Its credential-bearing URL was intentionally not printed.")
    }

    private static func waitForLocalActivation() throws {
        let configuration = try ConfigurationStore().load()
        let connectorToken = try KeychainStore().connectorTokenValue()
        let deadline = Date().addingTimeInterval(90)
        var lastError = "the helper has not completed its activation handshake"

        while Date() < deadline {
            do {
                try runActivationProbe(
                    port: configuration.localMCPPort,
                    capabilityToken: connectorToken,
                    requiresInteractiveUI: configuration.desiredCapabilities["mac.ui"] == true
                )
                guard let current = try? ConfigurationStore().load(),
                      OnboardingStateClassifier.classify(current) == .completed else {
                    lastError = "the helper is active but required onboarding state is still pending"
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                print("Local activation confirmed. The credential-bearing local MCP URL was intentionally not printed.")
                printClientHandoff()
                printPermissionGuidance(configuration: configuration)
                return
            } catch {
                lastError = error.localizedDescription
                Thread.sleep(forTimeInterval: 1)
            }
        }

        print("Local connection is not ready; the installed helper remains in place.")
        printPermissionGuidance(configuration: configuration)
        throw TerminalCommandError.agentRequestFailed(
            "local activation did not complete within 90 seconds (\(lastError))."
        )
    }

    private static func printPermissionGuidance(configuration: AppConfiguration) {
        let runtimeDirectory = ConfigurationStore.defaultDirectoryURL()
            .appendingPathComponent("runtime", isDirectory: true)
        guard let permissions = SystemManagedPermissionChecker().probe(runtimeDirectory: runtimeDirectory) else {
            print("Permission status is unavailable; managed capabilities remain fail-closed.")
            return
        }

        let uiRequired = configuration.desiredCapabilities["mac.ui"] == true
        let screenOcrRequired = configuration.desiredCapabilities["mac.screenOcr"] == true
        print("Accessibility: \(permissions.accessibility ? "ready" : uiRequired ? "pending" : "not required")")
        print("Screen Recording: \(permissions.screenRecording ? "ready" : screenOcrRequired ? "pending" : "not required")")
        print("Automation / Apple Events: \(permissions.automation ? "ready" : uiRequired ? "pending" : "not required")")
        print("Active console session: \(permissions.activeConsole ? "ready" : uiRequired ? "pending" : "not required")")
        print("Screen unlocked: \(permissions.unlocked ? "yes" : uiRequired ? "no" : "not required")")
        if uiRequired && !permissions.accessibility {
            print("Grant Accessibility to the installed managed runtime in Privacy & Security, then Restart.")
        }
        if screenOcrRequired && !permissions.screenRecording {
            print("Grant Screen Recording to the installed managed runtime in Privacy & Security, then Restart.")
        }
        if uiRequired && !permissions.automation {
            print("Grant Automation / Apple Events to the installed managed runtime in Privacy & Security, then Restart.")
        }
        if uiRequired && (!permissions.activeConsole || !permissions.unlocked) {
            print("Unlock the Mac and use the active console session before retrying UI capabilities.")
        }
    }

    private static func printClientHandoff() {
        print("Use the installed authenticated client handoff to connect; credential-bearing URLs are not printed by the terminal.")
    }

    private static func waitForRemoteConnector() throws {
        let deadline = Date().addingTimeInterval(90)
        var lastError = "no confirmed HTTPS endpoint was available"
        while Date() < deadline {
            do {
                let url = try currentConnectorURL()
                _ = url
                print("Remote connector confirmed.")
                printClientHandoff()
                return
            } catch {
                lastError = error.localizedDescription
                Thread.sleep(forTimeInterval: 1)
            }
        }
        throw TerminalCommandError.agentRequestFailed(
            "remote connector did not become live within 90 seconds (\(lastError))."
        )
    }

    private static func waitForRemoteConnectorToDisappear() throws {
        let deadline = Date().addingTimeInterval(30)
        var lastError = "the Agent API did not confirm endpoint removal"
        while Date() < deadline {
            do {
                let data = try requestAgentEndpoints()
                guard NgrokEndpointParser.isValidResponse(from: data) else {
                    lastError = "the Agent API returned an invalid endpoint response"
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                if !NgrokEndpointParser.hasLiveHTTPS(from: data) {
                    print("Remote connector disabled; no live HTTPS endpoint remains.")
                    return
                }
                lastError = "the previous HTTPS endpoint is still present"
                Thread.sleep(forTimeInterval: 1)
            } catch {
                lastError = error.localizedDescription
                Thread.sleep(forTimeInterval: 1)
            }
        }
        throw TerminalCommandError.agentRequestFailed(
            "remote connector shutdown was not confirmed within 30 seconds (\(lastError))."
        )
    }

    private static func runActivationProbe(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = TerminalProbeErrorBox()
        Task.detached {
            do {
                try await LocalActivationProbe().run(
                    port: port,
                    capabilityToken: capabilityToken,
                    requiresInteractiveUI: requiresInteractiveUI
                )
            } catch {
                errorBox.store(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success else {
            throw TerminalCommandError.agentRequestFailed("activation probe timed out")
        }
        if let error = errorBox.load() {
            throw error
        }
    }

    private static func currentConnectorURL() throws -> URL {
        let configuration = try ConfigurationStore().load()
        let data = try requestAgentEndpoints()
        let connectorToken = try KeychainStore().connectorTokenValue()
        guard let publicURL = NgrokEndpointParser.publicURL(
            from: data,
            matching: "http://127.0.0.1:\(configuration.localMCPPort)"
        ),
        let connectorURL = ConnectorURLBuilder.make(
            publicURL: publicURL.absoluteString,
            capabilityToken: connectorToken
        ) else {
            throw TerminalCommandError.noLiveConnector
        }
        return connectorURL
    }

    private static func requestAgentEndpoints() throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4040/api/endpoints")!)
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<Data, Error>?
        NoRedirectURLSession.make().dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                resultLock.lock()
                result = .failure(error)
                resultLock.unlock()
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url == request.url,
                  httpResponse.statusCode == 200,
                  let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                resultLock.lock()
                result = .failure(
                    TerminalCommandError.agentRequestFailed("HTTP status \(status)")
                )
                resultLock.unlock()
                return
            }
            resultLock.lock()
            result = .success(data)
            resultLock.unlock()
        }.resume()

        guard semaphore.wait(timeout: .now() + 4) == .success else {
            throw TerminalCommandError.agentRequestFailed("request timed out")
        }
        resultLock.lock()
        let completedResult = result
        resultLock.unlock()
        guard let completedResult else {
            throw TerminalCommandError.agentRequestFailed("request returned no result")
        }
        let data = try completedResult.get()
        return data
    }

    private static func clearNgrokToken(ifMatching candidate: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainItem.ngrokAuthtoken.service,
            kSecAttrAccount as String: KeychainItem.ngrokAuthtoken.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return false }
        guard status == errSecSuccess,
              let data = result as? Data,
              let stored = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.operationFailed(Int(status))
        }
        guard stored == candidate else { return false }

        _ = try ConfigurationStore().update { configuration in
            configuration.process.tunnelDesired = false
            configuration.desiredCapabilities["remote.connector"] = false
        }
        let supervisorWasReloaded = try restartRunningSupervisorIfLoaded()
        if supervisorWasReloaded {
            try waitForRemoteConnectorToDisappear()
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainItem.ngrokAuthtoken.service,
            kSecAttrAccount as String: KeychainItem.ngrokAuthtoken.account,
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(Int(deleteStatus))
        }
        return deleteStatus == errSecSuccess
    }
}
