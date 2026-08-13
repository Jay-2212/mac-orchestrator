# Task 4 Fix-Round Report

Starting SHA: `05d9e568ad87e656dfc19229d75d1cc41668bad3`

Implementation commit: `4b7c4ef`

Branch: `phase3/doctor-support`

## Review fixes

- Current-core clipboard expectations now map `mac.clipboard.write` only to the shipped `clipboard` tool and expose the group only when the complete mapping is present.
- Remote diagnostics inject an existence-only Keychain presence provider. Auth is reported only as `present`, `absent`, or `inaccessible`; disabled remote mode contacts neither Keychain nor the ngrok Agent API.
- Local activation retains the canonical throwing API and request sequence, with a narrow phase-aware outcome seam. Transport and invalid-token failures after canonical health success preserve liveness truth.
- Port diagnostics no longer select the first PID from multiple listeners; ambiguity is reported as present but unowned with no selected PID.
- Lifecycle diagnostics require running processes, exact server/tunnel component markers, matching recorded PIDs, a matching owner, and reject malformed, stale, duplicate, ambiguous, and reused assignments.
- LaunchAgent validation now checks the supported label, exact one-element executable arguments, required launchd contract fields, supported optional distribution fields, symlink safety, and unknown-key rejection against the existing bootstrap/distribution writers.
- Deterministic coverage was added for installed-release facts, lifecycle malformed/stale/duplicate/PID-reuse cases, exact LaunchAgent contract rejection, multi-listener ambiguity, ngrok auth presence and redirected Agent API behavior, disk symlinks, clipboard inventory, and post-health activation branches.

## Verification

- `swift build` — PASS (exit 0).
- `swift build -c release` — PASS (exit 0).
- `git diff --check` — PASS (exit 0).
- `swift test` — BLOCKED (exit 1) by the installed Command Line Tools environment: `unable to resolve module dependency: 'XCTest'` from `Tests/MacOrchestratorTests/CapabilityReadinessCoordinatorTests.swift:2:8`; no XCTest cases executed.
- Focused XCTest invocation — same XCTest module-resolution blocker.

The final report commit appends this file after implementation commit `4b7c4ef`.
