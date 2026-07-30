# Mac Orchestrator — Agent Working Guide

## What this is

Mac Orchestrator combines a Python FastMCP server (`automac_mcp.py`) with a
native Swift menu-bar supervisor. The server gives trusted AI agents 20 tools
to control a macOS desktop. The installed supervisor owns the Python and ngrok
processes, while direct Python execution remains available for development.

**The file you will almost always be editing:** `automac_mcp.py` (~1340 lines).

---

## File map

| File | Purpose |
|------|---------|
| `automac_mcp.py` | The server: 20 MCP tools + internal helpers + startup (~1340 lines) |
| `indexer.py` | Standalone crawler — indexes local files into Cloudflare RAG for `vector_search` |
| `Sources/MacOrchestrator/` | Native menu-bar supervisor, Keychain, process lifecycle, and rotating logs |
| `script/distribute.sh` | Personal install/update flow for this Mac |
| `test_mcp_server.py` | Imports, tool inventory, representative behavior, managed auth path, and cleanup tests |
| `pyproject.toml` | uv dependencies, entry point `automac-mcp` → `automac_mcp:main` |
| `sync_state.db` | SQLite used by `indexer.py` for incremental sync state |
| Keychain | Managed connector capability token |
| `~/.config/mac-orchestrator/config.json` | Legacy Telegram and ingestion configuration |

---

## `automac_mcp.py` internal structure

The file has **four distinct layers**. Don't mix them up.

### Layer 1 — Helpers and constants (lines 1–140)
Setup, imports, global flags, response builders, the KEY_MAP/MODIFIER_MAP tables, and the AppleScript runner.

Key items:
- `ACCESSIBILITY_AVAILABLE` (line 37) — `False` if pyobjc import failed; several tools fail gracefully when this is False.
- `_ok(msg, **data)` (line 63) — builds `{"status": "success", "message": msg, ...data}`
- `_fail(msg, error_code, **data)` (line 66) — builds `{"status": "error", "error_code": ..., "message": msg, ...data}`
- `_scale(x, y)` (line 71) — converts raw Retina pixel coords → logical coords for pyautogui
- `_run_applescript(body, timeout)` (line 128) — wraps body in `tell application "System Events"` and runs via osascript

### Layer 2 — Internal implementations (`_do_*`, lines 144–260)
Private Python functions. Called by MCP tools AND by `execute_macro`. Changing behavior here affects both.

| Function | Does |
|----------|------|
| `_do_keystroke(key, modifiers)` | Builds AppleScript, calls `_run_applescript` |
| `_do_mouse(x, y, action, hold_keys, end_x, end_y)` | Calls `_scale` then pyautogui; handles modifier key hold and drag |
| `_do_type(text, use_clipboard)` | Auto-detects ASCII vs Unicode; uses clipboard for non-ASCII |
| `_do_scroll(dx, dy)` | CGEvent for both axes — consistent pixel units |
| `_do_focus_app(app_name, timeout)` | osascript activate + polls NSWorkspace until active |
| `_ax_get(elem, attr)` | Helper: safely reads an AX attribute from an accessibility element |

### Layer 3 — MCP Tools (public API, lines 270–1060)
All `@mcp.tool()` decorated functions. These are what agent clients call.

### Layer 4 — Server startup
`setup_telegram()`, `setup_ngrok()`, `main()` — interactive local development
or noninteractive managed launch. In managed mode the Swift app owns ngrok and
passes a Keychain-backed capability path to the server.

---

## All 20 MCP tools (fast reference)

### Keyboard / Input
| Tool | Key params | Returns |
|------|-----------|---------|
| `press_keystroke` | `key: str`, `modifiers: list[str]` | status |
| `type_text` | `text: str`, `use_clipboard: bool\|None` | status — Unicode-safe via auto clipboard |
| `scroll` | `dx: int`, `dy: int` | status — both axes in pixels |

### Mouse
| Tool | Key params | Returns |
|------|-----------|---------|
| `mouse_action` | `x: int`, `y: int`, `action: str`, `hold_keys: list`, `end_x: int`, `end_y: int` | status — takes **logical** coords. `action` supports "click", "double_click", "right_click", "move", "drag". For drag, `end_x`/`end_y` are required. |

### Batch
| Tool | Key params | Returns |
|------|-----------|---------|
| `execute_macro` | `actions: list[dict]`, `default_delay_ms: int` | `status` ("success"/"partial_success"/"error"), per-step `steps` array, `recovery_hint` on failure |

### App management
| Tool | Key params | Returns |
|------|-----------|---------|
| `focus_app` | `app_name: str`, `timeout: int` | status + active_app dict |
| `get_available_apps` | — | `apps: list[str]` |

### Screen
| Tool | Key params | Returns |
|------|-----------|---------|
| `get_screen_size` | — | `logical_width/height`, `pixel_width/height`, `scale_factor` |
| `get_screen_layout` | — | `windows: list` — uses AX API, works for all modern apps |
| `get_screen_text` | `screenshot: bool = False` | OCR mode: `text_elements: list`, `full_text: str` in **logical** coords. Screenshot mode: `screenshot_path`, `logical_width/height`, `pixel_width/height` |

### File system
| Tool | Key params | Returns |
|------|-----------|---------|
| `find_file` | `query`, `search_dir`, `file_type`, `sort_by`, `limit` | `files: list[{path, name, last_modified, size_kb}]` |
| `vector_search` | `query: str` | `results: list` (from Cloudflare RAG) |
| `read_file` | `path`, `preview`, `preview_size_kb`, `preview_lines` | `content: str` |
| `write_file` | `path`, `content`, `mode: str = "overwrite"` | status — `mode="append"` adds to end of file |
| `list_directory` | `path`, `limit`, `sort_by`, `summary_only`, `offset` | `folders: list`, `files: list` |
| `smart_search` | `directory`, `regex_pattern`, `file_extension_filter`, `max_chars` | `results: list[{file, matches}]` |

