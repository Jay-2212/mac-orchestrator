# Phase 4A Remote Protocol / Provider Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a typed ngrok connector adapter and a shared MCP activation engine, then add a URL-safe one-shot remote activation probe without integrating it into `ProcessSupervisor`.

**Architecture:** `NgrokRemoteConnectorAdapter` owns provider launch/Agent API seams and delegates pure endpoint matching to a typed `NgrokEndpointParser` reconciliation contract. `MCPActivationProtocolEngine` owns all MCP session semantics; LocalActivationProbe wraps it while preserving local health and error compatibility, and RemoteActivationProbe wraps it with exact inventory, URL-free errors, and non-browser request metadata.

**Tech Stack:** Swift 5.9, Foundation URLSession/URLProtocol, XCTest, Swift Package Manager, existing `NoRedirectURLSession`.

## Global Constraints

- Start from exact SHA `584259c44370d7d83f3a2764c94518b862a3c4ff` on branch `phase4/remote-protocol-foundation`.
- Do not modify `ProcessSupervisor.swift`, `LifecycleState.swift`, `CapabilityReadinessCoordinator.swift`, `CapabilityRegistry.swift`, `KeychainStore.swift`, `TerminalCommand.swift`, `MenuController.swift`, diagnostic/doctor/repair files, `Configuration.swift`, update/uninstall/release code, or Meridian.
- Do not add Cloudflare, Tailscale, registry/plugin, provider-resource, or inspector-port configuration support.
- Do not wire the new adapter or remote probe into lifecycle code in Phase 4A.
- No credential-bearing URL may appear in remote results, errors, descriptions, logs, request debug output, or test failure output.
- Use the current ngrok `GET /api/endpoints` response; reject deprecated `/api/tunnels` payloads.
- No live ngrok or network test is permitted.

---

### Task 1: Lock the typed endpoint reconciliation contract

**Files:**
- Modify: `Sources/MacOrchestrator/NgrokSupport.swift`
- Modify: `Tests/MacOrchestratorTests/NgrokSupportTests.swift`

**Interfaces:**
- Produces `RemoteEndpointReconciliation` with `current(publicURL:)`, `missing`, `foreign`, `ambiguous`, `agentAPIUnavailable`, and `invalidAgentAPIResponse`.
- Produces `NgrokEndpointParser.reconcile(from:matching:)` for raw Agent API bytes.
- Keeps `isValidResponse(from:)`, `hasLiveHTTPS(from:)`, and `publicURL(from:matching:)` as compatibility methods.

- [ ] **Step 1: Write the failing tests**

Add focused tests for an exact current endpoint, zero endpoints, wrong upstream, multiple matching endpoints, malformed JSON, non-HTTPS matching public URL, and deprecated `tunnels` JSON. Assert the typed result rather than only `nil`.

- [ ] **Step 2: Run the parser tests and verify the expected red failure**

Run `swift test --filter NgrokSupportTests`.

Expected failure: the typed reconciliation API is not defined yet; existing compatibility tests may remain green.

- [ ] **Step 3: Implement the pure parser contract**

Decode only `{ "endpoints": [...] }`. Normalize expected and upstream addresses by trimming whitespace, removing trailing path slashes, and dropping query/fragment components. Return `missing` for a valid empty array, `foreign` when no endpoint upstream matches, `ambiguous` for multiple matching valid HTTPS candidates, `invalidAgentAPIResponse` for malformed/deprecated data or an invalid matching public URL, and `current` only for one matching HTTPS URL with a host.

- [ ] **Step 4: Run the focused tests and the existing compatibility tests**

Run `swift test --filter NgrokSupportTests`.

Expected: all parser tests pass, including the pre-existing compatibility cases.

- [ ] **Step 5: Commit the parser cycle**

Run `git add Sources/MacOrchestrator/NgrokSupport.swift Tests/MacOrchestratorTests/NgrokSupportTests.swift && git commit -m "feat: type ngrok endpoint reconciliation"`.

