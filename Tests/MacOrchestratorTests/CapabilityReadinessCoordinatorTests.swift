import Foundation
import XCTest
@testable import MacOrchestrator

final class CapabilityReadinessCoordinatorTests: XCTestCase {
    @MainActor
    func testGuidedAndFullLocalReadinessUsesFrozenProfilePolicy() async throws {
        let runtime = try makeRuntime()
        let coordinator = makeCoordinator(
            permissions: FakeCapabilityPermissionChecker(accessibility: true, screenRecording: true)
        )
        let keychain = KeychainStore(client: ReadinessKeychainClient())
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.approvedFileRoots = ["/tmp/approved"]
        configuration.desiredCapabilities["mac.files.read"] = true
        configuration.desiredCapabilities["mac.files.write"] = true
        configuration.desiredCapabilities["mac.shell"] = true
        configuration.desiredCapabilities["mac.clipboard.write"] = true
        configuration.policy.clipboardMutation = true

        let guided = await coordinator.evaluate(
            configuration: configuration,
            keychain: keychain,
            runtimeDirectory: runtime
        )

        XCTAssertTrue(guided.coreSessionReady)
        XCTAssertTrue(guided.fileReadReady)
        XCTAssertFalse(guided.fileWriteReady)
        XCTAssertFalse(guided.shellReady)
        XCTAssertTrue(guided.clipboardReady)

        configuration.controlProfile = .full
        configuration.approvedFileRoots = []
        let full = await coordinator.evaluate(
            configuration: configuration,
            keychain: keychain,
            runtimeDirectory: runtime
        )

        XCTAssertTrue(full.fileReadReady)
        XCTAssertTrue(full.fileWriteReady)
        XCTAssertTrue(full.shellReady)
    }

    @MainActor
    func testOCRRequiresScreenRecordingAndExistingLocalRuntimePayload() async throws {
        let runtime = try makeRuntime()
        let fileManager = ReadinessFileManager(
            homeDirectory: runtime.appendingPathComponent("synthetic-home", isDirectory: true)
        )
        let keychain = KeychainStore(client: ReadinessKeychainClient())
        let configuration = AppConfiguration.fresh(ownerID: "owner")
        let permitted = makeCoordinator(
            permissions: FakeCapabilityPermissionChecker(accessibility: true, screenRecording: true),
            fileManager: fileManager
        )

        let withoutPayload = await permitted.evaluate(
            configuration: configuration,
            keychain: keychain,
            runtimeDirectory: runtime
        )
        XCTAssertTrue(withoutPayload.localUIReady)
        XCTAssertFalse(withoutPayload.screenOcrReady)

        try installOCRPayload(using: fileManager)
        let withPayload = await permitted.evaluate(
            configuration: configuration,
            keychain: keychain,
            runtimeDirectory: runtime
        )
        XCTAssertTrue(withPayload.screenOcrReady)

        let denied = makeCoordinator(
            permissions: FakeCapabilityPermissionChecker(accessibility: true, screenRecording: false),
            fileManager: fileManager
        )
        let withoutScreenRecording = await denied.evaluate(
            configuration: configuration,
            keychain: keychain,
            runtimeDirectory: runtime
        )
        XCTAssertFalse(withoutScreenRecording.screenOcrReady)
    }

    @MainActor
    func testTelegramReadinessValidatesIdentityAndChatWithoutSending() async throws {
        TelegramReadinessURLProtocol.reset(mode: .success)
        let session = makeTelegramSession()
        let coordinator = CapabilityReadinessCoordinator(
            session: session,
            fileManager: .default,
            permissionChecker: FakeCapabilityPermissionChecker(accessibility: false, screenRecording: false)
        )
        let client = ReadinessKeychainClient(values: [
            KeychainItem.telegramSendBotToken.key: "123456:synthetic-token",
            KeychainItem.telegramSendChatID.key: "123456",
        ])
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.desiredCapabilities["telegram.send"] = true

        let facts = await coordinator.evaluate(
            configuration: configuration,
            keychain: KeychainStore(client: client),
            runtimeDirectory: try makeRuntime()
        )

        XCTAssertTrue(facts.telegramCredentialsPresent)
        XCTAssertTrue(facts.telegramReady)
        XCTAssertEqual(Set(TelegramReadinessURLProtocol.endpointNames), Set(["getMe", "getChat"]))
        XCTAssertFalse(TelegramReadinessURLProtocol.endpointNames.contains("sendMessage"))
        XCTAssertFalse(TelegramReadinessURLProtocol.endpointNames.contains("sendDocument"))
    }

