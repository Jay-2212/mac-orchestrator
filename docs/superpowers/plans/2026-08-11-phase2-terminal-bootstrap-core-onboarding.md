# Phase 2 Terminal Bootstrap and Core Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a truthful Phase 2 public-core candidate that installs the prebuilt arm64 helper and private Python runtime from immutable release inputs, preserves Wave 1 behavior, and verifies local MCP activation before presenting remote setup.

**Architecture:** A Bash bootstrap performs platform checks, digest verification, staged private-runtime installation, helper/ngrok verification, and LaunchAgent setup. Swift remains the canonical configuration and lifecycle plane; it classifies onboarding state, persists a safe local port, performs the exact first-run activation probe, stores ngrok credentials through Keychain, and discovers the live endpoint through `/api/endpoints`. The public core keeps OCR in the first runtime and moves indexer/document-parser dependencies to an explicit optional extra.

**Tech Stack:** SwiftPM/AppKit, Swift 5.9 language mode with macOS 13 APIs, Bash 3.2-compatible shell tooling, `plutil`, `shasum`, `codesign`, pinned uv `0.12.3`, managed CPython `3.13.14`, FastMCP/Starlette, XCTest, and deterministic Python fixture tests.

## Global Constraints

- Base commit is exactly `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6`; do not use the feasibility-spike branch as the implementation base.
- Preserve `~/Library/Application Support/Mac Orchestrator/runtime/.venv/bin/python` and the Wave 1 managed launch contract.
- Fresh installs default to Guided Control; Full Control requires explicit selection and warning.
- MCP stays loopback-bound and capability-path authenticated; connector URLs and tokens are credentials.
- No Developer ID, notarization, DMG-first flow, Gatekeeper weakening, silent quarantine removal, Intel, Meridian source changes, or Phase 3/4 lifecycle expansion.
- The helper is arm64, ad-hoc signed only, installed under user-owned Application Support, and does not contain ngrok.
- Ngrok is acquired directly from the vendor, verified by digest and original Developer ID identity, and is never re-signed.
- Every new behavioral production function gets a deterministic test written and observed failing before its implementation.
- CI required gates remain fail-closed; only genuinely TCC-dependent observations remain informational.

## File Map

