# Mac Orchestrator

[![License: CC0 1.0](https://img.shields.io/badge/License-CC0%201.0-lightgrey.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-black.svg)](https://www.apple.com/macos/)

Mac Orchestrator is a local-first, self-hosted macOS MCP server for trusted AI
clients. It brings macOS UI automation, screen inspection, file access,
clipboard control, terminal commands, application control, and macros behind a
single MCP connector.

The current architecture is deliberately single-user by design: one trusted
agent connects to one Mac through a capability URL. This is a public community
source project, but it is not a hosted service, a multi-tenant server, or an
OAuth provider.

This project started as a fork of [digithree/automac-mcp](https://github.com/digithree/automac-mcp),
an experimental macOS UI-automation MCP server. Since forking, it has been
substantially rewritten and extended: terminal/shell command execution, a
Telegram file-send connector, a local retrieval index (`indexer.py`), a native
Swift menu-bar supervisor app that owns and health-checks the Python server and
ngrok as managed child processes, capability-URL authentication, and permission
diagnostics were all added after the fork, and the tool surface was curated
down from the original ~40 tools to 24. See [Acknowledgments](#acknowledgments)
for the full attribution.

## Status and scope

The current main branch exposes 24 MCP tools and includes a native menu-bar
supervisor, managed local processes, authenticated public ingress, permission
diagnostics, and Python tests. Tagged
[GitHub Releases](https://github.com/Jay-2212/mac-orchestrator/releases)
ship a source archive, not a prebuilt app — see
[Install the managed app](#install-the-managed-app) for why, and
[Upgrading](#upgrading) for the upgrade path. The included installer builds a
local app; it does not perform Developer ID signing, notarisation, App Store
packaging, or hosted deployment.

This project is intended for technically capable users who understand the
permissions and trust required to let an AI client operate their Mac. It should
not be treated as a security boundary between mutually untrusted users.

More documentation: [`SECURITY.md`](SECURITY.md) (threat model),
[`CONTRIBUTING.md`](CONTRIBUTING.md) (dev setup),
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (component map), and
[`CHANGELOG.md`](CHANGELOG.md).

## What it does

- Runs a Python FastMCP server for macOS automation and local retrieval.
- Provides keyboard, pointer, application, window, screen, UI-tree, clipboard,
  file, terminal, macro, and utility tools.
- Supervises the Python server and ngrok from a Swift menu-bar application.
- Starts public ingress only after the local server is healthy.
- Tracks and cleans up only processes created by this installation.
- Restarts owned children with bounded backoff and checks health after wake.
- Reports lock state, active-console state, and actual Accessibility and Screen
  Recording permission state through `get_session_state`.
- Optionally sends a file to Telegram through the existing connector setup.

## Architecture

```text
macOS LaunchAgent
  └── Swift menu-bar supervisor
        ├── Python FastMCP server → 127.0.0.1:8000
        └── ngrok agent → authenticated capability URL → local server
```

The supervisor owns both child processes. It starts ngrok only after a local
health check, closes ingress before stopping the server, applies bounded restart
backoff, and refuses to clean processes that do not carry this installation's
ownership marker.

## Trust and security model

Managed installations generate a random 256-bit capability token and store it
in the macOS Keychain. The token is part of the connector path:

```text
https://<current-ngrok-host>/<keychain-token>/mcp
```

In managed mode, the ordinary public `/mcp` path is never registered — it
returns `404`. (Unmanaged/local-dev mode without a configured token mounts
plain `/mcp` too, but only on loopback; see [Local development](#local-development)
and `SECURITY.md`.) The exact URL is available from **Copy Connector URL**
in the menu-bar app.

Treat the connector URL like a password. Anyone who obtains it can invoke the
enabled tools without a separate approval prompt for each action. In particular,
`run_terminal_command`, file writes, UI actions, and application control can
change the Mac or its data. Do not put the URL in issues, screenshots, logs,
documents, or chat messages beyond the trusted MCP client configuration.

The URL is the trust boundary in the current release. Authentication is
capability-URL based, not OAuth-based, and there are no user accounts, roles, or
per-action authorization rules. ngrok provides the public TLS connection, but
enabling public ingress still exposes a powerful local system to whoever has
the URL. Keep the connector disabled when it is not needed and review the ngrok
account and endpoint configuration yourself. See `SECURITY.md` for the full
threat model, including why the token is matched via URL routing rather than
a compared string, and the one endpoint (`/__mac_orchestrator_health`) that
deliberately sits outside the capability path.

The optional indexer (`indexer.py`) can read local files and upload their
extracted contents to whatever HTTP backend you configure via
`MAC_ORCHESTRATOR_WORKER_URL` — there is no built-in default backend. The
repository does not guarantee that those contents are private once they
leave the Mac; review whatever backend you point it at, and its retention
policy, before indexing sensitive material.

`indexer.py` requires `sentence-transformers` to build local embeddings before
upload. It's a regular (non-optional) dependency because `script/distribute.sh`
copies `indexer.py` into the managed runtime venv so it works out of the box
from a `cron` job pointed at that venv (see [Architecture](docs/ARCHITECTURE.md)),
and a partially-installed runtime is worse than a larger one. It adds real
download weight — `transformers`, `tokenizers`, `scikit-learn`, and friends —
but not `torch` itself, which `easyocr` already requires for the core server's
OCR tools.

### Permissions

Depending on the tools you use, macOS may request:

- **Accessibility** for keystrokes, clicks, application focus, and UI data;
- **Screen & System Audio Recording** for screenshots and OCR;
- **Automation** for Apple Events sent to System Events or another app.

Permissions are granted to the installed app/helper shown by macOS. Existing
Terminal permissions do not necessarily transfer to the installed helper.

### Session and lock-screen limitation

`get_session_state` can report that a session is locked or that a required
permission is missing. It does not unlock the Mac or make UI automation work at
the lock screen. UI tools require a usable, unlocked console session and the
appropriate macOS permissions; this project does not claim unattended lock-screen
operation.

## Requirements

- Apple Silicon Mac running macOS 13 or newer.
- A Swift toolchain from Xcode or the Apple Command Line Tools.
- Python 3.10 or newer and [`uv`](https://docs.astral.sh/uv/).
- An ngrok account and authtoken configured at
  `~/Library/Application Support/ngrok/ngrok.yml` for managed public ingress.

## Install the managed app

Tagged releases ship a **source archive**, not a prebuilt `.app`. Two
reasons: the app is not standalone — it looks for a Python runtime under
`~/Library/Application Support/Mac Orchestrator/runtime`, which only
`distribute.sh` creates, so a bare `.app` downloaded on its own would launch
and immediately report "Installed Python runtime is missing"; and the bundle
embeds ngrok's proprietary binary, which this project doesn't redistribute
outside of a build you produce yourself from your own bootstrapped copy. Build
locally instead — it takes under a minute on Apple Silicon:

```bash
# From a tagged release:
curl -LO https://github.com/Jay-2212/mac-orchestrator/releases/download/vX.Y.Z/mac-orchestrator-X.Y.Z.tar.gz
curl -LO https://github.com/Jay-2212/mac-orchestrator/releases/download/vX.Y.Z/mac-orchestrator-X.Y.Z.tar.gz.sha256
shasum -a 256 -c mac-orchestrator-X.Y.Z.tar.gz.sha256   # verify before extracting
tar xzf mac-orchestrator-X.Y.Z.tar.gz
cd mac-orchestrator-X.Y.Z

# Or from source directly:
git clone https://github.com/Jay-2212/mac-orchestrator.git
cd mac-orchestrator

./script/bootstrap_ngrok.sh   # one-time: downloads the ngrok binary to bundle
./script/distribute.sh
```

`bootstrap_ngrok.sh` only downloads the ngrok binary (via `pyngrok`) so it
can be bundled into the app — it does not start a tunnel or expose
anything. The distribute script builds a release app, bundles that ngrok
executable, creates a Python environment under
`~/Library/Application Support/Mac Orchestrator/runtime`, installs the app at
`/Applications/Mac Orchestrator.app`, installs a user LaunchAgent, and launches
the menu-bar supervisor.

The default code signature is ad hoc. Set `CODESIGN_IDENTITY` to a persistent
local signing identity or a suitable Apple signing identity if you want TCC
permissions to survive rebuilds. The packaging script does not notarise the
app — see [Signing and notarisation](#signing-and-notarisation).

On first launch, ad hoc–signed apps and downloaded scripts trigger Gatekeeper.
If macOS blocks the app ("cannot be opened because the developer cannot be
verified"), open **System Settings → Privacy & Security**, scroll to the
blocked-app notice, and click **Open Anyway** — or run
`xattr -d com.apple.quarantine "/Applications/Mac Orchestrator.app"` once,
from Terminal, if you built it yourself and trust what you built.

After installation, use **Enable Public Connector**, wait for a healthy status,
and choose **Copy Connector URL**. Paste that URL into the trusted MCP client;
do not construct a URL manually. The connector token is generated once (on
first launch, ever) and stored in Keychain — see
[Connector configuration](#connector-configuration).

### Signing and notarisation

There is no paid Apple Developer ID behind this project, so releases are not
notarised and the default build is ad hoc signed (`codesign --sign -`). Ad hoc
signing embeds a cdhash-only designated requirement that changes on every
rebuild, so **Accessibility and Screen Recording grants do not survive a
rebuild** unless you set `CODESIGN_IDENTITY` to a signing identity backed by a
persistent certificate (a self-signed Keychain certificate works, and does not
require a paid account — see Apple's Keychain Access documentation for
"Create a Certificate"). Set it once, before running `distribute.sh`:

```bash
CODESIGN_IDENTITY="Your Cert Name" ./script/distribute.sh
```

Whichever way you sign it, expect a Gatekeeper prompt on first launch (see
above). This is expected for a locally built, non-notarised app and is not a
sign of a broken build.

### Upgrading

```bash
git pull   # or download and extract a newer release archive over the old checkout
./script/bootstrap_ngrok.sh   # only if the bundled ngrok version needs refreshing
./script/distribute.sh
```

`distribute.sh` asks the running app to quit via AppleScript, polls for up to
8 seconds, and then runs `launchctl bootout` regardless of whether the poll
saw it exit — which sends `SIGTERM` if the app is still running. As of 0.2.1,
both paths (AppleScript quit and a raw `SIGTERM`) go through the same graceful
shutdown, so either way the outgoing version's server and tunnel are stopped
cleanly rather than left running under the new install. `distribute.sh` then
rebuilds and re-installs to the same `/Applications` path and relaunches. It
does **not** touch Keychain, so the existing connector token — and therefore
the existing connector URL's token portion — is preserved across upgrades; no
client reconfiguration is required. `serverDesired` and `tunnelDesired`
(whether the connector was left on or off) are also preserved, so a Mac that
had the connector enabled before an upgrade will have it enabled again after.

### Uninstalling

```bash
osascript -e 'tell application id "com.jay.mac-orchestrator" to quit'
launchctl bootout "gui/$(id -u)/com.jay.mac-orchestrator" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.jay.mac-orchestrator.plist
rm -rf "/Applications/Mac Orchestrator.app"
rm -rf ~/Library/Application\ Support/Mac\ Orchestrator
rm -rf ~/Library/Logs/Mac\ Orchestrator
```

Quit the app (via the command above, or the menu bar's **Quit Mac
Orchestrator**) *before* removing the LaunchAgent or app bundle — quitting
first lets the supervisor shut down its owned server/tunnel children
gracefully rather than leaving them orphaned.

This intentionally leaves the Keychain item
(`com.jay.mac-orchestrator` / `connector-capability-token`) in place, so a
future reinstall gets the same connector URL rather than forcing every
configured client to be updated. If you want a clean break — a genuinely new
identity, not just removed files — also run:

```bash
security delete-generic-password -s com.jay.mac-orchestrator -a connector-capability-token
```

Only do this if you actually want a new connector URL (a new random token is
generated on the next launch); it is irreversible for the old URL, which
becomes permanently invalid.

## Connector configuration

The connector URL has the shape:

```text
https://<current-ngrok-host>/<keychain-token>/mcp
```

To configure a trusted MCP client:

1. In the menu-bar app, choose **Enable Public Connector** and wait for the
   status to show healthy.
2. Choose **Copy Connector URL** and paste it, unmodified, into the client's
   MCP server URL field. Don't retype or reconstruct it by hand — the token
   is 64 hex characters and a single mistyped character produces a
   permanent 404, not a helpful error.
3. Treat the URL exactly like a password: don't paste it into issues,
   screenshots, chat messages, or committed config files. See
   [Trust and security model](#trust-and-security-model).

Two parts of that URL behave differently:

- **The token** (`<keychain-token>`) is stable. It's generated once, on
  first launch ever, and stored in Keychain — see [Upgrading](#upgrading)
  and [Uninstalling](#uninstalling) for exactly when it does and doesn't
  change.
- **The ngrok hostname** (`<current-ngrok-host>`) is only as stable as your
  ngrok plan. A free ngrok account gets a new random hostname on every
  tunnel restart (app relaunch, sleep/wake recovery, network change); the
  full URL will change even though the token doesn't. A paid ngrok plan
  with a reserved domain keeps the hostname fixed too, giving you a fully
  stable URL. Either way, **Copy Connector URL** always gives you the
  currently-correct full URL — reconfigure the client with it if the
  hostname portion has changed.

## Local development

The Python server can be run without the menu-bar supervisor:

```bash
uv sync
uv run python automac_mcp.py
```

It listens on `http://127.0.0.1:8000/mcp` by default, loopback only. Set
`MAC_ORCHESTRATOR_PORT` when testing on another local port. This mode does
**not** create a tunnel or expose the server publicly — public ingress is
exclusively wired up by the managed app's menu-bar controls. If you need to
run a tunnel by hand against an unmanaged server for testing, see the
"advanced manual exposure" note in `SECURITY.md`; it requires setting both
`MAC_ORCHESTRATOR_CONNECTOR_TOKEN` and `MAC_ORCHESTRATOR_MANAGED=1`
yourself and understanding that the token becomes your entire security
boundary at that point.

The native bundle can be exercised with:

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

## MCP tools

| Area | Tools |
|---|---|
| Orientation | `describe`, `get_session_state` |
| Keyboard and pointer | `press_keystroke`, `type_text`, `mouse_action`, `scroll` |
| Macros and apps | `execute_macro`, `focus_app`, `get_available_apps` |
| Screen and UI | `get_screen_size`, `get_screen_layout`, `get_ui_tree`, `perform_ui_action`, `get_screen_text` |
| Terminal | `run_terminal_command` |
| Files | `find_file`, `vector_search`, `read_file`, `write_file`, `list_directory`, `smart_search` |
| Utility | `clipboard`, `play_sound_for_user_prompt`, `send_file_to_telegram` |

The UI-tree tools support depth, role, actionable-element, pagination, and
node-budget controls. `perform_ui_action` acts on a previously returned element
reference and reports a before/after result rather than assuming success.

## Tests

Run the Python suite and Swift package checks on macOS:

```bash
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B test_mcp_server.py
swift build
swift build -c release
git diff --check
```

The Python test suite covers the 24-tool surface, representative behavior,
capability-path configuration (including malformed/missing-token rejection
and the health-check route's isolation from the capability path), process
cleanup, and UI-tree pagination. It needs Accessibility and Screen Recording
permission granted to the Python binary running it, plus an active unlocked
console session, so it is authoritative only when run locally on a Mac with
those grants — not in CI.

`.github/workflows/ci.yml` runs on `macos-14` runners: a required job builds
the Swift package (debug and release) and does a portable Python
syntax/secret-scan pass; a separate best-effort job attempts the full
Python suite but is expected to report permission-related skips rather than
full passes, since GitHub-hosted runners don't have an interactive console
session with Accessibility/Screen Recording granted.

## Lifecycle and diagnostics

The supervisor handles server failure, tunnel failure, duplicate launches,
sleep/wake, login recovery, and clean shutdown for processes it owns — whether
shutdown is requested through the menu bar, `osascript ... quit`, or a direct
`SIGTERM` (e.g. `launchctl bootout`/`kill`); all three route through the same
graceful shutdown path as of 0.2.1, so an owned server or tunnel is never left
orphaned holding its port. Logs are written under
`~/Library/Logs/Mac Orchestrator/` and rotate locally. The capability token is
stored in Keychain and is redacted from managed logs.

To rotate a leaked connector token, see
[Uninstalling](#uninstalling)'s `security delete-generic-password` step —
the same command works without uninstalling anything else; just quit and
relaunch the app afterward and copy the replacement URL into each trusted
client.

## Troubleshooting

- **"Installed Python runtime is missing. Run script/distribute.sh."** — the
  app was launched without `distribute.sh` ever having run (e.g. a bare
  `.app` copied from somewhere other than a full install). Run
  `./script/distribute.sh` from a checkout.
- **"Port 8000 is already used by another process."** — something else on
  the Mac is bound to 8000, or an unmanaged `uv run python automac_mcp.py`
  dev server is still running. Stop it, or set `MAC_ORCHESTRATOR_PORT` for
  the dev server so it doesn't collide with the managed instance.
- **Gatekeeper blocks the app on first launch** — expected for an
  ad hoc–signed, non-notarised build; see
  [Signing and notarisation](#signing-and-notarisation).
- **Accessibility/Screen Recording grants disappear after every rebuild** —
  expected with the default ad hoc signature; set `CODESIGN_IDENTITY` to a
  persistent identity (same section).
- **`get_session_state()` reports the session as locked or not on console,
  and UI tools fail or no-op** — this is accurate, not a bug: UI automation
  requires an unlocked, active console session. File, terminal, and
  clipboard tools remain available regardless. See
  [Session and lock-screen limitation](#session-and-lock-screen-limitation).
- **The connector URL stopped working after a Mac restart or network
  change** — if you're on a free ngrok plan, the hostname portion of the
  URL rotates on tunnel restart even though the token doesn't; copy the
  current URL again from **Copy Connector URL**. See
  [Connector configuration](#connector-configuration).
- **`vector_search` returns `INVALID_PARAM`** — `MAC_ORCHESTRATOR_WORKER_URL`
  is not set; this tool has no built-in default backend. See
  [Trust and security model](#trust-and-security-model).
- **Something else** — check `~/Library/Logs/Mac Orchestrator/app.log`,
  `server.log`, and `tunnel.log` first (the connector token is redacted from
  them); then see [Contributing and support](#contributing-and-support) or
  [`SECURITY.md`](SECURITY.md) for anything sensitive.

## Limitations

- Single-user and single-Mac architecture in the current release.
- No OAuth, user accounts, roles, hosted service, or enterprise device
  management integration.
- No guarantee of operation at the lock screen or without an active user
  session.
- Terminal and file tools are powerful; the connector holder is trusted with
  the resulting actions.
- Public ngrok endpoints may change, and the endpoint is an external service
  with its own limits and terms.
- The distributed app is ad hoc signed and not notarised.

## Contributing and support

Issues and pull requests are welcome for reproducible bugs, documentation
corrections, safer defaults, and macOS compatibility work. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for dev setup and the pre-PR checklist.
Include macOS and Apple Silicon details, the command or tool involved, and a
redacted diagnostic description. Never include connector URLs, tokens,
private file contents, or personal logs in an issue. For anything sensitive
enough that public disclosure before a fix would be harmful, see
[`SECURITY.md`](SECURITY.md).

## Licence

The original source in this repository is dedicated to the public domain under
[CC0 1.0 Universal](LICENSE). Third-party dependencies and external services
remain subject to their own terms. CC0 does not add an express patent grant;
review the repository contents and dependencies before redistributing a build.

## Acknowledgments

This project began as a fork of [digithree/automac-mcp](https://github.com/digithree/automac-mcp)
by [digithree](https://github.com/digithree), which established the original
FastMCP-based macOS UI-automation tool set. Everything under "What it does"
beyond core UI automation — the Swift menu-bar supervisor, terminal/shell
tools, the Telegram connector, the local retrieval index, capability-URL auth,
and process supervision — was added after the fork.
