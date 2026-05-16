# Mac Orchestrator (AutoMac MCP)

A lean, efficient, and feature-rich Mac orchestrator locally hosted MCP server that exposes full macOS UI automation over HTTP. Run it on your Mac, and connect it to any AI assistant or agent that supports MCP to grant it the ability to seamlessly orchestrate your local environment.

**Note: This project is strictly for macOS (Apple Silicon or Intel).**

> [!NOTE]
> **Project Status:** We have recently optimized the server to be much leaner. By modifying and compressing tool calls, we have cut the toolset in half (from 46 to 18 tools), making it highly efficient for AI agents while remaining feature-rich.


> [!WARNING]
> This server grants an AI assistant direct, system-level control over your operating system's user interface. Only run it in environments you fully control and **never** expose the port to the public internet without proper auth. Monitor the AI's actions closely.

---

## 🎯 How It Works

```
AI Agent (Cloud/Local)  ->  http://localhost:8000/mcp (or ngrok URL)  ->  Mac Orchestrator MCP  ->  macOS System APIs
```

Once running, the server provides a standard MCP interface exposing tools to:
- Comprehend the screen via Apple's native Accessibility APIs and optical character recognition (OCR).
- Perform mouse actions, keyboard input, and scrolling with Retina display support.
- Chain multiple UI actions into atomic macros with realistic inter-step timing.
- Open, focus, and manage running applications natively.
- Execute terminal commands (with configurable timeouts and background mode).
- Search files instantly via macOS Spotlight and perform local file I/O.

## 🚀 Quick Start

### Prerequisites

