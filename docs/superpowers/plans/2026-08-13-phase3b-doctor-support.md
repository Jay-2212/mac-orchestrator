# Phase 3B Doctor and Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable read-only doctor, explicit bounded repairs, preview-first support bundles, and canonical adversarial redaction for the current Mac Orchestrator core.

**Architecture:** Introduce additive diagnostic models, pure check functions, and separately injected read-only fact providers. Keep mutations behind a typed `RepairEngine` and adapters. Make support bundles plan-backed and archive-safe, with one redaction core shared by streaming and bundle paths.

**Tech Stack:** Swift 5.9, SwiftPM macOS 13, Foundation, Security, AppKit, Darwin, XCTest, macOS `codesign`/`launchctl`/`ditto` adapters.

## Global Constraints

- Start and finish on `phase3/doctor-support`; required base is exactly `3cf8e7d43f17524b705b9fe612eebe75a0450571`.
- Do not create nested manual worktrees; preserve Codex isolation and inspect checkout state before each commit/push operation.
- `swift test` may remain environment-blocked by the installed Command Line Tools failing to resolve `XCTest`; record the exact failure and do not change package code to accommodate it.
- Do not modify `ProcessSupervisor.swift`, lifecycle state models, `Configuration.swift`, `ConfigurationStore.swift`, `Migrations.swift`, `KeychainStore.swift`, updater/release/bootstrap machinery, `MenuController.swift`, `AppDelegate.swift`, or `TerminalCommand.swift`.
- Prefer no `LocalActivationProbe.swift` change. If the inventory seam is unavoidable, preserve every existing health, redirect, protocol, session, tools/list, and application-level safe-call semantic and add regression coverage.
- Keychain presence queries must not request `kSecReturnData` and must never use `connectorTokenValue()`.
- Doctor must never call a repair, create configuration/runtime/support directories, migrate, restore, rewrite, increment generations, or mutate permissions.
- Missing or intentionally disabled optional capabilities and future Meridian/Cloudflare/Telegram Assistant systems are `SKIP` or another non-failure state, not automatic `FAIL`.
- No provider failure may abort unrelated checks; raw provider error text, request bodies, secret values, connector URLs, and unnecessary home paths must not enter reports.
- No generic shell-command repair abstraction; lifecycle, port/configuration, LaunchAgent, permissions, and bootstrap handoff are typed adapters.
- Preview must not collect entry contents. Creation must accept only an engine-issued plan, collect only listed logical entries, validate safe archive names, and test extracted archive payloads.
- Use TDD: write each focused failing test, run it to observe the expected failure, implement the smallest behavior, run it green, then refactor while keeping the test green.

---

### Task 1: Establish diagnostic models and deterministic report serialization

**Files:**
- Create: `Sources/MacOrchestrator/DiagnosticModels.swift`
- Create: `Tests/MacOrchestratorTests/DiagnosticModelsTests.swift`

**Interfaces:**
- Produces `DiagnosticStatus`, `RepairActionID`, `RepairActionDescriptor`,
  `DiagnosticResult`, `DiagnosticSummary`, and `DoctorReport` for every later
  task.
- `DoctorReport` exposes `reportSchemaVersion`, `generatedAt`, `results`, and
  `summary`; its encoded form uses sorted keys and ISO-8601 dates.
- `RepairActionID` includes exactly the current bounded identifiers
  `retryMCPServer`, `retryRemoteConnector`, `openAccessibilitySettings`,
  `openScreenRecordingSettings`, `openAutomationSettings`,
  `restoreConfigurationBackup`, `reassignLocalPort`, `repairLaunchAgent`, and
  `rerunVerifiedBootstrap`.

- [ ] **Step 1: Write failing status and result tests**

