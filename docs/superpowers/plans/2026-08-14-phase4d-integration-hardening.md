# Phase 4D Integration, Hardening, and Hosted Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the reviewed Phase 4A/4B/4C streams and harden Mac Orchestrator until remote readiness is an authenticated MCP fact, recovery is forward-only, and hosted CI passes on the exact final candidate SHA.

**Architecture:** Keep `LifecycleStateMachine` authoritative. Put one strict ngrok adapter/reconciler underneath ProcessSupervisor, one authenticated remote probe beside the existing local probe, and one nonsecret state identity model beneath both Doctor and explicit client handoff. Add injectable network and transaction seams without creating a second lifecycle implementation or restarting Python when only live remote readiness changes.

**Tech Stack:** Swift 5 package on macOS 13+, AppKit, Foundation URL loading, Network.framework `NWPathMonitor`, Security Keychain APIs, XCTest, Python 3.13/uv behavioral checks, GitHub Actions on `macos-14`.

## Global Constraints

- Start from exactly `584259c44370d7d83f3a2764c94518b862a3c4ff`; do not silently rebase onto later work.
- Integrate reviewed heads in order: 4A `65eaf47a7191d68265ad79cc4e0fb9f4055b7448`, 4B `619036194f663544242573e4c8319dbb37b5ec58`, 4C `6ec6c416b3666bf5c2d82473b1a8f3262c6712fe`.
- Define `RemoteConnectorProvider` exactly once and keep only `.ngrok`.
- Agent API addresses are loopback-only; public endpoint values are canonical HTTPS origins; Mac Orchestrator alone appends the credential path.
- Remote readiness requires owned/current ngrok, usable Agent API, exactly one current HTTPS endpoint, local MCP readiness, current generations, and authenticated initialize/session/initialized/tools-list/safe-call success.
- Service readiness and client handoff are independent; a successful probe or rotation never records a handoff.
- Connector rotation is serialized, async, forward-only, has no dual-token grace period, and never restores an old connector token after Keychain cutover.
- Candidate ngrok credentials are hidden input and candidate process environment only until validation succeeds.
- Doctor is read-only; current auth/path rejection recommends reconciliation/retry before deliberate credential rotation; a 404 never proves stale client state.
- Do not create a second lifecycle state machine, block the MainActor with semaphores, spin a run loop to await async work, or use UI/private APIs to rewrite clients.
- Do not modify Meridian, provider-side resources, Cloudflare connectors, updater schema migration, release tags, or public releases.
- Ordinary status, Doctor, logs, support bundles, process arguments, and CI output must not contain connector tokens, credential-bearing URLs, ngrok authtokens, content, tool arguments, or user paths.
- Hosted CI is the authoritative XCTest gate; local Command Line Tools inability to resolve XCTest must remain an explicit limitation.

---

### Task 1: Integrate reviewed streams without changing provenance

**Files:**
- Git history only; no source files are edited in this task.
- Inspect: all files changed by the three reviewed stream ranges.

**Interfaces:**
- Consumes: exact canonical base and verified stream heads.
- Produces: integration branch containing the reviewed 4A → 4B → 4C commits, with conflicts isolated for the next tasks.

- [ ] **Step 1: Verify the integration branch and stream refs**

```bash
test "$(git rev-parse HEAD)" = "584259c44370d7d83f3a2764c94518b862a3c4ff"
test "$(git rev-parse phase4/remote-protocol-foundation)" = "65eaf47a7191d68265ad79cc4e0fb9f4055b7448"
test "$(git rev-parse phase4/credential-recovery)" = "619036194f663544242573e4c8319dbb37b5ec58"
test "$(git rev-parse phase4/doctor-client-recovery)" = "6ec6c416b3666bf5c2d82473b1a8f3262c6712fe"
```

- [ ] **Step 2: Cherry-pick the six 4A commits in chronological order**

```bash
git cherry-pick 158f659^..65eaf47
```

Resolve `RemoteConnectorProvider` and any shared probe conflicts only after
reading both sides. Run `git status` and `git diff --check` before continuing.

