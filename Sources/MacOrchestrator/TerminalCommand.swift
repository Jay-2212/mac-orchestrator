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

enum TerminalCommand {
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
              --print-connector-url      Print the current live HTTPS connector URL.
              --wait-for-local-activation Wait for the authenticated local MCP activation oracle.
              --print-local-connector-url Confirm activation and print the local MCP URL.
              --wait-for-remote-connector Wait for and print a confirmed live HTTPS connector URL.
            """
        )
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
        print(try currentConnectorURL().absoluteString)
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
                print("Local activation confirmed.")
                print(
                    "Local MCP URL: http://127.0.0.1:\(configuration.localMCPPort)/\(connectorToken)/mcp"
                )
                printClientHandoff()
                printPermissionGuidance(configuration: configuration)
                return
            } catch {
                lastError = error.localizedDescription
                Thread.sleep(forTimeInterval: 1)
            }
        }

        print("Local connection is not ready; the previous installation remains in place.")
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
        print("Paste the full URL into your MCP client's HTTP or Streamable HTTP URL field.")
        print("Treat the connector URL like a password and do not share it.")
    }

    private static func waitForRemoteConnector() throws {
        let deadline = Date().addingTimeInterval(90)
        var lastError = "no confirmed HTTPS endpoint was available"
        while Date() < deadline {
            do {
                let url = try currentConnectorURL()
                print("Remote connector confirmed.")
                print(url.absoluteString)
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
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                resultLock.lock()
                result = .failure(error)
                resultLock.unlock()
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
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
        _ = try restartRunningSupervisorIfLoaded()
        try waitForRemoteConnectorToDisappear()

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