### Task 2: Define and test the remote connector adapter seam

**Files:**
- Create: `Sources/MacOrchestrator/RemoteConnectorAdapter.swift`
- Create: `Tests/MacOrchestratorTests/RemoteConnectorAdapterTests.swift`

**Interfaces:**
- `RemoteConnectorAdapter` exposes prerequisite validation, launch specification creation, Agent API inspection, endpoint reconciliation, and provider diagnostics only.
- `NgrokRemoteConnectorAdapter` is the only implementation and defaults to `http://127.0.0.1:4040/api` while accepting an injected base URL and URLSession.
- `RemoteConnectorLaunchSpecification` contains executable URL, arguments, and in-memory environment; its debug/description output is redacted.
- `RemoteConnectorAgentAPIInspection` contains only `.available(endpoints:)`, `.unavailable`, or `.invalidResponse`.

- [ ] **Step 1: Write failing tests for the adapter contract**

Test that the injected custom Agent API base address is used for `GET /api/endpoints`, a valid response is exposed to endpoint reconciliation, non-200/redirect/network failures become unavailable, malformed 200 data becomes invalid, launch arguments preserve the current ngrok production shape, missing launch prerequisites are diagnosed, and no launch specification description contains the auth token.

- [ ] **Step 2: Run the new adapter tests and verify the expected red failure**

Run `swift test --filter RemoteConnectorAdapterTests`.

Expected failure: the adapter types and methods are not defined yet.

- [ ] **Step 3: Implement the minimal adapter**

Use `NoRedirectURLSession` by default, set a one-second Agent API request timeout, reject response URL changes, and map all HTTP/network failures without retaining their underlying error text. Construct the existing `ngrok http <target> --config <config> --log stdout --log-format json --log-level info --inspect=true --metadata mac-orchestrator-owner=<owner>` arguments and add `NGROK_AUTHTOKEN` only in the returned in-memory process environment.

- [ ] **Step 4: Run adapter tests and inspect the source for lifecycle leakage**

Run `swift test --filter RemoteConnectorAdapterTests` and search the new source for `Process`, `PID`, retry, backoff, or credential-bearing string interpolation. The only process-related value should be the launch specification.

- [ ] **Step 5: Commit the adapter cycle**

Run `git add Sources/MacOrchestrator/RemoteConnectorAdapter.swift Tests/MacOrchestratorTests/RemoteConnectorAdapterTests.swift && git commit -m "feat: add ngrok remote connector adapter seam"`.

### Task 3: Extract the shared MCP activation protocol engine

**Files:**
- Create: `Sources/MacOrchestrator/MCPActivationProbe.swift`
- Modify: `Sources/MacOrchestrator/LocalActivationProbe.swift`
- Modify: `Tests/MacOrchestratorTests/LocalActivationProbeTests.swift` only if fixture/API adjustments are required

**Interfaces:**
- `MCPActivationProtocolEngine` accepts an endpoint URL, injected URLSession, optional User-Agent, an explicit required-only or exact inventory policy, and the interactive-UI requirement.
- The engine returns nonsecret tool/session/safe-call facts and a phase-specific protocol outcome.
- `LocalActivationProbe` keeps `LocalActivationProbeError`, `LocalActivationProbeOutcome`, `LocalActivationProbeDetails`, and all existing public method signatures.

- [ ] **Step 1: Add a shared-engine contract test through the existing local tests**

First add a test assertion that the local sequence still sends the same four MCP methods, accepts the existing `202` initialized response, and preserves the existing error mappings. Run `swift test --filter LocalActivationProbeTests` and record the failure caused by the not-yet-extracted engine seam.

- [ ] **Step 2: Implement the shared request/response engine**

Move only MCP request construction, one-request execution, redirect checks, session-header parsing, JSON-RPC validation, tools-list parsing, exact/required inventory validation, and safe-call validation into the new source. Keep the local exact health request in `LocalActivationProbe`. Map engine failures back to the existing local error cases without changing their localized text or the local optional-UI semantics.

