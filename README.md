# Mac Orchestrator

[![License: CC0 1.0](https://img.shields.io/badge/License-CC0%201.0-lightgrey.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-black.svg)](https://www.apple.com/macos/)

Mac Orchestrator is a local-first, single-user macOS MCP server for a trusted AI
client. It exposes macOS UI automation, screen inspection, files, clipboard,
terminal commands, application control, and macros through one authenticated
connector. It is not a hosted service, a multi-tenant server, or an OAuth
provider.

The Phase 2 public-core candidate is installed from an immutable, versioned
release asset. Ordinary users do not need Git, Xcode or Command Line Tools,
Python, uv, Homebrew, or ngrok. The installer downloads a release-pinned
manifest, verifies its digests, and installs a prebuilt arm64 helper plus a
private managed Python runtime below the user-owned Application Support tree.

This repository is a source project. A branch or source archive is not a
published Phase 2 release. Use the generated install command from a tagged
release page; do not substitute a branch URL or an unverified script.

## Install the public-core release

When a Phase 2 release is published, copy the generated installation command
directly from the tagged release page and paste it into Terminal. It contains
the exact version, immutable bootstrap URL, bootstrap SHA-256, manifest URL,
and manifest SHA-256. `install-command.sh` is also attached as a convenience
artifact. Do not hand-edit those values.

The generated command verifies the bootstrap before executing it and passes
both external trust anchors to the bootstrap. The bootstrap verifies the
release version and manifest before parsing it, then verifies every helper,
uv, runtime lock, core-payload, and vendor ngrok digest before promotion. A
missing, sentinel, all-zero, or mismatched digest stops installation. The
release asset is the trust anchor; this is an integrity chain, not a
project-owned signature scheme. `SHA256SUMS` is published alongside the
assets for independent release-output checks. Project-owned artifact signing
remains future work.

The default profile is Guided Control. Full Control is an explicit opt-in with
a warning because the connector can execute terminal, file, UI, and application
actions on the Mac. Remote ingress is also optional; local setup remains useful
without an ngrok account or token.

The installer prints `Local connection ready.` only after the helper has
passed the exact health, authenticated initialize, tools/list, and safe
`get_session_state` probe. When Guided Control's UI capability is desired, the
managed Python requester must also confirm Accessibility, Automation / Apple
Events, an active console session, and an unlocked screen. Startup/status
output does not print a credential-bearing URL; use an explicit supported
client handoff after Remote is authenticated. Continue with
[client setup](docs/CLIENT_SETUP.md) after that message.

## Where the installation lives

The helper and runtime are owned by the installing macOS user:

```text
~/Library/Application Support/Mac Orchestrator/
├── app/Mac Orchestrator.app
├── python/cpython-3.13.14/
├── runtime/.venv/bin/python
├── runtime/{automac_mcp.py,pyproject.toml,uv.lock}
├── remote/ngrok/ngrok
├── remote/ngrok/ngrok.yml
├── meridian/indexer                 # optional separately installed tool
├── meridian/indexer.previous        # last-known-good optional tool
└── meridian/index-state.json        # owned by Meridian's indexer
└── install/{staging-*,runtime.previous/}
```

The LaunchAgent starts the helper from `app/`. The helper does not contain
ngrok. The external ngrok binary is downloaded directly from the vendor and is
checked for the manifest digest, arm64 architecture, and its original Developer
ID authority/team. It is never re-signed by this project.

Installation stages and validates a new runtime before promotion. A failed or
interrupted promotion keeps the previous runtime, configuration, and Keychain
state available for recovery. The installer does not change the global `PATH`.

## Optional Meridian indexer

Meridian indexing is an explicit opt-in capability. The Mac helper does not
copy Meridian's `src/indexer`, install Node or embedding packages, or place the
indexer in the public Python core payload. A separately distributed,
release-pinned Meridian indexer executable may be installed into the optional
tool boundary with the helper's digest-checked installer. A failed candidate
verification or promotion leaves the previous optional executable available.

The configured invocation supplies explicit source scopes and the Core URL as
local stdin JSON. Absolute roots are consumed only by the local indexer; Core
requests, progress events, Mac logs, support artifacts, and remote IDs contain
only opaque source IDs and canonical relative paths. `MERIDIAN_CORE_TOKEN` is
read from Keychain and supplied only to the owned indexer child environment.

The canonical indexer owns discovery, parsing, hashing, chunking, Core
begin/ingest/commit reconciliation, local index state, and last-known-good
replacement. Mac Orchestrator only schedules one-shot runs, supervises the
owned process, supports cancellation/retry/rebuild, and records bounded
status. Missing optional tooling or credentials leaves the base MCP runtime
usable and marks Meridian indexing unavailable.

## Runtime and connector model

```text
LaunchAgent
  └── Mac Orchestrator.app (Swift helper)
        ├── managed Python FastMCP server → 127.0.0.1:<selected-port>
        └── optional external ngrok agent → live HTTPS endpoint
```

The server stays loopback-bound and uses a capability path. On first activation,
the helper requires all of these before publishing the service as running:

1. the exact local health response `200` with `{"status":"ok"}`;
2. authenticated MCP `initialize` and `tools/list` responses; and
3. a safe authenticated `get_session_state` call.

Only after that probe succeeds may remote ingress start. When remote mode is
enabled, the adapter asks ngrok's loopback-only Agent API at `/api/endpoints`,
selects exactly one live HTTPS endpoint whose upstream matches the owned
loopback port, and performs an authenticated MCP probe. The probe uses a
transient credential-bearing request internally and discards it; the URL is
exposed or recorded as a client handoff only inside the explicit Copy/Show
action. It does not use the deprecated `/api/tunnels` route or publish a stale
URL through ordinary status, Doctor, logs, or support bundles.

The connector URL contains the capability token and is a password-like
credential. It is stored in Keychain, redacted from logs, and never passed in
command-line arguments. Enter an ngrok token only through the helper's hidden
prompt or stdin handoff. Never put it in shell history, a process argument, a
committed file, a screenshot, or a support ticket. See
[client setup](docs/CLIENT_SETUP.md) for the handoff and rotation guidance.

## Permissions and trust limits

The helper is arm64 and ad-hoc signed in Phase 2. It is not notarized and does
not have a Developer ID trust chain. macOS may show a Gatekeeper warning for a
downloaded helper; that warning is expected and is not silently bypassed by the
installer. Use the release page's documented verification steps and macOS's
normal Open/Privacy & Security flow. Do not disable Gatekeeper globally or
remove quarantine as a substitute for trust.

Accessibility, Screen Recording, Apple Events, and related TCC permissions are
granted to a particular installed identity. An ad-hoc rebuild or replacement
can receive a new identity and lose previous grants. The helper runs a
managed-Python permission probe in the same child-runtime identity that
performs UI work; its result and `get_session_state` are authoritative for
Python-side readiness. A permission prompt or an opened System Settings pane
is not proof that access was granted. Hosted CI cannot provide authoritative
TCC evidence, so its UI suite is informational only.

The connector holder is trusted with the enabled actions. Mac Orchestrator is
not a security boundary between mutually untrusted users, and the current
architecture has no accounts, roles, OAuth, or enterprise device management.

## Core versus optional indexer

The public bootstrap installs the core server and OCR/native runtime. It does
not install `indexer.py`, `pyngrok` as a core dependency, or the document-parser
and embedding packages. The optional indexer remains a maintainer-controlled
capability and is installed separately with:

```bash
uv sync --extra indexer
```

The indexer can read local files and send embeddings to a configured external
worker. Treat its directories, worker URL, and credentials as a separate trust
boundary; it is not started by the public core supervisor.

## Upgrading, recovery, and troubleshooting

Use the bootstrap asset and manifest for the desired tagged version. Do not
copy a source-built `.app` over the managed installation. The installer keeps a
previous runtime while it promotes a validated replacement and records an
interrupted promotion for the next invocation to recover.

- If the manifest, digest, architecture, lock, import, or smoke check fails,
  stop and keep the previous runtime. Read the displayed validation error and
  retry the same verified release.
- If Gatekeeper warns, follow the normal macOS approval path; do not disable
  protections globally.
- If UI tools report missing permissions, unlock the Mac, confirm the active
  console session, grant access to the exact installed helper, and verify the
  resulting state. Replacing an ad-hoc helper may require granting it again.
- If the connector stops working after restart or network change, wait for the
  authenticated Remote state to recover and use **Copy Connector URL** or
  `--print-connector-url` again. Free ngrok endpoints can change, and only the
  live adapter reconciliation is authoritative.
- If the connector URL may have leaked, disable Remote immediately, remove the
  old URL from trusted clients, and run the explicit
  `--rotate-connector-token` action. Then perform a new deliberate handoff.
- If the ngrok account credential needs replacement, pipe a candidate through
  hidden stdin with `--replace-ngrok-token`; the candidate is validated before
  it is committed to Keychain. Use `--fail-closed-if-compromised` only when
  the old provider credential must not be restored.

Logs are stored under `~/Library/Logs/Mac Orchestrator/`. Redact connector URLs,
tokens, local file contents, and personal paths before sharing diagnostics.

## Maintainer and source workflows

The following scripts are maintainer workflows, not the public installation
path:

- `script/package_app.sh` builds a local app for development/release assembly.
- `script/distribute.sh` installs a locally built app and LaunchAgent for
  maintainer testing.
- `script/bootstrap_ngrok.sh` is legacy source-packaging support and is not a
  public-user setup mechanism.
- `script/build_and_run.sh` is for local development.

Maintainers should read [`CONTRIBUTING.md`](CONTRIBUTING.md), keep the lockfile
in sync, and use the Phase 2 release inputs and CI contract. Do not tell an
ordinary user to clone the repository, install Xcode/Python/uv, run a source
build, or bootstrap an embedded ngrok binary.

For component boundaries, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
For release gates and the exact publication boundary, see
[`docs/RELEASING.md`](docs/RELEASING.md).

## Release boundary

The Phase 2 release boundary intentionally does not provide Developer ID
signing or notarization, DMG packaging, Intel support, Meridian/provider
changes, or provider-side destructive operations. Doctor, authenticated remote
recovery, and explicit credential transactions are repository Phase 3/4 source
workflows; a tagged Phase 2 release must not be assumed to contain them.

## Project documents

- [`SECURITY.md`](SECURITY.md) — threat model and credential boundaries.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — maintainer setup and contribution checks.
- [`docs/CLIENT_SETUP.md`](docs/CLIENT_SETUP.md) — endpoint and client handoff.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — runtime and installer design.
- [`docs/RELEASING.md`](docs/RELEASING.md) — required CI and release validation.
- [`CHANGELOG.md`](CHANGELOG.md) — user-visible changes.

## Licence and acknowledgments

The original source in this repository is dedicated to the public domain under
[CC0 1.0 Universal](LICENSE). Third-party dependencies and external services
remain subject to their own terms.

This project began as a fork of [digithree/automac-mcp](https://github.com/digithree/automac-mcp),
which established the original FastMCP-based macOS UI-automation tool set.
