import ApplicationServices
import CoreGraphics
import Foundation

protocol CapabilityPermissionChecking {
    func accessibilityIsGranted() -> Bool
    func screenRecordingIsGranted() -> Bool
}

struct ManagedPermissionProbeFacts: Equatable, Sendable {
    let accessibility: Bool
    let screenRecording: Bool
    let automation: Bool
    let activeConsole: Bool
    let unlocked: Bool

    init(
        accessibility: Bool,
        screenRecording: Bool,
        automation: Bool = true,
        activeConsole: Bool = true,
        unlocked: Bool = true
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.automation = automation
        self.activeConsole = activeConsole
        self.unlocked = unlocked
    }
}

protocol ManagedPermissionChecking {
    func probe(runtimeDirectory: URL) -> ManagedPermissionProbeFacts?
}

struct SystemCapabilityPermissionChecker: CapabilityPermissionChecking {
    func accessibilityIsGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func screenRecordingIsGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

struct SystemManagedPermissionChecker: ManagedPermissionChecking {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func probe(runtimeDirectory: URL) -> ManagedPermissionProbeFacts? {
        let python = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        let server = runtimeDirectory.appendingPathComponent("automac_mcp.py")
        guard fileManager.isExecutableFile(atPath: python.path),
              fileManager.fileExists(atPath: server.path) else {
            return nil
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.arguments = [server.path, "--permission-probe"]
        process.currentDirectoryURL = runtimeDirectory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard !process.isRunning else {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let envelope = try JSONDecoder().decode(PermissionProbeEnvelope.self, from: data)
            guard envelope.status == "success" else { return nil }
            return ManagedPermissionProbeFacts(
                accessibility: envelope.permissions.accessibility == true,
                screenRecording: envelope.permissions.screenRecording == true,
                automation: envelope.permissions.automation == true,
                activeConsole: envelope.session.onConsole == true,
                unlocked: envelope.session.isLocked == false
            )
        } catch {
            return nil
        }
    }
}

@MainActor
final class CapabilityReadinessCoordinator {
    private let session: URLSession
    private let fileManager: FileManager
    private let permissionChecker: CapabilityPermissionChecking
    private let managedPermissionChecker: ManagedPermissionChecking?

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.fileManager = fileManager
        self.permissionChecker = SystemCapabilityPermissionChecker()
        self.managedPermissionChecker = SystemManagedPermissionChecker(fileManager: fileManager)
    }

    init(
        session: URLSession,
        fileManager: FileManager,
        permissionChecker: CapabilityPermissionChecking
    ) {
        self.session = session
        self.fileManager = fileManager
        self.permissionChecker = permissionChecker
        self.managedPermissionChecker = nil
    }

    init(
        session: URLSession,
        fileManager: FileManager,
        permissionChecker: CapabilityPermissionChecking,
        managedPermissionChecker: ManagedPermissionChecking
    ) {
        self.session = session
        self.fileManager = fileManager
        self.permissionChecker = permissionChecker
        self.managedPermissionChecker = managedPermissionChecker
    }

    func evaluate(
        configuration: AppConfiguration,
        keychain: KeychainStore,
        runtimeDirectory: URL
    ) async -> CapabilityReadinessFacts {
        let coreSessionReady = localRuntimeIsReady(at: runtimeDirectory)
        let managedPermissions = managedPermissionChecker?.probe(runtimeDirectory: runtimeDirectory)
        let accessibilityGranted = managedPermissions?.accessibility
            ?? (managedPermissionChecker == nil ? permissionChecker.accessibilityIsGranted() : false)
        let screenRecordingGranted = managedPermissions?.screenRecording
            ?? (managedPermissionChecker == nil ? permissionChecker.screenRecordingIsGranted() : false)
        let managedSessionReady = managedPermissions.map {
            $0.automation && $0.activeConsole && $0.unlocked
        } ?? (managedPermissionChecker == nil)
        let localUIReady = accessibilityGranted && managedSessionReady
        let screenOcrReady = screenRecordingGranted && managedSessionReady
            && localOCRPayloadIsReady(at: runtimeDirectory)

        let normalizedRoots = try? ApprovedFileRootNormalizer.normalize(configuration.approvedFileRoots)
        let fullControl = configuration.controlProfile == .full
        let fileReadReady = fullControl || normalizedRoots?.isEmpty == false
        let fileWriteReady = fullControl
        let shellReady = fullControl && configuration.desiredCapabilities["mac.shell"] == true
        let clipboardReady = configuration.desiredCapabilities["mac.clipboard.write"] == true
            && configuration.policy.clipboardMutation

        let telegramToken = nonblankSecret(try? keychain.value(for: .telegramSendBotToken))
        let telegramChatID = nonblankSecret(try? keychain.value(for: .telegramSendChatID))
        let telegramCredentialsPresent = telegramToken != nil && telegramChatID != nil
        var telegramReady = false
        if configuration.desiredCapabilities["telegram.send"] == true,
           let telegramToken,
           let telegramChatID {
            telegramReady = await validateTelegramIdentityAndChat(
                token: telegramToken,
                chatIdentifier: telegramChatID
            )
        }

        let meridianCredentialsPresent = nonblankSecret(try? keychain.meridianIngestToken()) != nil
        let meridianTelegramConfigured = nonblankSecret(
            try? keychain.value(for: .meridianTelegramBotToken)
        ) != nil && nonblankSecret(
            try? keychain.value(for: .meridianTelegramWebhookSecret)
        ) != nil

        return CapabilityReadinessFacts(
            coreSessionReady: coreSessionReady,
            localUIReady: localUIReady,
            screenOcrReady: screenOcrReady,
            fileReadReady: fileReadReady,
            fileWriteReady: fileWriteReady,
            shellReady: shellReady,
            clipboardReady: clipboardReady,
            telegramCredentialsPresent: telegramCredentialsPresent,
            telegramReady: telegramReady,
            meridianCredentialsPresent: meridianCredentialsPresent,
            meridianSearchReady: false,
            meridianTelegramConfigured: meridianTelegramConfigured,
            meridianTelegramReady: false,
            remoteConnectorConfigured: configuration.process.tunnelDesired,
            remoteConnectorReady: false
        )
    }