- macOS (Apple Silicon or Intel)
- Python 3.10 or later
- [uv package manager](https://astral.sh/uv/) (recommended) or standard `pip`

### Step 1: Clone the Repository

```bash
git clone https://github.com/Jay-2212/mac-orchestrator.git
cd mac-orchestrator
```

### Step 2: Install Dependencies

Using `uv` (Recommended):
```bash
uv venv
source .venv/bin/activate
uv sync
```

Alternatively, using `pip`:
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

### Step 3: Grant Required macOS Permissions

The server interacts natively with the macOS UI, which requires system-level permissions. 
If these permissions are not granted, the server will start but will gracefully fail when executing input tools.

1. Open **System Settings -> Privacy & Security -> Accessibility**
   - Add your terminal app (Terminal.app, iTerm2, Warp, etc.)
2. Open **System Settings -> Privacy & Security -> Screen Recording**
   - Add your terminal app

*Note: Restart your terminal app entirely after granting these permissions.*

### Step 4: Start the Server

```bash
# Ensure your virtual environment is active
source .venv/bin/activate
python automac_mcp.py
```

Upon starting, the server will prompt you:
1. **Telegram Setup:** (Optional) Enter your Telegram Bot Token and Chat ID to allow the server to send files to you.
2. **ngrok Setup:** (Optional but required for cloud bots) Provide your [ngrok authtoken](https://dashboard.ngrok.com) to securely expose the server to the internet via a temporary tunnel.

You should see output similar to:
```text
Mac Orchestrator
Your local MCP server for macOS UI automation.
...
SUCCESS! Mac Orchestrator is now live.
🔗 https://[random-string].ngrok-free.app/mcp
```
*(If you skip ngrok, the URL will be `http://127.0.0.1:8000/mcp`)*

### Step 5: Connect Your AI App

Copy the provided MCP URL (`https://...ngrok-free.app/mcp` for cloud bots, or `http://localhost:8000/mcp` for local desktop apps) and provide it to your AI agent or platform that supports external MCP connections.

## 🛠️ MCP Tools (18 Tools)

Mac Orchestrator provides a lean, powerful set of tools designed so any AI agent can understand them at first glance:

### Keyboard & Mouse
| Tool | Description |
|---|---|
| `press_keystroke(key, modifiers)` | Press any key with optional modifiers. Replaces all individual shortcut tools. E.g., `key="c", modifiers=["command"]` for Copy. |
| `mouse_action(x, y, action, hold_keys)` | Click, double-click, right-click, or move the mouse. Supports modifier-held clicks. |
| `type_text(text)` | Type a string of text into the focused field. |
| `scroll(dx, dy)` | Pixel-precise horizontal and vertical scrolling. |

### Macro Execution
| Tool | Description |
|---|---|
| `execute_macro(actions, default_delay_ms)` | **Chain multiple UI actions in one call.** Accepts a list of action dicts and executes them sequentially with a configurable inter-step delay (default 750ms) so macOS UI has time to animate. Supports: keystroke, type, click, scroll, focus_app, delay. |

### Screen Comprehension
| Tool | Description |
|---|---|
| `get_screen_size()` | Screen dimensions in pixels. |
| `get_screen_layout()` | Window positions, apps, and layout via native Accessibility APIs. |
| `get_screen_text()` | Read all on-screen text via OCR with coordinate bounding boxes. |
| `focus_app(app_name, timeout)` | Bring an app to the foreground and wait for it to become active. |
| `get_available_apps()` | List all currently running applications. |

### Terminal & File System
| Tool | Description |
|---|---|
| `run_terminal_command(command, timeout_seconds, run_in_background)` | Run shell commands with configurable timeout (up to 300s) and optional background mode that returns a PID. |
| `find_file(query, search_dir, file_type, sort_by, limit, include_source)` | **Spotlight-powered file search** via `mdfind`. Supports sorting, limits, and fetching source URLs (caution: may slow down search). |
| `read_file(path, preview, preview_size_kb)` | Read file contents. Supports preview mode (head and tail) to save context window. |
| `write_file(path, content)` | Write/overwrite a file (auto-creates parent dirs). |
| `list_directory(path, limit, sort_by, summary_only)` | List directory contents. Supports sorting, limits, and a high-level summary mode (file counts, sizes, age distribution). |
| `smart_search(directory, regex_pattern, file_extension_filter)` | Regex search inside files within a directory. |

### Utility
| Tool | Description |
|---|---|
| `play_sound_for_user_prompt()` | Play the macOS system bell to alert the user. |
| `send_file_to_telegram(file_path, caption)` | Send a file to the user via Telegram. |

### Standardized Responses

Every tool returns a consistent JSON envelope:
```json
{"status": "success", "message": "Human-readable summary", ...}
{"status": "error", "message": "What went wrong", ...}
```

## 🛡️ Architecture & Safety

Mac Orchestrator is built on top of [FastMCP](https://github.com/jlowin/fastmcp), converting incoming JSON-RPC calls over HTTP into native macOS executions via `pyobjc`, `pyautogui`, and `osascript`. 

**Safety nets implemented:**
- **Graceful Failures:** Operations that interact with the system or external programs are wrapped with robust exception handlers and strict timeouts, returning formatted JSON errors to the agent rather than crashing the MCP process.
- **Lazy Loading:** Heavy dependencies like OCR models are dynamically loaded on their first execution, ensuring near-instantaneous startup times.
- **Macro Timing:** The `execute_macro` tool inserts realistic delays (750ms default) between UI actions, preventing race conditions where the AI fires actions faster than macOS can animate.

## 🐛 Troubleshooting

| Symptom | Fix |
|---|---|
| AI attempts to click but nothing happens | Verify **Accessibility** permissions for your terminal app in System Settings. |
| Server throws port conflict errors | A previous instance might still be running. Use `lsof -i :8000` to find it and `kill -9 <PID>`, or change the port in `automac_mcp.py`. |
| OCR takes 10+ seconds on the first call | `easyocr` downloads PyTorch model weights on its initial execution. Give it a moment to download. Subsequent calls will be fast. |

For best visual AI comprehension results, it is recommended to enable **Increase Contrast** in *System Settings -> Accessibility -> Display*.
