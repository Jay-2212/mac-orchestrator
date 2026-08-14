# Mac Orchestrator Phase 4D Integration and Hardening Design

**Date:** 2026-08-14  
**Repository:** `Jay-2212/mac-orchestrator`  
**Canonical starting SHA:** `584259c44370d7d83f3a2764c94518b862a3c4ff`  
**Integration branch:** `phase4/integration-hardening`

## Goal

Integrate the reviewed Phase 4A, 4B, and 4C streams into a stable remote
connector whose readiness means a real authenticated MCP connection, whose
credential and provider recovery are forward-only and recoverable, and whose
client handoff state is explicit rather than inferred.

The work preserves the existing Phase 3 `LifecycleStateMachine`, local MCP
activation contract, one-command onboarding, minimal menu-bar supervisor, and
manual client configuration boundary. It does not modify Meridian.

## Approaches considered

### Recommended: ordered stream integration plus one supervisory pass

Create the integration branch at the canonical Phase 3 merge, cherry-pick 4A,
4B, and 4C in the requested order, then resolve type conflicts and implement
the live supervisor integration around the existing lifecycle state machine.

This preserves reviewed history and tests, makes the exact provenance of every
stream inspectable, and keeps the Phase 4D corrections in one integration
context. The cost is deliberate conflict resolution across the provider,
state, Doctor, and supervisor seams.

### Rewrite Phase 4 from the canonical base

Reimplement the remote connector, state, transactions, and Doctor integration
directly on the Phase 3 merge. This could produce a smaller final diff, but it
would discard the reviewed stream history and violate the required 4A → 4B → 4C
integration order.

### Merge the streams and leave live wiring for a later phase

Combine the reviewed primitives and stop after compilation. This is lower risk
in the short term, but it leaves endpoint-only readiness, duplicate parsers,
synchronous transaction hooks, and nonfunctional production Doctor seams. It
does not satisfy Phase 4D’s definition of done.

## Architecture

### One remote provider truth

`RemoteConnectorProvider` is defined once and remains an enum containing only
`.ngrok`. `NgrokRemoteConnectorAdapter` owns Agent API transport, endpoint
inspection, typed reconciliation, and launch-spec construction. The
`ProcessSupervisor` retains process identity, ownership markers, launch
generations, lifecycle transitions, retries, and termination; it consumes the
adapter instead of duplicating its HTTP or launch logic.

Agent API inputs are accepted only when they are local loopback addresses
(`127.0.0.1`, `::1`, or canonical `localhost`), with optional custom ports and
the expected local API path. Userinfo, query, fragment, LAN/public hosts, and
noncanonical alternatives fail closed. Public endpoint values are accepted
only as clean HTTPS origins with no userinfo, query, fragment, or
provider-controlled path. Mac Orchestrator appends the capability path.

The typed endpoint reconciler is the only implementation used by the
supervisor, terminal handoff, Doctor, and credential replacement. It requires
exactly one valid HTTPS endpoint whose upstream matches the current local
target; missing, foreign, ambiguous, malformed, and unavailable states remain
distinct.

### Authenticated remote readiness

The existing `LifecycleStateMachine` remains the sole lifecycle authority.
After an owned ngrok process is running, the supervisor reconciles the current
endpoint, builds the connector URL transiently from the validated public
origin and Keychain connector token, and runs one bounded
`RemoteActivationProbe` using the canonical current-core tool inventory.

The probe sequence is initialize, session establishment, initialized
notification, exact `tools/list`, and successful `get_session_state`. An
endpoint string or successful Agent API response alone never marks the remote
component ready. The probe coordinator owns no retry state machine; lifecycle
retry/backoff/circuit behavior remains in Phase 3.

Every async completion carries and validates the tunnel process identity,
tunnel launch generation, active configuration generation, connector
credential generation, reconciled public origin, local MCP readiness/generation,
desired state, maintenance/quiesce state, and quitting state. Any mismatch is
discarded without mutating newer lifecycle state.

### Independent service readiness and client handoff

Remote connector state stores the current connector credential generation and
verified public origin as service identity. It stores an optional nonsecret
handoff receipt containing the generation, origin, and timestamp. The receipt
is not updated by a successful probe or credential rotation.

Handoff classification is:

- no receipt → `.notAvailable`;
- receipt generation and origin both match current verified identity →
  `.unchanged`;
- any mismatch → `.changed`.

Remote service readiness depends on authenticated lifecycle truth and current
state, never on the handoff receipt. Connector-token rotation and ngrok origin
replacement preserve the previous receipt and therefore expose a changed
handoff until the user explicitly copies/shows the current connector URL.

For a pending connector rotation, the Keychain value currently present is
treated as canonical. Recovery generates another fresh token and performs a
new forward rotation; it never restores an old token or accepts an ambiguous
state as already committed.

### Async transactions and serialized operations

Connector-token rotation and ngrok credential replacement expose `async throws`
hooks and execute methods. Process restart, lifecycle quiescence, endpoint
reconciliation, and remote activation are awaited through the existing
supervisor/lifecycle seams. No semaphore, run-loop spin, second lifecycle
implementation, or dual-token grace period is introduced.

