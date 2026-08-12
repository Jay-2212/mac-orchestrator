# Phase 2 Terminal Bootstrap and Core Onboarding Design

**Date:** 2026-08-11
**Base:** `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6`
**Status:** implementation design for the Phase 2 public-core candidate

## Goal

Make Mac Orchestrator installable on a supported Apple-Silicon Mac from one
version-pinned Terminal command without asking an ordinary user to install Git,
Xcode/Command Line Tools, Python, uv, Homebrew, or ngrok. Preserve the Swift
supervisor and Wave 1 configuration/capability architecture.

This design deliberately produces a candidate release pipeline and a
deterministic local installer harness. It does not claim that an unpublished
branch is a hosted release, that an ad-hoc helper is Gatekeeper-trusted, or
that TCC grants survive replacement.

## Decisions

### Release trust and manifest

The generated public command targets immutable, same-tag release assets and
pins the release version plus both the bootstrap and manifest SHA-256 digests.
It verifies the downloaded bootstrap before executing it. The bootstrap then
verifies the independently pinned manifest before parsing or using it, and the
manifest describes and hashes the helper, uv, core payload, and direct-vendor
ngrok archive. Production URLs and digests are validated again at each trust
boundary, including rejection of all-zero sentinel digests. This is an
integrity chain, not an end-to-end signature against a compromised release
account; the limitation is documented and a project-owned signing key remains
future work.

The manifest has schema version 1 and contains:

- product version, bootstrap version/digest, runtime schema, and configuration
  schema range;
- arm64 and minimum macOS constraints;
- helper URL/digest, architecture, bundle identifier, version, and `adhoc`
  signing declaration;
- uv version/URL/digest, managed CPython version, lock digest, and core payload
  metadata;
- ngrok version/archive URL/digest/format, executable name, required Developer ID
  authority/team, and Agent API version;
- compatible runtime and configuration schema ranges.

The committed release template is intentionally marked as a release template. The
artifact builder emits a concrete manifest and generated install command only when
all release inputs and digests are present. The bootstrap rejects missing or
sentinel digests and mutable production URLs.

### User-owned installation layout

All public payloads live below:

```text
~/Library/Application Support/Mac Orchestrator/
├── app/Mac Orchestrator.app
├── python/cpython-3.13.14/
├── runtime/.venv/bin/python
├── runtime/{automac_mcp.py,pyproject.toml,uv.lock}
├── remote/ngrok/ngrok
├── remote/ngrok/ngrok.yml
├── install/staging-*/
└── install/runtime.previous/
```

The LaunchAgent points at the helper under `app/`. The helper remains outside
`/Applications` and does not contain ngrok. The canonical runtime path remains
the Wave 1 path even though bootstrap work is staged elsewhere.

### Staging and recovery

Bootstrap downloads and extracts into a unique staging directory under the
Application Support tree. It validates architecture, versions, lock identity,
imports, non-editable metadata, and smoke startup before promotion. Promotion
keeps the previous runtime in a named backup; a trap and the next invocation
restore that backup if promotion is interrupted. Configuration and Keychain
are never removed or replaced by installation.

### Dependency boundary

The default project dependency set remains the truthful first core runtime,
including OCR because the current Swift readiness contract already validates
EasyOCR payload presence and splitting OCR would make this wave substantially
more complex. `pyngrok`, office/document parser packages, and
Sentence-Transformers/indexer ML packages move to an explicit `indexer` extra.
The bootstrap copies only the core server and never copies `indexer.py`.

### Onboarding state and port

`OnboardingConfiguration` gains an additive, backward-compatible
`phase2State` value with four states: `fresh`, `legacyMigrated`, `interrupted`,
and `completed`. The existing `completed` boolean remains for compatibility and
is set only after local activation succeeds and the current managed requester
has satisfied the required desired UI/OCR readiness. The running supervisor's
activation flag remains an in-memory local-activation fact; remote setup remains
separate and optional. Legacy markers and legacy Full Control behavior continue
to be authoritative; a false legacy `completed` value never blocks supervisor
startup.

For a fresh or interrupted setup, the coordinator checks the configured port
before client setup and persists the first free port from a bounded candidate
range. A completed or genuine legacy install retains its persisted port and
fails clearly if an unrelated process occupies it.

### Local activation oracle

The supervisor’s first-run activation is a one-time strict probe:

1. `GET /__mac_orchestrator_health` returns HTTP 200 and the exact body
   `{"status":"ok"}`;
2. the capability-path MCP endpoint accepts authenticated `initialize`;
3. authenticated `tools/list` returns a tool array;
4. authenticated `tools/call` invokes the safe `get_session_state` orientation
   tool and receives an application-level success result. When `mac.ui` is
   desired, that result must also report the managed Python UI requester as
   available: Accessibility, Automation/Apple Events, active console, and an
   unlocked screen.

