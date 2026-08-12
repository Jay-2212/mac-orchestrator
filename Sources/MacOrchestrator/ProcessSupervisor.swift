import AppKit
import Foundation
import Darwin

@MainActor
final class ProcessSupervisor {
    var onSnapshot: ((ServiceSnapshot) -> Void)?

    private(set) var snapshot = ServiceSnapshot() {
        didSet { onSnapshot?(snapshot) }
    }

    private let runtimeCoordinator: NativeRuntimeCoordinator
    private let supportDirectory: URL
    let logsDirectory: URL
    private let runtimeDirectory: URL
    private let stateURL: URL
    private let appLog: RotatingLog
    private let serverLog: RotatingLog
    private let tunnelLog: RotatingLog

    private var serverProcess: Process?
    private var tunnelProcess: Process?
    private var healthTimer: Timer?
    private var restartWorkItem: DispatchWorkItem?
    private var serverFailures: [Date] = []
    private var tunnelFailures: [Date] = []
    private var serverRetryNotBefore = Date.distantPast
    private var tunnelRetryNotBefore = Date.distantPast
    private var quitting = false
    private var activeContract: ManagedRuntimeLaunchContract?
    private var ownerID = ""
    private var serverDesired = false
    private var tunnelDesired = false
    private var activationSucceeded = false
    private var activationInFlight = false

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
    }

    func launch(with contract: ManagedRuntimeLaunchContract) {
        activationSucceeded = false
        activationInFlight = false
        install(contract, requiresClientRefresh: false)
        appLog.write("Supervisor launched")
        cleanStaleOwnedProcesses()
        startHealthTimer()
        if serverDesired {
            startServer()
        }
    }

    func reportStartupFailure(_ error: Error) {
        snapshot.server = .failed
        fail("Configuration startup failed: \(error.localizedDescription)")
    }

    func startServerRequested() {
        Task { @MainActor [weak self] in
            await self?.updateConfiguration { configuration in
                configuration.process.serverDesired = true
            }
        }
    }

    func stopServerRequested() {
        serverDesired = false
        tunnelDesired = false
        stopTunnel()
        stopServer()
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
        tunnelDesired = false
        stopTunnel()
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
        restartWorkItem?.cancel()
        healthTimer?.invalidate()
        stopTunnel()
        stopServer()
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
            self.checkHealth()
        }
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
            if serverDesired { startServer() }
            return
        }

        let transition = ManagedRuntimeTransition.between(
            current: current,
            replacement: replacement
        )
        if forceRestart || transition.requiresRestart {
            restartWorkItem?.cancel()
            stopTunnel()
            stopServer()
            install(
                replacement,
                requiresClientRefresh: transition.requiresClientRefresh
            )
            activationSucceeded = false
            activationInFlight = false
            serverFailures.removeAll()
            tunnelFailures.removeAll()
            serverRetryNotBefore = .distantPast
            tunnelRetryNotBefore = .distantPast
            if serverDesired { startServer() }
            return
        }

        install(replacement, requiresClientRefresh: false)
        if !serverDesired {
            stopTunnel()
            stopServer()
        } else if serverProcess == nil {
            startServer()
        }
        if !tunnelDesired {
            stopTunnel()
        } else if snapshot.server == .running {
            startTunnel()
        }
    }

    private func install(
        _ contract: ManagedRuntimeLaunchContract,
        requiresClientRefresh: Bool
    ) {
        activeContract = contract
        ownerID = contract.configuration.ownerID
        serverDesired = contract.configuration.process.serverDesired
        tunnelDesired = contract.configuration.process.tunnelDesired
        snapshot.applyRuntimeContract(
            contract,
            requiresClientRefresh: requiresClientRefresh
        )
        snapshot.error = nil
        appLog.redact(contract.redactedSecrets)
        serverLog.redact(contract.redactedSecrets)
        tunnelLog.redact(contract.redactedSecrets)
    }

    private func startServer() {
        guard !quitting, serverDesired, serverProcess == nil,
              Date() >= serverRetryNotBefore,
              let contract = activeContract else { return }
        let python = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        let script = runtimeDirectory.appendingPathComponent("automac_mcp.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            fail("Installed Python runtime is missing. Run the terminal bootstrap again.")
            return
        }
        if portIsOccupied(contract.port) {
            fail("Port \(contract.port) is already used by another process. Mac Orchestrator did not terminate it.")
            scheduleRestart(component: "server", status: EADDRINUSE)
            return
        }

        snapshot.server = .starting
        snapshot.error = nil
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
                self.serverProcess = nil
                self.persistState()
                self.snapshot.server = self.serverDesired ? .failed : .stopped
                self.stopTunnel()
                if !self.quitting && self.serverDesired {
                    self.scheduleRestart(component: "server", status: terminationStatus)
                }
            }
        }
        do {
            try process.run()
            serverProcess = process
            persistState()
            appLog.write("Started owned server pid=\(process.processIdentifier)")
        } catch {
            serverProcess = nil
            fail("Could not start Python server: \(error.localizedDescription)")
            scheduleRestart(component: "server", status: -1)
        }
    }

    private func startTunnel() {
        guard !quitting, tunnelDesired, snapshot.server == .running, tunnelProcess == nil,
              Date() >= tunnelRetryNotBefore,
              let contract = activeContract else { return }
        guard FileManager.default.isExecutableFile(atPath: ngrokBinaryURL.path) else {
            fail("Installed ngrok agent is missing. Run the terminal bootstrap again.")
            return
        }
        guard FileManager.default.fileExists(atPath: ngrokConfigURL.path) else {
            fail("Installed ngrok configuration is missing. Run the terminal bootstrap again.")
            return
        }
        guard contract.ngrokAuthtoken != nil else {
            fail("ngrok authentication is not configured. Store an authtoken before enabling remote access.")
            return
        }
        snapshot.tunnel = .starting
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
            Task { @MainActor [weak self, processID, terminationStatus] in
                guard let self,
                      let process = self.tunnelProcess,
                      ObjectIdentifier(process) == processID else { return }
                self.tunnelProcess = nil
                self.persistState()
                self.snapshot.connectorURL = nil
                self.snapshot.tunnel = self.tunnelDesired ? .failed : .stopped
                if !self.quitting && self.tunnelDesired && self.serverDesired {
                    self.scheduleRestart(component: "tunnel", status: terminationStatus)
                }
            }
        }
        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            tunnelProcess = process
            persistState()
            appLog.write("Started owned tunnel pid=\(process.processIdentifier)")
        } catch {
            tunnelProcess = nil
            fail("Could not start ngrok: \(error.localizedDescription)")
            scheduleRestart(component: "tunnel", status: -1)
        }
    }

    private func stopServer() {
        restartWorkItem?.cancel()
        activationSucceeded = false
        activationInFlight = false
        guard let process = serverProcess else {
            snapshot.server = .stopped
            return
        }
        snapshot.server = .stopping
        terminateOwned(process, group: true, label: "server")
        serverProcess = nil
        persistState()
        snapshot.server = .stopped
    }

    private func stopTunnel() {
        guard let process = tunnelProcess else {
            snapshot.tunnel = .stopped
            snapshot.connectorURL = nil
            return
        }
        snapshot.tunnel = .stopping
        snapshot.connectorURL = nil
        terminateOwned(process, group: true, label: "tunnel")
        tunnelProcess = nil
        persistState()
        snapshot.tunnel = .stopped
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
                    healthURL: contract.healthURL
                )
                if snapshot.server != .running {
                    snapshot.server = .running
                    serverRetryNotBefore = .distantPast
                }
                if tunnelDesired { startTunnel() }
            } else if !activationInFlight {
                guard let connectorToken = contract.environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"],
                      !connectorToken.isEmpty else {
                    fail("The managed connector token is unavailable; activation is blocked.")
                    return
                }
                activationInFlight = true
                runActivationProbe(
                    processID: ObjectIdentifier(process),
                    port: contract.port,
                    capabilityToken: connectorToken
                )
            }
        } else if serverDesired && !quitting {
            startServer()
        }

        if let process = tunnelProcess, process.isRunning {
            queryTunnelURL()
        }
    }

    private func checkLightweightHealth(processID: ObjectIdentifier, healthURL: URL) {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1
        NoRedirectURLSession.make().dataTask(with: request) { [weak self, processID] data, response, _ in
            Task { @MainActor [weak self, processID] in
                guard let self,
                      let current = self.serverProcess,
                      ObjectIdentifier(current) == processID else { return }
                let expectedBody = Data(#"{"status":"ok"}"#.utf8)
                let isHealthy = (response as? HTTPURLResponse)?.statusCode == 200 &&
                    (response as? HTTPURLResponse)?.url == healthURL &&
                    data == expectedBody
                guard !isHealthy else { return }
                self.activationSucceeded = false
                self.snapshot.server = .starting
                self.stopTunnel()
                self.appLog.write("Server health check failed after activation")
            }
        }.resume()
    }

    private func runActivationProbe(
        processID: ObjectIdentifier,
        port: Int,
        capabilityToken: String
    ) {
        Task { @MainActor [weak self, processID] in
            guard let self else { return }
            do {
                try await LocalActivationProbe().run(
                    port: port,
                    capabilityToken: capabilityToken,
                    requiresInteractiveUI: self.activeContract?.capabilitySnapshot.capabilities["mac.ui"]?.desired == true
                )
                guard let process = self.serverProcess,
                      process.isRunning,
                      ObjectIdentifier(process) == processID else {
                    self.activationInFlight = false
                    return
                }
                do {
                    try await self.runtimeCoordinator.markPhase2Completed()
                } catch {
                    self.activationInFlight = false
                    self.fail("Activation succeeded but onboarding state could not be saved: \(error.localizedDescription)")
                    return
                }
                self.activationInFlight = false
                self.activationSucceeded = true
                self.snapshot.server = .running
                self.snapshot.error = nil
                self.serverRetryNotBefore = .distantPast
                self.appLog.write("Server activation probe passed")
                if self.tunnelDesired { self.startTunnel() }
            } catch {
                self.activationInFlight = false
                guard let process = self.serverProcess,
                      process.isRunning,
                      ObjectIdentifier(process) == processID else { return }
                self.snapshot.server = .starting
                self.appLog.write("Server activation probe pending: \(error.localizedDescription)")
            }
        }
    }

    private func queryTunnelURL() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4040/api/endpoints")!)
        request.timeoutInterval = 1
        guard let process = tunnelProcess, process.isRunning else { return }
        guard let contract = activeContract,
              let connectorToken = contract.environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"] else {
            snapshot.connectorURL = nil
            snapshot.tunnel = .reconnecting
            snapshot.error = "Remote connector identity is unavailable."
            return
        }
        let processID = ObjectIdentifier(process)
        NoRedirectURLSession.make().dataTask(with: request) { [weak self, processID] data, response, _ in
            Task { @MainActor [weak self, processID] in
                guard let self, let process = self.tunnelProcess, process.isRunning,
                      ObjectIdentifier(process) == processID else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (response as? HTTPURLResponse)?.url == request.url,
                      let data,
                      let base = NgrokEndpointParser.publicURL(
                          from: data,
                          matching: contract.tunnelTarget
                      ) else {
                    // A previously observed public URL is never current
                    // evidence. Clear it until the owned tunnel is confirmed
                    // again by the Agent API.
                    self.snapshot.connectorURL = nil
                    self.snapshot.tunnel = .reconnecting
                    self.snapshot.error = "Remote connector endpoint is not currently confirmed."
                    return
                }
                self.snapshot.connectorURL = ConnectorURLBuilder.make(
                    publicURL: base.absoluteString,
                    capabilityToken: connectorToken
                )
                self.snapshot.tunnel = .running
                self.snapshot.error = nil
                self.tunnelRetryNotBefore = .distantPast
            }
        }.resume()
    }

    private func scheduleRestart(component: String, status: Int32) {
        let now = Date()
        let supervisorComponent: SupervisorComponent = component == "server" ? .server : .tunnel
        let existingFailures = supervisorComponent == .server ? serverFailures : tunnelFailures
        let decision = SupervisorRetryPolicy.decision(failures: existingFailures, now: now)

        switch (supervisorComponent, decision) {
        case let (.server, .circuitOpen(failures)):
            serverFailures = failures
            serverRetryNotBefore = .distantFuture
            fail("Server stopped repeatedly (last exit \(status)). Use Restart after checking logs.")
            return
        case let (.tunnel, .circuitOpen(failures)):
            tunnelFailures = failures
            tunnelRetryNotBefore = .distantFuture
            fail("Tunnel stopped repeatedly (last exit \(status)). Check ngrok credentials and logs.")
            return
        case let (.server, .retry(failures, delay)):
            serverFailures = failures
            serverRetryNotBefore = now.addingTimeInterval(delay)
        case let (.tunnel, .retry(failures, delay)):
            tunnelFailures = failures
            tunnelRetryNotBefore = now.addingTimeInterval(delay)
        }

        guard case let .retry(_, delay) = decision else { return }
        appLog.write("\(component) exited status=\(status); restart in \(Int(delay))s")
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.quitting else { return }
            component == "server" ? self.startServer() : self.startTunnel()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
        guard kill(pid, 0) == 0,
              ProcessOwnership.matches(
                  commandLine: commandLine(for: pid),
                  component: component,
                  ownerID: ownerID
              ) else { return }
        appLog.write("Cleaning \(label) pid=\(pid)")
        _ = kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(pid, 0) == 0 { _ = kill(-pid, SIGKILL) }
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
