# Mac Orchestrator

Mac Orchestrator is a personal macOS MCP server that lets trusted AI clients
control this Mac through one authenticated connector URL. It combines native
macOS UI automation, screen reading, file access, clipboard control, terminal
commands, and macros in one FastMCP server.

> **Personal installation only.** This repository is configured for Jay's Mac.
> It is not a public installer, App Store product, or multi-user service.

## Architecture

```text
macOS LaunchAgent
  └── Mac Orchestrator menu-bar app (Swift supervisor)
        ├── Python FastMCP server → 127.0.0.1:8000
        └── ngrok agent → authenticated capability URL → local server
```

The native menu-bar app owns both child processes. The Python server no longer
kills whatever happens to use port 8000, and it does not own ngrok in managed
mode. The app records only the PIDs it launches, adds a per-installation
ownership marker, and validates that marker before cleaning stale processes.

The Swift supervisor:

- prevents duplicate app instances with an exclusive local lock;
- starts the Python server in its own process group;
- starts ngrok only after the local MCP health check passes;
- stops public ingress before stopping the server;
- uses bounded restart backoff and a crash-loop circuit breaker;
- cleans owned stale processes after an app crash;
- terminates MCP-launched background command processes on stop or quit;
- reconnects and rechecks health after wake;
- writes small rotating diagnostic logs.

## Authentication model

Managed installations use a 256-bit random capability token stored in macOS
Keychain. The token is part of the MCP endpoint path:

```text
https://<current-ngrok-host>/<keychain-token>/mcp
```

Requests to the ordinary public `/mcp` path return `404`. The exact connector
URL is available only from **Copy Connector URL** in the menu-bar app.

Treat that URL like a password. Anyone who obtains it can invoke the enabled
Mac tools without per-action approval. Do not paste it into documents, issues,
logs, screenshots, or chat messages other than the trusted MCP connector
configuration in ChatGPT or Claude.

The supervisor redacts the capability token from captured server output and
discards its own health-probe access lines so the capability path is not written
to local logs. ngrok provides TLS for the public connection.
This intentionally simple capability-URL boundary is optimized for maximum MCP
client compatibility on a single-user personal system; it is not a substitute
for multi-user OAuth authorization.

To rotate a leaked connector token:

```bash
security delete-generic-password \
  -s com.jay.mac-orchestrator \
  -a connector-capability-token
```

Then quit and relaunch Mac Orchestrator. Copy the new connector URL into each
trusted client.

## Personal install or update

Prerequisites:

- macOS on Apple Silicon;
- `uv`;
- an ngrok account and authtoken already configured at
  `~/Library/Application Support/ngrok/ngrok.yml`.

From this checkout:

```bash
./script/distribute.sh
```

The script:

1. builds the Swift app in release mode;
2. ad-hoc signs the personal app and bundled ngrok executable;
3. installs the app at `/Applications/Mac Orchestrator.app`;
4. installs a self-contained Python environment under
   `~/Library/Application Support/Mac Orchestrator/runtime`;
5. installs `~/Library/LaunchAgents/com.jay.mac-orchestrator.plist`;
6. launches the menu-bar app.

Run the same command to update the installation. It asks the running app to
quit cleanly before replacing files. No Developer ID, notarization, App Store,
or public-distribution packaging is performed.

After installation, startup and login recovery do not require Terminal.

## First launch and permissions

The server starts automatically. Public ingress is disabled until you choose
**Enable Public Connector** in the menu.

The automation tools need:

- **Accessibility** for keystrokes, clicks, app focus, and window information;
- **Screen & System Audio Recording** for screenshots and OCR;
- **Automation** permission when macOS asks to control System Events or another
  application.

Grant the permission to the installed Mac Orchestrator/Python helper shown by
System Settings, then use **Restart** from the menu. Existing Terminal
permissions do not necessarily transfer to the installed helper.

## Menu-bar controls

The status dot summarizes the product state:

- green: server and public connector running;
- blue: local server running, public connector disabled;
- yellow: starting, stopping, or reconnecting;
- red: failure that needs attention;
- gray: stopped.

