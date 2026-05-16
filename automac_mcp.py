#!/usr/bin/env python3
"""
Mac Orchestrator (AutoMac MCP) — A lean MCP server for macOS UI automation.

Exposes a small, powerful set of tools that allow any AI agent to control a
macOS desktop: press keys, move the mouse, read the screen, run commands,
and chain multiple UI actions into atomic macros with realistic timing.
"""

import subprocess
import json
import time
import os
import sys
import re
import signal
import requests
from datetime import datetime
from pathlib import Path
from pyngrok import ngrok, conf
from rich.console import Console
from rich.prompt import Prompt
from rich.panel import Panel
from typing import Any, Dict, List, Optional
import pyautogui
import numpy as np
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import TransportSecuritySettings
try:
    from Cocoa import NSWorkspace
    from Quartz import (CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly,
                        kCGNullWindowID, CGEventCreateScrollWheelEvent, CGEventPost,
                        kCGScrollEventUnitPixel, kCGHIDEventTap)
    from ApplicationServices import (AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
                                     kAXWindowsAttribute, kAXTitleAttribute, kAXPositionAttribute,
                                     kAXSizeAttribute, kAXRoleAttribute)
    ACCESSIBILITY_AVAILABLE = True
except ImportError:
    ACCESSIBILITY_AVAILABLE = False

TELEGRAM_BOT_TOKEN = ""
TELEGRAM_CHAT_ID = ""

mcp = FastMCP(
    "AutoMac MCP - macOS UI Automation",
    host="127.0.0.1", port=8000,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False)
)

pyautogui.FAILSAFE = True
_ocr_reader = None

def get_ocr_reader():
    """Lazy-load the EasyOCR reader so startup stays fast."""
    global _ocr_reader
    if _ocr_reader is None:
        import easyocr
        _ocr_reader = easyocr.Reader(['en'])
    return _ocr_reader

# ── Response Helpers ──────────────────────────────────────────────────────────

def _ok(message: str, **data) -> Dict[str, Any]:
    return {"status": "success", "message": message, **data}

def _fail(message: str, **data) -> Dict[str, Any]:
    return {"status": "error", "message": message, **data}

# ── Coordinate Scaling (Retina) ───────────────────────────────────────────────

def _scale(x: int, y: int) -> tuple[int, int]:
    """Map screenshot coords to pyautogui coords on HiDPI displays."""
    try:
        sw, sh = pyautogui.size()
        ss = pyautogui.screenshot()
        return int(x * sw / ss.size[0]), int(y * sh / ss.size[1])
    except Exception:
        return x, y

# ── AppleScript Key Mapping ──────────────────────────────────────────────────
# ("keystroke", val) → keystroke <val>;  ("keycode", N) → key code N

KEY_MAP = {
    "return": ("keystroke", "return"), "enter": ("keystroke", "return"),
    "tab": ("keystroke", "tab"),
    "escape": ("keycode", 53), "esc": ("keycode", 53),
    "space": ("keystroke", '" "'),
    "delete": ("keycode", 51), "backspace": ("keycode", 51),
    "forward_delete": ("keycode", 117),
    "up": ("keycode", 126), "down": ("keycode", 125),
    "left": ("keycode", 123), "right": ("keycode", 124),
    "home": ("keycode", 115), "end": ("keycode", 119),
    "page_up": ("keycode", 116), "page_down": ("keycode", 121),
    "f1": ("keycode", 122), "f2": ("keycode", 120), "f3": ("keycode", 99),
    "f4": ("keycode", 118), "f5": ("keycode", 96),  "f6": ("keycode", 97),
    "f7": ("keycode", 98),  "f8": ("keycode", 100), "f9": ("keycode", 101),
    "f10": ("keycode", 109), "f11": ("keycode", 103), "f12": ("keycode", 111),
}

MODIFIER_MAP = {
    "command": "command down", "cmd": "command down",
    "shift": "shift down",
    "option": "option down", "alt": "option down",
    "control": "control down", "ctrl": "control down",
}

def _build_keystroke_cmd(key: str, modifiers: list = None) -> str:
    """Build AppleScript keystroke command string."""
    mod_clause = ""
    if modifiers:
        parts = []
        for m in modifiers:
            mapped = MODIFIER_MAP.get(m.lower())
            if not mapped:
                raise ValueError(f"Unknown modifier '{m}'. Valid: {list(MODIFIER_MAP.keys())}")
            parts.append(mapped)
        mod_clause = f" using {{{', '.join(parts)}}}"

    kl = key.lower()
    if kl in KEY_MAP:
        kind, val = KEY_MAP[kl]
        return f"keystroke {val}{mod_clause}" if kind == "keystroke" else f"key code {val}{mod_clause}"
    elif len(key) == 1:
        return f'keystroke "{key}"{mod_clause}'
    else:
        raise ValueError(f"Unknown key '{key}'. Use a character or: {sorted(KEY_MAP.keys())}")