- [ ] **Step 3: Cherry-pick the two 4B commits**

```bash
git cherry-pick 0cc6896^..6190361
```

Keep the adapter’s provider definition as the eventual canonical definition;
do not preserve two declarations merely to make the cherry-pick compile.

- [ ] **Step 4: Cherry-pick the two 4C commits**

```bash
git cherry-pick 11fbd68^..6ec6c41
git diff --check
```

- [ ] **Step 5: Build the merged primitives before hardening**

Run `swift build`. Expected: the merged product builds; `swift test` may stop
before discovery with the known local `XCTest` module-resolution failure. Do
not weaken production code or tests to work around that environment.

---

### Task 2: Establish strict adapter trust and one endpoint reconciler

**Files:**
- Modify: `Sources/MacOrchestrator/RemoteConnectorAdapter.swift`
- Modify: `Sources/MacOrchestrator/NgrokSupport.swift`
- Modify: `Sources/MacOrchestrator/RemoteActivationProbe.swift`
- Modify: `Sources/MacOrchestrator/SupervisorPolicy.swift`
- Test: `Tests/MacOrchestratorTests/RemoteConnectorAdapterTests.swift`
- Test: `Tests/MacOrchestratorTests/NgrokSupportTests.swift`
- Test: `Tests/MacOrchestratorTests/RemoteActivationProbeTests.swift`

**Interfaces:**
- Consumes: `RemoteConnectorAdapter`, `RemoteEndpointReconciliation`, and
  `RemotePublicOrigin` from the reviewed streams.
- Produces: strict `AgentAPIAddress`/public-origin validation and a single
  reconciliation path used by supervisor, Doctor, terminal, and transactions.

- [ ] **Step 1: Add failing trust-boundary tests**

Add tests with hand-written literals for:

```swift
func testRejectsNonLoopbackAgentAPIHosts() { /* attacker.example and 192.168.1.8 */ }
func testAcceptsLoopbackAgentAPIWithCustomPort() { /* http://127.0.0.1:5050/api */ }
func testRejectsAgentAPIUserinfoQueryFragmentAndForeignPath() { /* each fails closed */ }
func testRejectsPublicOriginUserinfoPathQueryAndFragment() { /* each fails closed */ }
func testEndpointWithTwoExactMatchesIsAmbiguousEvenWhenOneURLIsInvalid() { }
```

Run the focused tests through hosted XCTest when available. Locally, confirm
the test target reaches the known `XCTest` import failure rather than claiming
the tests executed.

- [ ] **Step 2: Implement strict address and origin validators**

Require Agent API scheme `http`, loopback host, no userinfo/query/fragment,
and only the canonical `/api` path with a permitted custom port. Require a
public endpoint scheme `https`, nonempty host, no userinfo/query/fragment,
port restrictions matching the provider result, and path empty or `/`.

Expose only sanitized value objects to downstream code. Never use the raw
provider URL as the base for credential-path injection.

- [ ] **Step 3: Make reconciliation reject every ambiguous or malformed match**

Parse all endpoint candidates first, validate every matching public origin, and
return `.ambiguous` when more than one exact upstream match exists, including
when one candidate is invalid. Keep `.foreign`, `.missing`, and
`.invalidAgentAPIResponse` distinct.

- [ ] **Step 4: Route all existing callers through the adapter**

Remove direct `/api/endpoints` requests and duplicate decoding from
`ProcessSupervisor`, `TerminalCommand`, and `ReadOnlyRemoteConnectorFactsProvider`.
Keep one default `http://127.0.0.1:4040/api` value in the adapter; custom ports
must enter through the injected adapter, not scattered literals.

- [ ] **Step 5: Add bounded protocol hardening**

Reject non-integer JSON-RPC IDs, impose a bounded response size before JSON
decoding, require no redirects in the production URL session, and give public
secret-bearing request/configuration types safe descriptions. Add tests for
redirect-following injected sessions, boolean/fractional IDs, oversized
responses, and canary absence from thrown/public descriptions.

- [ ] **Step 6: Run the focused build and diff checks**