```swift
func testDiagnosticStatusUsesStableLowercaseWireValues() throws {
    XCTAssertEqual(DiagnosticStatus.pass.rawValue, "pass")
    XCTAssertEqual(DiagnosticStatus.warn.rawValue, "warn")
    XCTAssertEqual(DiagnosticStatus.fail.rawValue, "fail")
    XCTAssertEqual(DiagnosticStatus.skip.rawValue, "skip")
}

func testDiagnosticResultRoundTripsOneBoundedRepair() throws {
    let result = DiagnosticResult(
        id: "config.primary",
        title: "Configuration",
        status: .warn,
        reason: "The primary is malformed; a valid backup is available.",
        repair: RepairActionDescriptor(
            id: .restoreConfigurationBackup,
            title: "Restore configuration backup",
            guidance: "Review and explicitly restore the validated backup."
        )
    )

    let decoded = try JSONDecoder().decode(
        DiagnosticResult.self,
        from: JSONEncoder().encode(result)
    )

    XCTAssertEqual(decoded, result)
}
```

- [ ] **Step 2: Run the focused test to verify the missing contract fails**

Run: `swift test --filter DiagnosticModelsTests/testDiagnosticStatusUsesStableLowercaseWireValues`

Expected: compilation failure because the diagnostic model types do not yet exist. If the local toolchain reports the known XCTest import failure instead, record that exact environment failure and use `swift build` for compile feedback while preserving the test-first ordering.

- [ ] **Step 3: Implement the minimal Codable/Equatable/Sendable models**

Define the enums and structs with `let` fields, stable raw values, optional one-action repair descriptors, and synthesized `Codable`, `Equatable`, and `Sendable` conformances where possible. Make the report initializer compute counts from results in their supplied stable order.

- [ ] **Step 4: Add deterministic report encoding and summary tests**

```swift
func testDoctorReportSummaryAndEncodingAreDeterministic() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let results = [
        DiagnosticResult(id: "z", title: "Z", status: .skip, reason: "not applicable"),
        DiagnosticResult(id: "a", title: "A", status: .pass, reason: "verified"),
        DiagnosticResult(id: "b", title: "B", status: .fail, reason: "missing")
    ]
    let report = DoctorReport(generatedAt: date, results: results)

    XCTAssertEqual(report.summary.pass, 1)
    XCTAssertEqual(report.summary.fail, 1)
    XCTAssertEqual(report.summary.skip, 1)
    XCTAssertEqual(report.summary.warn, 0)
    XCTAssertEqual(report.encodedJSON(), try DoctorReport(generatedAt: date, results: results).encodedJSON())
}
```

- [ ] **Step 5: Run the focused model tests and compile the package**

Run: `swift test --filter DiagnosticModelsTests`

Run: `swift build`

Expected: hosted/XCTest-capable environments pass the tests; local failure remains only the documented XCTest/toolchain limitation. `swift build` must compile the new production file.

- [ ] **Step 6: Commit the model contract**

```bash
git add Sources/MacOrchestrator/DiagnosticModels.swift Tests/MacOrchestratorTests/DiagnosticModelsTests.swift
git commit -m "feat: add diagnostic report contract"
```

### Task 2: Build the canonical shared redactor and preserve streaming behavior

**Files:**
- Create: `Sources/MacOrchestrator/SensitiveDataRedactor.swift`
- Modify: `Sources/MacOrchestrator/StreamingLogRedactor.swift`
- Modify: `Sources/MacOrchestrator/RotatingLog.swift`
- Create: `Tests/MacOrchestratorTests/SensitiveDataRedactorTests.swift`
- Modify: `Tests/MacOrchestratorTests/StreamingLogRedactorTests.swift`

**Interfaces:**
- `SensitiveDataRedactor(exactSecrets: [String], homeDirectory: String?)`
  exposes `redact(_:)`, `redactJSON(_:)`, and `redactedPath(_:)`.
- `StreamingLogRedactor` keeps its existing initializer and `append(_:flush:)`
  API but delegates complete-line redaction to `SensitiveDataRedactor`.
- `RotatingLog.redact(_:)` uses the same primitive for current and rotated log
  files without logging its source values.

- [ ] **Step 1: Write failing adversarial redaction tests**