def _run_applescript(body: str, timeout: int = 10) -> Dict[str, Any]:
    """Execute AppleScript inside a System Events tell block."""
    script = f'tell application "System Events"\n{body}\nend tell'
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
        if r.returncode != 0:
            return _fail(f"AppleScript error: {r.stderr.strip()}")
        return _ok(f"Executed: {body.strip()}")
    except subprocess.TimeoutExpired:
        return _fail(f"AppleScript timed out after {timeout}s")
    except Exception as e:
        return _fail(f"Execution failed: {e}")

# ── Internal Action Implementations ──────────────────────────────────────────
# These are called by individual MCP tools AND by execute_macro.

def _do_keystroke(key: str, modifiers: list = None) -> Dict[str, Any]:
    try:
        cmd = _build_keystroke_cmd(key, modifiers)
    except ValueError as e:
        return _fail(str(e))
    mod_s = f" + {'+'.join(modifiers)}" if modifiers else ""
    res = _run_applescript(cmd)
    if res["status"] == "success":
        res["message"] = f"Pressed: {key}{mod_s}"
    return res

def _do_mouse(x: int, y: int, action: str = "click", hold_keys: list = None) -> Dict[str, Any]:
    valid = {"move", "click", "double_click", "right_click"}
    if action not in valid:
        return _fail(f"Invalid action '{action}'. Valid: {sorted(valid)}")
    held = []
    try:
        sx, sy = _scale(x, y)
        pg_map = {"command": "command", "cmd": "command", "shift": "shift",
                  "option": "option", "alt": "option", "control": "ctrl", "ctrl": "ctrl"}
        if hold_keys:
            for hk in hold_keys:
                pk = pg_map.get(hk.lower())
                if pk:
                    pyautogui.keyDown(pk)
                    held.append(pk)
        if action == "move":
            pyautogui.moveTo(x=sx, y=sy)
        elif action == "click":
            pyautogui.click(x=sx, y=sy, clicks=1)
        elif action == "double_click":
            pyautogui.click(x=sx, y=sy, clicks=2)
        elif action == "right_click":
            pyautogui.rightClick(x=sx, y=sy)
        for hk in reversed(held):
            pyautogui.keyUp(hk)
        hs = f" (holding {'+'.join(hold_keys)})" if hold_keys else ""
        return _ok(f"{action} at ({x}, {y}){hs}")
    except Exception as e:
        for hk in reversed(held):
            try: pyautogui.keyUp(hk)
            except: pass
        return _fail(f"Mouse action failed: {e}")

def _do_type(text: str) -> Dict[str, Any]:
    if not text:
        return _fail("text is required")
    try:
        pyautogui.write(text)
        return _ok(f"Typed: {text}")
    except Exception as e:
        return _fail(f"Failed to type: {e}")

def _do_scroll(dx: int = 0, dy: int = 0) -> Dict[str, Any]:
    try:
        if dy != 0:
            CGEventPost(kCGHIDEventTap, CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 1, -dy))
        if dx != 0:
            pyautogui.hscroll(clicks=dx)
        return _ok(f"Scrolled dx={dx}, dy={dy}")
    except Exception as e:
        return _fail(f"Scroll failed: {e}")

