# Mac Orchestrator (AutoMac MCP)

A powerful, self-hosted Model Context Protocol (MCP) server that exposes full macOS UI automation over HTTP. Run it on your Mac, and connect it to any AI assistant or agent that supports MCP to grant it the ability to seamlessly orchestrate your local environment.

**Note: This project is strictly for macOS (Apple Silicon or Intel).**

> [!WARNING]
> This server grants an AI assistant direct, system-level control over your operating system's user interface. Only run it in environments you fully control and **never** expose the port to the public internet without proper auth. Monitor the AI's actions closely.

---

## 🎯 How It Works

```
AI Agent (Cloud/Local)  ->  http://localhost:8000/mcp (or ngrok URL)  ->  Mac Orchestrator MCP  ->  macOS System APIs
```

Once running, the server provides a standard MCP interface exposing tools to:
- Comprehend the screen via Apple's native Accessibility APIs and optical character recognition (OCR).
- Perform mouse movements, clicks, scrolling, and keyboard shortcuts.
- Open, focus, and manage running applications natively.
- Execute terminal commands and perform local file I/O safely.

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

## 🛠️ MCP Tools Overview

Mac Orchestrator provides a rich set of specialized tools out of the box:

### UI Comprehension
- `get_screen_layout()`: Fetches window bounds, apps, and layouts via native macOS Accessibility APIs.
- `get_screen_text()`: Employs `easyocr` to read on-screen text with precise coordinate bounding boxes.
- `focus_app(app_name, timeout)`: Reliably brings an application to the foreground.
- `get_available_apps()`: Lists all currently running background/foreground applications.

### Keyboard & Mouse Control
- **Mouse**: `mouse_move(x, y)`, `mouse_single_click(x, y)`, `mouse_double_click(x, y)`, `scroll(dx, dy)`
- **Keyboard Utilities**: Wide array of system shortcuts including `type_text(text)`, `keyboard_shortcut_select_all()`, `keyboard_shortcut_spotlight_search()`, `keyboard_shortcut_quit_app()`, etc.

### System & File I/O
- `run_terminal_command(command)`: Execute safe, sandboxed terminal queries.
- `read_file(path)`, `write_file(path, content)`, `list_directory(path)`, `smart_search(directory, pattern)`

## 🛡️ Architecture & Safety

Mac Orchestrator is built on top of [FastMCP](https://github.com/jlowin/fastmcp), converting incoming JSON-RPC calls over HTTP into native macOS executions via `pyobjc`, `pyautogui`, and `osascript`. 

**Safety nets implemented:**
- **Graceful Failures:** Operations that interact with the system or external programs are wrapped with robust exception handlers and strict timeouts, returning formatted JSON errors to the agent rather than crashing the MCP process.
- **Lazy Loading:** Heavy dependencies like OCR models are dynamically loaded on their first execution, ensuring near-instantaneous startup times.

## 🐛 Troubleshooting

| Symptom | Fix |
|---|---|
| AI attempts to click but nothing happens | Verify **Accessibility** permissions for your terminal app in System Settings. |
| Server throws port conflict errors | A previous instance might still be running. Use `lsof -i :8000` to find it and `kill -9 <PID>`, or change the port in `automac_mcp.py`. |
| OCR takes 10+ seconds on the first call | `easyocr` downloads PyTorch model weights on its initial execution. Give it a moment to download. Subsequent calls will be fast. |

For best visual AI comprehension results, it is recommended to enable **Increase Contrast** in *System Settings -> Accessibility -> Display*.

---

<details>
<summary><b>Case Study: Automated Steam Game Purchase</b></summary>

*This was a real session in which the AI agent autonomously navigated the Steam desktop app to make a purchase within a specific budget constraint.*

Prompt provided to the AI: 
> "Open Steam and buy one or more new games for me from my wishlist, pick the best ones for me. You have a budget of €5. You have my full permission to complete the purchase. Don't forget to switch back to the Claude app when you are done and report on the result."

The AI used `focus_app("Steam")`, `get_screen_text()`, `mouse_single_click()`, and `scroll()` sequentially to:
1. Navigate to the user's wishlist in the Steam UI.
2. Read the text on screen (using the OCR capabilities) to parse the game names and prices.
3. Identify a game ("Heroes of Book & Paper" at €4.55) that matched the criteria and budget.
4. Add it to the cart, navigate through the PayPal checkout, agree to the Subscriber Agreement, and complete the transaction autonomously.
5. Focus back on the Claude app to deliver the final report.

*(Screenshots of this flow were captured and successfully verified the behavior of the `mac-orchestrator` in a live environment).*
</details>