```swift
func testRedactsOverlappingSecretsAndConnectorURLVariants() {
    let token = "ngrok_2sPlausibleToken_1234567890"
    let connector = "connector-capability-token-abcdefghijklmnopqrstuvwxyz"
    let redactor = SensitiveDataRedactor(
        exactSecrets: ["secret", "secret-long", token, connector],
        homeDirectory: "/Users/synthetic"
    )
    let input = "https://demo.ngrok.app/\(connector)/mcp token=\(token) secret-long"
    let output = redactor.redact(input)

    XCTAssertFalse(output.contains(connector))
    XCTAssertFalse(output.contains(token))
    XCTAssertFalse(output.contains("secret-long"))
    XCTAssertFalse(output.contains("https://demo.ngrok.app/"))
}

func testRedactsSecretNamedJSONFieldsAndNormalizesHomePaths() throws {
    let redactor = SensitiveDataRedactor(
        exactSecrets: ["bot-secret"],
        homeDirectory: "/Users/synthetic"
    )
    let sanitized = try XCTUnwrap(redactor.redactJSON(Data(
        #"{"token":"bot-secret","path":"/Users/synthetic/Library/Logs/x"}"#.utf8
    )))
    let text = String(decoding: sanitized, as: UTF8.self)

    XCTAssertFalse(text.contains("bot-secret"))
    XCTAssertFalse(text.contains("/Users/synthetic"))
    XCTAssertTrue(text.contains("<redacted>"))
    XCTAssertTrue(text.contains("<home>/Library/Logs/x"))
}

func testStreamingRedactionRemainsSafeAcrossSecretAndURLChunkBoundaries() {
    var redactor = StreamingLogRedactor(
        secrets: ["connector-token", "ngrok_2sPlausibleToken_1234567890"]
    )
    _ = redactor.append("prefix https://demo.ngrok.app/connect", flush: false)
    let lines = redactor.append(
        "or-token/mcp and ngrok_2sPlausibleToken_1234567890\n",
        flush: false
    )

    XCTAssertEqual(lines.count, 1)
    XCTAssertFalse(lines[0].contains("connector-token"))
    XCTAssertFalse(lines[0].contains("ngrok_2sPlausibleToken_1234567890"))
    XCTAssertFalse(lines[0].contains("https://demo.ngrok.app/"))
}
```

- [ ] **Step 2: Run redaction tests and confirm the expected missing/weak behavior**

Run: `swift test --filter SensitiveDataRedactorTests`

Run: `swift test --filter StreamingLogRedactorTests`

Expected: the new tests fail before implementation; the pre-existing streaming tests remain the regression target.

- [ ] **Step 3: Implement longest-first exact replacement, URL/path rules, and structured-field redaction**

Sort nonblank exact secrets by descending length. Replace connector URLs as complete credential-bearing values, including token routes in longer lines. Apply a conservative pattern for HTTPS token-bearing `/.../mcp` paths, normalize the injected home prefix and `/Users/<name>` paths, and recursively replace values under case-insensitive fields such as `token`, `authtoken`, `secret`, `password`, `authorization`, `credential`, `connectorURL`, and `capabilityToken`. Preserve nonsecret JSON keys, filenames, categories, statuses, and error classes.

- [ ] **Step 4: Delegate existing streaming and rotating-log paths to the shared primitive**

Keep pending-line buffering and flush behavior unchanged. In `RotatingLog.redact`, construct the shared redactor once per call and rewrite only changed current/rotated files with existing `0600` permissions.

- [ ] **Step 5: Run all redaction regression tests**

Run: `swift test --filter 'SensitiveDataRedactorTests|StreamingLogRedactorTests'`

Run: `swift build`

Expected: every planted secret/path is absent from produced text; existing chunk-boundary tests remain green in an XCTest-capable environment.

- [ ] **Step 6: Commit the shared redactor**

```bash
git add Sources/MacOrchestrator/SensitiveDataRedactor.swift Sources/MacOrchestrator/StreamingLogRedactor.swift Sources/MacOrchestrator/RotatingLog.swift Tests/MacOrchestratorTests/SensitiveDataRedactorTests.swift Tests/MacOrchestratorTests/StreamingLogRedactorTests.swift
git commit -m "feat: share sensitive data redaction across logs"
```

### Task 3: Add read-only fact-provider contracts and deterministic filesystem/Keychain adapters

**Files:**
- Create: `Sources/MacOrchestrator/DiagnosticProviders.swift`
- Create: `Tests/MacOrchestratorTests/DiagnosticProviderTests.swift`

**Interfaces:**
- Define `DiagnosticProviderError` with bounded categories and safe descriptions.
- Define facts for installed release, configuration, Keychain presence,
  permissions, port/listener state, lifecycle, local MCP, remote connector,
  update availability, and disk/filesystem state.
