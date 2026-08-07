# Contributing

Mac Orchestrator is a personal, single-user tool that's open for community
use and improvement. It is not aiming to become a hosted service or a
multi-tenant product — see the [Limitations](README.md#limitations) section
of the README before proposing anything in that direction.

## Before you start

Read, in this order:

1. `README.md` — what this is, the trust model, requirements.
2. `SECURITY.md` — the threat model. Most non-trivial changes to
   `automac_mcp.py`'s startup, routing, or the Swift supervisor's process
   ownership logic touch this.
3. `.claude/CLAUDE.md` — a detailed internal map of `automac_mcp.py`'s
   layers, tool inventory, and response schema. Written for an AI coding
   agent but equally useful for a human contributor working in that file.

## Good first contributions

- Reproducible bugs with clear repro steps.
- Documentation corrections (especially anything that's drifted from what
  the code actually does — call it out explicitly).
- Safer defaults, as long as they don't silently change documented
  behavior without updating the docs in the same change.
- macOS compatibility fixes (older macOS versions, Intel Macs — the
  project targets Apple Silicon + macOS 13+ but doesn't intentionally
  exclude Intel).
- Test coverage for logic that's currently only exercised manually.

## What's out of scope

- Turning this into a hosted/multi-tenant service, adding OAuth or user
  accounts, or anything that weakens the single-user capability-URL model.
  See `SECURITY.md`'s threat model.
- Unattended lock-screen automation. This project does not and should not
  claim to work at the lock screen.
- Claims of code signing, notarization, or "production-ready" distribution
  that the repository doesn't actually demonstrate. If you add signing
  support, it needs to be verifiable (a documented, reproducible process),
  not just claimed in a doc.

## Setting up a dev environment

```bash
git clone https://github.com/Jay-2212/mac-orchestrator.git
cd mac-orchestrator
uv sync
uv run python -c "import automac_mcp; print('OK')"
```

Run the Python server directly without the Swift supervisor:

```bash
uv run python automac_mcp.py
```

Build and exercise the native app:

```bash
swift build
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

## Before opening a PR

```bash
# Python
PYTHONDONTWRITEBYTECODE=1 uv run python -B test_mcp_server.py

# Swift
swift build
swift build -c release

# Whitespace hygiene on your diff
git diff --check

# Secret / personal-data scan on your diff
git diff -U0 | grep -inE "ghp_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{20,}|/Users/[a-z0-9_-]+/(Documents|Desktop|Downloads)"
```

`test_mcp_server.py` needs Accessibility and Screen Recording permission
granted to whatever Python binary you're running it with, and an active
unlocked console session — it is not expected to pass in a headless CI
runner without those grants. If a specific check can't run in your
environment, say so explicitly in the PR description rather than silently
skipping it.

### Style notes specific to this codebase

- `automac_mcp.py` has four layers (helpers, `_do_*` internal
  implementations, `@mcp.tool()` public API, server startup) — see
  `.claude/CLAUDE.md` for the map. Keep new tools in the layer that matches
  their role; don't put business logic directly in a `@mcp.tool()`
  function if `execute_macro` also needs to call it — put it in a `_do_*`
  helper instead and have both call that.
- Every tool returns `{"status": "success"|"error", "message": str,
  "error_code": str|None, ...}`. Reuse `_ok()`/`_fail()`; don't invent a new
  response shape for a new tool.
- Don't set `pyautogui.FAILSAFE = False`.
- Don't add new committed defaults that point at a specific person's
  infrastructure, directories, or accounts (see `indexer.py`'s
  `validate_config()` for the pattern: required env var, no baked-in
  fallback, actionable error if missing).

## Reporting a security issue

See `SECURITY.md` — do not open a public issue with a live connector URL,
token, or private file contents attached.