    private func localRuntimeIsReady(at runtimeDirectory: URL) -> Bool {
        let python = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        let server = runtimeDirectory.appendingPathComponent("automac_mcp.py")
        return fileManager.isExecutableFile(atPath: python.path)
            && fileManager.fileExists(atPath: server.path)
    }

    private func localOCRPayloadIsReady(at runtimeDirectory: URL) -> Bool {
        guard localRuntimeIsReady(at: runtimeDirectory),
              easyOCRPackageIsInstalled(at: runtimeDirectory) else {
            return false
        }

        let modelDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".EasyOCR/model", isDirectory: true)
        return ["craft_mlt_25k.pth", "english_g2.pth"].allSatisfy { filename in
            let path = modelDirectory.appendingPathComponent(filename).path
            guard fileManager.fileExists(atPath: path),
                  let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.int64Value > 0
        }
    }

    private func easyOCRPackageIsInstalled(at runtimeDirectory: URL) -> Bool {
        for libraryName in ["lib", "lib64"] {
            let libraryDirectory = runtimeDirectory
                .appendingPathComponent(".venv", isDirectory: true)
                .appendingPathComponent(libraryName, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: libraryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            if entries.contains(where: { entry in
                guard entry.lastPathComponent.hasPrefix("python") else {
                    return false
                }
                return fileManager.fileExists(
                    atPath: entry
                        .appendingPathComponent("site-packages/easyocr/__init__.py")
                        .path
                )
            }) {
                return true
            }
        }
        return false
    }

    private func nonblankSecret(_ value: String??) -> String? {
        guard let value = value ?? nil else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateTelegramIdentityAndChat(
        token: String,
        chatIdentifier: String
    ) async -> Bool {
        guard token.unicodeScalars.allSatisfy(Self.telegramTokenCharacters.contains),
              let getMeURL = URL(string: "https://api.telegram.org/bot" + token + "/getMe"),
              let getChatURL = URL(string: "https://api.telegram.org/bot" + token + "/getChat") else {
            return false
        }

        var getMe = URLRequest(url: getMeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        getMe.httpMethod = "POST"
        guard let bot: TelegramBotIdentity = await telegramResult(for: getMe),
              bot.id > 0,
              bot.isBot else {
            return false
        }

        var getChat = URLRequest(
            url: getChatURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 5
        )
        getChat.httpMethod = "POST"
        getChat.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "chat_id", value: chatIdentifier)]
        getChat.httpBody = Data((form.percentEncodedQuery ?? "").utf8)

        guard let chat: TelegramChatIdentity = await telegramResult(for: getChat) else {
            return false
        }
        if let requestedID = Int64(chatIdentifier) {
            return chat.id == requestedID
        }
        if chatIdentifier.hasPrefix("@"), let username = chat.username {
            return username.caseInsensitiveCompare(String(chatIdentifier.dropFirst())) == .orderedSame
        }
        return false
    }

    private func telegramResult<Result: Decodable>(for request: URLRequest) async -> Result? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.url?.host == "api.telegram.org",
                  (200...299).contains(response.statusCode) else {
                return nil
            }
            let envelope = try JSONDecoder().decode(TelegramAPIEnvelope<Result>.self, from: data)
            return envelope.ok ? envelope.result : nil
        } catch {
            return nil
        }
    }

    private static let telegramTokenCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_-"
    )
}

private struct PermissionProbeEnvelope: Decodable {
    let status: String
    let permissions: PermissionProbeValues
    let session: PermissionProbeSession
}

private struct PermissionProbeValues: Decodable {
    let accessibility: Bool?
    let screenRecording: Bool?
    let automation: Bool?

    private enum CodingKeys: String, CodingKey {
        case accessibility
        case screenRecording = "screen_recording"
        case automation
    }
}

private struct PermissionProbeSession: Decodable {
    let onConsole: Bool?
    let isLocked: Bool?

    private enum CodingKeys: String, CodingKey {
        case onConsole = "on_console"
        case isLocked = "is_locked"
    }
}

private struct TelegramAPIEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
}

private struct TelegramBotIdentity: Decodable {
    let id: Int64
    let isBot: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
    }
}

private struct TelegramChatIdentity: Decodable {
    let id: Int64
    let username: String?
}
