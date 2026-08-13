# Phase 4C Remote Doctor / Client Recovery Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the read-only Doctor so remote endpoint, authenticated MCP readiness, inventory, and client-handoff evidence are separate, truthful, secret-free diagnoses, while leaving live RemoteActivationProbe and ProcessSupervisor wiring for Phase 4D.

**Architecture:** Keep `ReadOnlyRemoteConnectorFactsProvider` responsible for deterministic local ngrok/Agent API observations only. Add typed nonsecret remote facts and an injectable asynchronous authenticated-MCP provider seam; Doctor invokes that seam only after local MCP and endpoint prerequisites are verified, and otherwise reports SKIP/WARN rather than inventing provider or client failures. Client recovery is represented as a manual bounded repair descriptor with no secret or URL input.

**Tech Stack:** Swift 5 SwiftPM package, Foundation/Codable, XCTest, existing injected diagnostic providers, existing sensitive-data redactor, Markdown maintainer documentation.

## Global Constraints

- Start from exact base `584259c44370d7d83f3a2764c94518b862a3c4ff` on branch `phase4/doctor-client-recovery` in an isolated worktree.
- Do not wire live `RemoteActivationProbe` into `ProcessSupervisor` in this stream.
- Doctor remains strictly read-only; repairs remain separately invoked and bounded.
- Remote endpoint existence alone can never produce a final remote-ready PASS.
- Authenticated readiness requires the full nonsecret probe facts; inventory mismatch is FAIL.
- Do not diagnose an arbitrary client as stale without a known/manual handoff receipt showing connector identity changed.
- Do not include secrets, capability paths, connector URLs, or raw provider response bodies in facts, reports, repairs, or support bundles.
- Preserve generic Streamable HTTP MCP guidance; add no named client without an existing product promise, current official instructions, and an eligible stable registration API.
- Do not modify `ProcessSupervisor.swift`, `LifecycleState.swift`, `LocalActivationProbe.swift`, `NgrokSupport.swift`, `KeychainStore.swift`, `CapabilityReadinessCoordinator.swift`, `CapabilityRegistry.swift`, `TerminalCommand.swift`, `MenuController.swift`, configuration schema, updater/uninstaller/release, Meridian, or `README.md` unless an unavoidable conflict is found and explicitly reported.

---

### Task 1: Define the typed remote evidence model and test contract

**Files:**
- Modify: `Sources/MacOrchestrator/DiagnosticModels.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticProviders.swift`
- Test: `Tests/MacOrchestratorTests/DiagnosticModelsTests.swift`
- Test: `Tests/MacOrchestratorTests/DoctorEngineTests.swift`

**Interfaces:**
- Produce `RemoteLocalMCPPrerequisiteState`, `RemoteNgrokCredentialState`, `RemoteManagedProcessState`, `RemoteAgentAPIState`, `RemoteEndpointState`, `RemoteAuthenticatedMCPState`, and `RemoteClientHandoffState` as Codable, Equatable, Sendable enums.
- Produce `RemoteAuthenticatedMCPFacts` with explicit probe/inventory/safe-call booleans and expected/exposed tool sets; its classifier must yield `notRun`, `authenticationRejected`, `initializeSessionFailed`, `inventoryMismatch`, `safeCallFailed`, or `ready` without storing a URL or token.
- Extend `RemoteConnectorFacts` with typed Agent API, endpoint, process, credential-rejection, local-prerequisite, authenticated-readiness, and client-handoff facts while preserving source compatibility through defaults for existing constructors.
- Produce `RemoteAuthenticatedMCPDiagnosticProviding` with `func inspect() async throws -> RemoteAuthenticatedMCPFacts` and no URL/token parameters.

- [ ] **Step 1: Write failing model/classifier tests.** Cover every requested remote state: unavailable local prerequisite; invalid binary/config; absent and inaccessible ngrok credential; provider credential rejected; missing managed process; duplicate/foreign ownership ambiguity; Agent API unavailable and malformed; no expected endpoint; foreign-only endpoints; multiple matching endpoints; established endpoint with probe not run; authentication/path rejection; initialize/session failure; inventory mismatch; safe-call failure; changed handoff identity; and fully ready remote.
- [ ] **Step 2: Run the focused tests and verify they fail for missing types/behavior.** Run `swift test --filter DiagnosticModelsTests` and `swift test --filter DoctorEngineTests`; record the local XCTest module-discovery limitation if the toolchain fails before discovery.
- [ ] **Step 3: Implement the minimal Codable facts, classifier, and provider protocol.** Keep identity comparison as a typed state only; never add raw connector identity, host, route, capability path, or provider response body to a serializable fact.
- [ ] **Step 4: Re-run the focused tests and verify the expected classifier states pass.** Also assert old `RemoteConnectorFacts` construction continues to derive a legacy established endpoint when `endpointAvailable` is true.

