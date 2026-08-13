# Mac Orchestrator Phase 3B Doctor and Support Design

## Goal

Add a reusable, read-only diagnostic engine, explicit bounded repair layer,
preview-first support bundles, and shared adversarial redaction for the current
Mac Orchestrator core. This branch does not add menu or terminal integration and
does not implement lifecycle, updater, installer, or future-provider behavior.

## Scope and invariants

- The diagnostic vocabulary is exactly `pass`, `warn`, `fail`, and `skip`.
- `DoctorEngine.run()` only observes injected facts and never calls a repair.
- Missing or intentionally disabled optional capabilities are represented as
  `SKIP` or an appropriate non-failure state rather than an automatic `FAIL`.
- Configuration inspection reads and validates the primary and backup files
  without creating directories, migrating, rewriting, restoring, or changing
  permissions.
- Keychain presence uses a Security query that does not request item data. The
  presence fact contains only `present`, `absent`, or `inaccessible`.
- Authenticated local MCP diagnosis reuses the existing canonical activation
  path through an adapter. No weaker readiness oracle is introduced.
- Repairs are explicit, bounded, auditable, and owned by injected adapters.
- Support preview describes a fixed inclusion plan without collecting entry
  contents. Archive creation accepts only a plan issued by that engine.
- Support archive entries are relative, unique, non-symlinked, and limited to
  explicitly configured safe sources. No home-directory recursion is allowed.
- The shared redactor removes exact secrets, connector URLs and token routes,
  structured secret fields, and private home prefixes while preserving safe
  structural context.

## Architecture

### Diagnostic contract

`DiagnosticModels.swift` defines:

- `DiagnosticStatus: String, Codable, Sendable` with exactly `pass`, `warn`,
  `fail`, and `skip`.
- `RepairActionID` with stable current-core actions:
  `retryMCPServer`, `retryRemoteConnector`, `openAccessibilitySettings`,
  `openScreenRecordingSettings`, `openAutomationSettings`,
  `restoreConfigurationBackup`, `reassignLocalPort`, `repairLaunchAgent`, and
  `rerunVerifiedBootstrap`.
- `RepairActionDescriptor`, `DiagnosticResult`, `DiagnosticSummary`, and
  `DoctorReport`.

Reports use schema version 1, injected generation time, sorted deterministic
JSON keys, ISO-8601 dates, stable result ordering, and summary counts. Provider
errors are converted into bounded result reasons; raw provider messages,
request bodies, paths, and secret material are never copied into a report.

### Fact providers and pure checks

`DiagnosticProviders.swift` supplies protocols and live read-only adapters for:

- configuration files and permission metadata;
- installed helper/runtime/release facts and code-sign inspection;
- Keychain existence queries;
- managed-Python requester permission facts;
- configured-port/listener facts;
- LaunchAgent and owned-process lifecycle facts;
- disk-space and critical-path symlink facts;
- update-availability facts;
- local MCP and ngrok observations through explicit probe adapters.

Each provider is independently replaceable by a deterministic fake. The
configuration provider decodes `AppConfiguration` with the existing date and
validation semantics but never calls `loadOrCreate()` or a mutating recovery
path. The Keychain provider calls `SecItemCopyMatching` without
`kSecReturnData`; the local authenticated probe is a separate narrowly scoped
adapter and never places its credential in a fact or report.

`DiagnosticChecks.swift` contains individually callable pure check functions.
They consume observations, select at most one primary repair, and use these
semantics:

- required helper/runtime/config failures are `FAIL`;
- unsupported trust claims and unavailable receipt/integrity evidence are
  factual `WARN` or `SKIP`, never fabricated `PASS`;
- disabled remote mode, future Meridian/Cloudflare/Telegram Assistant systems,
  and unavailable update discovery are `SKIP`;
- low but noncritical disk space is `WARN` at an explicit injected threshold;
- an unrelated listener on the selected port is `FAIL` with only
  `reassignLocalPort`, and diagnosis never kills it;
- local MCP liveness, canonical authenticated readiness, tool inventory, and
  capability-group comparison remain distinct results;
- permissions use managed-Python requester facts when that runtime is the
  consumer, including Automation, active-console, and lock state.

`DoctorEngine.swift` gathers provider observations independently, catches
provider failures per check, and continues with unrelated checks. A missing
prerequisite produces a bounded `SKIP` where evaluation is not meaningful.

