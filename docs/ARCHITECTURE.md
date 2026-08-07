# Architecture

## Components

```text
macOS LaunchAgent (script/distribute.sh installs this)
  └── Sources/MacOrchestrator (Swift menu-bar supervisor, ProcessSupervisor.swift)
        ├── automac_mcp.py — Python FastMCP server → 127.0.0.1:8000
        └── ngrok (bundled binary) — public tunnel → capability URL → local server
```

- **`automac_mcp.py`** — the MCP server. One file, four layers (helpers,
  internal `_do_*` implementations, `@mcp.tool()` public API, startup). See
  `.claude/CLAUDE.md` for the detailed internal map — tool inventory,
  response schema, coordinate system, and the AX-tree ref registry design.
- **`Sources/MacOrchestrator/`** — the native supervisor:
  - `ProcessSupervisor.swift` owns the Python server and ngrok as child
    processes: starts ngrok only after a local health check passes, closes
    ingress before stopping the server, applies bounded exponential
    backoff on repeated failures (capped, with a failure-count circuit
    breaker), and on launch cleans up only processes it can verify it
    started in a previous run (an owner-ID marker recorded in both the
    process's command line and a `0600`-permissioned state file).
  - `KeychainStore.swift` generates (once) and retrieves the 256-bit
    connector capability token via Keychain Services.
  - `RotatingLog.swift` — size-capped rotating logs with redaction and
    `0600`/`0700` permissions.
  - `MenuController.swift` / `AppDelegate.swift` — the menu-bar UI.
- **`indexer.py`** — a standalone crawler, run out-of-band (e.g. via `cron`
  or manually), that extracts text from local files and uploads embeddings
  to a configurable external worker for `vector_search`. It is not started
  by the supervisor and does not run inside the MCP server process.

## Why a single Python file for the server

`automac_mcp.py` intentionally stays one file. The tool surface is small
(24 tools) and most of the complexity is in a handful of tightly-coupled
areas (AppleScript execution, the AX-tree ref registry, coordinate
scaling) that benefit from being readable top-to-bottom rather than spread
across a package. If the tool count grows substantially, splitting by
layer (helpers / `_do_*` / tools / startup) is the natural seam — see
`.claude/CLAUDE.md`'s "Layer" breakdown for where those seams already are
conceptually, even though the file hasn't been physically split.

## Why the supervisor is Swift, not Python

The supervisor needs to reliably survive sleep/wake, detect and clean up
stale processes from a previous crashed run, and present a menu-bar UI —
all better served by a native `LSUIElement` app with `NSWorkspace`/`Process`
than a second Python daemon. It also means the Python server's lifecycle
(crash, restart, port conflicts) is managed by something that isn't itself
subject to the same Python-runtime failure modes.

## Process ownership and cleanup

Every process the supervisor starts is placed in its own process group
(`setpgid`) and recorded with three things: a random per-install owner ID
(persisted in `UserDefaults`), the process's actual PID, and — for
recovery after a supervisor crash — the owner ID re-verified against the
running process's command line (`ps -o command=`) before anything is
killed. This is what lets `cleanStaleOwnedProcesses()` clean up after a
previous crashed supervisor without risking killing an unrelated process
that happens to have reused the same PID. The Python server does the
analogous thing for command children it launches via
`run_terminal_command`/`execute_macro` (tracked in `_background_processes`,
cleaned up via `cleanup_background_processes()`, registered with
`atexit`).

## Data flow for a tool call

```text
AI client → HTTPS → ngrok → 127.0.0.1:8000/<capability-token>/mcp
   → FastMCP session → @mcp.tool() function → _do_* helper (if applicable)
   → subprocess / AppleScript / pyobjc call → structured {"status": ...} dict
```

`execute_macro` is the same path repeated: each step dispatches to the same
`_do_*` helpers the individual tools call, so behavior is identical whether
a client calls `press_keystroke()` directly or via a macro step.

## Configuration surfaces

| What | How |
|---|---|
| Server port (dev only) | `MAC_ORCHESTRATOR_PORT` |
| Capability token | `MAC_ORCHESTRATOR_CONNECTOR_TOKEN` (managed mode: Keychain, injected by the supervisor) |
| Managed-mode behavior switch | `MAC_ORCHESTRATOR_MANAGED=1` |
| Indexer directories | `MAC_ORCHESTRATOR_INDEX_DIRS` |
| Indexer ignore patterns | `MAC_ORCHESTRATOR_INDEX_IGNORE` |
| Indexer backend URL | `MAC_ORCHESTRATOR_WORKER_URL` (required, no default) |
| Indexer sync-state DB / log | `MAC_ORCHESTRATOR_INDEX_DB` / `MAC_ORCHESTRATOR_INDEX_LOG` |
| Ingest auth token | `INGEST_TOKEN` env var, `~/.config/mac-orchestrator/config.json`, or Keychain (`com.jay.mac-orchestrator.ingest-token`) — checked in that order |
| Telegram credentials | interactive prompt (unmanaged mode) → `~/.config/mac-orchestrator/config.json` |

See `SECURITY.md` for the security-relevant subset of this table and why
each default was chosen.
