# Remote Credential and State Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Phase 4B nonsecret remote state, minimal Keychain transaction seams, one-way connector-token rotation, and rollback-aware ngrok candidate replacement.

**Architecture:** Keep remote operational state in a strict standalone `RemoteConnectorStateV1` journal under Application Support. Use compare-and-replace for the one canonical connector token and injected lifecycle protocols for all validation. Keep ngrok replacement separate so a candidate is validated through `NGROK_AUTHTOKEN` before normal commit, with an explicit local fail-closed mode for a compromised old provider credential.

**Tech Stack:** Swift 5.9, macOS 13+, Foundation, Security, Darwin POSIX file primitives, SwiftPM, XCTest.

## Global Constraints

- `AppConfiguration` remains schema v1; do not modify `Configuration.swift` or `ConfigurationStore.swift`.
- Do not modify `ProcessSupervisor.swift`, `LifecycleState.swift`, `LocalActivationProbe.swift`, `NgrokSupport.swift`, `CapabilityReadinessCoordinator.swift`, `CapabilityRegistry.swift`, `TerminalCommand.swift`, `MenuController.swift`, `Diagnostic*.swift`, `RepairEngine.swift`, updater/uninstaller/release files, or Meridian.
- Remote state may contain only nonsecret operational facts; never persist connector tokens, ngrok authtokens, credential-bearing URLs, MCP bodies, or unrelated paths.
- Connector rotation never automatically restores the old capability token after Keychain cutover.
- Ngrok replacement never performs provider-side token deletion, account mutation, endpoint deletion, or resource cleanup.
- Use deterministic injected fakes and no live credential/provider operations.
- Run `swift test` and `git diff --check`; report the local XCTest environment limitation honestly if it remains.

---

### Task 1: State and Keychain test contracts

**Files:**
- Modify: `Tests/MacOrchestratorTests/KeychainStoreTests.swift`
- Create: `Tests/MacOrchestratorTests/RemoteConnectorStateTests.swift`

**Interfaces:**
- Tests define the desired `SecureRandomByteGenerating`, `RemoteConnectorStateV1`, `RemoteConnectorStateStore`, and explicit Keychain replacement behavior before production code exists.

- [ ] **Step 1: Add failing deterministic Keychain tests.** Cover 32-byte lowercase-hex generation without persistence, compare-and-replace, mismatch rejection, and ngrok candidate replacement.

  The first test should express the complete seam:

  ```swift
  func testGenerateConnectorTokenUsesExactly32InjectedRandomBytesWithoutPersisting() throws {
      let fake = FakeKeychainClient()
      let store = KeychainStore(client: fake, random: FixedRandomBytes(byte: 0xab))

      let token = try store.generateConnectorToken()

      XCTAssertEqual(token, String(repeating: "ab", count: 32))
      XCTAssertNil(try store.value(for: .connectorToken))
      XCTAssertEqual(fake.createCalls, [])
  }
  ```

- [ ] **Step 2: Add failing state-store tests.** Cover `loadOrCreate`, atomic round-trip, `0700` directory/`0600` file modes, malformed/unknown/unsupported schema rejection, symlinked directory/file rejection, strict origin validation, and credential/handoff generation regression rejection.

  The initial state contract should be explicit:

  ```swift
  func testLoadOrCreateWritesOnlyNonsecretVersionedState() throws {
      let directory = try makeTemporaryDirectory()
      let store = RemoteConnectorStateStore(directoryURL: directory)

      let state = try store.loadOrCreate(provider: .ngrok)

      XCTAssertEqual(state.schemaVersion, 1)
      XCTAssertEqual(state.connectorCredentialGeneration, 0)
      XCTAssertFalse(try String(contentsOf: store.stateURL).contains("token"))
  }
  ```

- [ ] **Step 3: Run the dedicated tests.**

  Run: `swift test --filter 'KeychainStoreTests|RemoteConnectorStateTests'`

  Expected: compile/test failure because the new production types and APIs do not yet exist; no unrelated source changes should be required.

### Task 2: Implement Keychain seams

**Files:**
- Modify: `Sources/MacOrchestrator/KeychainStore.swift`
- Test: `Tests/MacOrchestratorTests/KeychainStoreTests.swift`