Run `swift build` and `git diff --check`. Expected: production compiles and no
old direct endpoint parser remains outside the adapter/reconciler tests.

---

### Task 3: Replace scalar handoff state with independent identity receipts

**Files:**
- Modify: `Sources/MacOrchestrator/RemoteConnectorState.swift`
- Modify: `Sources/MacOrchestrator/RemoteConnectorStateStore.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticProviders.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticModels.swift`
- Test: `Tests/MacOrchestratorTests/RemoteConnectorStateTests.swift`
- Test: `Tests/MacOrchestratorTests/RemoteConnectorStateStoreTests.swift`
- Test: `Tests/MacOrchestratorTests/DiagnosticModelsTests.swift`

**Interfaces:**
- Consumes: current credential generation, verified public origin, and legacy
  `lastConnectorHandoffGeneration` state.
- Produces:

```swift
struct RemoteConnectorHandoffReceipt: Codable, Equatable, Sendable {
    let connectorCredentialGeneration: UInt64
    let publicOrigin: RemotePublicOrigin
    let handedOffAt: Date
}

enum RemoteClientHandoffClassification: String, Codable, Equatable, Sendable {
    case notAvailable
    case unchanged
    case changed
}
```

- [ ] **Step 1: Add failing state and classification tests**

Cover fresh state with no receipt, explicit current handoff, changed
generation, changed origin, repeated current handoff, ready service with
changed handoff, and ready service with no handoff. Assert that readiness does
not require receipt equality.

- [ ] **Step 2: Replace the scalar state field**

Store an optional nonsecret handoff receipt. Keep current credential generation
and current verified origin independent. A fresh state starts generation `0`,
has no receipt, and is not treated as handed off. A stable ready state requires
verified origin and successful probe time, but not a current receipt.

Decode missing/legacy receipt fields as no receipt; never synthesize a receipt
from generation `0` or from a remote probe. Encode only the receipt model.

- [ ] **Step 3: Add explicit handoff recording**

Implement a state-store operation that records a receipt only after the caller
has authenticated current readiness and deliberately displayed/copied the URL.
The operation must compare the supplied generation and origin with current
state and refuse stale handoff writes.

- [ ] **Step 4: Test persistence monotonicity and safe permissions**

Extend store tests to reject stale pending-generation overwrites, provider
mismatch, symlink/permission violations, and handoff identity regression while
retaining atomic private state writes.

- [ ] **Step 5: Run the state-focused verification**

Run `swift build`, inspect JSON fixtures for absence of secrets and credential
paths, and run hosted XCTest once the integration branch is pushed.

---

### Task 4: Make credential transactions async and forward-only

**Files:**
- Modify: `Sources/MacOrchestrator/RemoteCredentialTransaction.swift`
- Modify: `Sources/MacOrchestrator/KeychainStore.swift`
- Create: `Sources/MacOrchestrator/RemoteCredentialOperationCoordinator.swift`
- Test: `Tests/MacOrchestratorTests/RemoteCredentialTransactionTests.swift`
- Test: `Tests/MacOrchestratorTests/KeychainStoreTests.swift`

**Interfaces:**
- Consumes: reviewed synchronous hook protocols and state store.
- Produces: `async throws` transaction hooks/execution, serialized operation
  ownership, and explicit interrupted-rotation recovery.

- [ ] **Step 1: Add failing async and interruption tests**

Convert test fakes to async and add tests named for these observable breaks:

```swift
func testInterruptedRotationGeneratesFreshForwardTokenFromCurrentKeychainValue() async throws { }
func testPostCutoverFailureRetainsNewTokenAndNeverRestoresOldToken() async throws { }
func testStateCommitFailureLeavesRecoverableDegradedState() async throws { }
func testSuccessfulRotationPreservesOldHandoffReceipt() async throws { }
func testNgrokCandidateIsNotPersistedBeforeAuthenticatedValidation() async throws { }
func testNgrokCommitAmbiguityDoesNotRestorePossiblyCanonicalOldCredential() async throws { }
```

Fix the existing persistence fake so its configured failure count is honored.

- [ ] **Step 2: Refactor hooks and execute methods to `async throws`**

