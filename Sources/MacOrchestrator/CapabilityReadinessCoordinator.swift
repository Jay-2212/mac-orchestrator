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
    private let meridianProbe: MeridianReadinessProbing?
    private let meridianReceiptStore: MeridianReadinessReceiptStoring?
    private let meridianSupportDirectory: URL?

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        meridianSupportDirectory: URL? = nil,
        meridianProbe: MeridianReadinessProbing? = nil,
        meridianReceiptStore: MeridianReadinessReceiptStoring? = nil
    ) {
        self.session = session
        self.fileManager = fileManager
        self.permissionChecker = SystemCapabilityPermissionChecker()
        self.managedPermissionChecker = SystemManagedPermissionChecker(fileManager: fileManager)
        self.meridianSupportDirectory = meridianSupportDirectory
        self.meridianProbe = meridianProbe ?? (meridianSupportDirectory == nil ? nil : SystemMeridianReadinessProbe())
        self.meridianReceiptStore = meridianReceiptStore ?? meridianSupportDirectory.map {
            FileMeridianReadinessReceiptStore(
                url: $0.appendingPathComponent("meridian/readiness-receipt.json", isDirectory: false),
                fileManager: fileManager
            )
        }
    }

    init(
        session: URLSession,
        fileManager: FileManager,
        permissionChecker: CapabilityPermissionChecking,
        meridianSupportDirectory: URL? = nil,
        meridianProbe: MeridianReadinessProbing? = nil,
        meridianReceiptStore: MeridianReadinessReceiptStoring? = nil
    ) {
        self.session = session
        self.fileManager = fileManager
        self.permissionChecker = permissionChecker
        self.managedPermissionChecker = nil
        self.meridianSupportDirectory = meridianSupportDirectory
        self.meridianProbe = meridianProbe ?? (meridianSupportDirectory == nil ? nil : SystemMeridianReadinessProbe())
        self.meridianReceiptStore = meridianReceiptStore ?? meridianSupportDirectory.map {
            FileMeridianReadinessReceiptStore(
                url: $0.appendingPathComponent("meridian/readiness-receipt.json", isDirectory: false),
                fileManager: fileManager
            )
        }
    }

    init(
        session: URLSession,
        fileManager: FileManager,
        permissionChecker: CapabilityPermissionChecking,
        managedPermissionChecker: ManagedPermissionChecking,
        meridianSupportDirectory: URL? = nil,
        meridianProbe: MeridianReadinessProbing? = nil,
        meridianReceiptStore: MeridianReadinessReceiptStoring? = nil
    ) {
        self.session = session
        self.fileManager = fileManager
        self.permissionChecker = permissionChecker
        self.managedPermissionChecker = managedPermissionChecker
        self.meridianSupportDirectory = meridianSupportDirectory
        self.meridianProbe = meridianProbe ?? (meridianSupportDirectory == nil ? nil : SystemMeridianReadinessProbe())
        self.meridianReceiptStore = meridianReceiptStore ?? meridianSupportDirectory.map {
            FileMeridianReadinessReceiptStore(
                url: $0.appendingPathComponent("meridian/readiness-receipt.json", isDirectory: false),
                fileManager: fileManager
            )
        }
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

        let meridianEnabled = configuration.integration.meridianIndexer.enabled
        let meridianDesired = configuration.desiredCapabilities["meridian.search"] == true
        let meridianToken: String?
        if meridianEnabled && meridianDesired {
            meridianToken = nonblankSecret(try? keychain.meridianIngestToken())
        } else {
            meridianToken = nil
        }
        let meridianCredentialsPresent = meridianToken != nil
        let meridianSearchReady = await evaluateMeridianReadiness(
            configuration: configuration,
            token: meridianToken
        )
        let meridianTelegramConfigured: Bool
        if meridianEnabled && meridianDesired,
           configuration.desiredCapabilities["meridian.telegram"] == true {
            meridianTelegramConfigured = nonblankSecret(
                try? keychain.value(for: .meridianTelegramBotToken)
            ) != nil && nonblankSecret(
                try? keychain.value(for: .meridianTelegramWebhookSecret)
            ) != nil
        } else {
            meridianTelegramConfigured = false
        }

        // This is the startup/base capability snapshot. Live network and
        // authenticated remote lifecycle state are projected separately by
        // CapabilitySnapshot.projected(from:), so this evaluator never owns
        // or restarts the lifecycle authority.
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
            meridianSearchReady: meridianSearchReady,
            meridianTelegramConfigured: meridianTelegramConfigured,
            meridianTelegramReady: false,
            remoteConnectorConfigured: configuration.process.tunnelDesired,
            remoteConnectorReady: false
        )
    }

    private func evaluateMeridianReadiness(
        configuration: AppConfiguration,
        token: String?
    ) async -> Bool {
        let indexerConfiguration = configuration.integration.meridianIndexer
        guard configuration.desiredCapabilities["meridian.search"] == true,
              indexerConfiguration.enabled,
              (try? indexerConfiguration.validated()) != nil,
              let token,
              let deployment = configuration.integration.meridianDeploymentURL,
              let baseURL = URL(string: deployment),
              let meridianSupportDirectory,
              let meridianReceiptStore else {
            return false
        }
        let meridianDirectory = meridianSupportDirectory.appendingPathComponent("meridian", isDirectory: true)
        let installer = MeridianIndexerToolInstaller(rootURL: meridianDirectory, fileManager: fileManager)
        let currentDigest = installer.currentDigest()
        let tool = installer.receipt()
        var receipt = meridianReceiptStore.load() ?? MeridianReadinessReceipt()
        let deploymentFingerprint = MeridianReadinessEvaluator.fingerprint(for: deployment)
        let indexEvidenceMatches = receipt.deploymentFingerprint == deploymentFingerprint
            && receipt.toolDigest?.lowercased() == currentDigest?.lowercased()
        if !indexEvidenceMatches {
            receipt.lastSuccessfulIndexAt = nil
            receipt.lastSuccessfulIndexAction = nil
            receipt.lastResult = nil
        }
        let probeMatches = receipt.lastProbe?.passed == true
            && receipt.lastProbe?.deploymentFingerprint == deploymentFingerprint
            && receipt.lastProbe?.toolDigest?.lowercased() == currentDigest?.lowercased()
        if !probeMatches,
           let meridianProbe,
           let currentDigest {
            let probe = await meridianProbe.probe(
                baseURL: baseURL,
                stateURL: meridianDirectory.appendingPathComponent("index-state.json"),
                toolURL: installer.installedURL,
                token: token,
                currentToolDigest: currentDigest
            )
            receipt.deploymentFingerprint = deploymentFingerprint
            receipt.toolDigest = currentDigest
            receipt.lastProbe = probe
            try? meridianReceiptStore.save(receipt)
        }
        return MeridianReadinessEvaluator.evaluate(
            MeridianReadinessEvaluationInput(
                desired: true,
                enabled: true,
                deploymentURL: deployment,
                tokenPresent: true,
                tool: tool,
                currentToolDigest: currentDigest,
                lastSuccessfulIndexAt: receipt.lastSuccessfulIndexAt,
                lastSuccessfulIndexAction: receipt.lastSuccessfulIndexAction,
                lastSuccessfulIndexDeploymentFingerprint: receipt.deploymentFingerprint,
                lastSuccessfulIndexToolDigest: receipt.toolDigest,
                lastProbe: receipt.lastProbe,
                now: Date()
            )
        ).ready
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