### Task 2: Make local Agent API and endpoint classification deterministic

**Files:**
- Modify: `Sources/MacOrchestrator/DiagnosticLiveProviders.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticProviders.swift`
- Test: `Tests/MacOrchestratorTests/DiagnosticLiveProviderTests.swift`

**Interfaces:**
- `ReadOnlyRemoteConnectorFactsProvider.inspectDetailed()` must classify response status, JSON shape, expected-upstream match count, and managed-process observation without returning endpoint URLs.
- A valid 200 Agent API response with zero matches is `noExpectedUpstream`; nonmatching endpoints are `foreignOnly`; more than one exact match is `ambiguous`; exactly one valid HTTPS exact match is `established`.
- Credential rejection is an injected/provider fact for this stream; no live credential-authentication or supervisor implementation is added.

- [ ] **Step 1: Add failing provider tests for valid empty, foreign-only, ambiguous, malformed, unavailable, and token-bearing endpoint payloads.** Assert the typed state, endpoint count, and absence of the public URL/capability route from serialized facts.
- [ ] **Step 2: Run the provider tests to verify the new assertions fail.** Use `swift test --filter DiagnosticLiveProviderTests` and preserve the observed XCTest environment limitation if applicable.
- [ ] **Step 3: Implement a private response decoder/classifier in `DiagnosticLiveProviders.swift`.** Distinguish unavailable transport/status from malformed 200 JSON; count exact upstream matches without changing `NgrokSupport.swift`; classify process ownership as owned, missing, or ambiguous when the injected process runner is configured.
- [ ] **Step 4: Re-run provider tests and then `swift build`.** Confirm no raw endpoint URL or body is retained in `RemoteConnectorInspection`/`RemoteConnectorFacts`.

### Task 3: Add separate Doctor checks and authenticated-readiness gating

**Files:**
- Modify: `Sources/MacOrchestrator/DiagnosticChecks.swift`
- Modify: `Sources/MacOrchestrator/DoctorEngine.swift`
- Test: `Tests/MacOrchestratorTests/DoctorEngineTests.swift`

**Interfaces:**
- Keep `remote.endpoint` separate from new `remote.authenticated-readiness`, `remote.inventory`, and `remote.client-handoff` checks.
- `remote.endpoint` can PASS only for an established expected-upstream endpoint and never represents final remote readiness.
- `remote.authenticated-readiness` PASS requires `RemoteAuthenticatedMCPFacts.state == .ready`; endpoint/probe prerequisites yield SKIP or a truthful WARN for an established endpoint whose probe was not run.
- `remote.inventory` FAILs on typed mismatch and SKIPs until authenticated inventory evidence exists.
- `remote.client-handoff` WARNs with `.reconfigureRemoteClients` only for a known changed handoff; no receipt yields SKIP and no arbitrary client diagnosis.
- Add the optional async provider to `DoctorDependencies`; call it only after validated local MCP prerequisite and established endpoint. When absent, encode `notRun`; when it throws, preserve unavailable evidence without claiming remote readiness.

- [ ] **Step 1: Add failing Doctor check tests.** Test endpoint PASS versus authenticated-readiness non-PASS; each remote failure reason; local MCP unavailable causing downstream SKIP; auth rejection distinct from endpoint missing; inventory mismatch FAIL; changed identity plus healthy remote producing WARN; no handoff receipt producing no stale-client claim; disabled remote SKIP; and unchanged Meridian SKIP.
- [ ] **Step 2: Run the Doctor tests to verify the new behavior fails before implementation.** Use `swift test --filter DoctorEngineTests`.
- [ ] **Step 3: Implement prerequisite-aware checks, typed reason text, repair selection, and engine wiring.** Use placeholder facts with local prerequisite state when a provider fails so an unavailable local MCP never becomes a misleading provider-credential failure.
- [ ] **Step 4: Re-run focused tests and `swift build -c release`.** Verify the full report has all four explicit remote concern IDs and that remote endpoint PASS cannot make the authenticated check PASS.

### Task 4: Add bounded manual repair semantics and redaction adversarial tests