Use `Sendable` protocols with async methods for restart, local validation,
remote reconciliation, readiness, and negative validation. Keep synchronous
Keychain/state primitives where they are local and bounded, but await all
supervisor/lifecycle operations. Do not add semaphore or run-loop bridges.

- [ ] **Step 3: Implement forward-only pending recovery**

When state is `cutoverPendingValidation`, read the current Keychain connector
token as canonical, generate another fresh token, write a new pending marker,
perform local positive/negative checks, reconcile remote, perform remote
positive/negative checks, and commit stable state. Never restore or validate an
old token as canonical merely because filesystem state is ambiguous.

- [ ] **Step 4: Serialize production operations**

Use one `RemoteCredentialOperationCoordinator` for connector rotation and
ngrok replacement. It owns the operation lock and state-store coordination but
does not model lifecycle states. Reject overlapping operations with a safe
user-facing state.

- [ ] **Step 5: Implement candidate ngrok commit semantics**

Candidate launch receives the token only in `NGROK_AUTHTOKEN`. Validate the
candidate endpoint and authenticated MCP before Keychain commit. On normal
failure stop candidate and restore the prior session only when canonical old
credential ownership remains proven. On commit ambiguity, treat the candidate
as potentially canonical, preserve degraded state, and reconcile instead of
restoring the old token.

- [ ] **Step 6: Run transaction tests/build**

Run `swift build`, inspect all transaction error descriptions for canaries, and
run the focused XCTest filter on hosted macOS.

---

### Task 5: Wire ProcessSupervisor and the existing lifecycle authority

**Files:**
- Modify: `Sources/MacOrchestrator/ProcessSupervisor.swift`
- Modify: `Sources/MacOrchestrator/LifecycleState.swift`
- Modify: `Sources/MacOrchestrator/ServiceSnapshot.swift`
- Modify: `Sources/MacOrchestrator/ManagedRuntimeLaunchContract.swift`
- Create: `Sources/MacOrchestrator/RemoteProbeCoordinator.swift`
- Test: `Tests/MacOrchestratorTests/ProcessSupervisorTests.swift`
- Test: `Tests/MacOrchestratorTests/LifecycleStateTests.swift`
- Test: `Tests/MacOrchestratorTests/RemoteProbeCoordinatorTests.swift`

**Interfaces:**
- Consumes: strict adapter, remote probe, state identity, async transaction
  coordinator, and existing lifecycle effects.
- Produces: authenticated remote lifecycle readiness with complete fencing.

- [ ] **Step 1: Add failing lifecycle/probe-fencing tests**

Cover endpoint-only pending, initialize/session failure, redirect, inventory
mismatch, safe-call failure, and full authenticated readiness. Add one test for
each stale dimension: process identity, tunnel generation, config generation,
credential generation, public origin, local MCP readiness/generation, desired
state, maintenance, and quitting.

- [ ] **Step 2: Replace direct ngrok launch construction**

Build `RemoteConnectorLaunchInput` from the already validated contract and use
`NgrokRemoteConnectorAdapter.makeLaunchSpecification`. Preserve current
process ownership markers, process groups, termination handlers, and launch
generation checks in `ProcessSupervisor`.

- [ ] **Step 3: Replace endpoint-only `queryTunnelURL` behavior**

Inspect the owned adapter, reconcile exactly one endpoint, construct the
credential URL only transiently, and start `RemoteActivationProbe` with the
canonical active-core expected inventory. Keep the URL nil until the probe
finishes successfully.

- [ ] **Step 4: Apply lifecycle transitions only from fenced results**

Map probe success to `markReady` only when every captured fence still matches.
Map endpoint/auth/inventory failures to degraded/not-ready lifecycle state and
clear public URL. Do not add retry loops inside the probe coordinator.

- [ ] **Step 5: Reconcile startup, recovery, wake, and network events**

Trigger one lifecycle-controlled remote revalidation after initial launch,
endpoint change, owned agent restart, local MCP recovery, wake, network regain,
credential rotation, ngrok credential replacement, and explicit retry. Do not
run authenticated activation continuously while stable.