The menu shows:

- server status;
- tunnel status;
- current connector host;
- **Copy Connector URL**;
- **Start Server** / **Stop Server**;
- **Enable Public Connector** / **Disable Public Connector**;
- **Restart**;
- **Open Logs**;
- login-launch status;
- **Quit Mac Orchestrator**.

Quit always closes ngrok first, stops the Python process group, removes owned
background jobs, and exits cleanly. Because the LaunchAgent records a successful
exit, it does not immediately reopen the app. It starts again at the next login;
you can also open `/Applications/Mac Orchestrator.app` manually.

The public-connector preference persists. A fresh install defaults to disabled.
After you explicitly enable it, login/crash recovery restores it automatically.

## Connect ChatGPT or Claude

1. Choose **Enable Public Connector**.
2. Wait until the status dot is green.
3. Choose **Copy Connector URL**.
4. Paste the URL as a custom remote MCP connector in ChatGPT or Claude.
5. Complete the client's one-time connector setup.

Normal tool use does not show Mac Orchestrator per-action approval prompts. The
connector capability URL is the trust boundary.

The installer tightens existing mac-orchestrator and ngrok configuration files
to owner-only permissions when those files are present. The connector token is
stored in Keychain and redacted from managed server logs.

The optional vector-search ingest credential is also read from the
`com.jay.mac-orchestrator.ingest-token` Keychain item, with the existing local
config retained as a development fallback. It is never stored in this
repository.

Free ngrok endpoints may change if the account loses its assigned endpoint.
When that happens, use **Copy Connector URL** again and update the client.

## Local development

The existing Python workflow remains available:

```bash
uv sync
uv run python automac_mcp.py
```

Direct development listens on `http://127.0.0.1:8000/mcp` and retains the
interactive Telegram/ngrok setup. It never kills an existing port-8000
listener; startup fails normally and leaves that process untouched.

To run a local dev server on a different port — e.g. to test changes without
colliding with an already-running managed instance — set
`MAC_ORCHESTRATOR_PORT`:

```bash
MAC_ORCHESTRATOR_PORT=8791 uv run python -c \
  "import automac_mcp; automac_mcp.mcp.run(transport='streamable-http', mount_path='/mcp')"
```

For the native development bundle:

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
| Screen | `get_screen_size`, `get_screen_layout`, `get_ui_tree`, `perform_ui_action`, `get_screen_text` |
| Terminal | `run_terminal_command` |
| Files | `find_file`, `vector_search`, `read_file`, `write_file`, `list_directory`, `smart_search` |
| Utility | `clipboard`, `play_sound_for_user_prompt`, `send_file_to_telegram` |

24 tools total (up from 20). All prior tool names and arguments remain unchanged
— existing clients keep working without modification.

### New in this release

- **`get_ui_tree(app/pid/ref, depth, role_filter, actionable_only, limit,
  node_budget, continuation_token)`** — a real macOS accessibility tree (buttons,
  fields, labels, roles) with a stable `ref` per element, instead of relying on
  OCR-coordinate clicking for everything. Supports depth limits, role/actionable
  filtering, and pagination for large trees, with a `node_budget` that bounds how
  many elements are *visited* (not just returned) so one slow or wedged app can't
  block a call.
- **`perform_ui_action(ref, action, value)`** — acts on an element previously
  returned by `get_ui_tree` (click, focus, set value, or a named AX action) and
  reports an honest before/after diff, so the agent knows whether the action
  actually took effect rather than assuming success.
- **`get_session_state()`** — reports whether the screen is locked, whether this
  is the active console session, and whether Accessibility/Screen Recording
  permissions are genuinely granted (not just theoretically available). Lets an
  agent recognize "the session is locked" or "permission isn't granted" instead
  of retrying a doomed UI action and reporting a generic failure.
- **`describe(topic)`** — on-demand deep documentation (macro action catalog,
  `find_file` query syntax, UI-inspection guide, coordinate system) for anything
  trimmed out of the shorter tool descriptions, so connecting doesn't cost a lot
  of context up front.