def _do_focus_app(app_name: str, timeout: int = 30) -> Dict[str, Any]:
    if not app_name:
        return _fail("app_name is required")
    if timeout <= 0:
        return _fail("timeout must be positive")
    try:
        r = subprocess.run(["osascript", "-e", f'tell application "{app_name}" to activate'],
                           capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return _fail(f"Failed to activate '{app_name}': {r.stderr.strip()}")
    except Exception as e:
        return _fail(f"Execution failed: {e}")
    start = time.time()
    last = None
    while time.time() - start < timeout:
        try:
            if ACCESSIBILITY_AVAILABLE:
                ws = NSWorkspace.sharedWorkspace()
                aa = ws.activeApplication()
                if aa:
                    an = aa.get("NSApplicationName", "")
                    if an.lower() == app_name.lower():
                        el = round(time.time() - start, 2)
                        return _ok(f"Focused '{app_name}' ({el}s)", elapsed_time=el,
                                   active_app={"name": an,
                                               "bundle_id": aa.get("NSApplicationBundleIdentifier", ""),
                                               "pid": aa.get("NSApplicationProcessIdentifier", -1)})
                    last = an
            else:
                cs = 'tell application "System Events" to get name of first application process whose frontmost is true'
                cr = subprocess.run(["osascript", "-e", cs], capture_output=True, text=True)
                if cr.returncode == 0:
                    fn = cr.stdout.strip()
                    if fn.lower() == app_name.lower():
                        el = round(time.time() - start, 2)
                        return _ok(f"Focused '{app_name}' ({el}s)", elapsed_time=el,
                                   active_app={"name": fn})
                    last = fn
        except Exception:
            pass
        time.sleep(0.5)
    return _fail(f"Timeout waiting for '{app_name}' after {timeout}s", last_active_app=last)


# ═══════════════════════════════════════════════════════════════════════════════
#  MCP TOOLS — The public API that AI agents see and call
# ═══════════════════════════════════════════════════════════════════════════════

# ── 1. Keyboard ───────────────────────────────────────────────────────────────

@mcp.tool()
def press_keystroke(key: str, modifiers: list[str] = []) -> Dict[str, Any]:
    """Press a single key, optionally with modifier keys held down.

    This replaces all individual keyboard shortcut tools. Any key combo can
    be expressed here.

    Args:
        key: The key to press. Single character ("a", "1", "/") or named key:
             "return", "escape", "tab", "space", "delete", "forward_delete",
             "up", "down", "left", "right", "home", "end", "page_up",
             "page_down", "f1" through "f12".
        modifiers: Modifier keys to hold. Valid: "command"/"cmd", "shift",
                   "option"/"alt", "control"/"ctrl".

    Common shortcuts:
        Copy  → key="c", modifiers=["command"]
        Paste → key="v", modifiers=["command"]
        Undo  → key="z", modifiers=["command"]
        Redo  → key="z", modifiers=["command", "shift"]
        Save  → key="s", modifiers=["command"]
        Spotlight → key="space", modifiers=["command"]
        Close window → key="w", modifiers=["command"]
        Quit app → key="q", modifiers=["command"]
        Force Quit → key="escape", modifiers=["command", "option"]
        Select All → key="a", modifiers=["command"]
    """
    return _do_keystroke(key, modifiers if modifiers else None)


# ── 2. Mouse ──────────────────────────────────────────────────────────────────

@mcp.tool()
def mouse_action(x: int, y: int, action: str = "click",
                 hold_keys: list[str] = []) -> Dict[str, Any]:
    """Perform a mouse action at screen coordinates.

    Args:
        x: Pixels from left edge.
        y: Pixels from top edge.
        action: "click" (default), "double_click", "right_click", or "move".
        hold_keys: Modifier keys to hold during action (e.g. ["command"]).
    """
    if x is None or y is None:
        return _fail("x and y coordinates are required")
    return _do_mouse(x, y, action, hold_keys if hold_keys else None)


# ── 3. Text Input ────────────────────────────────────────────────────────────

@mcp.tool()
def type_text(text: str) -> Dict[str, Any]:
    """Type a string of text into the focused input field.

    For special keys or shortcuts (Return, Cmd+V), use press_keystroke instead.

    Args:
        text: The text string to type.
    """
    return _do_type(text)


# ── 4. Scrolling ─────────────────────────────────────────────────────────────

@mcp.tool()
def scroll(dx: int = 0, dy: int = 0) -> Dict[str, Any]:
    """Scroll at the current mouse position.

    Args:
        dx: Horizontal pixels (positive=right, negative=left).
        dy: Vertical pixels (positive=down, negative=up).
    """
    return _do_scroll(dx, dy)


# ── 5. Macro Execution ───────────────────────────────────────────────────────

@mcp.tool()
def execute_macro(actions: list[dict], default_delay_ms: int = 750) -> Dict[str, Any]:
    """Execute a sequence of UI actions as a single batch with realistic timing.

    Instead of making separate tool calls (each needing an LLM round-trip),
    send the whole recipe in one call. A delay is inserted between actions
    so macOS UI has time to animate (Spotlight appearing, windows switching).

    Args:
        actions: List of action dicts. Each must have an "action" key:
            {"action": "keystroke", "key": "space", "modifiers": ["command"]}
            {"action": "type", "text": "Hello World"}
            {"action": "click", "x": 100, "y": 200}
            {"action": "double_click", "x": 100, "y": 200}
            {"action": "right_click", "x": 100, "y": 200}
            {"action": "move", "x": 100, "y": 200}
            {"action": "scroll", "dx": 0, "dy": -300}
            {"action": "focus_app", "app": "Notes"}
            {"action": "delay", "ms": 2000}  ← explicit extra pause
        default_delay_ms: Pause between actions in ms (default 750).
                          Increase for slow UI transitions. The AI can also
                          insert explicit delay actions for known-slow steps.

    Example — Open Notes and type a message:
        actions=[
            {"action": "focus_app", "app": "Notes"},
            {"action": "keystroke", "key": "n", "modifiers": ["command"]},
            {"action": "type", "text": "Hello from AI!"}
        ]
    """
    if not actions:
        return _fail("actions list is empty")

    delay_s = max(0, default_delay_ms) / 1000.0
    results = []
    for i, act in enumerate(actions):
        action_type = act.get("action")
        if not action_type:
            results.append({"step": i + 1, **_fail("Missing 'action' key")})
            break

        # Dispatch to internal implementations
        if action_type == "keystroke":
            res = _do_keystroke(act.get("key", ""), act.get("modifiers"))
        elif action_type == "type":
            res = _do_type(act.get("text", ""))
        elif action_type in ("click", "double_click", "right_click", "move"):
            res = _do_mouse(act.get("x", 0), act.get("y", 0), action_type, act.get("hold_keys"))
        elif action_type == "scroll":
            res = _do_scroll(act.get("dx", 0), act.get("dy", 0))
        elif action_type == "focus_app":
            res = _do_focus_app(act.get("app", ""), act.get("timeout", 30))
        elif action_type == "delay":
            ms = act.get("ms", 1000)
            time.sleep(ms / 1000.0)
            res = _ok(f"Delayed {ms}ms")
        else:
            res = _fail(f"Unknown action type: {action_type}")

        results.append({"step": i + 1, "action": action_type, **res})

        # Stop on error
        if res.get("status") == "error":
            break

        # Inter-action delay (skip after last action and after explicit delays)
        if i < len(actions) - 1 and action_type != "delay":
            time.sleep(delay_s)

    failed = [r for r in results if r.get("status") == "error"]
    if failed:
        return _fail(f"Macro stopped at step {failed[0]['step']}: {failed[0]['message']}",
                     steps_completed=len(results), results=results)
    return _ok(f"Macro completed: {len(results)} actions executed", results=results)


# ── 6. App Management ────────────────────────────────────────────────────────

@mcp.tool()
def focus_app(app_name: str, timeout: int = 30) -> Dict[str, Any]:
    """Bring an application to the foreground and wait for it to become active.

    Args:
        app_name: Name of the app (e.g. "Safari", "Notes", "Finder").
        timeout: Max seconds to wait (default 30).
    """
    return _do_focus_app(app_name, timeout)

@mcp.tool()
def get_available_apps() -> Dict[str, Any]:
    """List all currently running (non-background) applications."""
    script = 'tell application "System Events"\nget name of (processes where background only is false)\nend tell'
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return _fail(f"Failed to get apps: {r.stderr}")
        apps = [a.strip() for a in r.stdout.split(", ")]
        return _ok(f"Found {len(apps)} running apps", apps=apps)
    except Exception as e:
        return _fail(f"Execution failed: {e}")


# ── 7. Screen Comprehension ──────────────────────────────────────────────────

@mcp.tool()
def get_screen_size() -> Dict[str, Any]:
    """Get the screen dimensions in pixels."""
    try:
        w, h = pyautogui.size()
        return _ok(f"Screen size: {w}x{h}", width=w, height=h)
    except Exception as e:
        return _fail(f"Failed: {e}")

@mcp.tool()
def get_screen_layout() -> Dict[str, Any]:
    """Get window positions and apps visible on screen via Accessibility APIs."""
    if not ACCESSIBILITY_AVAILABLE:
        return _fail("macOS accessibility frameworks not available")
    try:
        info = {"windows": [], "active_app": None}
        try:
            ws = NSWorkspace.sharedWorkspace()
            aa = ws.activeApplication()
            if aa:
                info["active_app"] = {
                    "name": aa.get("NSApplicationName", "Unknown"),
                    "bundle_id": aa.get("NSApplicationBundleIdentifier", ""),
                    "pid": aa.get("NSApplicationProcessIdentifier", -1)
                }
        except Exception as e:
            info["active_app_error"] = str(e)
        try:
            wl = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
            for w in wl:
                name = w.get('kCGWindowName', '')
                b = w.get('kCGWindowBounds', {})
                if name and b.get('Width', 0) > 50 and b.get('Height', 0) > 50:
                    info["windows"].append({
                        "title": name, "app": w.get('kCGWindowOwnerName', 'Unknown'),
                        "bounds": {"x": int(b.get('X', 0)), "y": int(b.get('Y', 0)),
                                   "width": int(b.get('Width', 0)), "height": int(b.get('Height', 0))},
                        "layer": w.get('kCGWindowLayer', 0),
                        "pid": w.get('kCGWindowOwnerPID', -1)
                    })
        except Exception as e:
            info["windows_error"] = str(e)
        info["windows"].sort(key=lambda w: w.get("layer", 0))
        try:
            ss = pyautogui.screenshot()
            info["screen_size"] = {"width": ss.width, "height": ss.height}
        except Exception:
            pass
        return _ok(f"Found {len(info['windows'])} visible windows", screen_info=info)
    except Exception as e:
        return _fail(f"Failed: {e}")

@mcp.tool()
def get_screen_text() -> Dict[str, Any]:
    """Read all text currently visible on screen using OCR."""
    try:
        ss = pyautogui.screenshot()
        arr = np.array(ss)
        results = get_ocr_reader().readtext(arr)
        elements = []
        for (bbox, text, conf) in results:
            if conf > 0.3:
                x1, y1 = bbox[0]; x2, y2 = bbox[2]
                elements.append({
                    "text": text.strip(), "confidence": round(conf, 3),
                    "position": {"center_x": int((x1+x2)/2), "center_y": int((y1+y2)/2),
                                 "bbox": [[int(p[0]), int(p[1])] for p in bbox]}
                })
        elements.sort(key=lambda e: (e["position"]["center_y"], e["position"]["center_x"]))
        full_text = "\n".join(e["text"] for e in elements)
        return _ok(f"Found {len(elements)} text elements",
                   screen_size={"width": ss.width, "height": ss.height},
                   text_elements=elements, full_text=full_text)
    except Exception as e:
        return _fail(f"OCR failed: {e}")


# ── 8. Terminal ───────────────────────────────────────────────────────────────

@mcp.tool()
def run_terminal_command(command: str, timeout_seconds: int = 30,
                         run_in_background: bool = False) -> Dict[str, Any]:
    """Execute a terminal command with configurable timeout and background mode.

    Args:
        command: Shell command to run.
        timeout_seconds: Max wait time in seconds (default 30, max 300).
        run_in_background: If true, start async and return the PID immediately.
                          Use this for dev servers, long builds, etc.
    """
    timeout_seconds = max(1, min(timeout_seconds, 300))
    try:
        if run_in_background:
            proc = subprocess.Popen(command, shell=True, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, start_new_session=True)
            return _ok(f"Background process started (PID {proc.pid})", pid=proc.pid)
        r = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout_seconds)
        return _ok("Command completed",
                   stdout=r.stdout, stderr=r.stderr, exit_code=r.returncode)
    except subprocess.TimeoutExpired:
        return _fail(f"Command timed out after {timeout_seconds}s")
    except Exception as e:
        return _fail(f"Execution failed: {e}")