- Define separate protocols such as `ConfigurationDiagnosticProviding`,
  `KeychainPresenceProviding`, `InstalledReleaseFactsProviding`,
  `PermissionFactsProviding`, `PortFactsProviding`,
  `LifecycleFactsProviding`, `LocalMCPDiagnosticProviding`,
  `RemoteConnectorFactsProviding`, `UpdateAvailabilityProviding`, and
  `DiskSpaceProviding`.
- Provide `ReadOnlyConfigurationDiagnosticProvider` and
  `SystemKeychainPresenceProvider`; providers read existing paths only.

- [ ] **Step 1: Write failing tests for nonmutating configuration inspection**

```swift
func testConfigurationProviderDoesNotCreateMissingConfigurationOrDirectory() throws {
    let root = try makeTemporaryDirectory()
    let support = root.appendingPathComponent("Mac Orchestrator", isDirectory: true)
    let provider = ReadOnlyConfigurationDiagnosticProvider(directoryURL: support)

    let facts = try provider.inspect()

    XCTAssertFalse(facts.primary.exists)
    XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
}

func testConfigurationProviderReportsValidBackupWithoutRestoringIt() throws {
    let support = try makeTemporaryDirectory()
    let backup = support.appendingPathComponent("config.json.backup")
    try JSONEncoder().encode(AppConfiguration.fresh(ownerID: "backup-owner")).write(to: backup)
    let provider = ReadOnlyConfigurationDiagnosticProvider(directoryURL: support)

    let facts = try provider.inspect()

    XCTAssertTrue(facts.backup.valid)
    XCTAssertFalse(facts.primary.exists)
    XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path))
}

func testMalformedPrimaryAndInvalidBackupRemainUnchanged() throws {
    let support = try makeTemporaryDirectory()
    let primary = support.appendingPathComponent("config.json")
    let backup = support.appendingPathComponent("config.json.backup")
    let primaryBytes = Data("{malformed".utf8)
    let backupBytes = Data("{\"schemaVersion\":99}".utf8)
    try primaryBytes.write(to: primary)
    try backupBytes.write(to: backup)

    let facts = try ReadOnlyConfigurationDiagnosticProvider(directoryURL: support).inspect()

    XCTAssertFalse(facts.primary.valid)
    XCTAssertFalse(facts.backup.valid)
    XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
    XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
}
```

- [ ] **Step 2: Run focused provider tests and observe the missing types/failure**

Run: `swift test --filter DiagnosticProviderTests`

Expected: failure because the fact models/providers do not yet exist, or the known local XCTest import failure.

- [ ] **Step 3: Implement pure configuration decoding and metadata observation**

Decode with ISO-8601 dates, call `validated()` only in memory, classify missing/readable/malformed/unsupported/invalid/valid states, count `config.json.corrupt*` evidence, inspect modes and symlink flags, and never call `createDirectory`, `save`, `load`, `loadOrCreate`, migration, recovery, or `setAttributes`.

- [ ] **Step 4: Write and run the no-value Keychain query test**

Create a `KeychainPresenceQuerying` fake that records whether a data-return flag was requested and returns `.present`, `.absent`, or `.inaccessible`. Assert that `ReadOnlySystemKeychainPresenceProvider` queries only the selected current-core items, never calls `connectorTokenValue()`, never receives a value, and never queries Meridian Telegram/webhook items.

- [ ] **Step 5: Implement the Security existence-only adapter**

Use `kSecClassGenericPassword`, exact service/account, and `kSecMatchLimitOne`, but omit `kSecReturnData`. Map `errSecSuccess` to `.present`, `errSecItemNotFound` to `.absent`, and all other statuses to `.inaccessible` without including status values or credentials in the fact.

- [ ] **Step 6: Add deterministic provider fakes for remaining fact categories**

Define value types with no raw credentials or request bodies: `CodeSignFacts`, `RuntimeFacts`, `ConfigurationDiagnosticFacts`, `PermissionFacts`, `PortFacts`, `LifecycleFacts`, `LocalMCPFacts`, `RemoteConnectorFacts`, `DiskSpaceFacts`, and `UpdateAvailabilityFacts`. Include expected/exposed MCP tool and capability-group sets, ownership markers, PID-reuse evidence, and safe archive metadata only.

