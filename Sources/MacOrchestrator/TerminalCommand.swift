import Darwin
import Foundation
import Security

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
                print("Remote connector enabled; it will start after local activation succeeds.")
                return 0
            case "--disable-remote":
                _ = try ConfigurationStore().update { configuration in
                    configuration.process.tunnelDesired = false
                    configuration.desiredCapabilities["remote.connector"] = false
                }
                print("Remote connector disabled.")
                return 0
            case "--print-connector-url":
                try printConnectorURL()
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
            """
        )
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
        let configuration = try ConfigurationStore().load()
        let connectorToken = try KeychainStore().connectorTokenValue()
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
        print(connectorURL.absoluteString)
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
