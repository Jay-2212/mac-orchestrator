# Security

Mac Orchestrator gives a trusted AI client direct control of one macOS
desktop: keyboard/mouse input, screen reading, file access, shell command
execution, application control, and macros. Read this document before
enabling public ingress (ngrok) or filing a security report.

## Threat model

**In scope / what this project defends against:**

- An untrusted party who does not have the connector URL should not be able
  to reach the MCP tool surface at all.
- The connector token should never be recoverable from logs, diagnostics,
  exception text, or process listings.
- A missing, malformed, or wrong-length token must fail closed (server
  refuses to start, or the request 404s) rather than falling back to an
  unauthenticated path.
- Process lifecycle management (the Swift supervisor) must only ever
  signal/kill processes it created and can prove ownership of.

**Explicitly out of scope / not defended against:**

- **The connector-URL holder.** Anyone who has the URL has the same access
  the trusted AI client has: shell commands, file reads/writes, UI control.
  This is a single capability boundary, not a permission system. There are
  no scopes, roles, or per-tool authorization.
- **A compromised or malicious AI client.** If the client itself is
  adversarial, this project cannot limit what it does with the tools it's
  given.
- **Multi-tenant or mutually-untrusted use.** This is a single-user,
  single-Mac tool. It is not a hosted service and does not claim to isolate
  one user's data or session from another's.
- **The lock screen.** UI tools require an unlocked, active console
  session and the relevant macOS permissions. `get_session_state()` reports
  lock state; it does not unlock the Mac or make automation work while
  locked.

## The capability-URL model

Managed installations (the Swift menu-bar app) generate a random 256-bit
token via `SecRandomCopyBytes` and store it in the macOS Keychain
(`Sources/MacOrchestrator/KeychainStore.swift`). The Python server mounts
its entire MCP surface at `/<token>/mcp` instead of a fixed path
(`automac_mcp.py`, `MCP_PATH`). The plain `/mcp` path is unregistered in
managed mode and 404s.

This is deliberately **path-based capability authentication, not a compared
secret**. There is no `token == provided_token` string comparison anywhere
in this codebase to make constant-time — the token is part of the ASGI
route table, matched by Starlette's router the same way any other URL path
is matched. We consider this an acceptable design for this threat model:
the token is 256 bits of entropy (64 hex characters), each guess requires a
full network round trip (through ngrok's TLS termination, not a local
function call an attacker can time), and there is no oracle that
distinguishes a near-miss path from a random one — both return a generic
404. If code is added later that does compare a token as a string (e.g. an
alternate auth header), it must use `secrets.compare_digest`, not `==`.

Token format is validated at startup
(`re.fullmatch(r"[A-Za-z0-9_-]{32,128}", CONNECTOR_TOKEN)`): anything
missing, too short, too long, or outside the URL-safe charset raises at
import time and the server does not start. This is covered by
`test_mcp_server.py`.

### What "unmanaged" mode does and does not do

Running `uv run python automac_mcp.py` directly (no Swift supervisor) is
supported for local development. As of this pass, that mode:

- Binds to `127.0.0.1` only.
- Mounts `/mcp` with no token, **unless** you explicitly set
  `MAC_ORCHESTRATOR_CONNECTOR_TOKEN` yourself.
- Never starts a tunnel. Earlier versions of this file had an interactive
  "expose via ngrok?" prompt (defaulting to "yes") in unmanaged mode. It has
  been removed. It relied on FastMCP's `transport_security=None` default,
  which (for a `127.0.0.1` host) auto-enables a Host/Origin allowlist
  restricted to `127.0.0.1`/`localhost`/`::1`
  (`mcp.server.fastmcp.server.FastMCP.__init__`) — so a request arriving
  through an ngrok tunnel with `Host: *.ngrok-free.app` would have been
  rejected with `421 Invalid Host header` by the MCP library itself. In
  practice the old flow was a broken, misleading UI rather than a live
  unauthenticated hole — but "broken" is one bad refactor away from
  "working and unauthenticated," so we removed the feature instead of
  patching around it. Public ingress is now only wired up by the Swift
  supervisor's managed mode, which always assigns a random token.
