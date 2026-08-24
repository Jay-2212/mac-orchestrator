# Phase 5C Meridian Mac Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a privacy-safe Mac consumer boundary for Meridian's optional one-shot indexer.

**Architecture:** Keep the canonical Meridian indexer as an optional installed executable. Swift owns configuration, optional-tool promotion, child-process invocation, scheduling, cancellation, and lifecycle receipts; Meridian owns local discovery, Core requests, reconciliation, and index state.

**Tech Stack:** Swift 5.9, SwiftPM macOS 13, Foundation, CryptoKit, XCTest.

## Global Constraints

- Consume Meridian Indexer Protocol `1.0.0` and Core API `1.0.0`, schema `2`.
- Use `MERIDIAN_CORE_TOKEN` only in the optional child process environment; never persist or log it.
- Send explicit opaque scope IDs and canonical relative paths; never send Mac absolute roots to Core or place them in logs/support artifacts.
- Do not copy Meridian `src/indexer`, add Node/indexer dependencies, or alter Core/provisioning code.
- Preserve last-known-good optional tool and index receipts on failed staging, cancellation, or reconciliation-required outcomes.

---

### Task 1: Configuration and optional installed-tool boundary

**Files:**
- Create: `Sources/MacOrchestrator/MeridianIndexer.swift`
- Modify: `Sources/MacOrchestrator/Configuration.swift`
- Test: `Tests/MacOrchestratorTests/MeridianIndexerTests.swift`

**Interfaces:**
- `MeridianSourceScope`, `MeridianIndexerConfiguration`, and `MeridianIndexerInvocation` are Codable, validated value types.
- `MeridianIndexerToolInstaller.install(candidateURL:expectedSHA256:)` atomically promotes the optional executable.

- [ ] Write failing tests for explicit selection validation, deterministic JSON, and invalid URL/path/token-shaped data.
- [ ] Run `swift test --filter MeridianIndexerTests` and confirm the new tests fail for missing types/behavior.
- [ ] Implement value validation and exact `baseUrl`/`statePath`/`sources` encoding.
- [ ] Add digest-checked staging under the owned optional tool directory, preserving the current executable on candidate failure.
- [ ] Run the focused tests and inspect serialized output for paths/secrets outside the intended local stdin shape.

### Task 2: Process runner and lifecycle coordinator

**Files:**
- Modify: `Sources/MacOrchestrator/ManagedRuntimeLaunchContract.swift`
- Modify: `Sources/MacOrchestrator/Models.swift`
- Modify: `Sources/MacOrchestrator/ProcessSupervisor.swift`
- Modify: `Sources/MacOrchestrator/LifecycleScheduler.swift` only if a scheduling seam is needed
- Test: `Tests/MacOrchestratorTests/MeridianIndexerTests.swift`

**Interfaces:**
- `MeridianIndexerCoordinator` owns one `Process`, one schedule handle, and a generation fence.
- `ProcessSupervisor` calls `launch`, `apply`, `cancel`, `retry`, `rebuild`, `stopForQuit`, and maintenance reconciliation.

- [ ] Write failing tests for no-overlap, fixed scheduling, cancellation, retry/rebuild, result classification, and bounded progress parsing.
- [ ] Run the focused tests and confirm each new behavior fails before implementation.
- [ ] Implement child stdin/environment isolation, stdout allow-listing, stderr dropping, exit classification, and owned-process cancellation.
- [ ] Reconcile the coordinator on launch/config changes and stop it before maintenance/quit without changing existing MCP/remote semantics.
- [ ] Run focused tests and the existing lifecycle/runtime tests.

### Task 3: Documentation and verification evidence

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/RELEASING.md`
- Create: `docs/manual/PHASE5C_MERIDIAN_EVIDENCE.md`

- [ ] Document the optional installed-tool boundary, exact invocation contract, and manual evidence split.
- [ ] Add static checks/tests proving the base runtime has no Meridian indexer payload/dependency.
- [ ] Run `swift build`, `swift build -c release`, `swift test`, `git diff --check`, and repository hygiene scans.

### Task 4: Independent review and handoff

- [ ] Dispatch one fresh `gpt-5.6-luna` high-reasoning reviewer for architecture/privacy/security/protocol/lifecycle.
- [ ] Verify each finding against the actual diff, fix all substantive P0/P1/P2 issues, and rerun affected tests.
- [ ] Commit intentionally, push the Mac draft branch, and verify exact-head hosted CI.
- [ ] Create and supervise exactly one durable Phase 5D child using `gpt-5.6-luna` high reasoning; no merge/tag/release/publication.