- Create `release/manifest.schema.json` and `release/manifest.template.json` for the immutable payload contract.
- Create `script/bootstrap.sh`, `script/build_release_artifacts.sh`, and `script/test_bootstrap.sh` for public install logic, release assembly, and fixture coverage.
- Modify `pyproject.toml`, `uv.lock`, and add `test_dependency_partition.py` for the core/indexer boundary.
- Create `Sources/MacOrchestrator/OnboardingState.swift`, `LocalPortAllocator.swift`, `LocalActivationProbe.swift`, and `NgrokSupport.swift` for focused testable seams.
- Modify `Configuration.swift`, `Migrations.swift`, `NativeRuntimeCoordinator.swift`, `ProcessSupervisor.swift`, `ManagedRuntimeLaunchContract.swift`, `KeychainStore.swift`, `main.swift`, and `Models.swift` only for the frozen Phase 2 contracts.
- Add focused XCTest files for onboarding/ports, activation, endpoint parsing, and command-line/configuration behavior.
- Modify `script/package_app.sh`, `script/distribute.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `README.md`, `docs/ARCHITECTURE.md`, and `docs/RELEASING.md` to separate public bootstrap from maintainer source-build workflows.

### Task 1: Establish release manifest schema and deterministic bootstrap tests

**Files:**
- Create: `release/manifest.schema.json`
- Create: `release/manifest.template.json`
- Create: `script/test_bootstrap.sh`
- Test: `script/test_bootstrap.sh` fixture cases

**Interfaces:**
- The manifest exposes `schemaVersion`, product/bootstrap data, platform constraints, helper payload, runtime/uv data, lock identity, and ngrok vendor metadata.
- `script/bootstrap.sh` consumes either a concrete manifest URL or `MAC_ORCHESTRATOR_MANIFEST_PATH` in the local harness.

- [ ] Write fixture tests for valid manifest acceptance, missing digest rejection, wrong digest rejection, unsupported architecture rejection, and macOS-version rejection.
- [ ] Run `bash script/test_bootstrap.sh` and confirm each new case fails because `script/bootstrap.sh` and the validation functions do not exist.
- [ ] Add Bash validation helpers that use `/usr/bin/plutil`, `/usr/bin/shasum`, `uname`, and `sw_vers` only; reject sentinel/empty digests and mutable-main URLs.
- [ ] Run the fixture suite and confirm all manifest/platform cases pass.
- [ ] Add a local fixture mode that never downloads or launches a process and prints only stage names.
- [ ] Run `git diff --check` and commit the isolated manifest/bootstrap-test contract.

### Task 2: Implement staged bootstrap, helper installation, and release assembly

**Files:**
- Create: `script/bootstrap.sh`
- Create: `script/build_release_artifacts.sh`
- Modify: `script/package_app.sh`
- Modify: `script/distribute.sh`
- Test: `script/test_bootstrap.sh`

**Interfaces:**
- `script/bootstrap.sh [--full-control] [--remote] [--verbose]` installs beneath the canonical support directory and never changes global `PATH`.
- `script/build_release_artifacts.sh` emits an arm64 ad-hoc helper zip and a concrete manifest only when all required release input digests are supplied.
- `script/package_app.sh` builds a helper without bundling or signing ngrok.

- [ ] Extend the bootstrap tests with clean, repeat, failed-download, and interrupted-promotion fixtures that use temporary `HOME`/support roots and fake `curl`, `sw_vers`, and `uname` commands.
- [ ] Run the tests and verify the new cases fail at the missing staging/promotion behavior.
- [ ] Implement unique staging directories, `0700` support/install directories, `0600` metadata/config files, verified downloads, private `UV_PYTHON_INSTALL_DIR`, managed CPython `3.13.14`, pinned uv `0.12.3`, `uv venv --managed-python`, and `uv sync --frozen --no-editable`.
- [ ] Validate interpreter version/arm64/path, lock hash, required imports, runtime health smoke, and absence of staging paths before promotion.
- [ ] Promote with a preserved previous runtime and recovery marker; ensure a failed run does not remove config or Keychain state.
- [ ] Build and verify the helper bundle with `codesign --verify --deep --strict`, `file`, and the expected bundle metadata. Install the helper at `Application Support/Mac Orchestrator/app/Mac Orchestrator.app`.
- [ ] Download and verify ngrok from the concrete manifest into `remote/ngrok/ngrok`, check its original Developer ID identity/team, create a restrictive v3 config without a token, and never re-sign it.
- [ ] Add concise trust/profile/permission/remote messages and client-specific handoff templates; default to Guided Control and permit remote setup to be skipped.
- [ ] Run `bash script/test_bootstrap.sh`, a local helper release build, and `git diff --check`; commit the installer/artifact work.

### Task 3: Partition core and indexer dependencies

**Files:**
- Modify: `pyproject.toml`
- Modify: `uv.lock`
- Create: `test_dependency_partition.py`
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/RELEASING.md`

**Interfaces:**
- The default dependency list contains the core/UI/OCR runtime and no `pyngrok`, Sentence Transformers, or document-parser packages.
- `[project.optional-dependencies].indexer` contains the standalone indexer and parser dependencies.
- Core bootstrap payload excludes `indexer.py`.

- [ ] Write the partition test asserting the exact package names moved to the indexer extra and asserting `pyngrok` is absent from all installable core dependencies.
- [ ] Run `PYTHONDONTWRITEBYTECODE=1 python3 -B test_dependency_partition.py` and observe the expected failure against the current monolithic manifest.
- [ ] Move the packages to the optional extra without removing direct `fastapi`/`uvicorn` declarations by intuition.
- [ ] Regenerate the lock with `uv lock`; verify `uv lock --check`.
- [ ] Run core frozen sync with the exact managed interpreter and `uv sync --frozen --no-editable`; verify imports, MCP startup, deterministic pagination, capability/policy tests, and no indexer file in the staged core payload.
- [ ] Run the partition test and report core versus optional artifact sizes where measured.
- [ ] Update contributor docs to show `uv sync --extra indexer` for maintainers and the bootstrap path for ordinary users.
- [ ] Commit the dependency boundary with its lock/import evidence.

