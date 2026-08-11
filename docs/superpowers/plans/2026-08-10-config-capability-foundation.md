# Wave 1 Configuration Capability Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a testable Swift-owned configuration store, explicit migrations, named Keychain storage, and a deterministic capability snapshot without changing supervisor, Python, workflow, packaging, or Meridian code.

**Architecture:** `AppConfiguration` is a Codable nonsecret value model. `ConfigurationStore` persists it under an injected Application Support directory with schema validation, generation tracking, atomic primary/backup replacement, and fail-closed recovery. `KeychainStore` depends on an injected `KeychainClient`; `UserDefaultsMigrator` and `LegacySecretMigrator` adapt existing state into the store. `CapabilityRegistry` resolves configuration plus injected readiness facts into a version-1 JSON snapshot.

**Tech Stack:** Swift 5.9 package targeting macOS 13+, Foundation, Security.framework, XCTest, JSONEncoder/JSONDecoder, temporary directories, and isolated UserDefaults suites.

## Global Constraints

- Base the branch on the freshly fetched `origin/main` exact SHA `b8b44cd494e436c22e60168cca8c3eda0f09aa33`.
- New configurations default to Guided Control and local MCP port 8000.
- Port validation accepts only integer values in `1...65535`; no automatic port selection is implemented.
- Configuration contains no secret values, provider account IDs, or partial credentials.
- Preserve the connector Keychain identity `com.jay.mac-orchestrator` / `connector-capability-token` exactly.
- Preserve the Meridian ingest convention `com.jay.mac-orchestrator.ingest-token` / current user account.
- Do not modify `ProcessSupervisor.swift`, `AppDelegate.swift`, `MenuController.swift`, `Models.swift`, `automac_mcp.py`, Python tests, workflows, packaging/release files, or the Meridian repository.
- Every new behavior is developed test-first: write one failing XCTest, run it, implement the smallest behavior, rerun it, then refactor only while green.
- All filesystem, UserDefaults, and Keychain tests use injected or temporary state.

---

### Task 1: Define versioned nonsecret configuration values

**Files:**
- Create: `Sources/MacOrchestrator/Configuration.swift`
- Test: `Tests/MacOrchestratorTests/ConfigurationTests.swift`

**Interfaces:**
- `enum ControlProfile: String, Codable, Sendable { case guided, full }`
- `struct AppConfiguration: Codable, Equatable, Sendable`
- `struct ProcessConfiguration: Codable, Equatable, Sendable`
- `struct ConfigurationPolicy: Codable, Equatable, Sendable`
- `struct SchedulingPlaceholder: Codable, Equatable, Sendable`
- `struct IntegrationConfiguration: Codable, Equatable, Sendable`
- `struct OnboardingConfiguration: Codable, Equatable, Sendable`
- `enum ConfigurationValidationError: Error, Equatable`
- `extension AppConfiguration { static func fresh(ownerID: String) -> AppConfiguration; func validated() throws -> AppConfiguration }`

- [ ] **Step 1: Write the failing tests for fresh defaults and validation.**