Installed facts are hidden behind an `InstalledReleaseFacts` abstraction so a
later installation-receipt branch can supply authoritative digests and
release metadata without changing the engine or check vocabulary.

The existing `LocalActivationProbe.swift` remains unchanged unless the
authenticated tools-list inventory cannot be exposed through an adapter. If a
small seam is unavoidable, it will return additional parsed facts while
preserving the exact health body, no-redirect session behavior, protocol
version, session establishment, tools/list validation, and application-level
`get_session_state` call. Existing activation tests will remain regression
coverage.

### Explicit repairs

`RepairEngine.swift` exposes one explicit action dispatch method and a typed
`RepairOutcome` with `repaired`, `notNeeded`, `refused`, `failed`, and
`requiresUserAction` states. It uses no generic shell-command abstraction.

Adapters own the mutations:

- retry actions call lifecycle adapters only;
- permission actions open the exact System Settings pane and return
  `requiresUserAction` until a later live re-check;
- backup restore validates the backup, preserves the bad primary through the
  existing recovery semantics, and refuses when both copies are invalid;
- port reassignment chooses and validates a genuinely free candidate, updates
  only the canonical config field, and records the client-reconfiguration
  consequence without terminating the occupying process;
- LaunchAgent repair accepts only the exact Mac Orchestrator label/path and
  contract, with ownership guards before write/reload;
- verified bootstrap recovery returns a pinned handoff/guidance adapter result;
  it never downloads arbitrary `main` or executes `curl | sh`.

Doctor has no reference to `RepairEngine` execution. The only connection is an
optional `RepairActionDescriptor` in a result.

### Shared redaction

`SensitiveDataRedactor.swift` is the canonical redaction primitive. It supports
longest-first exact secret replacement, connector URL and token-bearing route
normalization, home-directory normalization, and recursive replacement of
known secret-bearing JSON fields. Connector URLs are treated as credentials,
not merely as paths.

`StreamingLogRedactor` delegates line redaction to this primitive while keeping
its existing pending-line buffering, so a secret or route crossing pipe chunks
is still removed. `RotatingLog` uses the same redactor when sanitizing current
and rotated logs.

### Preview-first support bundles

`SupportBundle.swift` defines:

- `SupportBundlePlan` and entry descriptors containing a plan identifier,
  generation time, logical entry/category, inclusion reason, expected
  redaction, and optional approximate size;
- excluded sensitive categories covering credentials, connector URLs, request
  bodies, user documents, clipboard, browser data, and shell history;
- an engine that records plans it generated and refuses unapproved or altered
  plans;
- source adapters that collect only selected logical entries at creation time;
- a safe archive writer that validates relative unique entry names, rejects
  traversal/absolute paths/symlink escapes, and never follows unproven links.

The macOS writer uses a temporary staging directory and the platform archive
tool only after plan validation. Tests reopen and extract the resulting archive
and inspect every decoded filename and payload; compressed-byte searching is
only an additional negative assertion.

## Testing strategy

New deterministic suites cover the model/report contract, every status branch,
provider-failure isolation, read-only configuration observations, non-creating
Keychain presence, requester-truth permissions, port and ownership facts,
LaunchAgent/process states, MCP and ngrok observations, update SKIP behavior,
disk thresholds, repair ownership and non-invocation by diagnosis, preview
side-effect freedom, exact-plan archive creation, traversal/symlink/duplicate
entry rejection, and adversarial redaction.

Adversarial fixtures include overlapping secrets, plausible ngrok tokens,
connector URLs and route variants, chunk-boundary splits, rotated-log content,
structured secret fields, repeated absolute home paths, and malicious archive
filenames. Every extracted archive entry and sanitized log is checked for
absence of the planted values.

## Deferred integration and evidence

This branch does not wire the menu or terminal command, modify the lifecycle
state machine, add update discovery, change bootstrap/release machinery, or
contact Cloudflare, Meridian, Telegram Assistant, or other future providers.
Real TCC state, Gatekeeper behavior, installed receipt truth, live ngrok
account state, and Phase 3C update evidence remain manual or integration-pass
responsibilities. Local XCTest results remain environment-blocked if the
installed Command Line Tools cannot import XCTest; hosted exact-SHA CI is the
authoritative executable test evidence available for this branch.