# ── 9. Spotlight File Search ─────────────────────────────────────────────────

@mcp.tool()
def find_file(query: str, search_dir: str = "", file_type: str = "", sort_by: str = "", limit: int = 50) -> Dict[str, Any]:
    """Find files using macOS Spotlight (mdfind) — millisecond results across the whole drive.
    
    NOTE: Returns a list of objects with metadata (path, name, last_modified, size_kb) 
    instead of raw strings. This is a breaking change for agents expecting raw strings.

    Args:
        query: Search query (filename, content keyword, etc.)
        search_dir: Optional directory to scope the search.
        file_type: Optional extension filter (e.g. ".pdf", ".zip").
        sort_by: Optional sort order ("date_desc", "date_asc", "size_desc", "size_asc", "name_asc", "name_desc").
        limit: Max number of results to return (default 50).
    """
    if not query:
        return _fail("query is required")
    try:
        cmd = ["mdfind"]
        if search_dir:
            expanded = os.path.expanduser(search_dir)
            if os.path.isdir(expanded):
                cmd.extend(["-onlyin", expanded])
        search = f"kMDItemFSName == '*{query}*'" if file_type == "" else f"kMDItemFSName == '*{query}*{file_type}'"
        cmd.append(search)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        paths = [f for f in r.stdout.strip().split("\n") if f]
        
        files_data = []
        for p in paths:
            try:
                st = os.stat(p)
                files_data.append({
                    "path": p,
                    "name": os.path.basename(p),
                    "last_modified": datetime.fromtimestamp(st.st_mtime).isoformat(),
                    "size_kb": round(st.st_size / 1024, 2)
                })
            except OSError:
                continue
                
        if sort_by:
            if sort_by == "date_desc":
                files_data.sort(key=lambda x: x["last_modified"], reverse=True)
            elif sort_by == "date_asc":
                files_data.sort(key=lambda x: x["last_modified"])
            elif sort_by == "size_desc":
                files_data.sort(key=lambda x: x["size_kb"], reverse=True)
            elif sort_by == "size_asc":
                files_data.sort(key=lambda x: x["size_kb"])
            elif sort_by == "name_asc":
                files_data.sort(key=lambda x: x["name"])
            elif sort_by == "name_desc":
                files_data.sort(key=lambda x: x["name"], reverse=True)
                
        files_data = files_data[:limit]
        return _ok(f"Found {len(files_data)} files", files=files_data)
    except Exception as e:
        return _fail(f"Search failed: {e}")