**Interfaces:**
- Produce `SecureRandomByteGenerating`, `SystemSecureRandomByteGenerator`, `KeychainStore.generateConnectorToken()`, `KeychainStore.replaceConnectorToken(expectedCurrent:with:)`, and `KeychainStore.replaceNgrokAuthtoken(expectedCurrent:with:)`.

- [ ] **Step 1: Add only the random-generator protocol and fixed safe Keychain error cases needed by the red tests.**

  Use this production seam, with no token-bearing error payload:

  ```swift
  protocol SecureRandomByteGenerating: Sendable {
      func randomBytes(count: Int) throws -> [UInt8]
  }

  extension KeychainStoreError {
      // Add only fixed cases such as invalidConnectorToken and concurrentModification.
  }
  ```

- [ ] **Step 2: Implement the system generator with `SecRandomCopyBytes` and lowercase hexadecimal encoding of exactly 32 bytes.**

- [ ] **Step 3: Implement connector compare-and-replace using one canonical Keychain item and a read-back expected-value check.** Reject empty/invalid new connector values and concurrent changes without including either value in the error.

  The required ordering is:

  ```swift
  func replaceConnectorToken(expectedCurrent: String, with newValue: String) throws {
      guard Self.isConnectorToken(newValue) else { throw KeychainStoreError.invalidConnectorToken }
      guard try value(for: .connectorToken) == expectedCurrent else {
          throw KeychainStoreError.concurrentModification
      }
      try client.update(value: newValue, service: KeychainItem.connectorToken.service,
                        account: KeychainItem.connectorToken.account)
  }
  ```

- [ ] **Step 4: Implement explicit ngrok compare-and-replace/create semantics without changing generic named-item behavior.**

- [ ] **Step 5: Run the Keychain tests and then `swift build`.** Expected: Keychain tests pass under XCTest-capable tooling; local `swift build` remains the compile gate if Command Line Tools cannot import XCTest.

### Task 3: Implement strict remote state model/store

**Files:**
- Create: `Sources/MacOrchestrator/RemoteConnectorState.swift`
- Create: `Sources/MacOrchestrator/RemoteConnectorStateStore.swift`
- Test: `Tests/MacOrchestratorTests/RemoteConnectorStateTests.swift`

**Interfaces:**
- Produce `RemoteConnectorProvider`, `RemoteResultClassification`, `RemoteConnectorRecoveryPhase`, `RemotePublicOrigin`, `RemoteConnectorStateV1`, `RemoteConnectorStateStoreError`, and `RemoteConnectorStateStore` with `load()`, `loadOrCreate(provider:)`, `save(_:)`, and `update(_:)`.

- [ ] **Step 1: Add model validation tests for exact schema, unknown keys, provider, phase/pending-generation invariants, public origin restrictions, and handoff/generation monotonicity.**

  Include a credential-bearing URL rejection test:

  ```swift
  func testPublicOriginRejectsCredentialBearingConnectorURL() {
      XCTAssertThrowsError(try RemotePublicOrigin("https://secret@example.ngrok.app/abc/mcp"))
  }
  ```

- [ ] **Step 2: Implement the nonsecret model with custom Codable decoding that rejects unknown fields.** No `URL`, token, credential, arbitrary JSON, or request/response fields may be present.

  The model’s decoder must check all keys before decoding values:

  ```swift
  let container = try decoder.container(keyedBy: CodingKeys.self)
  let known = Set(CodingKeys.allCases.map(\.stringValue))
  guard Set(container.allKeys.map(\.stringValue)).isSubset(of: known) else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown state field"))
  }
  ```

- [ ] **Step 3: Implement the store’s default Application Support path and strict path validation.** Reject symlinked ancestors/files, non-directory ancestors, non-owned paths, wrong file types, and unsafe permissions.

- [ ] **Step 4: Implement exclusive private temporary-file creation, complete write, `fsync`, atomic same-directory rename, directory `fsync`, and cleanup.** Use no token-bearing temporary file or rollback copy.

  The write path must use same-directory descriptors and exclusive creation:

  ```swift
  let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  let temporaryFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  // write all encoded state bytes, fsync(temporaryFD), close, renameat(directoryFD, temporaryName, directoryFD, stateName)
  // fsync(directoryFD), then close(directoryFD)
  ```