### Terminal
| Tool | Key params | Returns |
|------|-----------|---------|
| `run_terminal_command` | `command`, `timeout_seconds`, `run_in_background`, `max_output_chars` | `stdout`, `stderr`, `exit_code`, `truncated` |

### Utility
| Tool | Key params | Returns |
|------|-----------|---------|
| `play_sound_for_user_prompt` | — | status |
| `clipboard` | `action: str` ("get"/"set"), `content: str` | get: `content`, `preview`, `length`. set: `length` |
| `send_file_to_telegram` | `file_path`, `caption` | status |

---

## Coordinate system

All screen tools use **logical** coordinates consistently:
- `get_screen_size()` returns `logical_width`/`logical_height` (e.g. 1280×832) plus `pixel_width`/`pixel_height` and `scale_factor`.
- `get_screen_text()` returns OCR positions already normalized to logical space — pass directly to `mouse_action()`.
- `mouse_action()` accepts logical coords and internally calls `_scale()` before moving.

Do not mix `pixel_width`/`pixel_height` from `get_screen_size()` with OCR positions — both are in logical space, use `logical_width`/`logical_height`.

---

## Response schema

Every tool returns a plain dict. Always check `result["status"]` before using other fields.

```python
# Success
{"status": "success", "message": str, "error_code": None, ...tool_specific_data}

# Error
{"status": "error", "message": str, "error_code": str, ...optional_detail}
```

**`error_code` values** (on `_fail()` responses):
- `"PERMISSION"` — accessibility or screen recording permission missing
- `"TIMEOUT"` — osascript or subprocess exceeded time limit
- `"NOT_FOUND"` — file/path/app does not exist
- `"INVALID_PARAM"` — bad argument value
- `"EXEC_ERROR"` — subprocess or AppleScript runtime error
- `"GENERIC"` — catch-all for unexpected exceptions

---

## Common task patterns

**Open an app and type something (with Unicode support):**
```python
execute_macro([
    {"action": "focus_app", "app": "Notes"},
    {"action": "keystroke", "key": "n", "modifiers": ["command"]},
    {"action": "delay", "ms": 500},
    {"action": "type", "text": "café ñoño 你好"}
])
```

**Find and read a file:**
```python
result = find_file("config.json", search_dir="~")
path = result["files"][0]["path"]
content = read_file(path)["content"]
```

**Click something visible on screen:**
```python
# OCR coords are in logical space — pass directly to mouse_action
elements = get_screen_text()["text_elements"]
target = next(e for e in elements if "Submit" in e["text"])
mouse_action(x=target["position"]["center_x"], y=target["position"]["center_y"])
```

**Run a shell command with output cap:**
```python
result = run_terminal_command("ls -la ~/Documents", timeout_seconds=10)
if result["status"] == "success":
    print(result["stdout"])
# Use max_output_chars=50000 for commands with large output
```

**Append to a log file:**
```python
write_file("~/Desktop/log.txt", "line 1\n")
write_file("~/Desktop/log.txt", "line 2\n", mode="append")  # file now has both lines
```

**Take a screenshot:**
```python
result = get_screen_text(screenshot=True)
# result["screenshot_path"] → "~/Desktop/orchestrator_screenshot.png"
```

**Read/write clipboard:**
```python
clipboard(action="set", content="hello 你好")   # load into clipboard
clipboard(action="get")                          # returns {"content": "hello 你好", ...}
```

**Drag a file in Finder:**
```python
mouse_action(x=200, y=300, action="drag", end_x=500, end_y=300)
```

**Mixed UI + terminal macro:**
```python
execute_macro([
    {"action": "focus_app", "app": "Notes"},
    {"action": "run_command", "command": "date"},          # get current date
    {"action": "write_file", "path": "~/Desktop/out.txt", "content": "log entry"},
    {"action": "keystroke", "key": "n", "modifiers": ["command"]},
    {"action": "set_clipboard", "content": "pasted text"},
    {"action": "keystroke", "key": "v", "modifiers": ["command"]}
])
# On failure, check result["status"] ("partial_success"/"error"), result["recovery_hint"]
```

---

## What NOT to change without care

- **`pyautogui.FAILSAFE = True`** — moving mouse to screen corner aborts execution. Do not set to False.
- **`ACCESSIBILITY_AVAILABLE` guard** — many tools silently degrade when pyobjc is missing. Don't assume it's always True.
- **`get_ocr_reader()`** — EasyOCR lazy-loads on first call (~5s delay). Don't eagerly initialize at module load.
- **`execute_macro` dispatch table** — if you add a new `_do_*` function, add the corresponding case here or it won't work in macros.
- **`_run_applescript` wraps in `System Events` tell block** — don't add another tell block inside the body argument, it will nest incorrectly.

---

## Dev commands

```bash
# Install / sync dependencies
uv sync

# Verify imports (non-interactive, no server start)
uv run python -c "import automac_mcp; print('OK')"

# Check syntax
uv run python -m py_compile automac_mcp.py && echo "Syntax OK"

# Run behavioral tests without writing bytecode
PYTHONDONTWRITEBYTECODE=1 uv run python -B test_mcp_server.py

# Start server (interactive — prompts for Telegram + ngrok)
uv run python automac_mcp.py

# Build the native app
swift build

# Install/update the personal menu-bar app and login job
./script/distribute.sh
```