- [ ] **Step 6: Verify local build and pure lifecycle tests**

Run `swift build`, `swift build -c release`, and the available deterministic
test harness. Record local XCTest unavailability without changing source.

---

### Task 6: Add injectable Network.framework monitoring and effective capabilities

**Files:**
- Create: `Sources/MacOrchestrator/NetworkPathMonitor.swift`
- Modify: `Sources/MacOrchestrator/AppDelegate.swift`
- Modify: `Sources/MacOrchestrator/ProcessSupervisor.swift`
- Modify: `Sources/MacOrchestrator/CapabilityReadinessCoordinator.swift`
- Modify: `Sources/MacOrchestrator/CapabilityRegistry.swift`
- Test: `Tests/MacOrchestratorTests/NetworkPathMonitorTests.swift`
- Test: `Tests/MacOrchestratorTests/CapabilityReadinessCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ProcessSupervisor.handleNetworkAvailabilityChanged(_:)` and
  existing base capability snapshots.
- Produces: `NetworkPathMonitoring` with a production `NWPathMonitor` adapter,
  a deterministic fake, and an effective capability projection.

- [ ] **Step 1: Add failing fake-monitor and capability tests**

Assert loss invalidates only remote readiness, regain requests one bounded
reconciliation, duplicate/noisy events do not overlap probes, termination
stops the monitor, and a remote-ready projection changes display state without
causing a Python MCP restart.

- [ ] **Step 2: Implement the narrow monitor adapter**

Wrap `NWPathMonitor` behind an injectable protocol. Start it on a dedicated
queue, map only usable/unusable path state, coalesce duplicate values, and
stop/cancel it from `AppDelegate`/supervisor termination.

- [ ] **Step 3: Implement effective capability projection**

Keep `CapabilityReadinessCoordinator` network-free. Combine its stable base
snapshot with `LifecycleSnapshot` for status/menu/Doctor. Keep
`ManagedRuntimeLaunchContract` unchanged when only remote lifecycle readiness
changes, and make `remote.connector` depend on core session plus live remote
readiness.

- [ ] **Step 4: Run focused build/tests**

Run `swift build`, inspect that no network callback starts a second lifecycle
owner, and run hosted XCTest for the new monitor/projection cases.

---

### Task 7: Bind Doctor and repairs to real Phase 4 observations

**Files:**
- Modify: `Sources/MacOrchestrator/DiagnosticProviders.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticLiveProviders.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticChecks.swift`
- Modify: `Sources/MacOrchestrator/DoctorEngine.swift`
- Modify: `Sources/MacOrchestrator/RepairEngine.swift`
- Modify: `Sources/MacOrchestrator/Phase3OperationCoordinator.swift`
- Test: `Tests/MacOrchestratorTests/DiagnosticLiveProviderTests.swift`
- Test: `Tests/MacOrchestratorTests/DoctorEngineTests.swift`
- Test: `Tests/MacOrchestratorTests/RepairEngineTests.swift`

**Interfaces:**
- Consumes: adapter/reconciler, remote probe, state store, lifecycle snapshot,
  current-core expected inventory, and transaction coordinator.
- Produces: truthful read-only taxonomy with explicit retry/reconcile versus
  deliberate rotation guidance.

- [ ] **Step 1: Add failing Doctor tests**

Cover endpoint PASS without authenticated PASS, current-token path/auth
rejection recommending retry/reconcile, 404 not asserting stale client,
handoff mismatch WARN only with a receipt, no receipt SKIP, contradictory typed
endpoint facts failing closed, and provider errors preserving a fail status.

- [ ] **Step 2: Add production authenticated remote provider wiring**

Implement `RemoteAuthenticatedMCPDiagnosticProviding` using the same adapter,
URL builder, expected inventory provider, and `RemoteActivationProbe` used by
ProcessSupervisor. Wire it in `TerminalCommand.makeDoctorEngine` and menu
Doctor paths. Populate provider credential state from safe Keychain presence
and state facts without exposing values.

- [ ] **Step 3: Make typed facts authoritative**