# ── 10. File I/O ─────────────────────────────────────────────────────────────

@mcp.tool()
def read_file(path: str) -> Dict[str, Any]:
    """Read a file's contents.

    Args:
        path: Absolute or ~-relative path to the file.
    """
    try:
        p = os.path.expanduser(path)
        with open(p, "r", encoding="utf-8") as f:
            content = f.read()
        return _ok(f"Read {len(content)} chars from {p}", content=content)
    except Exception as e:
        return _fail(f"Read failed: {e}")

@mcp.tool()
def write_file(path: str, content: str) -> Dict[str, Any]:
    """Write (or overwrite) a file.

    Args:
        path: Absolute or ~-relative file path. Parent dirs created automatically.
        content: The text content to write.
    """
    try:
        p = os.path.expanduser(path)
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(content)
        return _ok(f"Wrote {len(content)} chars to {p}")
    except Exception as e:
        return _fail(f"Write failed: {e}")

@mcp.tool()
def list_directory(path: str) -> Dict[str, Any]:
    """List contents of a directory.
    
    NOTE: Returns objects with metadata (name, path, last_modified, size_kb) 
    instead of raw strings. This is a breaking change for agents expecting raw strings.

    Args:
        path: Absolute or ~-relative directory path.
    """
    try:
        p = os.path.expanduser(path)
        if not os.path.isdir(p):
            return _fail(f"Not a directory: {p}")
        items = os.listdir(p)
        
        folders = []
        files = []
        
        for i in items:
            full_path = os.path.join(p, i)
            try:
                st = os.stat(full_path)
                item_data = {
                    "name": i,
                    "path": full_path,
                    "last_modified": datetime.fromtimestamp(st.st_mtime).isoformat(),
                    "size_kb": round(st.st_size / 1024, 2)
                }
                if os.path.isdir(full_path):
                    folders.append(item_data)
                else:
                    files.append(item_data)
            except OSError:
                continue
                
        folders.sort(key=lambda x: x["name"])
        files.sort(key=lambda x: x["name"])
        
        return _ok(f"{len(folders)} folders, {len(files)} files in {p}",
                   folders=folders, files=files)
    except Exception as e:
        return _fail(f"Failed: {e}")