    @MainActor
    func testTelegramProbeFailureIsNotReadyAndDoesNotExposeToken() async throws {
        TelegramReadinessURLProtocol.reset(mode: .botIdentityMismatch)
        let coordinator = CapabilityReadinessCoordinator(
            session: makeTelegramSession(),
            fileManager: .default,
            permissionChecker: FakeCapabilityPermissionChecker(accessibility: false, screenRecording: false)
        )
        let secret = "123456:do-not-leak-this-token"
        let client = ReadinessKeychainClient(values: [
            KeychainItem.telegramSendBotToken.key: secret,
            KeychainItem.telegramSendChatID.key: "123456",
        ])
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.desiredCapabilities["telegram.send"] = true

        let facts = await coordinator.evaluate(
            configuration: configuration,
            keychain: KeychainStore(client: client),
            runtimeDirectory: try makeRuntime()
        )

        XCTAssertFalse(facts.telegramReady)
        XCTAssertFalse(String(reflecting: facts).contains(secret))
    }

    @MainActor
    func testTelegramChatIdentityMismatchIsNotReady() async throws {
        TelegramReadinessURLProtocol.reset(mode: .chatIdentityMismatch)
        let coordinator = CapabilityReadinessCoordinator(
            session: makeTelegramSession(),
            fileManager: .default,
            permissionChecker: FakeCapabilityPermissionChecker(accessibility: false, screenRecording: false)
        )
        let client = ReadinessKeychainClient(values: [
            KeychainItem.telegramSendBotToken.key: "123456:synthetic-token",
            KeychainItem.telegramSendChatID.key: "123456",
        ])
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.desiredCapabilities["telegram.send"] = true

        let facts = await coordinator.evaluate(
            configuration: configuration,
            keychain: KeychainStore(client: client),
            runtimeDirectory: try makeRuntime()
        )

        XCTAssertFalse(facts.telegramReady)
    }

    @MainActor
    func testDisabledTelegramDoesNotPerformNetworkValidation() async throws {
        TelegramReadinessURLProtocol.reset(mode: .success)
        let coordinator = CapabilityReadinessCoordinator(
            session: makeTelegramSession(),
            fileManager: .default,
            permissionChecker: FakeCapabilityPermissionChecker(accessibility: false, screenRecording: false)
        )
        let client = ReadinessKeychainClient(values: [
            KeychainItem.telegramSendBotToken.key: "123456:synthetic-token",
            KeychainItem.telegramSendChatID.key: "123456",
        ])

        let facts = await coordinator.evaluate(
            configuration: AppConfiguration.fresh(ownerID: "owner"),
            keychain: KeychainStore(client: client),
            runtimeDirectory: try makeRuntime()
        )

        XCTAssertTrue(facts.telegramCredentialsPresent)
        XCTAssertFalse(facts.telegramReady)
        XCTAssertTrue(TelegramReadinessURLProtocol.endpointNames.isEmpty)
    }