- **`get_screen_layout()` now actually returns window `bounds`.** Previously,
  `AXPosition`/`AXSize` came back as opaque `AXValueRef` objects that raised
  `AttributeError` when read directly; a bare exception handler silently
  swallowed this, so no window ever had a `bounds` field. Fixed via
  `AXValueGetValue()`.
- **`get_available_apps()` now enumerates the same app set as `get_screen_layout`/
  `get_ui_tree`** (previously a narrower, inconsistent list from a different
  AppleScript query). This means `apps`/`apps_detail` now include roughly 40
  additional background/menu-bar-only agents alongside ordinary apps — filter
  `apps_detail` on `activation_policy == "regular"` for Dock-visible apps that
  are meaningful `focus_app()` targets.
- AppleScript permission failures (e.g. Automation/Accessibility denial) now
  surface as `error_code="PERMISSION"` with a specific recovery hint, instead of
  a generic `EXEC_ERROR`.

Background terminal commands are still supported, but the server now registers
them and terminates them during managed shutdown. Synchronous commands remain
bounded to a maximum 300-second timeout and output is capped.

## Logs and state

Open the log folder from the menu, or inspect:

```text
~/Library/Logs/Mac Orchestrator/app.log
~/Library/Logs/Mac Orchestrator/server.log
~/Library/Logs/Mac Orchestrator/tunnel.log
~/Library/Logs/Mac Orchestrator/launcher.log
```

App, server, and tunnel logs rotate at approximately 2 MB with four backups.
Secrets and connector paths are not intentionally logged.

Owned-process state is stored with user-only permissions at:

```text
~/Library/Application Support/Mac Orchestrator/owned-processes.json
```

Do not edit it while the app is running. Stale PIDs are harmless unless their
current command line also contains this installation's ownership marker.

## Lifecycle behavior

- **Server failure:** public ingress closes, then the server restarts with
  bounded exponential backoff. The tunnel returns only after health succeeds.
- **Tunnel failure/network loss:** the local server remains available and the
  tunnel reconnects with bounded backoff.
- **App crash:** launchd restarts the app. The new app validates and terminates
  only the two stale owned children, then restores desired state.
- **Duplicate launch:** the second app exits without changing the running
  instance.
- **Sleep/wake:** children remain quiescent during sleep; wake triggers an
  immediate health/tunnel check.
- **Logout/reboot:** macOS terminates the user LaunchAgent. `RunAtLoad` restores
  the supervisor at the next login.
- **Clean reinstall:** the installer requests clean app shutdown, updates the
  runtime and bundle, then bootstraps one LaunchAgent.

## Troubleshooting

### Port 8000 is already in use

Mac Orchestrator reports the conflict and leaves the listener untouched:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN
```

Stop or reconfigure that application, then choose **Restart**.

### Tunnel fails repeatedly

Check `tunnel.log` and confirm the ngrok authtoken file exists:

```bash
ls -l ~/Library/Application\ Support/ngrok/ngrok.yml
```

The app stops after repeated failures rather than entering an unbounded restart
loop. Fix the credential/network issue and choose **Restart**.

### Connector returns 404

The unauthenticated `/mcp` path is supposed to return 404. Use **Copy Connector
URL** instead of constructing the URL manually.

### Tools report permission errors

Open System Settings → Privacy & Security and check Accessibility, Screen &
System Audio Recording, and Automation. Restart the app afterward.

### Verify the login job

```bash
launchctl print "gui/$(id -u)/com.jay.mac-orchestrator"
```

## Tests

```bash
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B test_mcp_server.py
swift build
swift build -c release
git diff --check
```

The Python suite verifies all 24 tools, representative tool behavior, managed
capability-path configuration, background-process cleanup, and a durable
`get_ui_tree` pagination regression test (compares a paginated walk against an
unpaginated baseline in both tree and flat/filtered mode). Installation
acceptance additionally exercises local and public MCP initialization, duplicate
prevention, owned server/tunnel crash recovery, app crash recovery, and clean
quit cleanup.

## License

[CC0 1.0 Universal](LICENSE).
