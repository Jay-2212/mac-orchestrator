# Architecture

Phase 2 separates the public installation path from maintainer source-build
tools. The service remains local-first and single-user: the Python server binds
to loopback, while an optional external ngrok agent provides a capability URL
for a trusted client.

## Installed components

```text
Versioned release asset
  └── bootstrap.sh
        ├── verified manifest and payloads
        └── user-owned Application Support/Mac Orchestrator/
              ├── app/Mac Orchestrator.app
              │     └── LaunchAgent → Swift helper
              ├── python/cpython-3.13.14/
              ├── runtime/.venv/bin/python
              │     └── automac_mcp.py → 127.0.0.1:<selected-port>
              ├── remote/ngrok/ngrok (optional external binary)
              └── meridian/indexer (optional separately installed executable)
```

The helper is installed below:

```text
~/Library/Application Support/Mac Orchestrator/
├── app/Mac Orchestrator.app
├── python/cpython-3.13.14/
├── runtime/.venv/bin/python
├── runtime/{automac_mcp.py,pyproject.toml,uv.lock}
├── remote/ngrok/ngrok
├── remote/ngrok/ngrok.yml
└── install/{staging-*,runtime.previous/}
```

The helper does not contain ngrok. The bootstrap downloads the exact vendor
archive named by the concrete manifest, verifies SHA-256, architecture, and
the original Developer ID authority/team, and never re-signs the binary. The
LaunchAgent starts only the helper under the installing user's Application
Support directory.

The public bootstrap also does not contain Meridian's optional indexer or its
Node/document/embedding dependencies. A separate Meridian distribution may
promote one executable under `meridian/indexer`; the native helper verifies
its SHA-256, regular-file ownership, and executable bit before promotion and
keeps `meridian/indexer.previous` as the last-known-good optional tool.

## Bootstrap trust and promotion

The release page publishes a generated install handoff that pins the bootstrap
asset, bootstrap SHA-256, manifest asset, and manifest SHA-256 to one version.
The bootstrap verifies those outer anchors before parsing a schema-versioned
manifest containing product, platform, helper, uv/runtime, lock, core-payload,
and ngrok metadata. Empty, all-zero, sentinel, or mismatched digests stop
before extraction or promotion. This protects against accidental or tampered
payload substitution but is not an end-to-end signature against a compromised
release account; project-owned signing is deferred.

Installation uses a unique staging directory and validates architecture,
versions, lock identity, imports, non-editable metadata, and a local health
smoke before promotion. A previous runtime is retained, and interrupted
promotion is recorded for recovery by the next invocation. Configuration and
Keychain state are never replaced by a runtime install failure. The public
bootstrap does not modify global `PATH` and does not require a source checkout,
Swift build, Xcode, Homebrew, or a preinstalled Python/uv.

Maintainer scripts such as `script/package_app.sh`, `script/distribute.sh`, and
the legacy `script/bootstrap_ngrok.sh` are separate source-build/assembly
workflows. They are not part of the ordinary-user contract and must not be
used as a substitute for the immutable bootstrap.

## Swift helper responsibilities

The Swift helper is the lifecycle and configuration plane:

- `ProcessSupervisor.swift` owns the managed Python child and, only when local
  activation succeeds, the optional external ngrok child.
- `NativeRuntimeCoordinator` owns the canonical runtime path, migration,
  bounded port selection, and completion state.
- `OnboardingStateClassifier` distinguishes `fresh`, `legacyMigrated`,
  `interrupted`, and `completed` without making a false legacy completion bit a
  startup gate.
- `KeychainStore.swift` owns the capability token and dedicated ngrok
  authtoken item. Tokens are not normal configuration fields or process
  arguments.
- `RotatingLog.swift` writes local restricted logs and redacts capability
  credentials.
- `MeridianIndexer.swift` owns the optional installed-tool boundary, explicit
  scope configuration, exact stdin handoff, bounded progress parsing, fixed
  scheduling, cancellation, retry/rebuild requests, and child lifecycle. It
  does not implement Meridian discovery, parsing, Core calls, or index state.
- `MenuController.swift` and `AppDelegate.swift` expose profile, permission
  guidance, remote, restart, and explicit Copy Connector URL controls. Opening
  Settings is guidance only; the managed Python probe remains the permission
  oracle. Ordinary status has no credential-bearing URL field.

Fresh or interrupted setup selects and persists the first free port in the
bounded `8000...8100` range. A completed or genuine legacy installation keeps
its persisted port and reports a clear collision instead of silently moving a
working client.

## Local activation oracle

On first activation, the helper performs one strict probe over the authenticated
capability path:

1. `GET /__mac_orchestrator_health` must return HTTP 200 and exactly
   `{"status":"ok"}`.
2. Authenticated MCP `initialize` must succeed, negotiate the expected
   protocol version, and include session-header handling.
3. Authenticated `tools/list` must return a tool array.
4. Authenticated `tools/call` must complete the safe `get_session_state`
   orientation call with an application-level success result, not merely a
   JSON-RPC envelope. When `mac.ui` is desired, the result must also report
   the managed Python requester as UI-ready: Accessibility, Automation / Apple
   Events, active console, and an unlocked screen.

