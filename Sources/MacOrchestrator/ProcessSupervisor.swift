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

    init(runtimeCoordinator: NativeRuntimeCoordinator) throws {
        self.runtimeCoordinator = runtimeCoordinator
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
        lifecycle = LifecycleStateMachine(scheduler: lifecycleScheduler)
        lifecycle.onSnapshot = { [weak self] lifecycleSnapshot in
            self?.applyLifecycleSnapshot(lifecycleSnapshot)
        }
        lifecycle.onEffect = { [weak self] effect in
            self?.handleLifecycleEffect(effect)
        }
    }

    func launch(with contract: ManagedRuntimeLaunchContract) {
        activationSucceeded = false
        activationInFlight = false
        install(contract, requiresClientRefresh: false)
        appLog.write("Supervisor launched")
        cleanStaleOwnedProcesses()
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
        healthTimer?.invalidate()
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
            self.checkHealth()
        }
    }

    func handleNetworkAvailabilityChanged(_ available: Bool) {
        lifecycle.handleNetworkAvailabilityChanged(available)
    }

    func prepareForMaintenance() {
        lifecycle.prepareForMaintenance()
    }

    func retry(component: ManagedComponentID) {
        if component == .mcpServer {
            invalidateServerActivation()
        } else {
            snapshot.connectorURL = nil
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
    }

    private func applyLifecycleSnapshot(_ lifecycleSnapshot: LifecycleSnapshot) {
        var projection = snapshot.projected(from: lifecycleSnapshot)
        if lifecycleSnapshot.remoteConnector.lifecycle != .ready {
            projection.connectorURL = nil
        }
        snapshot = projection
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
            queryTunnelURL()
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
        snapshot.connectorURL = nil
        let process = Process()
        process.executableURL = ngrokBinaryURL
        process.arguments = [
            "http", contract.tunnelTarget,
            "--config", ngrokConfigURL.path,
            "--log", "stdout",
            "--log-format", "json",
            "--log-level", "info",
            "--inspect=true",
            "--metadata", "mac-orchestrator-owner=\(ownerID)",
        ]
        process.environment = contract.ngrokEnvironment()
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
                self.snapshot.connectorURL = nil
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
            snapshot.connectorURL = nil
            lifecycle.markStopped(for: .remoteConnector)
            return
        }
        snapshot.connectorURL = nil
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
            queryTunnelURL()
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
        return tunnelLaunchGeneration
    }

    private func invalidateTunnelLaunch() {
        tunnelLaunchGeneration &+= 1
    }

    private func queryTunnelURL() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4040/api/endpoints")!)
        request.timeoutInterval = 1
        guard let process = tunnelProcess, process.isRunning else { return }
        guard let contract = activeContract,
              let connectorToken = contract.environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"] else {
            snapshot.connectorURL = nil
            lifecycle.markDegraded(
                for: .remoteConnector,
                reason: "Remote connector identity is unavailable."
            )
            return
        }
        let processID = ObjectIdentifier(process)
        let launchGeneration = tunnelLaunchGeneration
        let expectedTunnelTarget = contract.tunnelTarget
        let expectedConnectorToken = connectorToken
        NoRedirectURLSession.make().dataTask(with: request) { [weak self, processID, launchGeneration, expectedTunnelTarget, expectedConnectorToken] data, response, _ in
            Task { @MainActor [weak self, processID, launchGeneration, expectedTunnelTarget, expectedConnectorToken] in
                guard let self, let process = self.tunnelProcess, process.isRunning,
                      ObjectIdentifier(process) == processID,
                      self.tunnelLaunchGeneration == launchGeneration,
                      self.tunnelDesired,
                      self.serverDesired,
                      !self.quitting,
                      !self.lifecycle.isQuiescing,
                      self.lifecycle.snapshot.mcpServer.isReady,
                      self.activeContract?.tunnelTarget == expectedTunnelTarget,
                      self.activeContract?.environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"] == expectedConnectorToken else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (response as? HTTPURLResponse)?.url == request.url,
                      let data,
                      let base = NgrokEndpointParser.publicURL(
                          from: data,
                          matching: expectedTunnelTarget
                      ) else {
                    // A previously observed public URL is never current
                    // evidence. Clear it until the owned tunnel is confirmed
                    // again by the Agent API.
                    self.snapshot.connectorURL = nil
                    self.lifecycle.markDegraded(
                        for: .remoteConnector,
                        reason: "Remote connector endpoint is not currently confirmed."
                    )
                    return
                }
                self.snapshot.connectorURL = ConnectorURLBuilder.make(
                    publicURL: base.absoluteString,
                    capabilityToken: connectorToken
                )
                self.lifecycle.markReady(for: .remoteConnector)
            }
        }.resume()
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
