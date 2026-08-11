# Phase 2 Acceptance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Leave PR #9 as a truthful Phase 2 candidate whose pinned bootstrap, staged installer, helper onboarding, local activation, optional ngrok flow, CI, and documentation agree on one safe user journey.

**Architecture:** Preserve the existing Swift supervisor, Application Support runtime root, Keychain identity, capability snapshot, and Bash fixture harness. Add an outer release-command trust anchor for the bootstrap and manifest, make the bootstrap wait on the real helper activation oracle, make the safe MCP result semantic rather than envelope-only, and use a managed-Python permission probe for capability readiness. Remove ngrok from project release outputs while retaining direct vendor acquisition and verification.

**Tech Stack:** Bash 3.2-compatible shell, macOS `plutil`/`shasum`/`codesign`/`launchctl`, SwiftPM/AppKit/XCTest, managed CPython `3.13.14`, uv `0.12.3`, FastMCP/Starlette, and deterministic fixture tests.

## Global Constraints

- Continue on `phase2/terminal-bootstrap-core-onboarding`; never reset it, merge PR #9, tag, publish a release, or modify Meridian/production resources.
- Preserve the Phase 1 base `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6` and the canonical runtime path `~/Library/Application Support/Mac Orchestrator/runtime/.venv/bin/python`.
- Fresh installs remain Guided Control; Full Control requires explicit confirmation; genuine legacy control state remains preserved.
- The copy-paste release command pins the product version, immutable bootstrap URL and SHA-256, immutable manifest URL and SHA-256, and verifies both before payload installation.
- Every downloaded helper, uv binary, core payload, lock file, and direct-vendor ngrok archive is digest-checked before use; project release assets never contain the ngrok archive.
- Promotion is confined to the user-owned support tree, rejects symlinked roots and unsafe archive members, and preserves a known-good runtime through failure/interruption.
- Local completion requires helper launch, exact health, authenticated MCP initialize, session-aware tools/list, and a semantically successful safe `get_session_state` call; remote setup remains opt-in and skippable.
- Permission readiness must use the managed Python requester for Python-consumed Accessibility/Screen Recording observations; opening System Settings is never success evidence.
- New behavior is test-first: add a regression test, observe the expected failure as far as the local XCTest/toolchain permits, then implement the smallest fix.

---

### Task 1: Close the bootstrap and manifest trust chain

