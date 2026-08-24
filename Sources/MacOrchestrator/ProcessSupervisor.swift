import AppKit
import Foundation
import Darwin

@MainActor
final class ProcessSupervisor {
    var onSnapshot: ((ServiceSnapshot) -> Void)?

    private(set) var snapshot = ServiceSnapshot() {
        didSet { onSnapshot?(snapshot) }
    }

    var lifecycleSnapshot: LifecycleSnapshot {
        lifecycle.snapshot
    }

    var meridianConfiguration: MeridianIndexerConfiguration {
        activeContract?.configuration.integration.meridianIndexer ?? MeridianIndexerConfiguration()
    }

    var meridianScopeIDs: [String] {
        meridianConfiguration.scopes.map(\.scopeID).sorted()
    }

    private let runtimeCoordinator: NativeRuntimeCoordinator
    private let supportDirectory: URL
    let logsDirectory: URL
    private let runtimeDirectory: URL
    private let stateURL: URL
    private let appLog: RotatingLog
    private let serverLog: RotatingLog
    private let tunnelLog: RotatingLog
    private let lifecycleScheduler: MainLifecycleScheduler
    private let lifecycle: LifecycleStateMachine
    private let meridianIndexerCoordinator: MeridianIndexerCoordinator
    private let remoteConnectorAdapter: any RemoteConnectorAdapter
    private let remoteProbeCoordinator: RemoteProbeCoordinator
    private let remoteConnectorStateStore: any RemoteConnectorStatePersisting
    private let networkPathMonitor: any NetworkPathMonitoring

    private var serverProcess: Process?
    private var tunnelProcess: Process?
    private var healthTimer: Timer?
    private var quitting = false
    private var activeContract: ManagedRuntimeLaunchContract?
    private var ownerID = ""
    private var activationSucceeded = false
    private var activationInFlight = false
    private var serverLaunchGeneration: UInt64 = 0
    private var tunnelLaunchGeneration: UInt64 = 0
    private var serverProcessGroupOwned = false
    private var tunnelProcessGroupOwned = false
    private var connectorCredentialGeneration: UInt64 = 0
    private var verifiedRemoteOrigin: RemotePublicOrigin?

    private var serverDesired: Bool {
        lifecycle.desiredState(for: .mcpServer).isEnabled
    }

    private var tunnelDesired: Bool {
        lifecycle.desiredState(for: .remoteConnector).isEnabled
    }

    private var ngrokDirectory: URL {
        supportDirectory
            .appendingPathComponent("remote", isDirectory: true)
            .appendingPathComponent("ngrok", isDirectory: true)
    }

    private var ngrokBinaryURL: URL {
        ngrokDirectory.appendingPathComponent("ngrok", isDirectory: false)
    }

    private var ngrokConfigURL: URL {
        ngrokDirectory.appendingPathComponent("ngrok.yml", isDirectory: false)
    }

    init(
        runtimeCoordinator: NativeRuntimeCoordinator,
        remoteConnectorAdapter: any RemoteConnectorAdapter = NgrokRemoteConnectorAdapter(),
        remoteConnectorStateStore: any RemoteConnectorStatePersisting = RemoteConnectorStateStore(),
        networkPathMonitor: any NetworkPathMonitoring = SystemNetworkPathMonitor()
    ) throws {
        self.runtimeCoordinator = runtimeCoordinator
        self.remoteConnectorAdapter = remoteConnectorAdapter
        self.remoteProbeCoordinator = RemoteProbeCoordinator(adapter: remoteConnectorAdapter)
        self.remoteConnectorStateStore = remoteConnectorStateStore
        self.networkPathMonitor = networkPathMonitor
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        supportDirectory = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Mac Orchestrator", isDirectory: true)
        logsDirectory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Mac Orchestrator", isDirectory: true)
        runtimeDirectory = runtimeCoordinator.runtimeDirectory
        stateURL = supportDirectory.appendingPathComponent("owned-processes.json")
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        appLog = RotatingLog(directory: logsDirectory, name: "app.log")
        serverLog = RotatingLog(directory: logsDirectory, name: "server.log")
        tunnelLog = RotatingLog(directory: logsDirectory, name: "tunnel.log")
        lifecycleScheduler = MainLifecycleScheduler()
        meridianIndexerCoordinator = MeridianIndexerCoordinator(
            scheduler: lifecycleScheduler,
            supportDirectory: supportDirectory
        )
        lifecycle = LifecycleStateMachine(scheduler: lifecycleScheduler)
        lifecycle.onSnapshot = { [weak self] lifecycleSnapshot in
            self?.applyLifecycleSnapshot(lifecycleSnapshot)
        }
        lifecycle.onEffect = { [weak self] effect in
            self?.handleLifecycleEffect(effect)
        }
        meridianIndexerCoordinator.onSnapshot = { [weak self] indexerSnapshot in
            self?.snapshot.applyMeridianIndexerSnapshot(indexerSnapshot)
        }
        meridianIndexerCoordinator.onReadinessEvidenceChanged = { [weak self] in
            self?.reloadMeridianReadiness()
        }
    }