# ── 11. Regex Search ─────────────────────────────────────────────────────────

@mcp.tool()
def smart_search(directory: str, regex_pattern: str,
                 file_extension_filter: Optional[str] = None) -> Dict[str, Any]:
    """Search for a regex pattern inside files within a directory.

    Args:
        directory: Root directory to search recursively.
        regex_pattern: Regex pattern to match against file contents.
        file_extension_filter: Optional file extension (e.g. ".py").
    """
    try:
        d = os.path.expanduser(directory)
        if not os.path.isdir(d):
            return _fail(f"Not a directory: {d}")
        ignore = {".git", "node_modules", "venv", ".venv", "__pycache__", ".idea", ".vscode"}
        try:
            pat = re.compile(regex_pattern)
        except re.error as e:
            return _fail(f"Invalid regex: {e}")
        results = []
        char_count = 0
        MAX = 10000
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if not x.startswith('.') and x not in ignore]
            for fname in files:
                if fname.startswith('.'):
                    continue
                if file_extension_filter and not fname.endswith(file_extension_filter):
                    continue
                fp = os.path.join(root, fname)
                try:
                    with open(fp, "r", encoding="utf-8") as f:
                        lines = f.readlines()
                    matches = []
                    for i, line in enumerate(lines):
                        if pat.search(line):
                            matches.append({"line": i + 1, "content": line.strip()})
                    if matches:
                        entry = {"file": fp, "matches": matches}
                        s = json.dumps(entry)
                        if char_count + len(s) > MAX:
                            results.append({"file": fp, "matches": matches[:3], "truncated": True})
                            return _ok(f"Found matches (truncated at {MAX} chars)", results=results)
                        results.append(entry)
                        char_count += len(s)
                except (PermissionError, UnicodeDecodeError, Exception):
                    continue
        if not results:
            return _ok(f"No matches for '{regex_pattern}' in {d}", results=[])
        return _ok(f"Found matches in {len(results)} files", results=results)
    except Exception as e:
        return _fail(f"Search failed: {e}")


