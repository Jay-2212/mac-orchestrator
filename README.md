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
diagnostics, and Python tests. There is no tagged binary release in the GitHub
repository at the time of writing. The included installer builds a local app;
it does not perform Developer ID signing, notarisation, App Store packaging, or
hosted deployment.

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

```bash
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
app. See the signing notes in the script and the issue tracker before making a
distribution decision.

After installation, use **Enable Public Connector**, wait for a healthy status,
and choose **Copy Connector URL**. Paste that URL into the trusted MCP client;
do not construct a URL manually.

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
sleep/wake, login recovery, and clean shutdown for processes it owns. Logs are
written under `~/Library/Logs/Mac Orchestrator/` and rotate locally. The
capability token is stored in Keychain and is redacted from managed logs.

To rotate a leaked connector token:

```bash
security delete-generic-password \
  -s com.jay.mac-orchestrator \
  -a connector-capability-token
```

Then quit and relaunch the app and copy the replacement URL into each trusted
client.

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