Only after the probe and a fresh readiness evaluation succeed does the
supervisor publish the server as running, start ngrok, and mark Phase 2
onboarding complete. Installation payload promotion, onboarding completion,
local activation, and optional remote setup remain distinct facts. Subsequent
health polls remain the existing lightweight lifecycle behavior; this does not
redesign the Phase 3 retry architecture.

### ngrok

The bootstrap downloads the exact Apple-Silicon archive named by the manifest,
checks its SHA-256, checks that it is arm64, and verifies the original ngrok
Developer ID authority/team with `codesign`. It never re-signs or embeds the
binary. The Swift supervisor starts the external binary with an app-owned v3
config and `NGROK_AUTHTOKEN` environment value read from Keychain. The token is
redacted from logs and is not passed in arguments.

Endpoint discovery uses the local Agent API `GET /api/endpoints`, matches the
live endpoint’s upstream against the configured loopback port, and constructs
the capability URL from the live HTTPS endpoint plus the existing Keychain
token. Deprecated `/api/tunnels` is not used.

The official ngrok documentation currently describes `/api/endpoints` as the
supported list endpoint, `NGROK_AUTHTOKEN` as an accepted environment value,
and the v3 config shape with `agent` and `endpoints`; these are implementation
inputs, not claims that a live account was exercised in this branch.

### Terminal handoff

The generated install command carries the trust warning through its pinned
release inputs. The bootstrap reports concise progress, defaults to Guided
Control, and offers explicit `--full-control` and `--remote` opt-ins. Full
Control requires an explicit confirmation flag. Remote setup uses a hidden
token prompt and can be skipped. A tiny Swift command-line mode stores the token in Keychain without
putting it in argv, then the helper is restarted and the live connector URL is
queried for display. The URL is explicitly labeled as a password-like
credential. Client instructions are copyable and distinguish HTTP URL clients
from JSON-configured clients.

## Interfaces

The implementation freezes these testable interfaces:

```swift
enum Phase2OnboardingState: String, Codable, Sendable {
    case fresh, legacyMigrated, interrupted, completed
}

enum OnboardingStateClassifier {
    static func classify(_ configuration: AppConfiguration) -> Phase2OnboardingState
}

enum LocalPortAllocator {
    static func select(
        preferred: Int,
        isOccupied: (Int) -> Bool,
        candidates: ClosedRange<Int> = 8000...8100
    ) throws -> Int
}

enum NgrokEndpointParser {
    static func publicURL(
        from data: Data,
        matching target: String
    ) -> URL?
}
```

`LocalActivationProbe` owns the exact HTTP/MCP request sequence and exposes a
small sanitized async error surface. `ProcessSupervisor` owns when that probe
is run and when the existing snapshot transitions to running. `NativeRuntimeCoordinator`
owns migrations, port persistence, and the completion marker. `ManagedRuntimeLaunchContract`
continues to own the Python environment and loopback target contract.

The helper command-line modes are deliberately narrow:

```text
--store-ngrok-token       read one token from stdin and write Keychain only
--set-profile guided|full update canonical configuration
--enable-remote           set the canonical remote desired state
--wait-for-local-activation
                          wait for exact authenticated local activation
--print-local-connector-url
                          wait for local activation and print its URL
--wait-for-remote-connector
                          wait for a live remote endpoint and print its URL
--print-connector-url     query the live local Agent API and print the URL
```

## Failure behavior

- Unsupported architecture or macOS stops before download with a concise
  explanation.
- Missing or mismatched manifest/payload digests stop before extraction or
  promotion.
- Any failed runtime validation leaves the previous runtime and configuration
  intact where promotion has not completed and reports the failing validation.
- Missing/invalid ngrok credentials leaves local MCP usable and reports remote
  access as optional/not ready.
- Missing macOS permissions are reported as pending and block onboarding
  completion when the corresponding UI/OCR capability is desired; opening
  System Settings is not counted as success.
- A stale or unavailable endpoint is never displayed as the current connector
  URL.

## Verification strategy

Deterministic tests cover manifest fields/digests, platform gates, staged
promotion recovery, dependency partition, onboarding classification, port
selection, exact health/MCP response parsing, endpoint parsing, token
redaction, and command-line configuration behavior. CI adds helper
architecture/signature checks, manifest/bootstrap syntax, lock/path scans,
clean/repeat/interrupted installer harnesses, and preserves all existing
required Wave 0/1 gates. Real TCC, Gatekeeper, and authenticated ngrok account
tests remain explicitly manual/staging evidence.

## Deferred boundaries

This design does not add Developer ID/notarization, DMG packaging, Intel,
Meridian changes, provider abstraction, a new retry state machine, a doctor,
full updater/rollback, or mature remote recovery. Those remain Phase 3/4 or
later work as specified by the governing handoff.
