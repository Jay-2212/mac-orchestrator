import AppKit
import Foundation
import Darwin

@MainActor
final class ProcessSupervisor {
    var onSnapshot: ((ServiceSnapshot) -> Void)?

    private(set) var snapshot = ServiceSnapshot() {
        didSet { onSnapshot?(snapshot) }
    }

    private let defaults = UserDefaults.standard
    private let supportDirectory: URL
    let logsDirectory: URL
    private let runtimeDirectory: URL
    private let stateURL: URL
    private let ownerID: String
    private let connectorToken: String
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

    private var serverDesired: Bool {
        get { defaults.object(forKey: "serverDesired") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "serverDesired") }
    }

    private var tunnelDesired: Bool {
        get { defaults.bool(forKey: "tunnelDesired") }
        set { defaults.set(newValue, forKey: "tunnelDesired") }
    }

    init() throws {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        supportDirectory = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Mac Orchestrator", isDirectory: true)
        logsDirectory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Mac Orchestrator", isDirectory: true)
        runtimeDirectory = supportDirectory.appendingPathComponent("runtime", isDirectory: true)
        stateURL = supportDirectory.appendingPathComponent("owned-processes.json")
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if let existing = defaults.string(forKey: "ownerID") {
            ownerID = existing
        } else {
            ownerID = UUID().uuidString.lowercased()
            defaults.set(ownerID, forKey: "ownerID")
        }
        connectorToken = try KeychainStore.connectorToken()
        appLog = RotatingLog(directory: logsDirectory, name: "app.log")
        serverLog = RotatingLog(directory: logsDirectory, name: "server.log")
        tunnelLog = RotatingLog(directory: logsDirectory, name: "tunnel.log")
        serverLog.redact([connectorToken])
    }

    func launch() {
        appLog.write("Supervisor launched")
        cleanStaleOwnedProcesses()
        startHealthTimer()
        if serverDesired {
            startServer()
        }
    }

    func startServerRequested() {
        serverDesired = true
        restartWorkItem?.cancel()
        serverFailures.removeAll()
        serverRetryNotBefore = .distantPast
        startServer()
    }

    func stopServerRequested() {
        serverDesired = false
        tunnelDesired = false
        stopTunnel()
        stopServer()
    }

    func enableConnectorRequested() {
        tunnelDesired = true
        tunnelFailures.removeAll()
        tunnelRetryNotBefore = .distantPast
        if serverProcess == nil {
            serverDesired = true
            startServer()
        } else if snapshot.server == .running {
            startTunnel()
        }
    }

    func disableConnectorRequested() {
        tunnelDesired = false
        stopTunnel()
    }

    func restartRequested() {
        let restoreServer = serverDesired
        let restoreTunnel = tunnelDesired
        restartWorkItem?.cancel()
        stopTunnel()
        stopServer()
        serverDesired = restoreServer
        tunnelDesired = restoreTunnel
        serverFailures.removeAll()
        tunnelFailures.removeAll()
        serverRetryNotBefore = .distantPast
        tunnelRetryNotBefore = .distantPast
        if restoreServer { startServer() }
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
        checkHealth()
    }

    func openLogs() {
        NSWorkspace.shared.open(logsDirectory)
    }

    private func startServer() {
        guard !quitting, serverDesired, serverProcess == nil,
              Date() >= serverRetryNotBefore else { return }
        let python = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        let script = runtimeDirectory.appendingPathComponent("automac_mcp.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            fail("Installed Python runtime is missing. Run script/distribute.sh.")
            return
        }
        if portIsOccupied(8000) {
            fail("Port 8000 is already used by another process. Mac Orchestrator did not terminate it.")
            scheduleRestart(component: "server", status: EADDRINUSE)
            return
        }

        snapshot.server = .starting
        snapshot.error = nil
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--managed-owner", ownerID]
        var environment = ProcessInfo.processInfo.environment
        environment["MAC_ORCHESTRATOR_MANAGED"] = "1"
        environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"] = connectorToken
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.currentDirectoryURL = runtimeDirectory
        attachOutput(
            of: process,
            to: serverLog,
            redacting: [connectorToken],
            dropping: ["GET /__mac_orchestrator_health "]
        )
        process.terminationHandler = { [weak self, weak process] terminated in
            DispatchQueue.main.async {
                guard let self, let process, self.serverProcess === process else { return }
                self.serverProcess = nil
                self.persistState()
                self.snapshot.server = self.serverDesired ? .failed : .stopped
                self.stopTunnel()
                if !self.quitting && self.serverDesired {
                    self.scheduleRestart(component: "server", status: terminated.terminationStatus)
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
              Date() >= tunnelRetryNotBefore else { return }
        guard let ngrok = Bundle.main.url(forResource: "ngrok", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: ngrok.path) else {
            fail("Bundled ngrok agent is missing. Reinstall Mac Orchestrator.")
            return
        }
        snapshot.tunnel = .starting
        snapshot.connectorURL = nil
        let process = Process()
        process.executableURL = ngrok
        process.arguments = [
            "http", "http://127.0.0.1:8000",
            "--log", "stdout",
            "--log-format", "json",
            "--log-level", "info",
            "--inspect=true",
            "--metadata", "mac-orchestrator-owner=\(ownerID)",
        ]
        attachOutput(of: process, to: tunnelLog)
        process.terminationHandler = { [weak self, weak process] terminated in
            DispatchQueue.main.async {
                guard let self, let process, self.tunnelProcess === process else { return }
                self.tunnelProcess = nil
                self.persistState()
                self.snapshot.connectorURL = nil
                self.snapshot.tunnel = self.tunnelDesired ? .failed : .stopped
                if !self.quitting && self.tunnelDesired && self.serverDesired {
                    self.scheduleRestart(component: "tunnel", status: terminated.terminationStatus)
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
            Task { @MainActor in
                self?.checkHealth()
            }
        }
    }

    private func checkHealth() {
        if let process = serverProcess, process.isRunning {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/__mac_orchestrator_health")!)
            request.timeoutInterval = 1
            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                DispatchQueue.main.async {
                    guard let self, let current = self.serverProcess, current === process else { return }
                    if response != nil {
                        if self.snapshot.server != .running {
                            self.snapshot.server = .running
                            self.serverRetryNotBefore = .distantPast
                            self.appLog.write("Server health check passed")
                        }
                        if self.tunnelDesired { self.startTunnel() }
                    } else if self.snapshot.server == .running {
                        self.snapshot.server = .starting
                    }
                }
            }.resume()
        } else if serverDesired && !quitting {
            startServer()
        }

        if let process = tunnelProcess, process.isRunning {
            queryTunnelURL()
        }
    }

    private func queryTunnelURL() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4040/api/tunnels")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self, let process = self.tunnelProcess, process.isRunning,
                      let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tunnels = object["tunnels"] as? [[String: Any]],
                      let ownedTunnel = tunnels.first(where: {
                          guard let config = $0["config"] as? [String: Any],
                                let address = config["addr"] as? String else { return false }
                          return address == "http://127.0.0.1:8000" ||
                                 address == "http://localhost:8000"
                      }),
                      let publicURL = ownedTunnel["public_url"] as? String,
                      publicURL.hasPrefix("https://"),
                      let base = URL(string: publicURL) else { return }
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                components.path = "/\(self.connectorToken)/mcp"
                self.snapshot.connectorURL = components.url
                self.snapshot.tunnel = .running
                self.snapshot.error = nil
                self.tunnelRetryNotBefore = .distantPast
            }
        }.resume()
    }

    private func scheduleRestart(component: String, status: Int32) {
        let now = Date()
        if component == "server" {
            serverFailures = serverFailures.filter { now.timeIntervalSince($0) < 120 }
            serverFailures.append(now)
            if serverFailures.count > 5 {
                serverRetryNotBefore = .distantFuture
                fail("Server stopped repeatedly (last exit \(status)). Use Restart after checking logs.")
                return
            }
        } else {
            tunnelFailures = tunnelFailures.filter { now.timeIntervalSince($0) < 120 }
            tunnelFailures.append(now)
            if tunnelFailures.count > 5 {
                tunnelRetryNotBefore = .distantFuture
                fail("Tunnel stopped repeatedly (last exit \(status)). Check ngrok credentials and logs.")
                return
            }
        }
        let attempts = component == "server" ? serverFailures.count : tunnelFailures.count
        let delay = min(pow(2.0, Double(max(0, attempts - 1))), 30)
        if component == "server" {
            serverRetryNotBefore = now.addingTimeInterval(delay)
        } else {
            tunnelRetryNotBefore = now.addingTimeInterval(delay)
        }
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
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                var safeLine = String(line)
                if fragments.contains(where: safeLine.contains) { continue }
                for secret in secrets where !secret.isEmpty {
                    safeLine = safeLine.replacingOccurrences(of: secret, with: "<redacted>")
                }
                log.write(safeLine)
            }
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
            return false
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
            terminateRecordedPID(pid, marker: "mac-orchestrator-owner=\(ownerID)", label: "stale tunnel")
        }
        if let pid = state.serverPID {
            terminateRecordedPID(pid, marker: "--managed-owner \(ownerID)", label: "stale server")
        }
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func terminateRecordedPID(_ pid: Int32, marker: String, label: String) {
        guard kill(pid, 0) == 0, commandLine(for: pid).contains(marker) else { return }
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