    @MainActor
    func testMeridianAndRemoteConnectorRemainNotReadyInProductionFacts() async throws {
        let client = ReadinessKeychainClient(values: [
            KeychainItem.meridianIngestToken(account: NSUserName()).key: "synthetic-ingest",
            KeychainItem.meridianTelegramBotToken.key: "synthetic-bot",
            KeychainItem.meridianTelegramWebhookSecret.key: "synthetic-webhook",
        ])
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.integration.meridianDeploymentURL = "https://meridian.invalid"
        configuration.desiredCapabilities["meridian.search"] = true
        configuration.desiredCapabilities["meridian.telegram"] = true
        configuration.desiredCapabilities["remote.connector"] = true
        configuration.process.tunnelDesired = true

        let facts = await makeCoordinator(
            permissions: FakeCapabilityPermissionChecker(accessibility: false, screenRecording: false)
        ).evaluate(
            configuration: configuration,
            keychain: KeychainStore(client: client),
            runtimeDirectory: try makeRuntime()
        )

        XCTAssertTrue(facts.meridianCredentialsPresent)
        XCTAssertFalse(facts.meridianSearchReady)
        XCTAssertTrue(facts.meridianTelegramConfigured)
        XCTAssertFalse(facts.meridianTelegramReady)
        XCTAssertTrue(facts.remoteConnectorConfigured)
        XCTAssertFalse(facts.remoteConnectorReady)
    }

    @MainActor
    private func makeCoordinator(
        permissions: CapabilityPermissionChecking,
        fileManager: FileManager = .default
    ) -> CapabilityReadinessCoordinator {
        CapabilityReadinessCoordinator(
            session: makeTelegramSession(),
            fileManager: fileManager,
            permissionChecker: permissions
        )
    }

    private func makeTelegramSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramReadinessURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private func makeRuntime() throws -> URL {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorReadinessTests-" + UUID().uuidString, isDirectory: true)
        let python = runtime.appendingPathComponent(".venv/bin/python")
        let easyOCR = runtime.appendingPathComponent(
            ".venv/lib/python3.13/site-packages/easyocr/__init__.py"
        )
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: easyOCR.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: python.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: runtime.appendingPathComponent("automac_mcp.py").path,
            contents: Data()
        ))
        XCTAssertTrue(FileManager.default.createFile(atPath: easyOCR.path, contents: Data()))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: runtime)
        }
        return runtime
    }

    @MainActor
    private func installOCRPayload(using fileManager: FileManager) throws {
        let models = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".EasyOCR/model", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        for filename in ["craft_mlt_25k.pth", "english_g2.pth"] {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: models.appendingPathComponent(filename).path,
                contents: Data([1])
            ))
        }
    }
}

private final class ReadinessFileManager: FileManager {
    private let syntheticHomeDirectory: URL

    init(homeDirectory: URL) {
        self.syntheticHomeDirectory = homeDirectory
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL {
        syntheticHomeDirectory
    }
}

private struct FakeCapabilityPermissionChecker: CapabilityPermissionChecking {
    let accessibility: Bool
    let screenRecording: Bool

    func accessibilityIsGranted() -> Bool { accessibility }
    func screenRecordingIsGranted() -> Bool { screenRecording }
}

private final class ReadinessKeychainClient: KeychainClient {
    private let values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(service: String, account: String) throws -> String? {
        values[KeychainItem.key(service: service, account: account)]
    }

    func create(value: String, service: String, account: String) throws {
        throw KeychainStoreError.operationFailed(-1)
    }

    func update(value: String, service: String, account: String) throws {
        throw KeychainStoreError.operationFailed(-1)
    }
}

private final class TelegramReadinessURLProtocol: URLProtocol {
    enum Mode {
        case success
        case botIdentityMismatch
        case chatIdentityMismatch
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .success
    nonisolated(unsafe) private static var endpoints: [String] = []

    static var endpointNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return endpoints
    }

    static func reset(mode: Mode) {
        lock.lock()
        self.mode = mode
        endpoints = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let endpoint = request.url?.lastPathComponent ?? ""
        Self.lock.lock()
        Self.endpoints.append(endpoint)
        let mode = Self.mode
        Self.lock.unlock()

        let json: String
        switch (endpoint, mode) {
        case ("getMe", .success), ("getMe", .chatIdentityMismatch):
            json = "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":true}}"
        case ("getMe", .botIdentityMismatch):
            json = "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":false}}"
        case ("getChat", .chatIdentityMismatch):
            json = "{\"ok\":true,\"result\":{\"id\":999999}}"
        case ("getChat", _):
            json = "{\"ok\":true,\"result\":{\"id\":123456}}"
        default:
            json = "{\"ok\":false}"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: endpoint == "getMe" || endpoint == "getChat" ? 200 : 404,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