# ── 12. Utility ──────────────────────────────────────────────────────────────

@mcp.tool()
def play_sound_for_user_prompt() -> Dict[str, Any]:
    """Play the macOS system bell sound to alert the user."""
    try:
        r = subprocess.run(["osascript", "-e", "beep"], capture_output=True, text=True, timeout=5)
        if r.returncode != 0:
            return _fail(f"Bell failed: {r.stderr.strip()}")
        return _ok("System bell played")
    except Exception as e:
        return _fail(f"Failed: {e}")

@mcp.tool()
def send_file_to_telegram(file_path: str, caption: str = "") -> Dict[str, Any]:
    """Send a file to the user via Telegram.

    Args:
        file_path: Path to the file to send.
        caption: Optional caption for the file.
    """
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return _fail("Telegram not configured. Restart and provide credentials.")
    try:
        p = os.path.expanduser(file_path)
        if not os.path.exists(p):
            return _fail(f"File not found: {p}")
        sz = os.path.getsize(p)
        if sz > 50 * 1024 * 1024:
            return _fail(f"File too large ({sz / 1048576:.1f}MB > 50MB limit)")
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument"
        with open(p, "rb") as f:
            data = {"chat_id": TELEGRAM_CHAT_ID}
            if caption:
                data["caption"] = caption
            resp = requests.post(url, data=data, files={"document": f}, timeout=60)
        if resp.status_code == 200:
            return _ok(f"Sent '{os.path.basename(p)}' to Telegram")
        return _fail(f"Telegram API error ({resp.status_code}): {resp.text}")
    except Exception as e:
        return _fail(f"Failed: {e}")


# ═══════════════════════════════════════════════════════════════════════════════
#  SERVER SETUP & MAIN
# ═══════════════════════════════════════════════════════════════════════════════

console = Console()

def setup_telegram():
    """Sets up Telegram configuration securely."""
    global TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
    config_dir = os.path.expanduser("~/.config/mac-orchestrator")
    config_path = os.path.join(config_dir, "config.json")
    try:
        if os.path.exists(config_path):
            with open(config_path, "r") as f:
                config = json.load(f)
                TELEGRAM_BOT_TOKEN = config.get("TELEGRAM_BOT_TOKEN", "")
                TELEGRAM_CHAT_ID = config.get("TELEGRAM_CHAT_ID", "")
    except Exception:
        pass
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        setup = Prompt.ask("\n[bold cyan]Do you want to configure Telegram integration for file sending?[/bold cyan]", choices=["y", "n"], default="y")
        if setup.lower() == 'y':
            console.print(Panel.fit(
                "You need your Telegram Bot Token and your personal Chat ID.\n"
                "1. Bot Token (from BotFather)\n"
                "2. Chat ID (from userinfobot or similar)",
                title="[bold blue]Telegram Setup[/bold blue]", border_style="blue"
            ))
            bot_token = Prompt.ask("[bold green]Enter your Telegram Bot Token[/bold green]").strip()
            chat_id = Prompt.ask("[bold green]Enter your Telegram Chat ID[/bold green]").strip()
            if bot_token and chat_id:
                TELEGRAM_BOT_TOKEN = bot_token
                TELEGRAM_CHAT_ID = chat_id
                try:
                    os.makedirs(config_dir, exist_ok=True)
                    config_data = {}
                    if os.path.exists(config_path):
                        with open(config_path, "r") as f:
                            try: config_data = json.load(f)
                            except: pass
                    config_data["TELEGRAM_BOT_TOKEN"] = TELEGRAM_BOT_TOKEN
                    config_data["TELEGRAM_CHAT_ID"] = TELEGRAM_CHAT_ID
                    with open(config_path, "w") as f:
                        json.dump(config_data, f, indent=4)
                    console.print("[green]✓ Telegram credentials saved![/green]")
                except Exception as e:
                    console.print(f"[yellow]Could not save config: {e}[/yellow]")
            else:
                console.print("[red]Incomplete Telegram setup. File sending will not work.[/red]")
        else:
            console.print("[yellow]Skipping Telegram setup.[/yellow]")