```swift
func testFreshConfigurationUsesGuidedSafeDefaults() throws {
    let configuration = AppConfiguration.fresh(ownerID: "owner-1")
    XCTAssertEqual(configuration.schemaVersion, 1)
    XCTAssertEqual(configuration.generation, 1)
    XCTAssertEqual(configuration.controlProfile, .guided)
    XCTAssertEqual(configuration.localMCPPort, 8000)
    XCTAssertTrue(configuration.process.serverDesired)
    XCTAssertFalse(configuration.process.tunnelDesired)
    XCTAssertEqual(configuration.ownerID, "owner-1")
    XCTAssertTrue(configuration.desiredCapabilities["core.session"] == true)
    XCTAssertTrue(configuration.desiredCapabilities["mac.ui"] == true)
    XCTAssertFalse(configuration.desiredCapabilities["mac.shell"] == true)
    XCTAssertFalse(configuration.desiredCapabilities["mac.files.write"] == true)
    XCTAssertFalse(configuration.policy.clipboardMutation)
    XCTAssertTrue(configuration.approvedFileRoots.isEmpty)
    XCTAssertTrue(configuration.integration.meridianDeploymentURL == nil)
}

func testInvalidPortIsRejectedBeforePersistence() {
    var configuration = AppConfiguration.fresh(ownerID: "owner-1")
    configuration.localMCPPort = 0
    XCTAssertThrowsError(try configuration.validated()) { error in
        XCTAssertEqual(error as? ConfigurationValidationError, .invalidPort(0))
    }
}

func testConfigurationRoundTripsArbitraryValidPortWithoutSecrets() throws {
    var configuration = AppConfiguration.fresh(ownerID: "owner-1")
    configuration.localMCPPort = 9876
    configuration.integration.meridianDeploymentURL = "https://meridian.example"
    let data = try JSONEncoder().encode(configuration.validated())
    let json = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(json.contains("bot-token-secret"))
    XCTAssertFalse(json.contains("ingest-secret"))
    let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
    XCTAssertEqual(decoded.localMCPPort, 9876)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail because the configuration model does not exist.**

Run: `swift test --filter ConfigurationTests`

Expected: compilation failure naming the missing `AppConfiguration`/configuration types, not a successful test run.

- [ ] **Step 3: Implement the minimal Codable model and validation.**

Use explicit default values in `AppConfiguration.fresh`, keep `desiredCapabilities` as a `[String: Bool]` nonsecret map, represent scheduling only as persisted placeholder state, and reject unsupported schema versions, generations below 1, blank owner IDs, and ports outside `1...65535`. Keep known capability keys in the default map but allow future nonsecret capability IDs to round-trip.

- [ ] **Step 4: Run the focused tests and the existing policy tests.**

Run: `swift test --filter ConfigurationTests`

Expected: all configuration tests pass.

Run: `swift test --filter SupervisorPolicyTests`

Expected: all pre-existing Wave-0 policy tests pass when the local XCTest toolchain is available.

- [ ] **Step 5: Commit the model and tests.**

```bash
git add Sources/MacOrchestrator/Configuration.swift Tests/MacOrchestratorTests/ConfigurationTests.swift
git commit -m "feat: add versioned nonsecret configuration model"
```

### Task 2: Implement atomic configuration persistence and recovery

**Files:**
- Create: `Sources/MacOrchestrator/ConfigurationStore.swift`
- Test: `Tests/MacOrchestratorTests/ConfigurationStoreTests.swift`

**Interfaces:**
- `enum ConfigurationStoreError: Error, Equatable`
- `final class ConfigurationStore`
- `init(directoryURL: URL, fileManager: FileManager = .default, ownerIDProvider: () -> String = { UUID().uuidString.lowercased() })`
- `var configurationURL: URL { get }`
- `var backupURL: URL { get }`
- `func load() throws -> AppConfiguration`
- `func loadOrCreate() throws -> AppConfiguration`
- `@discardableResult func save(_ configuration: AppConfiguration) throws -> AppConfiguration`
- `func update(_ body: (inout AppConfiguration) throws -> Void) throws -> AppConfiguration`

- [ ] **Step 1: Write failing tests for creation, round-trip, backup, atomic replacement, and invalid/corrupt input.**

```swift
func testLoadOrCreateWritesFreshConfigurationInInjectedDirectory() throws {
    let directory = try makeTemporaryDirectory()
    let store = ConfigurationStore(directoryURL: directory, ownerIDProvider: { "owner-1" })
    let configuration = try store.loadOrCreate()
    XCTAssertEqual(configuration.ownerID, "owner-1")
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path))
}

func testSecondSaveBacksUpPreviousPrimaryBeforeReplacingIt() throws {
    let store = try makeStore()
    var first = try store.loadOrCreate()
    first.localMCPPort = 8123
    _ = try store.save(first)
    var second = first
    second.localMCPPort = 9123
    _ = try store.save(second)
    let backup = try Data(contentsOf: store.backupURL)
    let backedUp = try JSONDecoder().decode(AppConfiguration.self, from: backup)
    XCTAssertEqual(backedUp.localMCPPort, 8123)
    XCTAssertEqual(try store.load().localMCPPort, 9123)
}

func testCorruptPrimaryIsPreservedAndKnownGoodBackupIsRecovered() throws {
    let store = try makeStore()
    var configuration = try store.loadOrCreate()
    configuration.localMCPPort = 8123
    _ = try store.save(configuration)
    configuration.localMCPPort = 9123
    _ = try store.save(configuration)
    let knownGood = try Data(contentsOf: store.backupURL)
    try Data("{not-json".utf8).write(to: store.configurationURL)
    let recovered = try store.load()
    XCTAssertEqual(recovered.localMCPPort, 8123)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path + ".corrupt"))
    XCTAssertEqual(try Data(contentsOf: store.backupURL), knownGood)
}