- [ ] **Step 7: Compile and commit provider contracts**

Run: `swift build`

```bash
git add Sources/MacOrchestrator/DiagnosticProviders.swift Tests/MacOrchestratorTests/DiagnosticProviderTests.swift
git commit -m "feat: add read-only diagnostic fact providers"
```

### Task 4: Reuse canonical local activation and add live current-core probes

**Files:**
- Create: `Sources/MacOrchestrator/DiagnosticLiveProviders.swift`
- Modify only if unavoidable: `Sources/MacOrchestrator/LocalActivationProbe.swift`
- Modify: `Tests/MacOrchestratorTests/LocalActivationProbeTests.swift`
- Create: `Tests/MacOrchestratorTests/DiagnosticLiveProviderTests.swift`

**Interfaces:**
- `LocalActivationProbeAdapter` consumes the existing probe through a typed
  protocol and maps its typed failure categories to liveness/readiness facts.
- `CurrentCoreMCPExpectationProvider` maps only currently shipped core groups
  and does not invent Meridian/Cloudflare/Telegram Assistant tooling.
- Live adapters inspect default support/runtime paths, helper bundle facts,
  LaunchAgent state, owned-process markers, local ports, ngrok Agent API, and
  disk/symlink state without mutation.

- [ ] **Step 1: Add a failing adapter test proving canonical activation is the source of readiness truth**

Use a fake `LocalActivationProbeRunning` that records the port, token use, and `requiresInteractiveUI` value and returns success/failure. Assert that the adapter reports readiness only from the canonical probe result, does not turn a Python PID into readiness, and does not put the token in returned facts.

- [ ] **Step 2: Add an inventory regression test**

If existing `LocalActivationProbe` cannot expose the parsed tools list, add the smallest internal `runDetailed` seam that runs the same sequence once and returns only sanitized tool names and safe-call success. Add tests that preserve canonical health status/body, no redirect rejection, protocol version, session header, tools/list, and `get_session_state` application-level validation. Existing tests must remain unchanged in their behavior.

- [ ] **Step 3: Implement the adapter without weakening activation**

Use `KeychainStore.value(for: .connectorToken)` only inside the authenticated probe adapter, never `connectorTokenValue()`. Map missing token to an unavailable prerequisite and never create one. Preserve every existing `LocalActivationProbe` error boundary and discard all response bodies/messages before constructing facts.

- [ ] **Step 4: Implement current-core expected tool/group mapping**

Use the shipped core inventory (`describe`, `get_capabilities`, `get_session_state`, current UI/screen/file/shell/clipboard tools) only when the corresponding current capability is desired. Treat optional disabled groups as `SKIP`, and treat future Meridian/Cloudflare/Telegram Assistant groups as `SKIP` without contacting them.

- [ ] **Step 5: Implement live read-only providers**

Use injected command/process/HTTP runners. Inspect helper architecture/version/bundle ID/ad-hoc code-sign validity, runtime marker/Python architecture/version/payload presence, receipt/integrity evidence, exact LaunchAgent label/path and `launchctl print`, duplicate helper instances, owned-process records, safe PID command markers, configured port listeners, ngrok binary/config/auth presence, `/api/endpoints`, and disk/symlink facts. Do not terminate processes, create directories, or expose URL/token values.

- [ ] **Step 6: Run focused activation/provider tests and compile**

Run: `swift test --filter 'LocalActivationProbeTests|DiagnosticLiveProviderTests'`

Run: `swift build`

Expected: existing activation semantics remain green where XCTest is available; local XCTest limitations remain explicitly recorded.

- [ ] **Step 7: Commit the canonical probe adapter and live facts**

```bash
git add Sources/MacOrchestrator/DiagnosticLiveProviders.swift Sources/MacOrchestrator/LocalActivationProbe.swift Tests/MacOrchestratorTests/LocalActivationProbeTests.swift Tests/MacOrchestratorTests/DiagnosticLiveProviderTests.swift
git commit -m "feat: adapt canonical activation facts for doctor"
```

### Task 5: Implement pure checks and the read-only DoctorEngine

