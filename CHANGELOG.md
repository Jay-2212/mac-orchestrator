# Changelog

Versions below refer to `pyproject.toml`'s `version` field and the native
app's `CFBundleShortVersionString`, which are kept in sync and match the
GitHub Release tag (`vX.Y.Z`).

All notable changes are recorded here. Format is loosely
[Keep a Changelog](https://keepachangelog.com/); dates are when the change
was made, not necessarily the release cut date.

## [0.2.1] - 2026-08-07

### Fixed

- A raw `SIGTERM` sent directly to the Swift supervisor process (e.g.
  `launchctl bootout`/`launchctl stop`, or `kill <pid>` without `-9`) did
  not go through AppKit's normal quit path, so
  `applicationWillTerminate()` never ran and the owned Python server (and
  ngrok tunnel, if running) were orphaned instead of cleaned up — silently
  leaving a fully capable automation server running and holding port 8000.
  This is reachable through the documented upgrade path: `distribute.sh`
  asks the app to quit via AppleScript first, but falls through to
  `launchctl bootout` (which sends `SIGTERM`) if the app doesn't exit
  within its poll window, so a slow shutdown during an upgrade could hit
  this. Fixed by installing a `SIGTERM` handler
  (`AppDelegate.swift`) that routes the signal through `NSApp.terminate`,
  so shutdown is always graceful regardless of how it's requested. A
  subsequent `startServer()` no longer fails with "Port 8000 is already
  used" because of a leftover orphan from a prior shutdown.
  Verified live: launched the packaged app, confirmed the Python child was
  running and bound to port 8000, sent a plain `kill <pid>` (not `-9`),
  and confirmed the app log recorded "Stopping owned server" /
  "Supervisor quit cleanly", all owned processes exited within 1 second,
  and port 8000 was free — before the fix, the same sequence left the
  Python child running and the port held.

## [0.2.0] - 2026-08-06

### Security

- Removed the interactive "expose via ngrok?" flow from unmanaged/local-dev
  mode (`setup_ngrok()` in `automac_mcp.py`). It defaulted the exposure
  prompt to "yes" and mounted a tokenless `/mcp` path; FastMCP's own
  loopback Host/Origin allowlist meant requests through an actual tunnel
  were rejected in practice, but the flow was misleading and one refactor
  away from a real hole. Public ingress is now exclusively wired through
  the Swift supervisor's managed mode, which always assigns a random
  256-bit capability token. See `SECURITY.md` for the full writeup and the
  advanced manual-tunnel opt-in.
- Added `/__mac_orchestrator_health`, a minimal liveness endpoint outside
  the capability path, so the Swift supervisor's health poll checks this
  server specifically instead of "any HTTP response on port 8000."
- Documented (in `SECURITY.md`) why the capability token is matched via
  ASGI path routing rather than a compared string, and the constraint on
  any future code that does compare a token directly.

### Fixed

- `indexer.py` imported `sentence_transformers`, which was not declared in
  `pyproject.toml`/`uv.lock` — a clean `uv sync` could not actually run the
  indexer. Added as a regular (non-optional) dependency, not an extra,
  because `script/distribute.sh` copies `indexer.py` into the managed
  runtime venv for out-of-band `cron` use and a partial runtime install is
  worse than a larger one. This adds real download weight (`transformers`,
  `tokenizers`, `scikit-learn`, `huggingface-hub`) to every install, managed
  or dev — see README's indexer section. It does not add `torch`, which
  `easyocr` already required.
- `mcp.run(transport="streamable-http", mount_path="/mcp")` passed a
  `mount_path` argument that FastMCP silently ignores for this transport
  (it only applies to SSE). Removed the misleading argument; the actual
  mount path is `MCP_PATH`, set once at import time.
- `test_mcp_server.py` had a latent scoping bug: a function-local
  `import tempfile, os` made `os` local for the *entire* enclosing
  function (Python resolves this at parse time), so any earlier use of the
  module-level `os` in that function would raise
  `UnboundLocalError`/"cannot access local variable" once a new use was
  added before that import line. Fixed by dropping the redundant local
  `import os` (it's already imported at module scope).
- `test_mcp_server.py` hardcoded `search_dir="~/Documents/mac-orchestrator"`
  for its `find_file` check, which only works if the repo happens to be
  cloned to that exact path. Now derives the directory from `__file__`.

### Changed

- `indexer.py` configuration is now environment-driven with no
  personally-identifying defaults:
  - `DIRECTORIES_TO_INDEX` — previously included a hardcoded OneDrive path
    naming a specific institution. Now `MAC_ORCHESTRATOR_INDEX_DIRS`
    (`:`-separated), defaulting to `~/Documents:~/Downloads:~/Desktop`.
  - `IGNORE_PATTERNS` — dropped several personal/idiosyncratic entries
    that had no generic value; extendable via
    `MAC_ORCHESTRATOR_INDEX_IGNORE`.
  - Removed a hardcoded "prioritize files with HOSPICE in the name" sort
    rule.
  - `WORKER_URL` — previously defaulted to a specific person's Cloudflare
    Worker URL. Now `MAC_ORCHESTRATOR_WORKER_URL`, required with no
    built-in default; validated with an actionable error via the new
    `validate_config()`.
  - `DB_PATH` / indexer log path — previously assumed the repo was checked
    out at `~/Documents/mac-orchestrator`. Now default to
    `~/Library/Application Support/Mac Orchestrator/` and
    `~/Library/Logs/Mac Orchestrator/` respectively (matching where the
    Swift supervisor already keeps its own state), overridable via
    `MAC_ORCHESTRATOR_INDEX_DB` / `MAC_ORCHESTRATOR_INDEX_LOG`.
- `script/package_app.sh` no longer expects the Python "setup" flow (now
  removed) to have downloaded the ngrok binary as a side effect. Added
  `script/bootstrap_ngrok.sh`, a one-time, non-networked-beyond-the-download
  helper that only fetches the ngrok binary via `pyngrok.ngrok.install_ngrok()`
  — no tunnel, no exposure.

### Added

- `SECURITY.md` — threat model, capability-URL design rationale, redaction
  guarantees, and known git-history residue.
- `CONTRIBUTING.md` — dev setup, pre-PR checklist, scope boundaries.
- `.github/workflows/ci.yml` — Swift debug/release build on `macos-14`,
  a portable Python syntax + secret/personal-path scan job, and a
  best-effort (non-blocking) full Python test run, with the reasons each
  job is scoped the way it is documented inline.
- Tests for: malformed/oversized/wrong-charset connector tokens rejected
  at startup, unmanaged mode mounting a tokenless `/mcp` by default, and
  the health-check route existing outside the capability path.
- A live-HTTP regression test that actually binds a socket and asks it:
  with a token configured, `/mcp` must 404 and `/<token>/mcp` must not;
  with no token, `/mcp` itself must not 404. The other capability-path
  tests only check `MCP_PATH`/route tables in-process, which would not
  have caught it if FastMCP's `streamable-http` transport had honored the
  removed `mount_path="/mcp"` argument (it doesn't — verified live on
  this pass — but the earlier tests couldn't tell you that).
- This file.

### Known limitations carried forward (not addressed this pass)

- No Swift/XCTest test target exists for `Sources/MacOrchestrator/`; the
  supervisor is verified by `swift build` / `swift build -c release`
  succeeding, not by unit tests. Adding one is future work.
- `test_mcp_server.py`'s `get_ui_tree` pagination checks depend on live
  Finder window state and can report a false mismatch if Finder's actual
  UI tree exceeds the test's pagination-cap safety valve at the moment it
  runs; this is pre-existing and unrelated to this pass's changes.
- The distributed app remains ad hoc–signed by default and is not
  notarized. See README.