Validate `RemoteConnectorFacts` so legacy booleans cannot turn `.notObserved`
or contradictory endpoint states into PASS. Preserve separate local MCP,
ngrok, Agent API, endpoint, authenticated MCP, inventory, and handoff checks.

- [ ] **Step 4: Change auth/path repair priority**

Add bounded remote retry/reconciliation as the primary repair for current-token
auth/path inconsistency. Keep connector rotation available only as an explicit
action for compromise, revocation, or requested renewal. Add remote readiness,
inventory, and handoff priorities to `Phase3OperationCoordinator`.

- [ ] **Step 5: Run Doctor serialization and leak tests**

Encode Doctor JSON with synthetic URL/token/authtoken canaries and assert they
are absent. Run `swift build` and hosted Doctor XCTest.

---

### Task 8: Implement explicit terminal/menu handoff and recovery UX

**Files:**
- Modify: `Sources/MacOrchestrator/TerminalCommand.swift`
- Modify: `Sources/MacOrchestrator/MenuController.swift`
- Modify: `Sources/MacOrchestrator/ServiceSnapshot.swift`
- Modify: `Sources/MacOrchestrator/AppDelegate.swift`
- Modify: `docs/CLIENT_SETUP.md`
- Modify: `README.md`
- Test: `Tests/MacOrchestratorTests/TerminalCommandTests.swift`
- Test: `Tests/MacOrchestratorTests/MenuControllerTests.swift`
- Test: `Tests/MacOrchestratorTests/ServiceSnapshotTests.swift`

**Interfaces:**
- Consumes: authenticated readiness, transient URL builder, receipt writer,
  async transaction coordinator, and effective capability projection.
- Produces: explicit connector rotation/replacement/handoff operations and
  truthful status text.

- [ ] **Step 1: Add failing command/menu tests**

Assert existing operations remain supported, ordinary status never prints a
credential URL, `--print-connector-url`/Copy Connector URL requires current
authenticated readiness, successful handoff records only origin/generation/
timestamp, and failures leave no URL in error/menu/support text.

- [ ] **Step 2: Wire explicit handoff**

Construct the URL only inside the explicit terminal/menu action, display/copy
it, then persist the receipt. Do not return it through status snapshots or
Doctor. Repeated current handoff is `.unchanged`; changed identity requires a
new explicit action.

- [ ] **Step 3: Wire rotation and ngrok replacement commands**

Add protected hidden-input entry for candidate ngrok credentials and explicit
connector rotation/revocation actions. Await the operation through `Task` or
async command paths. Keep old credentials out of argv, logs, config, support
bundles, and error descriptions.

- [ ] **Step 4: Update UX copy and client guidance**

Use status labels for waiting, starting, authenticating, ready, degraded,
provider replacement, and changed-client handoff. State clearly that client
automation count is zero and Mac Orchestrator does not inspect or rewrite
client configuration. Correct the stale README Doctor claim.

- [ ] **Step 5: Run command/help and redaction checks**

Run terminal help in a clean fixture and assert canaries are absent from output,
arguments, and persisted state. Run `swift build` and hosted XCTest.

---

### Task 9: Complete deterministic hardening, manual evidence, and CI contracts