**Files:**
- Create: `Sources/MacOrchestrator/DiagnosticChecks.swift`
- Create: `Sources/MacOrchestrator/DoctorEngine.swift`
- Create: `Tests/MacOrchestratorTests/DoctorEngineTests.swift`

**Interfaces:**
- `DiagnosticChecks` exposes pure functions for configuration, installation,
  trust, permissions, Keychain, port, local MCP, lifecycle, remote, update,
  disk/filesystem, and future-capability checks.
- `DoctorDependencies` holds the injected providers, thresholds, and clock.
- `DoctorEngine(dependencies:)` exposes `func run() async -> DoctorReport` and
  performs no repair or mutation.

- [ ] **Step 1: Write failing tests for all four statuses and provider isolation**

```swift
func testDoctorContinuesWhenOneProviderFails() async {
    let dependencies = DoctorDependencies.fixture(
        configurationError: .permissionDenied,
        installed: .healthy,
        update: .unavailable
    )

    let report = await DoctorEngine(dependencies: dependencies).run()

    XCTAssertEqual(report.result(withID: "configuration.read")?.status, .fail)
    XCTAssertEqual(report.result(withID: "installation.helper")?.status, .pass)
    XCTAssertEqual(report.result(withID: "update.availability")?.status, .skip)
}

func testDisabledRemoteAndFutureCapabilitiesAreSkipped() async {
    let report = await DoctorEngine(dependencies: .fixture(remoteDesired: false)).run()

    XCTAssertEqual(report.result(withID: "remote.ngrok")?.status, .skip)
    XCTAssertEqual(report.result(withID: "capability.meridian")?.status, .skip)
}
```

- [ ] **Step 2: Add failing tests for required diagnostic branches**

Cover missing/corrupt/unsupported config, valid/unusable backup, generation and migration markers, permissions and symlinks, missing runtime and structural version mismatch, ad-hoc signing truth, managed requester permission failures, locked/non-console sessions, malformed/occupied/owned ports, MCP liveness/readiness/inventory mismatch, missing/malformed/stale LaunchAgent and PID reuse, ngrok missing/invalid/current endpoint unavailable, low-disk threshold boundaries, and unavailable update provider.

- [ ] **Step 3: Run the focused Doctor tests to verify red state**

Run: `swift test --filter DoctorEngineTests`

Expected: missing engine/check types or the known XCTest import failure; do not treat static compilation as passing tests.

- [ ] **Step 4: Implement pure check functions with stable IDs and bounded repairs**

Use stable IDs such as `configuration.read`, `configuration.backup`, `configuration.recovery`, `installation.helper`, `installation.runtime`, `installation.integrity`, `installation.version-match`, `trust.codesign`, `permissions.requester`, `keychain.connector`, `port.selected`, `mcp.liveness`, `mcp.readiness`, `mcp.inventory`, `lifecycle.launch-agent`, `lifecycle.process-ownership`, `remote.ngrok`, `remote.endpoint`, `update.availability`, `disk.free-space`, and `filesystem.critical-paths`. Each check creates at most one `RepairActionDescriptor` and never invokes an adapter.

- [ ] **Step 5: Implement fault-isolated DoctorEngine orchestration**

Gather configuration first, pass only available nonsecret configuration facts to dependent providers, run independent providers even when one throws, map provider errors to fixed safe reasons, sort results by stable ID, inject the clock timestamp, and construct the deterministic report. Confirm the engine has no `RepairEngine` reference and no mutating filesystem/Keychain calls.

- [ ] **Step 6: Add mutation-free negative-control tests**

Snapshot temporary directory contents, configuration bytes, generation, Keychain fake calls, process-runner invocations, and repair-spy invocations before `run()`. Assert every snapshot is unchanged, no connector token was created, no archive exists, and the repair spy received zero calls.

- [ ] **Step 7: Run Doctor tests and compile**

Run: `swift test --filter DoctorEngineTests`

Run: `swift build`

- [ ] **Step 8: Commit the read-only engine**

```bash
git add Sources/MacOrchestrator/DiagnosticChecks.swift Sources/MacOrchestrator/DoctorEngine.swift Tests/MacOrchestratorTests/DoctorEngineTests.swift
git commit -m "feat: add read-only doctor engine"
```