func testUnsupportedFutureSchemaIsRejectedWithoutDefaultReset() throws {
    let store = try makeStore()
    try Data("{\"schemaVersion\":99}".utf8).write(to: store.configurationURL)
    XCTAssertThrowsError(try store.load()) { error in
        XCTAssertEqual(error as? ConfigurationStoreError, .unsupportedSchema(99))
    }
}

func testInvalidPrimaryFailsClosedWhenNoBackupExists() throws {
    let store = try makeStore()
    var configuration = AppConfiguration.fresh(ownerID: "owner-1")
    configuration.localMCPPort = 70000
    let data = try JSONEncoder().encode(configuration)
    try data.write(to: store.configurationURL)
    XCTAssertThrowsError(try store.load())
}
```

- [ ] **Step 2: Run `swift test --filter ConfigurationStoreTests` and confirm the missing store APIs fail the tests.**

- [ ] **Step 3: Implement validation-before-use and atomic same-directory writes.**

Create the directory with `0700` permissions. Save a validated payload to a uniquely named temporary file in the same directory. When a primary exists, copy it to a temporary backup and move that backup into `config.json.backup` before moving the new primary into place; if preparing the backup fails, leave the primary untouched. Use `Data.write(..., options: [.atomic])` only for same-directory temporary payload creation and never delete the only known-good file on a failed operation. Treat unsupported schema as non-recoverable; treat malformed/invalid primary as recoverable only when a valid backup can be loaded. Preserve corrupt bytes under a deterministic `.corrupt` sidecar, adding a numeric suffix if needed.

- [ ] **Step 4: Add generation behavior and idempotent update tests.**

Assert `update` increments generation exactly once for a changed configuration, `save` never decreases generation, and a no-op migration/update does not rewrite or append duplicate markers. Run the focused test file again and keep output at zero failures.

- [ ] **Step 5: Commit the persistence layer.**

```bash
git add Sources/MacOrchestrator/ConfigurationStore.swift Tests/MacOrchestratorTests/ConfigurationStoreTests.swift
git commit -m "feat: persist configuration atomically with recovery"
```

### Task 3: Add injectable named Keychain storage

**Files:**
- Modify: `Sources/MacOrchestrator/KeychainStore.swift`
- Create: `Tests/MacOrchestratorTests/KeychainStoreTests.swift`

**Interfaces:**
- `protocol KeychainClient`
- `struct SystemKeychainClient: KeychainClient`
- `enum KeychainItem: Equatable, Sendable`
- `enum KeychainStoreError: Error, Equatable`
- `struct KeychainStore`
- `static func connectorToken() throws -> String`
- `func value(for item: KeychainItem) throws -> String?`
- `func set(_ value: String, for item: KeychainItem) throws`
- `func connectorToken() throws -> String`
- `func meridianIngestToken() throws -> String?`

- [ ] **Step 1: Write failing fake-client tests for create/read/update, connector identity preservation, and legacy Meridian identity.**

```swift
func testConnectorTokenReadsExistingIdentityWithoutCreatingOrRotating() throws {
    let fake = FakeKeychainClient(values: [
        KeychainItem.connectorToken.key: "connector-stable-value"
    ])
    let store = KeychainStore(client: fake)
    XCTAssertEqual(try store.connectorToken(), "connector-stable-value")
    XCTAssertEqual(fake.createCalls, [])
    XCTAssertEqual(fake.updateCalls, [])
}

func testNamedSecretCreatesThenUpdatesThroughInjectedClient() throws {
    let fake = FakeKeychainClient()
    let store = KeychainStore(client: fake)
    try store.set("telegram-one", for: .telegramSendBotToken)
    try store.set("telegram-two", for: .telegramSendBotToken)
    XCTAssertEqual(try store.value(for: .telegramSendBotToken), "telegram-two")
    XCTAssertEqual(fake.createCalls, [KeychainItem.telegramSendBotToken.key])
    XCTAssertEqual(fake.updateCalls, [KeychainItem.telegramSendBotToken.key])
}