    func launch(with contract: ManagedRuntimeLaunchContract) {
        activationSucceeded = false
        activationInFlight = false
        refreshRemoteConnectorIdentity()
        install(contract, requiresClientRefresh: false)
        appLog.write("Supervisor launched")
        cleanStaleOwnedProcesses()
        startNetworkPathMonitoring()
        startHealthTimer()
        if serverDesired {
            lifecycle.setDesiredState(.enabled, for: .mcpServer)
        }
        if tunnelDesired {
            lifecycle.setDesiredState(.enabled, for: .remoteConnector)
        }
    }

    func reportStartupFailure(_ error: Error) {
        let message = "Configuration startup failed: \(error.localizedDescription)"
        lifecycle.markStructuralFailure(for: .mcpServer, reason: message)
        appLog.write("ERROR: \(message)")
    }

    func startServerRequested() {
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.process.serverDesired = true
            }
        }
    }

    func stopServerRequested() {
        lifecycle.setDesiredState(.disabled, for: .remoteConnector)
        lifecycle.setDesiredState(.disabled, for: .mcpServer)
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.process.serverDesired = false
                configuration.process.tunnelDesired = false
                configuration.desiredCapabilities["remote.connector"] = false
            }
        }
    }

    func enableConnectorRequested() {
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.process.serverDesired = true
                configuration.process.tunnelDesired = true
                configuration.desiredCapabilities["remote.connector"] = true
            }
        }
    }

    func disableConnectorRequested() {
        lifecycle.setDesiredState(.disabled, for: .remoteConnector)
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.process.tunnelDesired = false
                configuration.desiredCapabilities["remote.connector"] = false
            }
        }
    }

    /// Copying the connector URL is an explicit credential handoff. The URL
    /// exists only inside this action, and the nonsecret receipt is written
    /// after NSPasteboard accepts the copy.
    func copyConnectorURLRequested(
        completion: @escaping (Result<RemoteClientHandoffClassification, Error>) -> Void = { _ in }
    ) {
        guard let configuration = activeContract?.configuration else {
            completion(.failure(RemoteConnectorHandoffError.stateUnavailable))
            return
        }
        let service = RemoteConnectorHandoffService(
            configuration: configuration,
            adapter: remoteConnectorAdapter,
            stateStore: remoteConnectorStateStore
        )
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            do {
                let handoff = try await service.prepare()
                guard NSPasteboard.general.clearContents() != 0,
                      NSPasteboard.general.setString(handoff.url.absoluteString, forType: .string) else {
                    throw RemoteConnectorHandoffError.recordFailed
                }
                let classification = try service.record(handoff)
                completion(.success(classification))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func restartRequested() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replacement = try await self.runtimeCoordinator.reload()
                self.apply(replacement, forceRestart: true)
            } catch {
                self.fail("Configuration reload failed: \(error.localizedDescription)")
            }
        }
    }

    func stopForQuit() {
        quitting = true
        networkPathMonitor.stop()
        healthTimer?.invalidate()
        meridianIndexerCoordinator.stop()
        lifecycle.prepareForMaintenance()
        appLog.write("Supervisor quit cleanly")
    }

    func handleWake() {
        appLog.write("Mac woke; rechecking managed services")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.apply(try await self.runtimeCoordinator.reload())
            } catch {
                self.fail("Configuration reload failed: \(error.localizedDescription)")
            }
            self.lifecycle.handleWake()
            self.meridianIndexerCoordinator.handleWake()
            self.checkHealth()
        }
    }

    func handleNetworkAvailabilityChanged(_ available: Bool) {
        guard !quitting else { return }
        lifecycle.handleNetworkAvailabilityChanged(available)
    }

    func prepareForMaintenance() {
        meridianIndexerCoordinator.stop()
        lifecycle.prepareForMaintenance()
    }

    func cancelMeridianIndexerRequested() {
        meridianIndexerCoordinator.cancel()
    }

    func retryMeridianIndexerRequested(rebuild: Bool = false) {
        meridianIndexerCoordinator.retry(rebuild: rebuild)
    }

    func configureMeridianRequested(deploymentURL: String, scopes: [MeridianSourceScope]) {
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.integration.meridianDeploymentURL = deploymentURL
                configuration.integration.meridianIndexer = MeridianIndexerConfiguration(
                    enabled: true,
                    scheduleMode: configuration.integration.meridianIndexer.scheduleMode,
                    scopes: scopes
                )
                configuration.desiredCapabilities["meridian.search"] = true
            }
        }
    }

    func setMeridianCredentialRequested(
        _ value: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.runtimeCoordinator.setMeridianIngestToken(value)
                self.apply(try await self.runtimeCoordinator.reload())
                completion(true)
            } catch {
                self.appLog.write("ERROR: Meridian credential update failed safely")
                completion(false)
            }
        }
    }

    func disableMeridianRequested() {
        meridianIndexerCoordinator.stop()
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.integration.meridianIndexer.enabled = false
                configuration.desiredCapabilities["meridian.search"] = false
            }
        }
    }

    func setMeridianScheduleRequested(_ mode: MeridianScheduleMode) {
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.integration.meridianIndexer.scheduleMode = mode
            }
        }
    }

    func scanMeridianNowRequested() {
        meridianIndexerCoordinator.scanNow()
    }

    func previewMeridianRequested() {
        meridianIndexerCoordinator.preview()
    }

    func pauseMeridianRequested() {
        meridianIndexerCoordinator.pause()
    }

    func resumeMeridianRequested() {
        meridianIndexerCoordinator.resume()
    }

    func deleteMeridianSourceRequested(scopeID: String) {
        meridianIndexerCoordinator.deleteSource(scopeID: scopeID)
    }

    func deleteAllMeridianDataRequested() {
        meridianIndexerCoordinator.deleteAllData()
    }

    func retry(component: ManagedComponentID) {
        if component == .mcpServer {
            invalidateServerActivation()
        }
        lifecycle.retry(component: component)
    }

    func reset(component: ManagedComponentID) {
        retry(component: component)
    }

    func openLogs() {
        NSWorkspace.shared.open(logsDirectory)
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateConfiguration(
        _ update: (inout AppConfiguration) throws -> Void
    ) async {
        do {
            apply(try await runtimeCoordinator.updateConfiguration(update))
        } catch {
            fail("Configuration update failed: \(error.localizedDescription)")
        }
    }

    private func apply(
        _ replacement: ManagedRuntimeLaunchContract,
        forceRestart: Bool = false
    ) {
        guard let current = activeContract else {
            install(replacement, requiresClientRefresh: false)
            if serverDesired {
                lifecycle.setDesiredState(.enabled, for: .mcpServer)
            }
            if tunnelDesired {
                lifecycle.setDesiredState(.enabled, for: .remoteConnector)
            }
            return
        }

        let transition = ManagedRuntimeTransition.between(
            current: current,
            replacement: replacement
        )
        if forceRestart || transition.requiresRestart {
            meridianIndexerCoordinator.stop()
            lifecycle.prepareForMaintenance()
            install(
                replacement,
                requiresClientRefresh: transition.requiresClientRefresh,
                resetFailureHistory: true
            )
            activationSucceeded = false
            activationInFlight = false
            lifecycle.resumeAfterMaintenance()
            return
        }

        install(replacement, requiresClientRefresh: false)
        if !serverDesired {
            stopTunnelProcess()
            stopServerProcess()
        } else if serverProcess == nil {
            lifecycle.setDesiredState(.enabled, for: .mcpServer)
        }
        if !tunnelDesired {
            stopTunnelProcess()
        } else if lifecycle.snapshot.mcpServer.isReady {
            lifecycle.setDesiredState(.enabled, for: .remoteConnector)
        }
        lifecycle.reconcile()
    }

    private func install(
        _ contract: ManagedRuntimeLaunchContract,
        requiresClientRefresh: Bool,
        resetFailureHistory: Bool = false
    ) {
        invalidateServerActivation()
        activeContract = contract
        ownerID = contract.configuration.ownerID
        lifecycle.synchronizeDesiredStates(
            mcpServer: contract.configuration.process.serverDesired,
            remoteConnector: contract.configuration.process.tunnelDesired,
            resetFailureHistory: resetFailureHistory
        )
        snapshot.applyRuntimeContract(
            contract,
            requiresClientRefresh: requiresClientRefresh
        )
        applyLifecycleSnapshot(lifecycle.snapshot)
        appLog.redact(contract.redactedSecrets)
        serverLog.redact(contract.redactedSecrets)
        tunnelLog.redact(contract.redactedSecrets)
        meridianIndexerCoordinator.reconcile(configuration: contract.configuration, contract: contract)
    }

    private func reloadMeridianReadiness() {
        guard !quitting else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.apply(try await self.runtimeCoordinator.reload())
            } catch {
                self.appLog.write("Meridian readiness refresh was not applied")
            }
        }
    }

    private func applyLifecycleSnapshot(_ lifecycleSnapshot: LifecycleSnapshot) {
        snapshot = snapshot.projected(from: lifecycleSnapshot)
    }

    private func handleLifecycleEffect(_ effect: LifecycleEffect) {
        switch effect {
        case .start(.mcpServer):
            startServer()
        case .start(.remoteConnector):
            startTunnel()
        case .stop(.mcpServer):
            stopServerProcess()
        case .stop(.remoteConnector):
            stopTunnelProcess()
        case .revalidate(.remoteConnector):
            queryTunnelURL(forceAuthenticatedProbe: true)
        case .revalidate(.mcpServer):
            checkHealth()
        }
    }

    private func startServer() {
        guard !quitting, !lifecycle.isQuiescing, serverDesired, serverProcess == nil,
              let contract = activeContract else { return }
        beginServerLaunch()
        lifecycle.markStarting(for: .mcpServer)
        let python = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        let script = runtimeDirectory.appendingPathComponent("automac_mcp.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            lifecycle.markFailed(
                for: .mcpServer,
                reason: "Installed Python runtime is missing. Run the terminal bootstrap again."
            )
            return
        }
        if PortSafetyPolicy.decision(isOccupied: portIsOccupied(contract.port)) ==
            .refuseWithoutTermination {
            lifecycle.recordFailure(
                for: .mcpServer,
                reason: "Port \(contract.port) is already used by another process. Mac Orchestrator did not terminate it."
            )
            return
        }

        activationSucceeded = false
        activationInFlight = false
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--managed-owner", ownerID]
        process.environment = contract.environment
        process.currentDirectoryURL = runtimeDirectory
        attachOutput(
            of: process,
            to: serverLog,
            redacting: contract.redactedSecrets,
            dropping: ["GET /__mac_orchestrator_health "]
        )
        process.terminationHandler = { [weak self] terminated in
            let processID = ObjectIdentifier(terminated)
            let terminationStatus = terminated.terminationStatus
            Task { @MainActor [weak self, processID, terminationStatus] in
                guard let self,
                      let process = self.serverProcess,
                      ObjectIdentifier(process) == processID else { return }
                self.invalidateServerActivation()
                self.serverProcess = nil
                self.persistState()
                if !self.quitting && self.serverDesired {
                    self.lifecycle.recordFailure(
                        for: .mcpServer,
                        reason: "MCP server exited with status \(terminationStatus)."
                    )
                } else {
                    self.lifecycle.markStopped(for: .mcpServer)
                }
            }
        }
        do {
            try process.run()
            serverProcessGroupOwned = setpgid(process.processIdentifier, process.processIdentifier) == 0
            serverProcess = process
            persistState()
            lifecycle.markProcessRunning(for: .mcpServer)
            appLog.write("Started owned server pid=\(process.processIdentifier)")
        } catch {
            serverProcessGroupOwned = false
            serverProcess = nil
            lifecycle.recordFailure(
                for: .mcpServer,
                reason: "Could not start Python server: \(error.localizedDescription)"
            )
        }
    }

    private func startTunnel() {
        guard !quitting, !lifecycle.isQuiescing, tunnelDesired,
              lifecycle.snapshot.mcpServer.isReady, tunnelProcess == nil,
              let contract = activeContract else { return }
        let launchGeneration = beginTunnelLaunch()
        lifecycle.markStarting(for: .remoteConnector)
        guard FileManager.default.isExecutableFile(atPath: ngrokBinaryURL.path) else {
            lifecycle.markFailed(
                for: .remoteConnector,
                reason: "Installed ngrok agent is missing. Run the terminal bootstrap again."
            )
            return
        }
        guard FileManager.default.fileExists(atPath: ngrokConfigURL.path) else {
            lifecycle.markFailed(
                for: .remoteConnector,
                reason: "Installed ngrok configuration is missing. Run the terminal bootstrap again."
            )
            return
        }
        guard contract.ngrokAuthtoken != nil else {
            lifecycle.markFailed(
                for: .remoteConnector,
                reason: "ngrok authentication is not configured. Store an authtoken before enabling remote access."
            )
            return
        }
        let launchSpecification: RemoteConnectorLaunchSpecification
        do {
            launchSpecification = try remoteConnectorAdapter.makeLaunchSpecification(
                for: contract.remoteConnectorLaunchInput(
                    executableURL: ngrokBinaryURL,
                    configurationURL: ngrokConfigURL
                )
            )
        } catch {
            lifecycle.markFailed(
                for: .remoteConnector,
                reason: "Remote connector launch inputs are invalid."
            )
            return
        }
        let process = Process()
        process.executableURL = launchSpecification.executableURL
        process.arguments = launchSpecification.arguments
        process.environment = launchSpecification.environment
        attachOutput(
            of: process,
            to: tunnelLog,
            redacting: contract.redactedSecrets
        )
        process.terminationHandler = { [weak self] terminated in
            let processID = ObjectIdentifier(terminated)
            let terminationStatus = terminated.terminationStatus
            Task { @MainActor [weak self, processID, terminationStatus, launchGeneration] in
                guard let self,
                      let process = self.tunnelProcess,
                      ObjectIdentifier(process) == processID,
                      self.tunnelLaunchGeneration == launchGeneration else { return }
                self.tunnelProcess = nil
                self.persistState()
                if !self.quitting && self.tunnelDesired && self.serverDesired {
                    self.lifecycle.recordFailure(
                        for: .remoteConnector,
                        reason: "Remote connector exited with status \(terminationStatus)."
                    )
                } else {
                    self.lifecycle.markStopped(for: .remoteConnector)
                }
            }
        }
        do {
            try process.run()
            tunnelProcessGroupOwned = setpgid(process.processIdentifier, process.processIdentifier) == 0
            tunnelProcess = process
            persistState()
            lifecycle.markProcessRunning(for: .remoteConnector)
            appLog.write("Started owned tunnel pid=\(process.processIdentifier)")
        } catch {
            tunnelProcessGroupOwned = false
            tunnelProcess = nil
            lifecycle.recordFailure(
                for: .remoteConnector,
                reason: "Could not start ngrok: \(error.localizedDescription)"
            )
        }
    }

    private func stopServerProcess() {
        invalidateServerActivation()
        guard let process = serverProcess else {
            lifecycle.markStopped(for: .mcpServer)
            return
        }
        terminateOwned(process, group: serverProcessGroupOwned, label: "server")
        serverProcessGroupOwned = false
        serverProcess = nil
        persistState()
        lifecycle.markStopped(for: .mcpServer)
    }

    private func stopTunnelProcess() {
        invalidateTunnelLaunch()
        guard let process = tunnelProcess else {
            verifiedRemoteOrigin = nil
            lifecycle.markStopped(for: .remoteConnector)
            return
        }
        verifiedRemoteOrigin = nil
        terminateOwned(process, group: tunnelProcessGroupOwned, label: "tunnel")
        tunnelProcessGroupOwned = false
        tunnelProcess = nil
        persistState()
        lifecycle.markStopped(for: .remoteConnector)
    }

    private func terminateOwned(_ process: Process, group: Bool, label: String) {
        let pid = process.processIdentifier
        guard process.isRunning else { return }
        appLog.write("Stopping owned \(label) pid=\(pid)")
        if group {
            _ = kill(-pid, SIGTERM)
        } else {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            appLog.write("Force-stopping unresponsive owned \(label) pid=\(pid)")
            _ = group ? kill(-pid, SIGKILL) : kill(pid, SIGKILL)
        }
    }

    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkHealth()
            }
        }
    }

    private func startNetworkPathMonitoring() {
        networkPathMonitor.start { [weak self] available in
            Task { @MainActor [weak self] in
                self?.handleNetworkAvailabilityChanged(available)
            }
        }
    }

    private func checkHealth() {
        if let process = serverProcess, process.isRunning, let contract = activeContract {
            if self.activationSucceeded {
                checkLightweightHealth(
                    processID: ObjectIdentifier(process),
                    healthURL: contract.healthURL,
                    launchGeneration: serverLaunchGeneration
                )
            } else if !activationInFlight {
                guard let connectorToken = contract.environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"],
                      !connectorToken.isEmpty else {
                    lifecycle.markFailed(
                        for: .mcpServer,
                        reason: "The managed connector token is unavailable; activation is blocked.",
                        liveness: .running
                    )
                    return
                }
                activationInFlight = true
                runActivationProbe(
                    processID: ObjectIdentifier(process),
                    port: contract.port,
                    capabilityToken: connectorToken,
                    launchGeneration: serverLaunchGeneration
                )
            }
        } else if serverDesired && !quitting {
            lifecycle.reconcile()
        }

        if let process = tunnelProcess, process.isRunning {
            queryTunnelURL(
                forceAuthenticatedProbe: lifecycle.snapshot.remoteConnector.lifecycle != .ready
            )
        }
    }

    private func checkLightweightHealth(
        processID: ObjectIdentifier,
        healthURL: URL,
        launchGeneration: UInt64
    ) {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1
        NoRedirectURLSession.make().dataTask(with: request) { [weak self, processID] data, response, _ in
            Task { @MainActor [weak self, processID] in
                guard let self,
                      let current = self.serverProcess,
                      current.isRunning,
                      ObjectIdentifier(current) == processID,
                      self.serverLaunchGeneration == launchGeneration,
                      self.serverDesired,
                      !self.quitting,
                      !self.lifecycle.isQuiescing else { return }
                let expectedBody = Data(#"{"status":"ok"}"#.utf8)
                let isHealthy = (response as? HTTPURLResponse)?.statusCode == 200 &&
                    (response as? HTTPURLResponse)?.url == healthURL &&
                    data == expectedBody
                guard !isHealthy else { return }
                self.activationSucceeded = false
                self.lifecycle.markDegraded(
                    for: .mcpServer,
                    reason: "Server health check failed after activation."
                )
                self.appLog.write("Server health check failed after activation")
            }
        }.resume()
    }

    private func runActivationProbe(
        processID: ObjectIdentifier,
        port: Int,
        capabilityToken: String,
        launchGeneration: UInt64
    ) {
        Task { @MainActor [weak self, processID, launchGeneration] in
            guard let self else { return }
            guard self.isCurrentServerActivation(
                processID: processID,
                launchGeneration: launchGeneration
            ) else { return }
            do {
                try await LocalActivationProbe().run(
                    port: port,
                    capabilityToken: capabilityToken,
                    requiresInteractiveUI: self.activeContract?.capabilitySnapshot.capabilities["mac.ui"]?.desired == true
                )
                guard self.isCurrentServerActivation(
                    processID: processID,
                    launchGeneration: launchGeneration
                ) else { return }
                do {
                    guard self.isCurrentServerActivation(
                        processID: processID,
                        launchGeneration: launchGeneration
                    ) else { return }
                    try await self.runtimeCoordinator.markPhase2Completed()
                } catch {
                    guard self.isCurrentServerActivation(
                        processID: processID,
                        launchGeneration: launchGeneration
                    ) else { return }
                    self.activationInFlight = false
                    self.lifecycle.markDegraded(
                        for: .mcpServer,
                        reason: "Activation succeeded but onboarding state could not be saved: \(error.localizedDescription)"
                    )
                    return
                }
                guard self.isCurrentServerActivation(
                    processID: processID,
                    launchGeneration: launchGeneration
                ) else { return }
                self.activationInFlight = false
                self.activationSucceeded = true
                self.lifecycle.markReady(for: .mcpServer)
                self.appLog.write("Server activation probe passed")
            } catch {
                guard self.isCurrentServerActivation(
                    processID: processID,
                    launchGeneration: launchGeneration
                ) else { return }
                self.activationInFlight = false
                self.lifecycle.markStarting(for: .mcpServer, liveness: .running)
                self.appLog.write("Server activation probe pending: \(error.localizedDescription)")
            }
        }
    }

    private func isCurrentServerActivation(
        processID: ObjectIdentifier,
        launchGeneration: UInt64
    ) -> Bool {
        guard !quitting,
              !lifecycle.isQuiescing,
              serverDesired,
              serverLaunchGeneration == launchGeneration,
              let process = serverProcess,
              process.isRunning,
              ObjectIdentifier(process) == processID else { return false }
        return true
    }

    @discardableResult
    private func beginServerLaunch() -> UInt64 {
        serverLaunchGeneration &+= 1
        activationSucceeded = false
        activationInFlight = false
        return serverLaunchGeneration
    }

    private func invalidateServerActivation() {
        serverLaunchGeneration &+= 1
        activationSucceeded = false
        activationInFlight = false
    }

    @discardableResult
    private func beginTunnelLaunch() -> UInt64 {
        tunnelLaunchGeneration &+= 1
        verifiedRemoteOrigin = nil
        return tunnelLaunchGeneration
    }

    private func invalidateTunnelLaunch() {
        tunnelLaunchGeneration &+= 1
    }

    private func queryTunnelURL(forceAuthenticatedProbe: Bool = true) {
        guard let process = tunnelProcess, process.isRunning,
              let serverProcess, serverProcess.isRunning,
              let contract = activeContract,
              let connectorToken = contract.environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"] else {
            lifecycle.markDegraded(
                for: .remoteConnector,
                reason: "Remote connector identity is unavailable."
            )
            return
        }

        refreshRemoteConnectorIdentity()
        let remoteSnapshot = lifecycle.snapshot.remoteConnector
        let fence = RemoteProbeFence(
            tunnelProcessID: process.processIdentifier,
            serverProcessID: serverProcess.processIdentifier,
            tunnelLaunchGeneration: tunnelLaunchGeneration,
            serverLaunchGeneration: serverLaunchGeneration,
            configurationGeneration: contract.configurationGeneration,
            connectorCredentialGeneration: connectorCredentialGeneration,
            knownPublicOrigin: verifiedRemoteOrigin,
            localMCPGeneration: lifecycle.snapshot.mcpServer.generation,
            localMCPReady: lifecycle.snapshot.mcpServer.isReady,
            remoteDesired: remoteSnapshot.desired == .enabled,
            serverDesired: lifecycle.snapshot.mcpServer.desired == .enabled,
            maintenance: lifecycle.isQuiescing,
            quitting: quitting
        )
        let request = RemoteProbeRequest(
            tunnelTarget: contract.tunnelTarget,
            connectorToken: connectorToken,
            expectedTools: CurrentCoreMCPExpectationProvider()
                .expectations(for: contract.configuration)
                .expectedTools,
            knownPublicOrigin: verifiedRemoteOrigin,
            forceAuthenticatedProbe: forceAuthenticatedProbe
        )

        Task { @MainActor [weak self, fence] in
            guard let self else { return }
            let result = await self.remoteProbeCoordinator.run(request)
            guard self.isCurrentRemoteProbe(fence) else { return }
            switch result {
            case .busy:
                return
            case let .unchanged(publicOrigin):
                self.verifiedRemoteOrigin = publicOrigin
            case let .authenticated(publicOrigin, _):
                do {
                    try self.persistRemoteProbeSuccess(publicOrigin)
                } catch {
                    self.verifiedRemoteOrigin = nil
                    self.lifecycle.markDegraded(
                        for: .remoteConnector,
                        reason: "Remote readiness was authenticated but could not be recorded safely."
                    )
                    return
                }
                self.verifiedRemoteOrigin = publicOrigin
                self.lifecycle.markReady(for: .remoteConnector)
            case let .failed(failure):
                self.verifiedRemoteOrigin = nil
                self.persistRemoteProbeFailure()
                self.lifecycle.markDegraded(
                    for: .remoteConnector,
                    reason: failure.localizedDescription
                )
            }
        }
    }

    private func isCurrentRemoteProbe(_ fence: RemoteProbeFence) -> Bool {
        guard !quitting,
              !lifecycle.isQuiescing,
              fence.quitting == false,
              fence.maintenance == false,
              tunnelDesired,
              serverDesired,
              fence.remoteDesired,
              fence.serverDesired,
              let tunnelProcess,
              tunnelProcess.isRunning,
              tunnelProcess.processIdentifier == fence.tunnelProcessID,
              let serverProcess,
              serverProcess.isRunning,
              serverProcess.processIdentifier == fence.serverProcessID,
              tunnelLaunchGeneration == fence.tunnelLaunchGeneration,
              serverLaunchGeneration == fence.serverLaunchGeneration,
              activeContract?.configurationGeneration == fence.configurationGeneration,
              connectorCredentialGeneration == fence.connectorCredentialGeneration,
              verifiedRemoteOrigin == fence.knownPublicOrigin,
              lifecycle.snapshot.mcpServer.generation == fence.localMCPGeneration,
              lifecycle.snapshot.mcpServer.isReady == fence.localMCPReady,
              lifecycle.snapshot.mcpServer.isReady,
              lifecycle.snapshot.remoteConnector.desired == .enabled else {
            return false
        }
        let current = RemoteProbeFence(
            tunnelProcessID: tunnelProcess.processIdentifier,
            serverProcessID: serverProcess.processIdentifier,
            tunnelLaunchGeneration: tunnelLaunchGeneration,
            serverLaunchGeneration: serverLaunchGeneration,
            configurationGeneration: activeContract?.configurationGeneration ?? 0,
            connectorCredentialGeneration: connectorCredentialGeneration,
            knownPublicOrigin: verifiedRemoteOrigin,
            localMCPGeneration: lifecycle.snapshot.mcpServer.generation,
            localMCPReady: lifecycle.snapshot.mcpServer.isReady,
            remoteDesired: lifecycle.snapshot.remoteConnector.desired == .enabled,
            serverDesired: lifecycle.snapshot.mcpServer.desired == .enabled,
            maintenance: lifecycle.isQuiescing,
            quitting: quitting
        )
        return fence.matches(current)
    }

    private func refreshRemoteConnectorIdentity() {
        do {
            guard let state = try remoteConnectorStateStore.load() else {
                connectorCredentialGeneration = 0
                verifiedRemoteOrigin = nil
                return
            }
            connectorCredentialGeneration = state.connectorCredentialGeneration
            verifiedRemoteOrigin = state.lastRemoteResult == .ready
                ? state.lastVerifiedPublicOrigin
                : nil
        } catch {
            connectorCredentialGeneration = 0
            verifiedRemoteOrigin = nil
        }
    }

    private func persistRemoteProbeSuccess(_ origin: RemotePublicOrigin) throws {
        var state = try remoteConnectorStateStore.loadOrCreate(provider: .ngrok)
        state.lastVerifiedPublicOrigin = origin
        state.lastSuccessfulRemoteProbeAt = Date()
        state.lastRemoteResult = .ready
        if state.pendingConnectorCredentialGeneration == nil {
            state.recoveryPhase = .stable
        }
        let saved = try remoteConnectorStateStore.save(state)
        connectorCredentialGeneration = saved.connectorCredentialGeneration
    }

    private func persistRemoteProbeFailure() {
        do {
            var state = try remoteConnectorStateStore.loadOrCreate(provider: .ngrok)
            state.lastVerifiedPublicOrigin = nil
            state.lastSuccessfulRemoteProbeAt = nil
            state.lastRemoteResult = .degraded
            state.recoveryPhase = state.pendingConnectorCredentialGeneration == nil
                ? .degraded
                : .cutoverPendingValidation
            let saved = try remoteConnectorStateStore.save(state)
            connectorCredentialGeneration = saved.connectorCredentialGeneration
        } catch {
            // The lifecycle remains degraded even when the optional diagnostic
            // state cannot be updated.
        }
    }

    private func fail(_ message: String) {
        snapshot.error = message
        appLog.write("ERROR: \(message)")
    }

    private func attachOutput(
        of process: Process,
        to log: RotatingLog,
        redacting secrets: [String] = [],
        dropping fragments: [String] = []
    ) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let redactor = LockedStreamingLogRedactor(secrets: secrets)
        let writeSafeLine: @Sendable (String) -> Void = { line in
            guard !line.isEmpty else { return }
            guard !fragments.contains(where: line.contains) else { return }
            log.write(line)
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                redactor.append("", flush: true).forEach(writeSafeLine)
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            redactor.append(text, flush: false).forEach(writeSafeLine)
        }
    }
    private func portIsOccupied(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // If ownership cannot be checked, fail closed rather than
            // claiming that another process is not listening.
            return true
        }
    }

    private func persistState() {
        let state = OwnedProcessState(
            ownerID: ownerID,
            serverPID: serverProcess?.processIdentifier,
            tunnelPID: tunnelProcess?.processIdentifier
        )
        if state.serverPID == nil && state.tunnelPID == nil {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }
    }

    private func cleanStaleOwnedProcesses() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(OwnedProcessState.self, from: data),
              state.ownerID == ownerID else {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        if let pid = state.tunnelPID {
            terminateRecordedPID(pid, component: .tunnel, label: "stale tunnel")
        }
        if let pid = state.serverPID {
            terminateRecordedPID(pid, component: .server, label: "stale server")
        }
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func terminateRecordedPID(
        _ pid: Int32,
        component: SupervisorComponent,
        label: String
    ) {
        let pidExists = kill(pid, 0) == 0
        let observedCommandLine = pidExists ? commandLine(for: pid) : ""
        guard ProcessOwnership.authorizesTermination(
            pidExists: pidExists,
            commandLine: observedCommandLine,
            component: component,
            ownerID: ownerID
        ) else { return }
        appLog.write("Cleaning \(label) pid=\(pid)")
        let ownsProcessGroup = getpgid(pid) == pid
        _ = ownsProcessGroup ? kill(-pid, SIGTERM) : kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(pid, 0) == 0 {
            _ = ownsProcessGroup ? kill(-pid, SIGKILL) : kill(pid, SIGKILL)
        }
    }

    private func commandLine(for pid: Int32) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