**Files:**
- Modify: `docs/manual/PHASE4_REMOTE_EVIDENCE.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `.github/workflows/ci.yml` only if the merged Swift/test contract requires it
- Test: all focused Phase 4 test files and existing Python suites

**Interfaces:**
- Consumes: final integrated product behavior and current official ngrok claims.
- Produces: auditable manual-evidence boundary and CI checks that test the
  exact candidate SHA.

- [ ] **Step 1: Add the manual evidence matrix without fabrication**

Record baseline, agent restart, helper restart, sleep/wake, network transitions,
reboot, invalid credential recovery, same-account replacement, safe dedicated
different-account replacement if available, and connector rotation. Use only
public origin/hostname, lifecycle classification, and result; mark unavailable
real transitions `MANUAL EVIDENCE REQUIRED`.

- [ ] **Step 2: Run Python verification required by current CI**

```bash
PYTHONDONTWRITEBYTECODE=1 uv run python -B test_pagination.py
PYTHONDONTWRITEBYTECODE=1 uv run python -B test_mcp_server.py
PYTHONDONTWRITEBYTECODE=1 uv run python -B -m py_compile automac_mcp.py indexer.py test_mcp_server.py test_pagination.py
```

Preserve the current informational/manual boundary for TCC-dependent checks.

- [ ] **Step 3: Run source-level adversarial scans**

Search for duplicate `RemoteConnectorProvider`, direct `/api/endpoints` calls,
scattered `:4040`, URL construction before origin validation, scalar handoff
readiness coupling, old-token restoration, automatic 404 rotation, arbitrary
client-file writes, and secret-shaped literals. Inspect every match rather than
accepting a grep-only conclusion.

- [ ] **Step 4: Run local release-gate commands**

```bash
swift build
swift build -c release
swift test
git diff --check
```

If `swift test` cannot resolve XCTest locally, retain its exact failure and
continue only with supplemental build/Python evidence; do not claim local
XCTest success.

---

### Task 10: Commit, push, draft PR, and validate the exact hosted candidate

**Files:**
- All intentionally changed files from Tasks 1–9.

**Interfaces:**
- Consumes: clean final branch, local evidence, and draft PR description.
- Produces: pushed `phase4/integration-hardening`, draft PR to `main`, and a
  final hosted run whose head SHA equals the final branch SHA.

- [ ] **Step 1: Review final diff and commit intentionally**

```bash
git status --short
git diff --check
git diff --stat 584259c44370d7d83f3a2764c94518b862a3c4ff...HEAD
# After reviewing the printed paths against the scoped files above:
git add -u -- .
git commit -m "feat: integrate Phase 4 remote connector hardening"
```

Do not stage credentials, local state, build output, support bundles, or
unrelated worktree files.

- [ ] **Step 2: Push the integration branch**

```bash
git push -u origin phase4/integration-hardening
```

- [ ] **Step 3: Create a draft PR targeting `main`**

Use the connected GitHub workflow or `gh` only after reading the repository
state. The PR must remain draft, must not merge, and must not create a tag or
release. Include the canonical base, stream SHAs, architecture summary, tests,
manual evidence boundary, and explicit secret-absence statement.

- [ ] **Step 4: Verify hosted CI against the exact PR head**

Record the PR number, workflow run ID, and head SHA. Inspect every job,
including the aggregate required gate and informational Python/TCC boundaries.
The hosted XCTest result is authoritative; a prior run on an earlier SHA is not
evidence for the final candidate.

- [ ] **Step 5: Fix every failure and repeat**

For each failing job, reproduce the smallest deterministic failure locally,
write or correct the failing test before source changes, commit the fix, push,
and verify a new run’s head SHA. Stop only when the exact final candidate has
green required hosted gates or when a real external blocker is documented.

---

## Final review checklist

- [ ] Agent API trust is loopback-only and public endpoint origin validation is canonical.
- [ ] Endpoint existence never marks lifecycle ready before authenticated MCP success.
- [ ] Exactly one provider enum and one endpoint reconciliation implementation remain.
- [ ] No synchronous/async deadlock bridge exists.
- [ ] Service readiness is independent of handoff receipt state.
- [ ] Origin changes and token rotations preserve old receipt and produce changed handoff.
- [ ] Every remote probe fence dimension is tested.
- [ ] Effective capability changes do not restart Python.
- [ ] Old connector token is never restored after cutover; no dual-token acceptance exists.
- [ ] Interrupted rotation performs fresh forward recovery from the current Keychain value.
- [ ] Candidate ngrok credentials are not persisted before validation.
- [ ] Doctor does not turn 404/auth/path mismatch into automatic rotation.
- [ ] No arbitrary client configuration is edited.
- [ ] No real token, authtoken, capability URL, content, path, or tool argument appears in commits, logs, test output, Doctor JSON, support artifacts, or process arguments.
- [ ] Final report contains exact final SHA, draft PR number, exact hosted run ID/head SHA, job conclusions, files changed, manual limitations, ngrok sources, and unresolved limitations.