### Task 6: Implement explicit bounded repairs and ownership guards

**Files:**
- Create: `Sources/MacOrchestrator/RepairEngine.swift`
- Create: `Tests/MacOrchestratorTests/RepairEngineTests.swift`

**Interfaces:**
- `RepairOutcomeStatus` and `RepairOutcome` represent `repaired`, `notNeeded`,
  `refused`, `failed`, and `requiresUserAction`.
- `RepairEngine(dependencies:)` exposes `func execute(_ action: RepairActionID) async -> RepairOutcome`.
- Typed adapters include `LifecycleRetrying`, `PermissionSettingsOpening`,
  `ConfigurationBackupRestoring`, `LocalPortReassigning`,
  `LaunchAgentRepairing`, and `VerifiedBootstrapHandingOff`.

- [ ] **Step 1: Write failing repair tests**

Test that each action routes only to its matching adapter, Doctor never calls the engine, missing ownership markers return `refused`, permission actions return `requiresUserAction`, invalid backup returns `refused`, port reassignment chooses a free candidate and records client reconfiguration, and the occupying unrelated process is never terminated.

- [ ] **Step 2: Run the focused repair tests and verify red state**

Run: `swift test --filter RepairEngineTests`

Expected: missing repair types or the known XCTest import failure.

- [ ] **Step 3: Implement typed outcome and adapter dispatch**

Use a fixed switch over `RepairActionID`; do not accept arbitrary executable paths, shell strings, URLs, or user-provided commands. Return bounded reasons that contain no provider raw messages or secrets.

- [ ] **Step 4: Implement safe default adapter contracts**

Port reassignment must validate the candidate through an injected occupancy query and update one canonical configuration property. Backup restore must prevalidate and preserve the bad primary. LaunchAgent repair must require exact label/path and contract ownership before writing/reloading. Bootstrap recovery must return verified handoff guidance only. Permission repair opens exact panes and never edits TCC databases.

- [ ] **Step 5: Run repair tests and compile**

Run: `swift test --filter RepairEngineTests`

Run: `swift build`

- [ ] **Step 6: Commit explicit repairs**

```bash
git add Sources/MacOrchestrator/RepairEngine.swift Tests/MacOrchestratorTests/RepairEngineTests.swift
git commit -m "feat: add bounded doctor repairs"
```

### Task 7: Implement plan-backed safe support bundles and extracted-archive tests

**Files:**
- Create: `Sources/MacOrchestrator/SupportBundle.swift`
- Create: `Tests/MacOrchestratorTests/SupportBundleTests.swift`

**Interfaces:**
- `SupportBundlePlan`, `SupportBundleEntryPlan`, and
  `SupportBundleRedactionSummary` are Codable/Equatable/Sendable.
- `SupportBundleSourceDescribing` provides logical metadata and approximate
  size without collecting content; `SupportBundleSourceCollecting` collects
  only a requested logical ID during creation.
- `SupportBundleArchiveWriting` writes validated entries; the production
  writer uses a temporary staging directory and macOS archive tooling.
- `SupportBundleEngine.preview()` returns a plan and performs no collection;
  `create(plan:to:)` accepts only a plan previously issued by that engine.

- [ ] **Step 1: Write failing preview and exact-plan tests**

```swift
func testPreviewDescribesEntriesWithoutCollectingOrCreatingArchive() throws {
    let source = RecordingBundleSource(entries: [.doctorReport, .logs])
    let engine = SupportBundleEngine(sources: [source], clock: FixedClock())

    let plan = engine.preview()

    XCTAssertEqual(source.collectCalls, [])
    XCTAssertEqual(plan.entries.map(\.logicalID), ["doctor-report", "logs"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: engine.previewArchiveURL.path))
}

func testCreationUsesExactlyTheApprovedPlan() throws {
    let source = RecordingBundleSource(entries: [.doctorReport, .logs, .config])
    let engine = SupportBundleEngine(sources: [source], clock: FixedClock())
    let plan = engine.preview()
    let selected = plan.selecting(logicalIDs: ["doctor-report"])
    let archive = try engine.create(plan: selected, to: temporaryArchiveURL())

    XCTAssertEqual(source.collectCalls, ["doctor-report"])
    XCTAssertEqual(try extractEntryNames(from: archive), ["doctor-report.json"])
}
```

