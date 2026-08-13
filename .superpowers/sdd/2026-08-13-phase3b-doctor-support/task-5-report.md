# Task 5 Implementation Report

## Status

Implemented the pure diagnostic checks and read-only `DoctorEngine` for the
current Mac Orchestrator core.

## Baseline and scope

- Branch: `phase3/doctor-support`
- Repository exact required base: `3cf8e7d43f17524b705b9fe612eebe75a0450571`.
- Task 5 implementation parent: `37e9f884440074d89a21780231fefbf14c2747a8`.
  The Task 5 implementation parent is distinct from the repository required
  base above.
- Fix-round starting HEAD: `1e28cf69556cc41f43a25c01352f428ee7a7a563` on
  `phase3/doctor-support`.
- Changed implementation paths are exactly:
  - `Sources/MacOrchestrator/DiagnosticChecks.swift`
  - `Sources/MacOrchestrator/DoctorEngine.swift`
  - `Tests/MacOrchestratorTests/DoctorEngineTests.swift`
  - this Task 5 report
- No provider, live-provider, core, lifecycle, repair, configuration, Keychain,
  UI, release, bootstrap, or unrelated files were modified.

## Implementation

- Added individually callable pure checks with stable IDs for configuration
  read/schema/permissions/backup/recovery/generation/migration, installation
  helper/runtime/integrity/version match, code-sign trust, requester
  permissions/session state, Keychain presence, selected port, local MCP
  liveness/readiness/inventory, LaunchAgent/process ownership, remote ngrok and
  endpoint, update availability, disk space, critical paths, and future
  Meridian/Cloudflare/Telegram Assistant capabilities.
- Added `DoctorDependencies` with injected synchronous providers, an owned
  async local-MCP provider seam for the canonical activation adapter, explicit
  thresholds, an injected clock, and no mutation or repair dependency.
- Added fault-isolated orchestration: every provider is observed independently,
  failures become fixed safe reasons, results are sorted by stable ID, and the
  report uses the injected timestamp and existing deterministic JSON encoding.
- Optional/disabled and future components use `SKIP`; required missing config or
  runtime uses `FAIL`; low noncritical disk uses `WARN`; ad-hoc trust is
  reported as a factual `WARN`; every result has at most one bounded repair
  descriptor.
- Tests cover all four statuses, provider isolation, configuration branches,
  permissions/session, presence-only Keychain behavior, ports, MCP phases and
  inventory, lifecycle/PID reuse, remote/update branches, disk thresholds and
  unsafe paths, stable sorted deterministic reports, async canonical-provider
  selection, mutation-free execution, and bounded repair IDs.

## Verification

1. `swift test --filter DoctorEngineTests`
   - Blocked before XCTest execution by the installed Command Line Tools:
     `Tests/MacOrchestratorTests/CapabilityReadinessCoordinatorTests.swift:2:8
     unable to resolve module dependency: 'XCTest'`.
   - The command exits with code 1; package test code was not executed.
2. `swift build`
   - Passed with exit code 0.
   - Existing linker warnings remain for missing Command Line Tools search paths
     under `/Library/Developer/CommandLineTools/`.
3. `swiftc -parse Sources/MacOrchestrator/DiagnosticChecks.swift`
   - Passed with exit code 0.
4. `swiftc -parse Sources/MacOrchestrator/DoctorEngine.swift`
   - Passed with exit code 0.
5. `swiftc -parse Tests/MacOrchestratorTests/DoctorEngineTests.swift`
   - Passed with exit code 0.
6. `git diff --check`
   - Passed with no whitespace errors.
7. Read-only safety scan
   - No `RepairEngine` reference, connector-token generator/value helper,
     Keychain create/update, directory creation, file write/removal, chmod,
     process termination, archive, URLSession, or Process invocation appears in
     the Doctor implementation. Temporary-directory creation/removal exists
     only in the mutation-free test fixture setup.

## Commit

- Message: `feat: add read-only doctor engine`
- The final commit SHA and clean-worktree verification are recorded in the
  completion handoff.

## Fix-round evidence

- This fix round preserves the provenance distinction above: `3cf8e7d...` is
  the repository required base, while `37e9f884...` is the Task 5
  implementation parent.
- Permission facts are now gated by a validated, server-enabled local
  protected-behavior consumer (`mac.ui` or `mac.screenOcr`); disabled and
  remote-only configurations skip the permission result and do not contact
  the permission provider.
- MCP inventory now requires liveness, readiness, session establishment, and
  safe-call success before comparing the canonical inventory.
- Process ownership now requires a running service and at least one owned
  process in addition to the ownership marker and PID safety facts; the
  LaunchAgent structural check remains separate.
- Deterministic coverage was restored for migration markers, unsafe
  configuration permissions, owned and malformed ports, critical-path
  symlinks, complete MCP readiness, successful async-provider selection,
  installation/trust, Keychain, remote/update, disk, future, and lifecycle
  branches.
- The mutation-negative test now uses `ReadOnlyDoctorConfigurationContextProvider`
  against its temporary `config.json`, with ISO-8601 decoding, and snapshots
  bytes, generation, directory entries, dependent-provider calls, Keychain
  mutation/value calls, archive absence, and repair absence.
- `swift build`: passed after the fix round.
- `swiftc -parse` passed for all three owned source/test files.
- An out-of-repository XCTest shim typechecked `DoctorEngineTests.swift`.
- `swift test --filter DoctorEngineTests`: remains blocked before XCTest
  execution by the installed Command Line Tools (`CapabilityReadinessCoordinatorTests.swift:2:8 unable to resolve module dependency: XCTest`).
- Fix-round code/test commit: `ae0c1da34d9b7e6c98764a2b1dc0e84f56a58fdb`
  (`fix: close Task 5 doctor review findings`).

- Fix commit: `58c94f23bbe0a240ae9e25d1c10083c96d3ada0a` (`fix: close Task 5 doctor review findings`).
- Configuration checks now share one usable-file predicate requiring existence,
  readability, validity, valid observation state, current schema, and no symlink;
  restore repair is offered only for a validated non-symlink backup.
- Doctor now gathers an owned configuration snapshot first, derives all desired
  state from its validated configuration, selectively probes Keychain items, and
  skips local MCP, remote, lifecycle, port, permission, and Keychain dependents
  when configuration context is unavailable or disabled.
- `DoctorEngineTests` now has deterministic missing/malformed/invalid/unsupported
  configuration, backup, recovery, generation, integrity/version, requester
  permission/session, MCP, lifecycle/PID reuse, remote/auth/endpoint, disk,
  update/future, disabled-provider, and real mutation-free negative-control
  coverage. The vacuous `allSatisfy { _ in true }` assertion is removed.
- `swift build`: passed with exit code 0; existing Command Line Tools linker
  search-path warnings remain.
- `swiftc -parse` passed for `DiagnosticChecks.swift`, `DoctorEngine.swift`,
  and `DoctorEngineTests.swift`; a temporary out-of-repo XCTest shim also
  typechecked the test file against the rebuilt testable production module.
- `swift test --filter DoctorEngineTests`: remains blocked before XCTest
  execution by the installed Command Line Tools (`CapabilityReadinessCoordinatorTests.swift:2:8 unable to resolve module dependency: 'XCTest'`).
- `git diff --check` and the no-repair/no-mutation/scope scans passed; tracked
  worktree was clean after commit.