**Files:**
- Modify: `script/bootstrap.sh`
- Modify: `release/manifest.template.json`
- Modify: `script/test_bootstrap.sh`
- Create: `script/generate_install_command.sh`
- Modify: `script/build_release_artifacts.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Test: `script/test_bootstrap.sh`

**Interfaces:**
- `bootstrap.sh` accepts `--manifest`, `--manifest-sha256`, `--bootstrap-sha256`, and `--release-version` (with equivalent environment variables for the harness); it refuses an unpinned manifest or bootstrap.
- `generate_install_command.sh` consumes the exact release version, bootstrap URL/SHA, and manifest URL/SHA and emits one copy-paste command without placeholders.
- `build_release_artifacts.sh` computes the concrete manifest SHA after writing the manifest and emits the command snippet beside the assets.

- [x] Add fixture cases that use the previous manifest digest and reject a modified manifest before parsing, reject a modified bootstrap before execution, reject a modified core payload, reject malformed/sentinel digests, and accept the exact pinned flow.
- [x] Run the focused fixture cases and confirm they fail for the missing pins or missing verification rather than passing by accident.
- [x] Add pinned argument/env parsing, validate the bootstrap file before manifest use, verify the downloaded manifest before parsing, and compare the manifest’s bootstrap/product values with the pinned command values.
- [x] Implement deterministic command generation with a temporary download file, `shasum -c`, exact release URLs, and explicit manifest/bootstrap digests; do not use a mutable branch URL or an unverified pipe.
- [x] Add CI assertions for the generated command, exact digest presence, immutable release URLs, and sentinel-hash rejection.
- [x] Run `bash -n`, the focused harness, JSON parsing, and `git diff --check`.

### Task 2: Harden archive extraction, promotion, recovery, and ngrok distribution

**Files:**
- Modify: `script/bootstrap.sh`
- Modify: `script/build_release_artifacts.sh`
- Modify: `script/test_bootstrap.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/ci.yml`
- Modify: `docs/RELEASING.md`
- Modify: `README.md`

**Interfaces:**
- Core payload extraction accepts only the declared regular files and writes them below the staging runtime; ngrok extraction reads the verified executable into the support tree without publishing the vendor ZIP.
- A malformed promotion marker or missing required backup fails closed without deleting outside the support root.
- Release assembly may download a vendor ngrok ZIP into a temporary CI directory for digest/signature/architecture validation, but `dist/release` and the GitHub release asset list exclude it.

- [x] Add tests for a symlinked support/install root, unsafe tar/zip entries, malformed recovery markers, missing required backups, and preservation of the previous runtime after every failed phase.
- [x] Run those tests against the current implementation and record the expected unsafe behavior/failure before changing extraction or promotion code.
- [x] Enforce non-symlink support roots, regular-file archive members, bounded extraction, validated executable paths, and backup presence checks; keep cleanup restricted to canonical descendants.
- [x] Remove ngrok copying from `build_release_artifacts.sh`, remove it from the release upload list, and add a required assertion that no release output contains `ngrok-arm64.zip` or an ngrok binary inside the helper.
- [x] Keep direct `bin.equinox.io` acquisition, SHA-256 validation, arm64 validation, and original Developer ID authority/team verification in the installer/assembly path.
- [x] Run the complete bootstrap harness, shell syntax, release workflow static checks, and a staged-diff/path scan.

### Task 3: Make activation semantic and make the installer complete the local journey

**Files:**
- Modify: `Sources/MacOrchestrator/LocalActivationProbe.swift`
- Modify: `Tests/MacOrchestratorTests/LocalActivationProbeTests.swift`
- Modify: `Sources/MacOrchestrator/TerminalCommand.swift`
- Modify: `Sources/MacOrchestrator/ProcessSupervisor.swift`
- Modify: `script/bootstrap.sh`
- Modify: `Sources/MacOrchestrator/main.swift`

**Interfaces:**
- `LocalActivationProbe.run` owns the exact request sequence and throws sanitized errors for transport failures, JSON-RPC errors, malformed results, and application-level tool failures; the separate managed Python probe owns permission observations.
- Terminal command `--wait-for-local-activation` retries the exact local oracle and returns nonzero with a concise safe-state message on timeout; `--print-local-connector-url` returns the current local capability URL only when explicitly requested.
- Bootstrap writes/loads the LaunchAgent, waits for the helper’s local activation result, prints the selected local client instructions, and only then reports completion; requested remote setup waits for a live HTTPS endpoint and remains independently skippable.

- [x] Add tests for HTTP success plus application-level safe-tool failure, malformed structured/text result, missing safe tool, wrong auth path, wrong session header, and the complete semantic success envelope.
- [ ] Run the focused XCTest filter and confirm the new cases fail for the current envelope-only validator; local XCTest cannot resolve XCTest, so hosted CI remains the behavioral execution gate.
- [x] Parse FastMCP `structuredContent`/`content` enough to require `status == success`, reject `isError`, and retain only permission/session fields needed for truthful onboarding output.
- [x] Add the narrow terminal wait/local-URL commands, invoke them after `launchctl bootstrap`/`kickstart`, and print client-specific HTTP/JSON setup guidance without putting credentials in logs.
- [x] Add bootstrap contract assertions for activation gating and verify the fixture install cannot report completion before the activation stage; cover remote skip and requested live endpoint handoff in the helper contract.
- [ ] Run Swift build, focused/hosted XCTest, the complete fixture harness, and a manual local activation probe where the installed helper/runtime can be safely exercised.

### Task 4: Verify the real managed requester for permission readiness

**Files:**
- Modify: `automac_mcp.py`
- Modify: `Sources/MacOrchestrator/CapabilityReadinessCoordinator.swift`
- Modify: `Sources/MacOrchestrator/CapabilityRegistry.swift`
- Modify: `Tests/MacOrchestratorTests/CapabilityReadinessCoordinatorTests.swift`
- Modify: `test_mcp_server.py`
- Modify: `test_capabilities.py`

**Interfaces:**
- The managed Python runtime exposes a safe one-shot permission probe using the same PyObjC requester as the MCP server; it reports Accessibility, Screen Recording, active-console, and lock observations without destructive actions.
- `CapabilityReadinessCoordinator` uses the managed probe for Python-consumed readiness when the runtime exists, treats probe failure as not-ready, and preserves injected deterministic fakes for tests.
- Automation/Apple Events remains an explicitly action-triggered permission with truthful guidance; no TCC database mutation or quarantine workaround is introduced.

- [x] Add deterministic probe parsing tests and a negative test proving Swift-only `AXIsProcessTrusted`/`CGPreflightScreenCaptureAccess` cannot mark a managed Python capability ready when the managed probe denies it.
- [ ] Run the focused Python/Swift tests and confirm the old Swift-only behavior fails the new assertion; local XCTest cannot resolve XCTest.
- [x] Implement the one-shot managed requester probe and use its result in readiness; surface concise pending/guidance text rather than claiming Settings-open success.
- [x] Add safe Automation denial classification/guidance without making a harmless local core activation depend on an unrequested Apple Events grant.
- [ ] Run the deterministic Python suite, Swift build/tests, and if safely possible perform denial → guidance → grant → re-probe on the real Apple-Silicon Mac without changing unrelated TCC state.

### Task 5: Reconcile UX, docs, CI, dependencies, and redaction

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/CLIENT_SETUP.md`
- Modify: `docs/RELEASING.md`
- Modify: `CONTRIBUTING.md`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `pyproject.toml`
- Modify: `uv.lock`
- Modify: `test_dependency_partition.py`
- Modify: `test_capabilities.py`