- [ ] **Step 2: Add failing archive safety and adversarial fixture tests**

Cover `../escape`, absolute paths, duplicate names, symlink sources, source roots outside approved locations, altered/unknown plan identifiers, and malicious filenames. Create a real archive, extract it, decode every file, and assert fake connector tokens, ngrok credentials, token routes, structured secret values, and `/Users/synthetic` paths are absent from every extracted filename and payload.

- [ ] **Step 3: Run focused support tests and observe red state**

Run: `swift test --filter SupportBundleTests`

Expected: missing support types or the known XCTest import failure.

- [ ] **Step 4: Implement descriptors and preview without content collection**

Store generated plans by stable plan identifier and exact descriptor set. Include reasons, categories, expected redaction, approximate sizes, excluded sensitive categories, and a redaction summary. Preview may inspect metadata but must not open arbitrary log/document contents.

- [ ] **Step 5: Implement plan validation and redacted selected-entry collection**

Reject plans not issued by this engine or with altered inclusion metadata. For each selected logical ID, validate the canonical safe archive name, collect only that entry, redact text/JSON/path content through `SensitiveDataRedactor`, reject symlink/unsafe sources, and reject duplicate names before writing anything.

- [ ] **Step 6: Implement the production archive writer and extraction helper tests**

Stage entries under a newly created private temporary directory only during explicit creation, write `0600` files, invoke `/usr/bin/ditto` with the validated staging root, and remove the staging directory after success/failure. Tests must extract the archive and inspect actual entry names and payloads; compressed-byte scans are supplemental only.

- [ ] **Step 7: Run support tests and compile**

Run: `swift test --filter SupportBundleTests`

Run: `swift build`

- [ ] **Step 8: Commit support bundles**

```bash
git add Sources/MacOrchestrator/SupportBundle.swift Tests/MacOrchestratorTests/SupportBundleTests.swift
git commit -m "feat: add plan-backed support bundles"
```

### Task 8: Integrate test fixtures, perform review, and prepare exact-SHA verification

**Files:**
- Modify only new Phase 3B test helpers or the focused new test files as needed.
- Do not modify prohibited Phase 2/lifecycle/integration files.

**Interfaces:**
- All new test fixtures implement the provider and adapter protocols from
  Tasks 1–7 without accessing real Application Support, real Keychain, real
  TCC, or live provider accounts.

- [ ] **Step 1: Run the complete deterministic test command**

Run: `swift test`

Record the exact exit code and full XCTest/toolchain error if `XCTest` remains unavailable. Do not report test success from compilation or static inspection.

- [ ] **Step 2: Run required builds and focused static checks**

Run: `swift build`

Run: `swift build -c release`

Run: `git diff --check`

Run a changed-file scope scan confirming no prohibited files changed and no future-provider/network integrations were introduced.

- [ ] **Step 3: Review security and semantic negative controls**

Verify Doctor has no repair invocation, no `connectorTokenValue()` call, no `kSecReturnData` in presence queries, no configuration writes, no provider calls for future systems, no process termination in diagnosis, no raw URL/token/body/path in report or bundle sources, and no generic repair shell execution.

- [ ] **Step 4: Inspect the final diff and each commit**

Read every changed production/test file, compare against the design and guardrails, verify stable IDs and status semantics, check archive extraction tests, and run `git status --short --branch` plus `git rev-parse HEAD`.

- [ ] **Step 5: Push only the exact requested branch**

```bash
git push origin phase3/doctor-support
```

After pushing, refresh remote refs and verify `git rev-parse origin/phase3/doctor-support` equals the final local SHA. If hosted CI is available, obtain the run/check evidence for that exact SHA; otherwise report hosted evidence as unavailable.

- [ ] **Step 6: Confirm clean final worktree and report bounded evidence**

Run: `git status --short --branch`

Expected: clean `phase3/doctor-support`; report the exact starting SHA, final SHA, commits, changed files, executed test/build outcomes, local XCTest limitation, hosted exact-SHA evidence, manual TCC/Gatekeeper/ngrok evidence still required, deferred integration seams, pushed-branch state, and no merge/tag/release claim.