def setup_ngrok():
    """Sets up ngrok tunnel, prompting for auth token if not configured."""
    try:
        import urllib.request
        try:
            req = urllib.request.Request("http://127.0.0.1:4040/api/tunnels")
            with urllib.request.urlopen(req, timeout=1) as response:
                if response.status == 200:
                    data = json.loads(response.read().decode('utf-8'))
                    for tunnel in data.get("tunnels", []):
                        addr = tunnel.get("config", {}).get("addr", "")
                        if "8000" in addr:
                            url = tunnel.get("public_url")
                            console.print("[green]Detected existing ngrok tunnel![/green]")
                            return url
        except Exception:
            pass
        expose = Prompt.ask("\n[bold cyan]Do you want to expose Mac Orchestrator publicly via ngrok?[/bold cyan] (Allows cloud bots to connect)", choices=["y", "n"], default="y")
        if expose.lower() != 'y':
            console.print("[yellow]Skipping ngrok. Server will only be available locally.[/yellow]")
            return None
        ngrok_config_paths = [
            os.path.expanduser("~/Library/Application Support/ngrok/ngrok.yml"),
            os.path.expanduser("~/.ngrok2/ngrok.yml"),
            os.path.expanduser("~/.config/ngrok/ngrok.yml")
        ]
        has_token = False
        for path in ngrok_config_paths:
            if os.path.exists(path):
                try:
                    with open(path, "r") as f:
                        if "authtoken" in f.read():
                            has_token = True
                            break
                except Exception:
                    pass
        if not has_token:
            console.print(Panel.fit(
                "To expose your local server, you need an ngrok authtoken.\n"
                "1. Sign up / Log in at [link=https://dashboard.ngrok.com]https://dashboard.ngrok.com[/link]\n"
                "2. Copy your Auth Token and paste it below.",
                title="[bold blue]ngrok Setup[/bold blue]", border_style="blue"
            ))
            token = Prompt.ask("[bold green]Enter your ngrok authtoken[/bold green]")
            if token.strip():
                ngrok.set_auth_token(token.strip())
                console.print("[green]✓ ngrok auth token saved![/green]")
            else:
                console.print("[red]No token provided. Skipping ngrok setup.[/red]")
                return None
        console.print("[cyan]Starting ngrok tunnel...[/cyan]")
        public_url = ngrok.connect(8000).public_url
        return public_url
    except Exception as e:
        console.print(f"[bold red]Failed to setup ngrok:[/bold red] {e}")
        return None

def main():
    try:
        subprocess.run("kill -9 $(lsof -t -i:8000)", shell=True, check=False, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
    except Exception:
        pass
    console.print(Panel.fit(
        "[bold magenta]Mac Orchestrator[/bold magenta]\n"
        "Your local MCP server for macOS UI automation.",
        border_style="magenta"
    ))
    setup_telegram()
    public_url = setup_ngrok()
    if public_url:
        mcp_url = f"{public_url}/mcp"
        console.print("\n[bold green]SUCCESS! Mac Orchestrator is now live.[/bold green]")
        console.print(f"🔗 [bold underline cyan]{mcp_url}[/bold underline cyan]")
        console.print("\nPaste this link into your cloud-hosted chatbots to give them access to this Mac.")
    else:
        console.print("\n[bold green]Mac Orchestrator is starting locally.[/bold green]")
        console.print("🔗 [bold underline cyan]http://localhost:8000/mcp[/bold underline cyan]")
    console.print("\n[dim]Press Ctrl+C to stop the server[/dim]\n")
    try:
        mcp.run(transport="streamable-http", mount_path="/mcp")
    except KeyboardInterrupt:
        pass
    finally:
        console.print("\n[yellow]Shutting down...[/yellow]")
        if public_url:
            ngrok.kill()

if __name__ == "__main__":
    main()