**Interfaces:**
- Public docs describe the actual generated command asset, direct-vendor ngrok acquisition, ad-hoc/TCC limits, local/remote completion semantics, and deferred Phase 3/4/Meridian work.
- CI required jobs remain fail-closed and prove trust, distribution, install-state, activation, secrets/path scans, dependency partition, and generated release-command consistency.
- Core dependency tests assert no `pyngrok`, indexer ML, or document-parser package is in the ordinary runtime and verify the real frozen import set.

- [x] Add negative-control scans/tests for connector URL/token/path redaction, staging-path leakage, ngrok release redistribution, exact tested SHA, and stale documentation claims.
- [x] Run each new scan/test against the current branch and record any failures before editing the corresponding contract.
- [x] Update code/docs/CI terminology and output so the normal terminal journey is calm, truthful, and actionable while verbose diagnostics remain redacted.
- [x] Reconcile dependency declarations/lock metadata only where the actual import graph proves a change is needed; do not remove direct runtime dependencies by intuition.
- [x] Run every deterministic gate locally with `.venv/bin/python`, `uv lock --check`, shell/JSON/workflow checks, and the complete Swift build/test commands.

### Task 6: Independent adversarial review and release handoff

**Files:**
- Review: `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6..HEAD`
- Review: all changed files and generated artifacts

- [x] Re-run the full local verification matrix after integration and inspect output rather than relying on exit codes alone.
- [x] Perform a fresh P0/P1 review of trust anchors, archive/promotion safety, requester truth, activation semantics, redaction, release output, and Phase 1 regressions.
- [ ] Verify real hardware/TCC and ngrok-account evidence separately; classify unavailable interactive/provider checks as `PARTIALLY VERIFIED`, never as success.
- [ ] Inspect final diff, branch/PR metadata, working tree, exact pushed SHA, and hosted CI at that SHA; ensure no tag/release/merge/external resource mutation occurred.
- [ ] Push the same Phase 2 branch and leave PR #9 as a draft ready for independent acceptance review.