After Keychain connector cutover, the new token remains canonical on every
failure. The old token exists only transiently for bounded negative local and
remote route checks. Persistence failure becomes a degraded, recoverable
state, followed by reconciliation against the current Keychain credential.

Ngrok candidate credentials are supplied only through hidden input and only in
the candidate child environment. Candidate validation completes endpoint and
authenticated-MCP checks before Keychain commit. Normal failure stops the
candidate and restores the prior provider session; compromised-old mode fails
closed without attempting restoration. A successful changed origin updates
current state while preserving the prior handoff receipt.

### Effective capability projection

`CapabilityReadinessCoordinator` continues to evaluate configuration and local
prerequisites without performing network probes. A separate effective/display
projection combines the stable base `CapabilitySnapshot` with the current
`LifecycleSnapshot`. `remote.connector` depends on the core session and live
authenticated remote readiness. A remote readiness transition changes menu,
Doctor, and status projections but does not change the stable Python launch
snapshot or restart the MCP process.

### Doctor, repairs, and user handoff

Doctor remains read-only and receives real adapter/reconciler observations,
authenticated probe facts, current state identity, and handoff classification.
Endpoint PASS is separate from authenticated-readiness PASS. A current-token
401/403/404/path mismatch first recommends bounded remote reconciliation/retry,
not automatic connector rotation; rotation is explicit security/user action.
No receipt produces SKIP rather than an arbitrary stale-client assertion.

The menu and terminal retain the existing remote operations and add explicit
rotation, safe ngrok replacement, and connector URL handoff actions. Only the
explicit handoff action may transiently display/copy the credential-bearing
URL and then persist the nonsecret receipt. Ordinary status, Doctor, logs,
support bundles, process arguments, and CI output remain secret-free.

Automation remains zero: clients receive manual generic Streamable HTTP or
`mcpServers` guidance only. No arbitrary client files or private APIs are
modified.

## Error and recovery model

The supervisor reports transient lifecycle states such as waiting for local
MCP, starting ngrok, endpoint established/authenticating, ready, remote
reconciliation failed, provider credential replacement required, and rotated
connector clients needing reconfiguration. It clears the public connector URL
whenever remote readiness is lost.

Network loss invalidates only remote readiness. The local MCP lifecycle stays
running. A narrow injectable `NWPathMonitor` adapter forwards availability
events to `ProcessSupervisor.handleNetworkAvailabilityChanged(_:)`; duplicate
events are coalesced by the existing lifecycle/reconciliation guards and the
monitor stops during termination.

No provider-side endpoint deletion, authtoken deletion, account mutation,
purchase, public release, or destructive client rewrite is performed.

## Test and evidence strategy

Tests are written before each production behavior change and must demonstrate
the required RED → GREEN cycle. The deterministic suite covers:

- loopback Agent API and strict public-origin validation;
- endpoint current/foreign/missing/ambiguous/malformed classifications;
- authenticated MCP sequence, redirect/auth/inventory/safe-call failures;
- every remote-probe fencing dimension;
- network loss/regain, wake, duplicate path events, and clean stop;
- capability projection without Python restart;
- fresh/explicit/changed handoff identity;
- successful, failed, and interrupted forward-only rotation;
- ngrok candidate validation, cleanup, commit ambiguity, and changed origin;
- Doctor taxonomy and no automatic rotation for path/auth mismatch;
- synthetic secret canaries absent from public descriptions, logs, Doctor JSON,
  support bundles, state files, arguments, and test-generated CI output.

Local verification includes debug/release Swift builds, XCTest where the native
toolchain permits it, required Python suites, compile checks, and
`git diff --check`. The local Command Line Tools environment is not treated as
XCTest evidence when it cannot resolve XCTest. Hosted macOS CI is authoritative
and must pass on the exact final PR head SHA.

`docs/manual/PHASE4_REMOTE_EVIDENCE.md` records only public origin/hostname,
lifecycle classification, and result. Sleep/wake, reboot, network transition,
and account replacement remain `MANUAL EVIDENCE REQUIRED` unless safely
performed and directly observed.

Official ngrok documentation currently states that the Free plan includes one
account-assigned development domain and up to three online endpoints, and that
the local Agent API has no authentication and may move when `web_addr` is
overridden:

- https://ngrok.com/docs/pricing-limits/free-plan-limits
- https://ngrok.com/docs/agent/api

The product documentation will describe restart persistence from empirical
evidence, not assume that a restart changes or preserves a domain.

## Scope boundaries

In scope: the three reviewed Phase 4 streams; Swift supervisor/lifecycle,
adapter, state, transaction, capability, Doctor, repair, terminal, menu, and
network seams; deterministic tests; focused documentation and manual evidence;
CI fixes required to validate the final candidate.

Out of scope: Meridian, Cloudflare migration, additional providers, OAuth,
multi-tenancy, Apple Developer/notarization, provider-side cleanup, plan
purchasing, arbitrary client-file rewriting, UI automation, credential/content
telemetry, Phase 3 updater schema migration, merge, tag, and public release.