Only after all four stages and a fresh required-capability readiness evaluation
pass does the supervisor publish the local service as running, start remote
ingress, and mark onboarding complete. Installation payload promotion,
onboarding completion, local activation, and optional remote setup remain
distinct facts. Later health polls remain lightweight lifecycle checks;
authenticated remote revalidation is lifecycle-controlled after endpoint,
network, wake, restart, and recovery transitions.

## Remote endpoint and credential flow

```text
Trusted MCP client
  → current HTTPS capability URL
  → ngrok agent
  → 127.0.0.1:<selected-port>/<capability-token>/mcp
  → FastMCP tool
  → macOS API or owned subprocess
```

The helper reads the ngrok authtoken from Keychain and passes it only through
the owned child environment as `NGROK_AUTHTOKEN`; it is never put in argv. Once
the agent is running, the shared adapter queries its loopback-only
`GET /api/endpoints` boundary, selects exactly one live canonical HTTPS origin
whose upstream matches the configured loopback target, and the lifecycle then
requires authenticated MCP readiness before marking Remote ready. The probe
uses a transient credential-bearing request but returns only typed readiness
facts. The full URL is exposed or recorded only by an explicit Copy/Show
handoff, after which the state journal stores generation, origin, and time.
The deprecated `/api/tunnels` route and cached/stale endpoint display are not
part of the contract.

The connector URL is a password-like capability. Possession grants the enabled
tool surface without a second approval prompt per action. Logs, diagnostics,
client configuration, support requests, and screenshots must redact it.

## Phase 4D remote Doctor boundary

Doctor keeps remote evidence in separate layers:

1. local MCP prerequisite readiness;
2. ngrok binary/configuration, provider-credential, managed-process, and Agent
   API observations;
3. expected-upstream endpoint classification;
4. an injectable authenticated remote MCP probe covering authentication,
   initialize/session, inventory, and a safe application call; and
5. a receipt-backed client-handoff comparison.

An Agent API endpoint match can pass its own endpoint check but can never stand
in for authenticated remote MCP readiness. A changed connector identity with a
healthy current probe is a manual client-reconfiguration warning. Without a
known handoff receipt, Doctor does not inspect arbitrary clients or assert that
any particular client is stale. Doctor and ProcessSupervisor consume the same
adapter/parser classifications, while the authenticated probe remains
read-only. Connector-token rotation and ngrok candidate replacement are
serialized async transactions; neither restores an old connector token after
cutover, and provider replacement never performs provider-side deletion.

## Dependency boundary

The default runtime contains the core MCP/UI/OCR stack. The explicit `indexer`
extra contains `pyngrok`, document-parser packages, and embedding/indexer ML
packages. The public bootstrap copies only the core server and never copies
`indexer.py`. Maintainers who need the optional crawler run:

```bash
uv sync --extra indexer
```

`indexer.py` is out-of-band: it reads configured local files and sends
embeddings to a configured external worker. Its directories, worker URL, and
credentials are a separate trust boundary and it is not started by the core
supervisor.

The Phase 5 Meridian indexer follows the same boundary with a different
optional tool: the base runtime never imports or bundles it. The Mac helper
passes a local-only invocation to the separately installed executable and
does not persist its token, document contents, vectors, provider bodies, or
absolute roots in diagnostics.

## Permissions and identity limits

Phase 2 distributes an arm64 ad-hoc-signed helper. It is not Developer ID
signed or notarized. Gatekeeper may warn when it is first opened; the helper and
bootstrap do not silently disable Gatekeeper or remove quarantine. TCC grants
are tied to the installed identity, so an ad-hoc replacement can require fresh
Accessibility, Screen Recording, or Apple Events approval. The helper executes
the permission probe in the managed Python child that consumes those grants.
Opening System Settings is not evidence that the grant succeeded; use the
probe and `get_session_state`, then Restart and recheck.

Hosted CI cannot supply authoritative TCC, Screen Recording, or interactive
console permissions. Those observations remain informational and never replace
the deterministic required gates.

## Maintainer and CI boundaries

Maintainer assembly is intentionally separate from public onboarding. Required
CI validates Swift build/test, Python compilation and lock/dependency state,
manifest/bootstrap syntax, immutable URLs, no core indexer payload, no
build-machine paths or secret-shaped values, helper fixture checks, and clean,
repeat, failed-download, and interrupted-promotion harness cases. The aggregate
required check fails closed. TCC-dependent UI evidence is a visibly separate,
non-required job.

## Deferred boundaries

Phase 2 does not add Developer ID/notarization, DMG packaging, Intel support,
Meridian or provider changes, a new retry state machine, or a full
updater/rollback product. Phase 4D binds the authenticated remote probe and
credential-recovery seams described above, while live provider lifecycle
behavior remains subject to the manual evidence matrix. The current
architecture also remains single-user and local-first;
OAuth, accounts, roles, hosted deployment, and enterprise management are not
implicit roadmap guarantees.