### Task 4: Add onboarding state classification and free-port persistence

**Files:**
- Create: `Sources/MacOrchestrator/OnboardingState.swift`
- Create: `Sources/MacOrchestrator/LocalPortAllocator.swift`
- Modify: `Sources/MacOrchestrator/Configuration.swift`
- Modify: `Sources/MacOrchestrator/Migrations.swift`
- Modify: `Sources/MacOrchestrator/NativeRuntimeCoordinator.swift`
- Test: `Tests/MacOrchestratorTests/OnboardingStateTests.swift`
- Test: `Tests/MacOrchestratorTests/RuntimeBootstrapTests.swift`

**Interfaces:**
- `Phase2OnboardingState` is Codable and additive to schema v1.
- `OnboardingStateClassifier.classify(_:)` returns fresh, legacyMigrated, interrupted, or completed.
- `LocalPortAllocator.select(preferred:isOccupied:candidates:)` returns the preferred free port or the first free bounded candidate and throws when none exists.

- [ ] Write tests for all four classifications, old v1 JSON without `phase2State`, legacy Full Control preservation, preferred-port selection, occupied-default fallback, and exhausted candidates.
- [ ] Run the focused XCTest filter and confirm the new symbols/tests fail before implementation.
- [ ] Add the additive `phase2State` field, classifier, and migration state updates without making `onboarding.completed` a startup gate.
- [ ] Add injected occupancy selection to `NativeRuntimeCoordinator.prepare()`; persist the selected port before returning a launch contract for fresh/interrupted setup.
- [ ] Add a completion method used only after successful activation; preserve old config/keychain/legacy markers.
- [ ] Run the focused tests and the existing migration/runtime tests; commit the state/port seam.

### Task 5: Add exact local activation and live ngrok endpoint parsing

**Files:**
- Create: `Sources/MacOrchestrator/LocalActivationProbe.swift`
- Create: `Sources/MacOrchestrator/NgrokSupport.swift`
- Modify: `Sources/MacOrchestrator/ProcessSupervisor.swift`
- Modify: `Sources/MacOrchestrator/Models.swift`
- Test: `Tests/MacOrchestratorTests/LocalActivationProbeTests.swift`
- Test: `Tests/MacOrchestratorTests/NgrokSupportTests.swift`

**Interfaces:**
- `LocalActivationProbe` performs exact health, authenticated MCP initialize/tools/list, and safe `get_session_state` calls over the capability URL.
- `NgrokEndpointParser.publicURL(from:matching:)` consumes `/api/endpoints` JSON and returns only a live HTTPS URL whose upstream matches the owned loopback target.

- [ ] Write URLProtocol fixture tests for exact health 200/body, wrong status/body rejection, MCP initialize/session-header handling, missing tools rejection, safe-call rejection, endpoint upstream mismatch, HTTP endpoint rejection, and valid endpoint acceptance.
- [ ] Run the focused tests and observe expected failures before implementation.
- [ ] Implement the probe with bounded timeouts, no token logging, JSON-RPC request IDs, `Mcp-Session-Id` propagation, and SSE/JSON response extraction.
- [ ] Replace the supervisor’s permissive health check with exact status/body validation and run the first-run probe once before setting `.running` or starting the tunnel.
- [ ] Mark onboarding complete only after the safe call succeeds; keep later polling lightweight.
- [ ] Replace `/api/tunnels` parsing with `/api/endpoints` parsing and external ngrok path resolution.
- [ ] Run focused and existing supervisor-policy tests; commit the activation/endpoint seam.

### Task 6: Add secure Keychain handoff and command-line onboarding controls