- [ ] **Step 5: Implement load/save/update and reject malformed, unsupported, provider-changing, or generation-regressing state.**

- [ ] **Step 6: Run the dedicated state tests and `swift build`; keep the red/green evidence in the task log.**

### Task 4: Connector rotation test contract

**Files:**
- Create: `Tests/MacOrchestratorTests/RemoteCredentialTransactionTests.swift`

**Interfaces:**
- Tests define fake Keychain storage and fake `ConnectorCredentialRotationHooks` for prerequisite, restart, positive local, old-local-negative, remote reconciliation, positive remote, and old-remote-negative phases.

- [ ] **Step 1: Add failing tests for candidate token shape, successful generation advance exactly once, and positive/negative hook order.** Assert the old token appears only in the two negative hook arguments.

  The fake hook records only phase names and receives secrets in memory:

  ```swift
  func testSuccessfulRotationAdvancesGenerationOnceAndScopesOldTokenToNegativeHooks() throws {
      let result = try makeTransaction(oldToken: "old-token").execute()

      XCTAssertEqual(result.generation, 1)
      XCTAssertEqual(fakeHooks.oldLocalTokens, ["old-token"])
      XCTAssertEqual(fakeHooks.oldRemoteTokens, ["old-token"])
      XCTAssertEqual(fakeHooks.newTokenUses.count, 4)
  }
  ```

- [ ] **Step 2: Add failing tests for pre-cutover failure, cutover failure, post-cutover validation failure, final-state persistence failure, and state recovery phase.** Assert the old token remains only before cutover and the new token remains canonical after cutover; no error/result contains either value.

  Each failure test should inspect the fake Keychain value and safe error text:

  ```swift
  XCTAssertThrowsError(try transaction.execute()) { error in
      XCTAssertFalse(String(describing: error).contains("old-token"))
      XCTAssertFalse(String(describing: error).contains("new-token"))
  }
  XCTAssertEqual(try keychain.value(for: .connectorToken), expectedCanonicalValue)
  ```

- [ ] **Step 3: Run the focused rotation tests.** Expected: compile/test failure because the transaction engine does not yet exist.

### Task 5: Implement connector rotation

**Files:**
- Create: `Sources/MacOrchestrator/RemoteCredentialTransaction.swift`
- Test: `Tests/MacOrchestratorTests/RemoteCredentialTransactionTests.swift`

**Interfaces:**
- Produce `ConnectorCredentialRotationHooks`, `RemoteConnectorProbe`, `ConnectorCredentialRotationError`, `ConnectorCredentialRotationReceipt`, and `ConnectorCredentialRotationTransaction.execute()`.

- [ ] **Step 1: Implement safe stage/phase enums and error mapping that discards underlying provider/keychain descriptions.**

  Map every hook failure to a fixed category:

  ```swift
  enum ConnectorCredentialRotationError: Error, Equatable, LocalizedError, Sendable {
      case prerequisitesFailed
      case stateUnavailable
      case tokenGenerationFailed
      case cutoverFailed
      case validationFailed(ConnectorRotationPhase)
      case statePersistenceFailed(ConnectorRotationPhase)
      case interruptedRecoveryRequired
  }
  ```

- [ ] **Step 2: Implement preflight, state pending marker, fresh in-memory token generation, and compare-and-replace cutover.**

  Persist the marker before calling the irreversible Keychain API:

  ```swift
  var pending = try stateStore.loadOrCreate(provider: .ngrok)
  let nextGeneration = pending.connectorCredentialGeneration + 1
  pending.pendingConnectorCredentialGeneration = nextGeneration
  pending.recoveryPhase = .cutoverPendingValidation
  try stateStore.save(pending)
  try keychain.replaceConnectorToken(expectedCurrent: oldToken, with: newToken)
  ```

- [ ] **Step 3: Implement new-token local/remote validation and bounded old-token negative validation in the specified order.** Release the old-token local variable on every exit path.

  Use a `defer` scope so all errors release the transaction-local old value:

  ```swift
  var oldToken: String? = try keychain.value(for: .connectorToken)
  defer { oldToken = nil }
  try hooks.validateOldLocalRouteRejects(oldToken: oldToken!)
  try hooks.validateOldRemoteRouteRejects(oldToken: oldToken!)
  oldToken = nil
  ```

