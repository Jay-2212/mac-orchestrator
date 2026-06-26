<h1 align="center">Mac Orchestrator</h1>

<p align="center">
  <strong>The only MCP server that unifies macOS UI control and terminal automation in a single, lean interface.</strong>
</p>

<p align="center">
  <a href="https://github.com/Jay-2212/mac-orchestrator/stargazers"><img src="https://img.shields.io/github/stars/Jay-2212/mac-orchestrator?style=flat-square&color=yellow" alt="Stars"></a>
  <a href="https://github.com/Jay-2212/mac-orchestrator/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-CC0--1.0-blue?style=flat-square" alt="License: CC0-1.0"></a>
  <img src="https://img.shields.io/badge/python-3.10%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.10+">
  <img src="https://img.shields.io/badge/platform-macOS-black?style=flat-square&logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/MCP%20tools-20-orange?style=flat-square" alt="20 MCP Tools">
  <a href="https://github.com/jlowin/fastmcp"><img src="https://img.shields.io/badge/powered%20by-FastMCP-blueviolet?style=flat-square" alt="FastMCP"></a>
</p>

---

Mac Orchestrator is a self-hosted [MCP](https://modelcontextprotocol.io) server that gives any AI agent 20 tools to fully control a Mac desktop. It is unique in combining both UI automation (keyboard, mouse, screen OCR, Accessibility API) and shell-level terminal access in a single lean server — no other macOS MCP does both.

Run it locally or expose it over ngrok to connect it to any cloud AI agent or assistant.

> [!WARNING]
> This server grants an AI assistant direct, system-level control over your Mac. Only run it in environments you fully control. Never expose the port publicly without authentication.

> [!NOTE]
> **macOS only.** Requires Apple Silicon or Intel Mac. Windows and Linux are not supported.

---

## How It Works

```
AI Agent (Claude, GPT, local LLM)
         │
         │  MCP over HTTP (JSON-RPC)
         ▼
http://localhost:8000/mcp   (or ngrok public URL for cloud agents)
         │
         ▼
 Mac Orchestrator MCP Server
         │
         ├── pyobjc / Accessibility API  →  Window layout, focus, key events
         ├── pyautogui + CGEvent          →  Mouse, scroll, Retina-aware input
         ├── osascript / AppleScript      →  App activation, keystroke dispatch
         ├── EasyOCR                      →  On-screen text with bounding boxes
         └── subprocess                   →  Shell commands, background jobs
```

---

## Quick Start

### Prerequisites

- macOS (Apple Silicon or Intel)
- Python 3.10+
- [`uv`](https://astral.sh/uv/) (recommended) or `pip`

### 1 — Clone

```bash
git clone https://github.com/Jay-2212/mac-orchestrator.git
cd mac-orchestrator
```

### 2 — Install dependencies

```bash
# Using uv (recommended)
uv sync

# Or pip
python3 -m venv .venv && source .venv/bin/activate && pip install -e .
```

### 3 — Grant macOS permissions

The server needs two permissions. If missing, UI tools fail gracefully with a `PERMISSION` error.

| Permission | Where to grant |
|---|---|
| **Accessibility** | System Settings → Privacy & Security → Accessibility → add your terminal app |
| **Screen Recording** | System Settings → Privacy & Security → Screen Recording → add your terminal app |

> [!TIP]
> Restart your terminal app entirely after granting permissions for them to take effect.

### 4 — Start the server

```bash
uv run python automac_mcp.py
# or, if installed as a package:
automac-mcp
```

On startup the server will optionally prompt for Telegram and ngrok setup (see [Optional Setup](#optional-setup)). Once running:

```
Mac Orchestrator
Your local MCP server for macOS UI automation.
...
SUCCESS! Mac Orchestrator is now live.
🔗 https://xxxx-xx-xx.ngrok-free.app/mcp
```

### 5 — Connect your AI

Copy the MCP URL and add it to your AI app or agent as an external MCP server:
- **Cloud agent (Claude.ai, custom API agent):** use the `https://...ngrok-free.app/mcp` URL
- **Local desktop app:** use `http://localhost:8000/mcp`

---

## MCP Tools — 20 Tools

### Keyboard & Input

| Tool | Description |
|---|---|
| `press_keystroke(key, modifiers)` | Press any key with optional modifiers. `key="c", modifiers=["command"]` → ⌘C. |
| `type_text(text, use_clipboard)` | Type a string into the focused field. Auto-uses clipboard for non-ASCII (Unicode, CJK, emoji). |
| `scroll(dx, dy)` | Pixel-precise horizontal and vertical scrolling. |

### Mouse

| Tool | Description |
|---|---|
| `mouse_action(x, y, action, hold_keys, end_x, end_y)` | Click, double-click, right-click, move, or **drag**. Accepts logical coordinates (matches OCR output). For drag, provide `end_x`/`end_y`. |

### Macro Execution

| Tool | Description |
|---|---|
| `execute_macro(actions, default_delay_ms)` | **Chain multiple actions in a single call.** Executes keystroke, type, click, scroll, focus_app, run_command, write_file, set_clipboard, and delay steps sequentially with configurable inter-step timing (default 750 ms). Returns per-step results and a `recovery_hint` on failure. |

### App Management

| Tool | Description |
|---|---|
| `focus_app(app_name, timeout)` | Bring an app to the foreground and wait for it to become active. |
| `get_available_apps()` | List all currently running applications. |

### Screen

| Tool | Description |
|---|---|
| `get_screen_size()` | Returns `logical_width/height`, `pixel_width/height`, and `scale_factor`. |
| `get_screen_layout()` | Window list with positions and app names via the native Accessibility API. |
| `get_screen_text(screenshot)` | **OCR mode** (default): returns `text_elements` with bounding boxes in logical coords — pass directly to `mouse_action`. **Screenshot mode** (`screenshot=True`): saves a timestamped PNG to `~/Desktop/` and returns the path. |

### Terminal

| Tool | Description |
|---|---|
| `run_terminal_command(command, timeout_seconds, run_in_background, max_output_chars)` | Run any shell command. Timeout up to 300 s. Background mode returns a PID immediately. Output capped at `max_output_chars` (default 10 000). |

### File System

| Tool | Description |
|---|---|
| `find_file(query, search_dir, file_type, sort_by, limit)` | Spotlight-powered file search via `mdfind`. Filter by type, sort by date or name, limit results. |
| `vector_search(query)` | Semantic search over your indexed files via Cloudflare RAG (requires `indexer.py` setup). |
| `read_file(path, preview, preview_size_kb, preview_lines)` | Read file contents. Preview mode returns head + tail to save context window. |
| `write_file(path, content, mode)` | Write or append to a file. `mode="append"` adds to the end; parent dirs are auto-created. |
| `list_directory(path, limit, sort_by, summary_only, offset)` | List directory contents with sorting, pagination, and a high-level summary mode. |
| `smart_search(directory, regex_pattern, file_extension_filter, max_chars)` | Regex search inside files within a directory. Returns matched lines with file paths. |

### Utility

| Tool | Description |
|---|---|
| `clipboard(action, content)` | Get or set clipboard contents. Unicode-safe. `action="get"` returns content + length; `action="set"` loads text into the clipboard. |
| `play_sound_for_user_prompt()` | Play the macOS system bell to alert the user that input is needed. |
| `send_file_to_telegram(file_path, caption)` | Send a file to the user via Telegram bot. |

---

## Coordinate System

All screen tools use **logical** coordinates consistently — no manual Retina scaling needed:

- `get_screen_size()` → `logical_width / logical_height` (e.g. 1280 × 832 on a 14" MacBook Pro)
- `get_screen_text()` → OCR positions already in logical space
- `mouse_action()` → accepts logical coords, calls `_scale()` internally

Do not use `pixel_width / pixel_height` for mouse targeting. Use `logical_width / logical_height`.

---

## Standardized Responses

Every tool returns a consistent JSON envelope. Always check `status` before using other fields.

```json
{ "status": "success", "message": "...", ...tool_data }
{ "status": "error",   "message": "...", "error_code": "PERMISSION" }
```

**Error codes:** `PERMISSION` · `TIMEOUT` · `NOT_FOUND` · `INVALID_PARAM` · `EXEC_ERROR` · `GENERIC`

---

## Common Patterns

**Type Unicode text into an app:**
```python
execute_macro([
    {"action": "focus_app", "app": "Notes"},
    {"action": "keystroke", "key": "n", "modifiers": ["command"]},
    {"action": "delay", "ms": 500},
    {"action": "type", "text": "café ñoño 你好"}
])
```

**Click something on screen using OCR:**
```python
elements = get_screen_text()["text_elements"]
btn = next(e for e in elements if "Submit" in e["text"])
mouse_action(x=btn["position"]["center_x"], y=btn["position"]["center_y"])
```

**Run a shell command:**
```python
result = run_terminal_command("git log --oneline -10", timeout_seconds=10)
print(result["stdout"])
```

**Take a timestamped screenshot:**
```python
result = get_screen_text(screenshot=True)
# → {"screenshot_path": "~/Desktop/orchestrator_screenshot_20260101_120000.png", ...}
```

**Drag a file in Finder:**
```python
mouse_action(x=200, y=300, action="drag", end_x=500, end_y=300)
```

---

## Optional Setup

### Telegram Notifications

Send files back to yourself from the agent. On startup, enter:
1. `TELEGRAM_BOT_TOKEN` — create a bot via [@BotFather](https://t.me/botfather)
2. `TELEGRAM_CHAT_ID` — get it from [@userinfobot](https://t.me/userinfobot)

Or persist them in `~/.config/mac-orchestrator/config.json`:
```json
{
  "TELEGRAM_BOT_TOKEN": "...",
  "TELEGRAM_CHAT_ID": "..."
}
```

### Remote Access via ngrok

Required for cloud AI agents that cannot reach `localhost`. On startup, provide your [ngrok authtoken](https://dashboard.ngrok.com). The server will print a public `https://...ngrok-free.app/mcp` URL to share with your agent.

---

## Architecture & Safety

Mac Orchestrator is built on [FastMCP](https://github.com/jlowin/fastmcp), which translates incoming MCP JSON-RPC calls over HTTP into native macOS system calls via `pyobjc`, `pyautogui`, and `osascript`.

**Safety mechanisms:**
- **Graceful failures** — every tool catches exceptions and returns a structured JSON error rather than crashing the server process.
- **Strict timeouts** — AppleScript and subprocess calls have configurable timeouts; the server stays responsive even if a command hangs.
- **Lazy OCR loading** — EasyOCR and its PyTorch weights are loaded on the first `get_screen_text` call, not at import time, keeping startup near-instant.
- **Macro timing** — `execute_macro` inserts 750 ms delays between steps by default, preventing race conditions caused by firing actions faster than macOS can animate.
- **pyautogui failsafe** — moving the mouse to the top-left corner of the screen aborts all pyautogui actions immediately.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Click / keyboard actions do nothing | Grant **Accessibility** permission for your terminal app in System Settings → Privacy & Security. |
| `PERMISSION` error on screen tools | Grant **Screen Recording** permission for your terminal app. Restart the terminal after granting. |
| Port 8000 already in use | Run `lsof -i :8000` to find the process, then `kill <PID>`. Or change the port in `automac_mcp.py`. |
| First `get_screen_text` call is slow (~5 s) | EasyOCR downloads PyTorch model weights on first run. Subsequent calls are fast. |
| ngrok tunnel not appearing | Ensure you provided a valid authtoken. Free ngrok accounts allow one simultaneous tunnel. |

---

## License

[CC0 1.0 Universal](LICENSE) — public domain dedication. Use freely, no attribution required.