func testMeridianIngestUsesExistingPythonServiceAndUserAccount() throws {
    let item = KeychainItem.meridianIngestToken(account: "jay")
    XCTAssertEqual(item.service, "com.jay.mac-orchestrator.ingest-token")
    XCTAssertEqual(item.account, "jay")
}
```

- [ ] **Step 2: Run `swift test --filter KeychainStoreTests` and verify failure because the injected client and named items are absent.**

- [ ] **Step 3: Implement Security.framework create/read/update and preserve the old connector item.**

Keep `com.jay.mac-orchestrator` and `connector-capability-token` as exact constants. Use read-before-write and update existing items rather than generating a new connector token. Define Telegram Send bot/chat items, the legacy Meridian ingest item, and future Meridian Telegram bot/webhook items. Read the legacy ingest item first; support a stable alias only as a read fallback, and never duplicate an existing legacy item. Do not include secret values in errors or descriptions.

- [ ] **Step 4: Run the focused tests and verify fake call ordering and values.**

- [ ] **Step 5: Commit the Keychain layer and tests.**

```bash
git add Sources/MacOrchestrator/KeychainStore.swift Tests/MacOrchestratorTests/KeychainStoreTests.swift
git commit -m "feat: add injectable named Keychain storage"
```

### Task 4: Migrate UserDefaults and legacy plaintext secrets

**Files:**
- Create: `Sources/MacOrchestrator/Migrations.swift`
- Create: `Tests/MacOrchestratorTests/MigrationTests.swift`

**Interfaces:**
- `enum UserDefaultsMigrator { static func migrate(userDefaults: UserDefaults, store: ConfigurationStore) throws -> AppConfiguration }`
- `struct LegacySecretMigrationResult: Equatable, Sendable`
- `struct LegacySecretMigrator`
- `init(legacyURL: URL, keychain: KeychainStore, store: ConfigurationStore)`
- `func migrate() throws -> LegacySecretMigrationResult`

- [ ] **Step 1: Write failing tests for current UserDefaults mapping and idempotence.**

```swift
func testLegacyUserDefaultsPreserveExistingBehaviorAndUseFullProfile() throws {
    let defaults = makeIsolatedDefaults()
    defaults.set(false, forKey: "serverDesired")
    defaults.set(true, forKey: "tunnelDesired")
    defaults.set("owner-legacy", forKey: "ownerID")
    let store = try makeStore()
    let configuration = try UserDefaultsMigrator.migrate(userDefaults: defaults, store: store)
    XCTAssertEqual(configuration.controlProfile, .full)
    XCTAssertFalse(configuration.process.serverDesired)
    XCTAssertTrue(configuration.process.tunnelDesired)
    XCTAssertEqual(configuration.ownerID, "owner-legacy")
    XCTAssertTrue(configuration.desiredCapabilities["remote.connector"] == true)
}