- [ ] **Step 4: Persist stable ready state only after all validation succeeds.** On post-cutover failure, persist degraded/new-generation state best-effort and never invoke a rollback operation.

- [ ] **Step 5: Run focused rotation tests and `swift build`.**

### Task 6: Ngrok candidate replacement test contract and implementation

**Files:**
- Modify: `Tests/MacOrchestratorTests/RemoteCredentialTransactionTests.swift`
- Modify: `Sources/MacOrchestrator/RemoteCredentialTransaction.swift`

**Interfaces:**
- Produce `NgrokCredentialFailurePolicy`, `NgrokCredentialCandidateValidationHooks`, `NgrokCredentialReplacementError`, `NgrokCredentialReplacementReceipt`, and `NgrokCredentialReplacementTransaction.execute(candidate:)`.

- [ ] **Step 1: Add failing tests for delayed commit, endpoint/readiness validation, normal failure preserving old Keychain value, normal repair hook invocation, compromised-old failure never restoring/using old value, and candidate/old secret exclusion from errors/results.**

  The commit ordering must be observable:

  ```swift
  XCTAssertEqual(fakeKeychain.value(for: .ngrokAuthtoken), "old-authtoken")
  XCTAssertEqual(fakeHooks.events, [.launchCandidate, .reconcileEndpoint, .validateReadiness])
  try transaction.execute(candidate: "candidate-authtoken")
  XCTAssertEqual(fakeKeychain.value(for: .ngrokAuthtoken), "candidate-authtoken")
  ```

- [ ] **Step 2: Add a compile-time/protocol test showing only candidate launch, endpoint reconciliation, readiness, and local prior-session restoration hooks exist; no provider-destructive method is expressible.**

- [ ] **Step 3: Implement candidate-only in-memory lifetime, validation-before-commit, normal repair behavior, and compromised-old local Keychain clearing without provider-side operations.**

  The policy branch is explicit and local-only:

  ```swift
  do {
      try hooks.launchCandidateSession(using: candidate)
      try hooks.reconcileCandidateEndpoint()
      let probe = try hooks.validateAuthenticatedRemoteReadiness()
      try keychain.replaceNgrokAuthtoken(expectedCurrent: oldValue, with: candidate)
      return NgrokCredentialReplacementReceipt(probe: probe)
  } catch {
      if failurePolicy == .preserveExistingCredential {
          try? hooks.restorePriorProviderSession()
      } else {
          try keychain.delete(.ngrokAuthtoken)
      }
      throw safeError(for: phase)
  }
  ```

- [ ] **Step 4: Run focused ngrok tests and `swift build`.**

### Task 7: Adversarial review and final verification

**Files:**
- Modify only the Phase 4B source/tests if a review finding requires a fix.

- [ ] **Step 1: Search the diff for secret-bearing state/error/result fields and token-bearing strings.**

  Run: `rg -n "token|authtoken|credential|connectorURL|requestBody|responseBody|write\(.*token|localizedDescription" Sources/MacOrchestrator/KeychainStore.swift Sources/MacOrchestrator/RemoteConnectorState.swift Sources/MacOrchestrator/RemoteConnectorStateStore.swift Sources/MacOrchestrator/RemoteCredentialTransaction.swift Tests/MacOrchestratorTests/KeychainStoreTests.swift Tests/MacOrchestratorTests/RemoteConnectorStateTests.swift Tests/MacOrchestratorTests/RemoteCredentialTransactionTests.swift`

- [ ] **Step 2: Verify no state or Keychain transaction path creates plaintext credential files, no connector rollback API exists, and no provider-destructive ngrok API is in the hook protocol.**

- [ ] **Step 3: Run `swift test` from the exact worktree and capture the complete result.** If local XCTest remains unavailable, report that exact environment failure and retain `swift build` evidence.

- [ ] **Step 4: Run `git diff --check` and inspect `git diff --stat`/`git diff --name-only` against the prohibited-file list.**

- [ ] **Step 5: Dispatch a final Luna code review against the exact starting SHA and review the findings before committing.**

- [ ] **Step 6: Commit the Phase 4B implementation and push `phase4/credential-recovery`; do not merge, tag, release, or touch Meridian.**