- If you want to run a tunnel by hand against an unmanaged server, you must
  set **both** `MAC_ORCHESTRATOR_CONNECTOR_TOKEN` (mounts `/<token>/mcp`)
  **and** `MAC_ORCHESTRATOR_MANAGED=1` (disables the loopback-only
  Host/Origin allowlist, since a real tunnel's Host header won't match
  it), and run your own tunnel tool. Understand that at that point the
  token, not the network topology, is your entire security boundary.

### The health-check endpoint

`/__mac_orchestrator_health` is registered via FastMCP's `custom_route`,
which is explicitly documented upstream as bypassing route auth — it exists
so the Swift supervisor can poll liveness without needing the capability
token. It returns a fixed `{"status": "ok"}` body: no token, no MCP path, no
process state, nothing that helps an attacker. Treat any future addition to
this route with the same restriction — it is deliberately the one endpoint
that doesn't require the capability path, so it must stay minimal.

## Redaction

- The Swift supervisor's `RotatingLog.redact()` scrubs the connector token
  from `server.log` (and its rotated backups) whenever it's known
  (`ProcessSupervisor.swift`). Child-process stdout/stderr is also
  redacted line-by-line as it's captured (`attachOutput(redacting:)`).
- `uvicorn.access` logging is disabled in managed mode
  (`logging.getLogger("uvicorn.access").disabled = True`), so request paths
  — which contain the token — are never written to the access log in the
  first place. This is a stronger guarantee than post-hoc redaction.
- `indexer.py`'s `INGEST_TOKEN` is used exactly once — set on
  `http_session.headers` as the `Authorization` header — and is never an
  argument to `log_msg()`; it cannot reach `indexer.log`. `log_msg()` does
  write local file paths (e.g. "Purging existing chunks ... for:
  `<path>`"), row/chunk counts, and, on a failed upload or delete, the
  Cloudflare **response's** `status_code`/`text` (`upload_batch()`,
  `delete_file_chunks()`). It never logs the outgoing request body — the
  extracted document text being uploaded is not passed to `log_msg()`
  anywhere in this file. `WORKER_URL` itself is not treated as a secret
  (it's a configured endpoint, not a credential) and does appear in the
  startup error message if it's missing or malformed
  (`validate_config()`); if you point it at a backend whose own error
  responses echo request content, that content would reach the
  `0600`-permissioned `indexer.log` via the response-body logging above —
  a property of whatever backend you configure, not of this file.
- Log files and the owned-process state file are created with `0600`
  permissions, and their containing directories with `0700`
  (`RotatingLog.swift`, `ProcessSupervisor.persistState`).

## Known residue in git history

An earlier version of `indexer.py` (before this pass) had a hardcoded
personal directory (a OneDrive path naming a specific institution) and a
hardcoded Cloudflare Worker URL as defaults. Both have been removed from
the working tree in favor of required environment variables with no
built-in default (see `indexer.py`'s `validate_config()`), but they remain
visible in this repository's git history, which this pass does not rewrite
(no force-push). Neither was a credential — the ingest token itself was
always sourced from an environment variable, a local config file, or
Keychain, never committed. If you fork this repository, treat the
now-removed worker URL as a defunct endpoint, not a live one you're
authorized to call.

## Reporting a vulnerability

This is a personal, single-user project without a security team or an SLA.
Open a GitHub issue for anything that isn't sensitive on its own (most
findings here are), or, for something that would be actively harmful to
disclose publicly before a fix, contact the maintainer through
[jaybharti.me](https://jaybharti.me/). Do not include a live connector URL,
token, or private file contents in a report.

## Permissions this project requests

- **Accessibility** — required for keystroke/mouse synthesis, UI-tree
  reading, and application focus.
- **Screen & System Audio Recording** — required for screenshots and OCR.
- **Automation (Apple Events)** — required for AppleScript calls to System
  Events and other apps.

These are macOS TCC grants tied to the specific signed binary that requests
them. An ad hoc–signed build (the default; see README) gets a new,
unrecognized identity on every rebuild, so grants do not persist across
rebuilds unless you configure a persistent `CODESIGN_IDENTITY`.