func testRunningUserDefaultsMigrationTwiceDoesNotResetOrDuplicateMarkers() throws {
    let defaults = makeIsolatedDefaults()
    defaults.set("owner-legacy", forKey: "ownerID")
    let store = try makeStore()
    let first = try UserDefaultsMigrator.migrate(userDefaults: defaults, store: store)
    var changed = first
    changed.localMCPPort = 9123
    _ = try store.save(changed)
    let second = try UserDefaultsMigrator.migrate(userDefaults: defaults, store: store)
    XCTAssertEqual(second.localMCPPort, 9123)
    XCTAssertEqual(second.onboarding.migrationMarkers.filter { $0 == "user-defaults-v1" }.count, 1)
}
```

- [ ] **Step 2: Run `swift test --filter MigrationTests` and confirm missing migrator APIs fail.**

- [ ] **Step 3: Implement UserDefaults migration with an explicit legacy-full-control rule.**

Detect any existing `ownerID`, `serverDesired`, or `tunnelDesired` object as a legacy install. Map present Boolean values without replacing explicit false values. Set `.full` only for that detected legacy install, add a single `legacy-control-profile-v1` marker, and map `tunnelDesired` to `remote.connector` desired state. Fresh stores remain Guided. Load and save only when the resulting value changes.

- [ ] **Step 4: Add failing tests for plaintext Telegram/ingest migration, preservation, verification, failure, and idempotence.**

Use a temp JSON object containing the three known keys plus `unrelatedSetting`. Assert the fake Keychain receives the Telegram items and the exact legacy Meridian service/account, the config contains only cleanup markers and no secret values, and the legacy file still contains all four original keys. Configure the fake to throw on a write; assert `legacyPlaintextCleanupPending` is true, the completed marker is absent, and the migration throws. Rerun after clearing the failure and assert no duplicate create calls and one completion marker.

- [ ] **Step 5: Implement verified secret migration without deletion.**

Read known string or numeric chat-ID values, set pending state before writes, skip writes for already-present canonical items, write only missing values, read every written value back, and record `legacy-secrets-v1` only after all known values verify. Report only item names and booleans. Leave the plaintext JSON untouched and preserve unrelated keys. A failed write must not set the completion marker.

- [ ] **Step 6: Run migration tests, then commit.**

```bash
swift test --filter MigrationTests
git add Sources/MacOrchestrator/Migrations.swift Tests/MacOrchestratorTests/MigrationTests.swift
git commit -m "feat: migrate legacy settings and secrets safely"
```

### Task 5: Implement capability resolution and snapshot encoding

**Files:**
- Create: `Sources/MacOrchestrator/CapabilityRegistry.swift`
- Create: `Tests/MacOrchestratorTests/CapabilityRegistryTests.swift`

**Interfaces:**
- `enum CapabilityHealth: String, Codable, Sendable { case ready, disabled, degraded, unavailable }`
- `struct CapabilityReadinessFacts: Equatable, Sendable`
- `struct CapabilityState: Codable, Equatable, Sendable`
- `struct CapabilityPolicySnapshot: Codable, Equatable, Sendable`
- `struct CapabilitySnapshot: Codable, Equatable, Sendable`
- `struct CapabilityRegistry`
- `init(configuration: AppConfiguration, facts: CapabilityReadinessFacts)`
- `func snapshot() -> CapabilitySnapshot`
- `enum CapabilitySnapshotCodec { static func encode(_ snapshot: CapabilitySnapshot) throws -> Data; static func decode(_ data: Data) throws -> CapabilitySnapshot }`

- [ ] **Step 1: Write failing tests for IDs, Guided/Full policy, dependencies, injected facts, and the snapshot contract.**

```swift
func testGuidedControlBlocksShellAndFileWritesEvenWhenDesired() throws {
    var configuration = AppConfiguration.fresh(ownerID: "owner-1")
    configuration.approvedFileRoots = ["/tmp/approved"]
    configuration.desiredCapabilities["mac.shell"] = true
    configuration.desiredCapabilities["mac.files.write"] = true
    let snapshot = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()
    XCTAssertFalse(snapshot.capabilities["mac.shell"]!.ready)
    XCTAssertFalse(snapshot.capabilities["mac.files.write"]!.ready)
    XCTAssertEqual(snapshot.capabilities["mac.shell"]!.reason, "Full Control must be explicitly selected.")
}

func testMeridianTelegramCannotOutrunMeridianSearch() throws {
    var configuration = AppConfiguration.fresh(ownerID: "owner-1")
    configuration.controlProfile = .full
    configuration.integration.meridianDeploymentURL = "https://meridian.example"
    configuration.desiredCapabilities["meridian.search"] = true
    configuration.desiredCapabilities["meridian.telegram"] = true
    let facts = readyFacts(meridianSearchReady: false, meridianTelegramReady: true)
    let snapshot = CapabilityRegistry(configuration: configuration, facts: facts).snapshot()
    XCTAssertFalse(snapshot.capabilities["meridian.search"]!.ready)
    XCTAssertFalse(snapshot.capabilities["meridian.telegram"]!.ready)
    XCTAssertEqual(snapshot.capabilities["meridian.telegram"]!.dependencies, ["meridian.search"])
}

func testMeridianURLAndCredentialFactsDoNotAloneMarkSearchReady() throws {
    var configuration = AppConfiguration.fresh(ownerID: "owner-1")
    configuration.integration.meridianDeploymentURL = "https://meridian.example"
    configuration.desiredCapabilities["meridian.search"] = true
    let facts = readyFacts(meridianCredentialsPresent: true, meridianSearchReady: false)
    XCTAssertFalse(CapabilityRegistry(configuration: configuration, facts: facts)
        .snapshot().capabilities["meridian.search"]!.ready)
}