- [ ] **Step 3: Run all local activation tests**

Run `swift test --filter LocalActivationProbeTests`.

Expected: the complete pre-existing LocalActivationProbe suite passes unchanged in behavior.

- [ ] **Step 4: Commit the shared-engine cycle**

Run `git add Sources/MacOrchestrator/MCPActivationProbe.swift Sources/MacOrchestrator/LocalActivationProbe.swift Tests/MacOrchestratorTests/LocalActivationProbeTests.swift && git commit -m "refactor: share MCP activation protocol"`.

### Task 4: Add the URL-safe remote activation probe

**Files:**
- Create: `Sources/MacOrchestrator/RemoteActivationProbe.swift`
- Create: `Tests/MacOrchestratorTests/RemoteActivationProbeTests.swift`

**Interfaces:**
- `RemoteActivationProbe.init(url:expectedTools:session:)` receives the complete HTTPS MCP URL and exact expected tool inventory.
- `run()`, `runDetailed()`, and `runOutcome()` perform one activation attempt and return only nonsecret structured facts.
- `RemoteActivationProbeError` and `RemoteActivationProbeOutcome` contain no URL, token, path, response body, or underlying URLSession error.

- [ ] **Step 1: Write failing URLProtocol tests**

Cover initialize success, redirect rejection at every credential-bearing step, missing and invalid session IDs, non-success initialized notification, missing required tool, exact-inventory rejection of an unexpected privileged tool, safe-call failure, non-browser User-Agent, absence of `ngrok-skip-browser-warning`, bounded request timeout, and success without `gui_interaction_available`.

Add a secret-safety test using a URL containing a synthetic token/path and response bodies/errors containing the same values. Assert that `String(describing:)`, `String(reflecting:)`, `localizedDescription`, result details, and outcome errors do not contain the URL, token, or path.

- [ ] **Step 2: Run the new remote tests and verify the expected red failure**

Run `swift test --filter RemoteActivationProbeTests`.

Expected failure: `RemoteActivationProbe` and its URL-free error contract are not defined yet.

- [ ] **Step 3: Implement the one-shot wrapper**

Validate HTTPS/host shape without echoing the URL, invoke the shared engine with exact inventory and a non-browser User-Agent, map every shared failure to a sanitized remote error, and do not perform retries or local UI readiness checks.

- [ ] **Step 4: Run remote and local focused tests**

Run `swift test --filter RemoteActivationProbeTests` and `swift test --filter LocalActivationProbeTests`.

- [ ] **Step 5: Commit the probe cycle**

Run `git add Sources/MacOrchestrator/RemoteActivationProbe.swift Tests/MacOrchestratorTests/RemoteActivationProbeTests.swift && git commit -m "feat: add authenticated remote activation probe"`.

### Task 5: Full verification and handoff

**Files:**
- No additional production files.

- [ ] **Step 1: Run the full Swift test suite**

Run `swift test` from the isolated checkout and record the exact pass/failure result.

- [ ] **Step 2: Run relevant Python protocol tests**

Use the repository’s managed Python environment if available and run the existing MCP/server protocol test command discovered from `pyproject.toml` or the test files. Do not change Python code or report live-provider evidence.

- [ ] **Step 3: Run static and security checks**

Run `git diff --check`, inspect `git diff --name-only`, and search changed source/tests for the synthetic connector token, URL construction in error text, `localizedDescription` propagation, `URLRequest` printing, redirect-following behavior, and any lifecycle/retry code.

- [ ] **Step 4: Commit the final verified state**

Run `git status --short`, then `git add` only the approved files and `git commit -m "feat: establish phase4 remote protocol foundation"`.

- [ ] **Step 5: Push without merging, tagging, or releasing**

Run `git push -u origin phase4/remote-protocol-foundation`. Verify the pushed commit with `git rev-parse HEAD` and `git ls-remote origin refs/heads/phase4/remote-protocol-foundation`.