**Files:**
- Modify: `Sources/MacOrchestrator/RepairEngine.swift`
- Modify: `Sources/MacOrchestrator/DiagnosticChecks.swift`
- Test: `Tests/MacOrchestratorTests/RepairEngineTests.swift`
- Test: `Tests/MacOrchestratorTests/DiagnosticModelsTests.swift`
- Test: `Tests/MacOrchestratorTests/SupportBundleTests.swift`
- Test: `Tests/MacOrchestratorTests/SensitiveDataRedactorTests.swift`

**Interfaces:**
- Add `.replaceNgrokCredential`, `.rotateConnectorCredential`, and `.reconfigureRemoteClients` to exhaustive repair IDs only as safe manual handoffs.
- Descriptors and outcomes must contain generic protected-input/manual-reconfiguration guidance, never secret input, capability paths, connector URLs, arbitrary client names, or claims that client settings were inspected.
- `RepairEngine` must return `.requiresUserAction` for these manual actions without mutating Keychain, client files, or Doctor state.

- [ ] **Step 1: Add failing repair/redaction tests.** Assert every new descriptor is secret/URL-free, manual outcomes do not invoke mutation adapters, a token-bearing connector URL is absent from serialized Doctor reports/support-bundle metadata, and only a known changed handoff yields reconfiguration guidance.
- [ ] **Step 2: Run the focused repair/support/redaction tests and verify failure.** Use the relevant `swift test --filter` commands and inspect the failure reason rather than weakening assertions.
- [ ] **Step 3: Implement exhaustive manual repair cases and safe static guidance.** Keep provider-credential rejection on provider-credential guidance, not generic retry; keep Doctor read-only.
- [ ] **Step 4: Re-run focused tests and `git diff --check`.** Confirm no new production API accepts a secret or connector URL.

### Task 5: Update generic client recipes and add empirical Phase 4 evidence matrix

**Files:**
- Modify: `docs/CLIENT_SETUP.md`
- Create: `docs/manual/PHASE4_REMOTE_EVIDENCE.md`

**Interfaces:**
- Preserve the generic Streamable HTTP recipe and explain the full password-like connector URL, current-URL copy versus automatic registration, token rotation invalidation, account/domain/endpoint changes, and the fact that arbitrary client settings are not inspected or rewritten.
- State that no named-client automatic registration API is eligible in Phase 4C; automation count is zero.
- Correct ngrok wording to distinguish the current Free account-specific assigned development domain and current plan limits from empirical lifecycle observations; do not claim restart always changes hostname or persistence across reboot/network/account replacement.
- The evidence matrix must cover baseline, ngrok restart, helper restart, sleep/wake, Wi-Fi down/up, network change, reboot, same-account authtoken replacement, different-account replacement, invalid-then-recovery credential flow, and connector capability-token rotation. Each row must define precondition, public-hostname-only observation, expected Agent API classification, expected authenticated MCP result, expected client-handoff state, and a result field; no token/path paste field is allowed.

- [ ] **Step 1: Add documentation assertions/checks as repository searches.** Search for stale restart/domain claims and for named-client promises before editing; keep README untouched unless a contradiction is unavoidable.
- [ ] **Step 2: Edit the generic setup recipe and create the manual evidence matrix.** Use only public hostname observations and placeholders for results; never request a capability path/token.
- [ ] **Step 3: Re-run documentation searches and inspect the full diff.** Confirm no named client, automatic registration claim, or unsupported persistence claim was introduced.

### Task 6: Final verification, adversarial review, commit, and push

**Files:**
- Verify only the owned implementation/tests/docs paths above; do not modify protected files.

- [ ] **Step 1: Run `swift build`, `swift build -c release`, `swift test`, relevant support/redaction filters, and `git diff --check`.** Record exact exit codes and distinguish the known local XCTest toolchain failure from source/build evidence.
- [ ] **Step 2: Perform adversarial searches.** Search all changed files for capability URL patterns, token-like fields, raw response bodies, named clients, `ProcessSupervisor`, `RemoteActivationProbe`, protected filenames, and accidental README changes.
- [ ] **Step 3: Review the final report taxonomy against all 18 requested states.** Verify each maps to a typed fact/check/reason and that no endpoint-only PASS is treated as remote-ready.
- [ ] **Step 4: Commit the implementation with a focused Phase 4C message.** Verify the commit tree and final SHA from the isolated branch.
- [ ] **Step 5: Push only `phase4/doctor-client-recovery` and verify `git ls-remote` matches the final SHA.** Do not merge, tag, release, or create a pull request.