func testSnapshotEncodingIsDeterministicAndContainsNoSecretsOrProviderIDs() throws {
    let snapshot = CapabilityRegistry(configuration: AppConfiguration.fresh(ownerID: "owner-1"), facts: readyFacts()).snapshot()
    let first = try CapabilitySnapshotCodec.encode(snapshot)
    let second = try CapabilitySnapshotCodec.encode(snapshot)
    XCTAssertEqual(first, second)
    let json = String(decoding: first, as: UTF8.self)
    XCTAssertTrue(json.contains("snapshotSchemaVersion"))
    XCTAssertFalse(json.contains("connector-secret"))
    XCTAssertFalse(json.contains("provider-account"))
    XCTAssertFalse(json.contains("https://meridian.example"))
}
```

- [ ] **Step 2: Run `swift test --filter CapabilityRegistryTests` and confirm the missing registry types fail.**

- [ ] **Step 3: Implement the registry with an explicit ordered ID/dependency table.**

Use exactly these IDs: `core.session`, `mac.ui`, `mac.screenOcr`, `mac.files.read`, `mac.files.write`, `mac.shell`, `mac.clipboard.write`, `telegram.send`, `meridian.search`, `meridian.telegram`, `remote.connector`. Resolve `desired` from configuration, `configured` from policy/configuration facts, and `ready` only when desired, configured, all dependencies ready, and the injected readiness fact is true. Use user-safe fixed reasons. `mac.shell` and `mac.files.write` require `.full`; clipboard requires the explicit policy flag; Meridian Search requires a deployment URL, credential-presence fact, compatibility/index readiness fact, and dependencies; Meridian Telegram requires Search; Remote Connector requires the stable injected readiness fact rather than process presence.

- [ ] **Step 4: Implement the Codable snapshot and sorted-key codec.**

Encode `snapshotSchemaVersion: 1`, `configGeneration`, `controlProfile`, `capabilities`, and `policy` with `approvedFileRoots` and `clipboardMutation`. Sort dictionary keys and policy arrays before encoding. Decode and reject any snapshot schema other than 1. Do not encode the integration URL, Keychain item names, account IDs, or facts.

- [ ] **Step 5: Run focused capability tests and all existing Swift tests available in the local toolchain.**

Run: `swift test --filter CapabilityRegistryTests`

Expected: all capability and snapshot tests pass.

- [ ] **Step 6: Commit the registry and tests.**

```bash
git add Sources/MacOrchestrator/CapabilityRegistry.swift Tests/MacOrchestratorTests/CapabilityRegistryTests.swift
git commit -m "feat: add policy-driven capability registry snapshot"
```

### Task 6: Full validation and handoff

**Files:**
- Modify only files already listed above if a test-discovered correction is required.

- [ ] **Step 1: Review the complete diff and run repository secret/path scans.**

Run `git diff origin/main...HEAD --check`, inspect `git diff origin/main...HEAD --stat`, and run the Wave-0 secret/path regex checks from `.github/workflows/ci.yml`. Confirm no `Sources/MacOrchestrator/ProcessSupervisor.swift`, AppDelegate, MenuController, Models, Python, workflow, packaging, or Meridian paths changed.

- [ ] **Step 2: Run the required Swift commands freshly from the final tree.**

Run each command independently and record its exit code and full result:

```bash
swift build
swift build -c release
swift test
```

Also run any documented strict Swift/concurrency variants available in the repository, preserving Wave-0 gate behavior. If local XCTest remains unavailable, verify with an installed Xcode developer directory if present and report the environment limitation rather than weakening tests.

- [ ] **Step 3: Perform the adversarial review against the implementation.**

Check corrupt-primary handling, unsupported schema rejection, backup ordering, generation monotonicity, connector identity preservation, Keychain failure markers, plaintext cleanup behavior, Guided/full policy gates, Meridian dependency/fact gates, snapshot secret exclusion, and test isolation. Add a failing XCTest before correcting any discovered issue.

- [ ] **Step 4: Run final tests and inspect status.**

Run `swift test` and `git status --short --branch`; verify only intentional files are present and the final commit has no secrets or account information.

- [ ] **Step 5: Commit, push, and open a draft PR against `main`.**

After the final verification, stage explicit intended paths, commit with a precise message, push `wave1/config-capability-foundation` to `origin`, and create a draft PR describing the configuration schema, migrations, Keychain strategy, registry/snapshot contract, tests, and deferred integration. Do not merge, tag, release, or modify Meridian.