**Files:**
- Modify: `Sources/MacOrchestrator/KeychainStore.swift`
- Modify: `Sources/MacOrchestrator/ManagedRuntimeLaunchContract.swift`
- Modify: `Sources/MacOrchestrator/ProcessSupervisor.swift`
- Modify: `Sources/MacOrchestrator/main.swift`
- Modify: `Sources/MacOrchestrator/AppDelegate.swift`
- Modify: `Tests/MacOrchestratorTests/RuntimeLaunchContractTests.swift`
- Modify: `Tests/MacOrchestratorTests/KeychainStoreTests.swift`

**Interfaces:**
- `KeychainItem.ngrokAuthtoken` is a dedicated secret item; no normal configuration field contains the token.
- Command-line modes read token input from stdin and never accept it as an argument.
- Managed ngrok launch injects `NGROK_AUTHTOKEN` only into the owned child environment and includes it in log redaction.

- [ ] Write tests for ngrok token storage/retrieval, environment redaction, no-token remote failure, and profile/remote configuration updates.
- [ ] Run the focused tests and observe failures against the current Keychain/launch contract.
- [ ] Implement the narrow command-line modes `--store-ngrok-token`, `--set-profile`, `--enable-remote`, and `--print-connector-url` before starting `NSApplication`.
- [ ] Resolve the external ngrok path/config from Application Support, pass `NGROK_AUTHTOKEN` without argv, and preserve original ngrok signing.
- [ ] Make full-control selection explicit and keep fresh Guided defaults unchanged.
- [ ] Run focused tests, compile the app, and inspect `ps`/log output in a fixture for token absence; commit the secure handoff.

### Task 7: Extend required CI/release gates and documentation

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/RELEASING.md`
- Create: `docs/CLIENT_SETUP.md`

**Interfaces:**
- Required CI checks include Swift build/test, manifest/bootstrap syntax, dependency partition, lock/path/secret checks, and artifact verification.
- TCC-dependent UI observations remain visibly informational; required-gate aggregation remains fail-closed.

- [ ] Write shell/CI assertions for no mutable-main bootstrap, no source-build prerequisite in the public path, no `pyngrok` core dependency, no indexer payload, no staging/build-machine paths, and no secret-shaped values.
- [ ] Run the assertions against the existing branch and observe failures for each not-yet-implemented contract.
- [ ] Add required jobs/steps without `continue-on-error` for deterministic gates; preserve existing job names/aggregation semantics where possible.
- [ ] Add release artifact assembly/manifest consistency checks without dispatching a release or tag.
- [ ] Rewrite public installation docs to the terminal-first flow and mark `package_app.sh`/`distribute.sh` as maintainer workflows.
- [ ] Document ad-hoc/Gatekeeper/TCC limitations, remote credential handling, local activation oracle, client instructions, and explicit deferred Phase 3/4 work.
- [ ] Run local CI-equivalent commands and `git diff --check`; commit documentation/workflow changes.

### Task 8: Adversarial review and handoff

**Files:**
- Review all changed files; create no new product behavior unless a finding requires a focused fix.

- [ ] Audit bootstrap/payload trust anchoring, digest source independence, staging recovery, no-editable metadata, source/build-machine path leakage, and mutable-main references.
- [ ] Audit token handling across shell history, argv, environment visibility, logs, screenshots, diagnostics, and connector URL presentation.
- [ ] Audit fresh Guided defaults, legacy Full preservation, occupied-port behavior, exact health/MCP probe, endpoint freshness, and optional remote skip.
- [ ] Run `swift build`, `swift build -c release`, `swift test` where the toolchain permits, pinned Python compile/sync/deterministic tests, bootstrap fixture tests, dependency partition tests, `git diff --check`, and secret/path scans.
- [ ] Inspect final ancestry and changed-file scope from `a6bd52b…`; do not claim hosted CI/manual TCC/ngrok evidence that was not observed.
- [ ] Commit only intended changes, push `phase2/terminal-bootstrap-core-onboarding`, and open a draft PR if the GitHub workflow is available; never merge/tag/publish.
