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

def _fail(message: str, error_code: str = "GENERIC", **data) -> Dict[str, Any]:
    # error_code values: PERMISSION, TIMEOUT, NOT_FOUND, INVALID_PARAM, EXEC_ERROR, GENERIC
    return {"status": "error", "error_code": error_code, "message": message, **data}

# ── Coordinate Scaling (Retina) ───────────────────────────────────────────────

_scale_cache: tuple[float, float] | None = None

def _scale(x: int, y: int) -> tuple[int, int]:
    """Map screenshot coords to pyautogui coords on HiDPI displays."""
    global _scale_cache
    try:
        if _scale_cache is None:
            sw, sh = pyautogui.size()
            ss = pyautogui.screenshot()
            _scale_cache = (sw / ss.size[0], sh / ss.size[1])
        sx_ratio, sy_ratio = _scale_cache
        return int(x * sx_ratio), int(y * sy_ratio)
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
            return _fail(f"AppleScript error: {r.stderr.strip()}", error_code="EXEC_ERROR")
        return _ok(f"Executed: {body.strip()}")
    except subprocess.TimeoutExpired:
        return _fail(f"AppleScript timed out after {timeout}s", error_code="TIMEOUT")
    except Exception as e:
        return _fail(f"Execution failed: {e}", error_code="EXEC_ERROR")

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

def _do_mouse(x: int, y: int, action: str = "click", hold_keys: list = None,
              end_x: int = None, end_y: int = None) -> Dict[str, Any]:
    valid = {"move", "click", "double_click", "right_click", "drag"}
    if action not in valid:
        return _fail(f"Invalid action '{action}'. Valid: {sorted(valid)}")
    if action == "drag" and (end_x is None or end_y is None):
        return _fail("drag requires end_x and end_y parameters", error_code="INVALID_PARAM")
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
        elif action == "drag":
            sex, sey = _scale(end_x, end_y)
            pyautogui.mouseDown(x=sx, y=sy)
            time.sleep(0.05)
            pyautogui.moveTo(sex, sey, duration=0.3)
            time.sleep(0.05)
            pyautogui.mouseUp()
        for hk in reversed(held):
            pyautogui.keyUp(hk)
        hs = f" (holding {'+'.join(hold_keys)})" if hold_keys else ""
        if action == "drag":
            return _ok(f"drag from ({x},{y}) to ({end_x},{end_y}){hs}")
        return _ok(f"{action} at ({x}, {y}){hs}")
    except Exception as e:
        for hk in reversed(held):
            try: pyautogui.keyUp(hk)
            except: pass
        return _fail(f"Mouse action failed: {e}")

def _do_type(text: str, use_clipboard: Optional[bool] = None) -> Dict[str, Any]:
    if not text:
        return _fail("text is required", error_code="INVALID_PARAM")
    is_pure_ascii = all(ord(c) < 128 for c in text)
    should_use_clipboard = use_clipboard if use_clipboard is not None else not is_pure_ascii
    try:
        if should_use_clipboard:
            r = subprocess.run(['pbcopy'], input=text, text=True, capture_output=True, timeout=5)
            if r.returncode != 0:
                return _fail(f"Failed to copy text to clipboard: {r.stderr}")
            time.sleep(0.05)
            paste_result = _run_applescript('keystroke "v" using {command down}')
            if paste_result["status"] != "success":
                return _fail(f"Clipboard paste failed: {paste_result['message']}")
            preview = text[:60] + ("..." if len(text) > 60 else "")
            return _ok(f"Typed via clipboard ({len(text)} chars): {preview}")
        else:
            pyautogui.write(text, interval=0.02)
            return _ok(f"Typed: {text}")
    except Exception as e:
        return _fail(f"Failed to type: {e}", error_code="EXEC_ERROR")

def _do_scroll(dx: int = 0, dy: int = 0) -> Dict[str, Any]:
    try:
        if dx == 0 and dy == 0:
            return _ok("Scrolled (no movement)")
        if dx != 0 and dy != 0:
            evt = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 2, -dy, -dx)
        elif dy != 0:
            evt = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 1, -dy)
        else:
            evt = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 2, 0, -dx)
        CGEventPost(kCGHIDEventTap, evt)
        return _ok(f"Scrolled dx={dx}px, dy={dy}px")
    except Exception as e:
        return _fail(f"Scroll failed: {e}", error_code="EXEC_ERROR")

def _do_focus_app(app_name: str, timeout: int = 30) -> Dict[str, Any]:
    if not app_name:
        return _fail("app_name is required")
    if timeout <= 0:
        return _fail("timeout must be positive")
    try:
        r = subprocess.run(["osascript", "-e", f'tell application "{app_name}" to activate'],
                           capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return _fail(f"Failed to activate '{app_name}': {r.stderr.strip()}", error_code="EXEC_ERROR")
    except Exception as e:
        return _fail(f"Execution failed: {e}", error_code="EXEC_ERROR")
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
    return _fail(f"Timeout waiting for '{app_name}' after {timeout}s", error_code="TIMEOUT", last_active_app=last)


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
                 hold_keys: list[str] = [],
                 end_x: int = None, end_y: int = None) -> Dict[str, Any]:
    """Perform a mouse action at screen coordinates.

    Args:
        x: Pixels from left edge (start position for drag, click position for others).
        y: Pixels from top edge.
        action: "click" (default), "double_click", "right_click", "move", or "drag".
        hold_keys: Modifier keys to hold during action (e.g. ["command"]).
        end_x: End x-position for "drag" action only. Ignored for other actions.
        end_y: End y-position for "drag" action only. Ignored for other actions.

        Example — drag a file from (200,300) to (800,400):
            mouse_action(x=200, y=300, action="drag", end_x=800, end_y=400)
    """
    if x is None or y is None:
        return _fail("x and y coordinates are required")
    return _do_mouse(x, y, action, hold_keys if hold_keys else None, end_x, end_y)


# ── 3. Text Input ────────────────────────────────────────────────────────────

@mcp.tool()
def type_text(text: str, use_clipboard: Optional[bool] = None) -> Dict[str, Any]:
    """Type a string of text into the focused input field.

    Automatically uses clipboard-paste for non-ASCII characters (Unicode, emoji,
    accented letters, etc.) which pyautogui cannot handle. For pure ASCII text,
    uses direct key synthesis.

    For special keys or shortcuts (Return, Cmd+V), use press_keystroke instead.

    Args:
        text: The text string to type. Supports any Unicode characters.
        use_clipboard: Override auto-detection. True = always use clipboard method
                      (safe for all text). False = always use direct key synthesis
                      (ASCII only). None = auto (default).
    """
    return _do_type(text, use_clipboard)


# ── 4. Scrolling ─────────────────────────────────────────────────────────────

@mcp.tool()
def scroll(dx: int = 0, dy: int = 0) -> Dict[str, Any]:
    """Scroll at the current mouse position.

    Args:
        dx: Horizontal scroll in pixels (positive=right, negative=left).
        dy: Vertical scroll in pixels (positive=down, negative=up).

        Typical values: 100-300px for small scroll, 500-1000px for page scroll.
        Note: Actual scroll distance may vary by app and system scroll speed settings.
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
            {"action": "drag", "x": 200, "y": 300, "end_x": 800, "end_y": 400}
            {"action": "scroll", "dx": 0, "dy": -300}
            {"action": "focus_app", "app": "Notes"}
            {"action": "delay", "ms": 2000}  ← explicit extra pause
            {"action": "run_command", "command": "ls ~/Desktop", "timeout_seconds": 30}
            {"action": "write_file", "path": "~/Desktop/out.txt", "content": "hello", "mode": "overwrite"}
            {"action": "read_file", "path": "~/Desktop/in.txt", "max_chars": 4000}
            {"action": "set_clipboard", "content": "text to paste later"}
        default_delay_ms: Pause between actions in ms (default 750).
                          Increase for slow UI transitions. The AI can also
                          insert explicit delay actions for known-slow steps.

    On failure, returns status="partial_success" if some steps succeeded before
    failure, or status="error" if the first step failed. Includes "recovery_hint"
    and "steps" array for per-step debugging.

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
            res = _do_type(act.get("text", ""), act.get("use_clipboard", None))
        elif action_type in ("click", "double_click", "right_click", "move", "drag"):
            res = _do_mouse(act.get("x", 0), act.get("y", 0), action_type,
                            act.get("hold_keys"), act.get("end_x"), act.get("end_y"))
        elif action_type == "scroll":
            res = _do_scroll(act.get("dx", 0), act.get("dy", 0))
        elif action_type == "focus_app":
            res = _do_focus_app(act.get("app", ""), act.get("timeout", 30))
        elif action_type == "delay":
            ms = act.get("ms", 1000)
            time.sleep(ms / 1000.0)
            res = _ok(f"Delayed {ms}ms")
        elif action_type == "run_command":
            cmd = act.get("command", "")
            if not cmd:
                res = _fail("run_command step requires 'command' key", error_code="INVALID_PARAM")
            else:
                timeout_s = max(1, min(act.get("timeout_seconds", 30), 300))
                try:
                    r = subprocess.run(cmd, shell=True, capture_output=True,
                                       text=True, timeout=timeout_s)
                    stdout = r.stdout[:3000] + ("...[truncated]" if len(r.stdout) > 3000 else "")
                    stderr = r.stderr[:500] + ("...[truncated]" if len(r.stderr) > 500 else "")
                    if r.returncode == 0:
                        res = _ok("Command completed", stdout=stdout, stderr=stderr, exit_code=0)
                    else:
                        res = _fail(f"Command failed (exit {r.returncode})",
                                    error_code="EXEC_ERROR", stdout=stdout, stderr=stderr,
                                    exit_code=r.returncode)
                except subprocess.TimeoutExpired:
                    res = _fail(f"Command timed out after {timeout_s}s", error_code="TIMEOUT")
                except Exception as e:
                    res = _fail(f"Command error: {e}", error_code="EXEC_ERROR")
        elif action_type == "write_file":
            wf_path = act.get("path", "")
            if not wf_path:
                res = _fail("write_file step requires 'path' key", error_code="INVALID_PARAM")
            else:
                try:
                    p = os.path.expanduser(wf_path)
                    os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
                    wf_mode = "a" if act.get("mode", "overwrite") == "append" else "w"
                    wf_content = act.get("content", "")
                    with open(p, wf_mode, encoding="utf-8") as f:
                        f.write(wf_content)
                    res = _ok(f"Wrote {len(wf_content)} chars to {p}")
                except Exception as e:
                    res = _fail(f"Write failed: {e}", error_code="EXEC_ERROR")
        elif action_type == "read_file":
            rf_path = act.get("path", "")
            if not rf_path:
                res = _fail("read_file step requires 'path' key", error_code="INVALID_PARAM")
            else:
                try:
                    p = os.path.expanduser(rf_path)
                    max_c = max(100, min(act.get("max_chars", 4000), 20000))
                    with open(p, "r", encoding="utf-8") as f:
                        content = f.read(max_c)
                    truncated = os.path.getsize(p) > max_c
                    res = _ok(f"Read {len(content)} chars from {p}",
                              content=content, truncated=truncated)
                except FileNotFoundError:
                    res = _fail(f"File not found: {rf_path}", error_code="NOT_FOUND")
                except Exception as e:
                    res = _fail(f"Read failed: {e}", error_code="EXEC_ERROR")
        elif action_type == "set_clipboard":
            clip_content = act.get("content", "")
            try:
                subprocess.run(['pbcopy'], input=clip_content, text=True, timeout=5)
                res = _ok(f"Clipboard set ({len(clip_content)} chars)")
            except Exception as e:
                res = _fail(f"Clipboard set failed: {e}", error_code="EXEC_ERROR")
        else:
            res = _fail(f"Unknown action type: {action_type}", error_code="INVALID_PARAM")

        results.append({"step": i + 1, "action": action_type, **res})

        # Stop on error
        if res.get("status") == "error":
            break

        # Inter-action delay (skip after last action and after explicit delays)
        if i < len(actions) - 1 and action_type != "delay":
            time.sleep(delay_s)

    failed = [r for r in results if r.get("status") == "error"]
    total = len(actions)

    if failed:
        failed_step = failed[0]
        completed_count = failed_step["step"] - 1
        overall_status = "error" if completed_count == 0 else "partial_success"
        return {
            "status": overall_status,
            "message": (
                f"Macro stopped at step {failed_step['step']} of {total}: "
                f"{failed_step['message']}"
            ),
            "completed_steps": completed_count,
            "total_steps": total,
            "stopped_at_step": failed_step["step"],
            "failed_action": failed_step.get("action", "unknown"),
            "failure_reason": failed_step.get("message", "unknown error"),
            "recovery_hint": (
                "Check 'steps' array for per-step results. "
                "You can retry from the failed step using a new execute_macro() call. "
                "If this was a UI permission dialog, use mouse_action() to click Allow first."
            ),
            "steps": results
        }

    return _ok(f"Macro completed: {len(results)}/{total} steps",
               completed_steps=len(results), total_steps=total, steps=results)


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
    """Get screen dimensions in both logical and pixel coordinates.

    IMPORTANT for agents: Always use logical_width/logical_height when specifying
    coordinates for mouse_action(), press_keystroke(), or scroll(). The pixel
    dimensions are only needed if you are processing raw screenshot images.
    Coordinates from get_screen_text() are already in logical space.
    """
    try:
        lw, lh = pyautogui.size()
        try:
            ss = pyautogui.screenshot()
            pw, ph = ss.width, ss.height
            scale = round(pw / lw, 1)
        except Exception:
            pw, ph, scale = lw, lh, 1.0
        return _ok(
            f"Screen: {lw}x{lh} logical ({pw}x{ph} physical, scale {scale}x)",
            logical_width=lw, logical_height=lh,
            pixel_width=pw, pixel_height=ph,
            scale_factor=scale,
            coordinate_space_note="Pass logical coordinates to mouse_action(). get_screen_text() returns logical coords."
        )
    except Exception as e:
        return _fail(f"Failed: {e}", error_code="EXEC_ERROR")

def _ax_get(elem, attr: str):
    """Safely retrieve an AX attribute value. Returns None on any failure."""
    try:
        err, val = AXUIElementCopyAttributeValue(elem, attr, None)
        return val if err == 0 else None
    except Exception:
        return None

@mcp.tool()
def get_screen_layout() -> Dict[str, Any]:
    """Get window titles and positions for all visible apps via Accessibility APIs.

    Returns accurate window information using the AX API, which works for all
    modern macOS applications. Use this to understand what is on screen before
    using mouse_action() or execute_macro() to interact with specific windows.

    Note: Requires Accessibility permission granted to Terminal in
    System Settings → Privacy & Security → Accessibility.
    Passwords in secure text fields are automatically redacted by macOS.
    """
    if not ACCESSIBILITY_AVAILABLE:
        return _fail(
            "macOS Accessibility frameworks not available. "
            "Grant Accessibility permission to Terminal (or your terminal app) in "
            "System Settings → Privacy & Security → Accessibility, then restart the terminal.",
            error_code="PERMISSION"
        )
    try:
        ws = NSWorkspace.sharedWorkspace()
        running_apps = ws.runningApplications()
        active_app_obj = ws.frontmostApplication()

        windows_out = []

        for app in running_apps:
            try:
                if app.activationPolicy() == 2:
                    continue
            except Exception:
                continue

            pid = app.processIdentifier()
            app_name = str(app.localizedName() or "Unknown")

            try:
                app_elem = AXUIElementCreateApplication(pid)
                windows_raw = _ax_get(app_elem, "AXWindows")
                if not windows_raw:
                    continue

                for win in windows_raw:
                    title = str(_ax_get(win, "AXTitle") or "")
                    pos   = _ax_get(win, "AXPosition")
                    size  = _ax_get(win, "AXSize")

                    win_data = {"app": app_name, "title": title}

                    if pos is not None and size is not None:
                        try:
                            win_data["bounds"] = {
                                "x": int(pos.x), "y": int(pos.y),
                                "width": int(size.width), "height": int(size.height)
                            }
                        except Exception:
                            pass

                    windows_out.append(win_data)

            except Exception:
                continue

        active_info = None
        if active_app_obj:
            active_info = {
                "name": str(active_app_obj.localizedName() or ""),
                "bundle_id": str(active_app_obj.bundleIdentifier() or ""),
                "pid": int(active_app_obj.processIdentifier())
            }

        return _ok(
            f"Found {len(windows_out)} visible windows",
            screen_info={"windows": windows_out, "active_app": active_info}
        )
    except Exception as e:
        return _fail(f"AX layout failed: {e}")

@mcp.tool()
def get_screen_text(screenshot: bool = False) -> Dict[str, Any]:
    """Read all text currently visible on screen using OCR, or capture a screenshot.

    Args:
        screenshot: If False (default), run OCR and return text elements with
                   coordinates. If True, skip OCR — capture a screenshot instead,
                   save it to ~/Desktop/orchestrator_screenshot.png, and return
                   the file path. Use screenshots when you need visual context
                   that OCR cannot capture (charts, images, custom UI graphics).

    Returns for screenshot=False: text_elements list with position data, full_text string.
    Returns for screenshot=True:  screenshot_path, width, height.

    COORDINATE NOTE: All position values returned are in LOGICAL screen coordinates
    (matching what mouse_action() expects). On Retina displays, these are half
    the raw pixel values. First OCR call is slow (~5s) due to EasyOCR model load.
    """
    try:
        ss = pyautogui.screenshot()

        if screenshot:
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            save_path = os.path.expanduser(f"~/Desktop/orchestrator_screenshot_{ts}.png")
            ss.save(save_path)
            lw, lh = pyautogui.size()
            return _ok(
                f"Screenshot saved to {save_path}",
                screenshot_path=save_path,
                logical_width=lw, logical_height=lh,
                pixel_width=ss.width, pixel_height=ss.height
            )

        lw, lh = pyautogui.size()
        scale_x = lw / ss.width
        scale_y = lh / ss.height
        arr = np.array(ss)
        results = get_ocr_reader().readtext(arr)
        elements = []
        for (bbox, text, conf) in results:
            if conf > 0.3:
                x1, y1 = bbox[0]; x2, y2 = bbox[2]
                cx = int(((x1 + x2) / 2) * scale_x)
                cy = int(((y1 + y2) / 2) * scale_y)
                scaled_bbox = [[int(p[0] * scale_x), int(p[1] * scale_y)] for p in bbox]
                elements.append({
                    "text": text.strip(), "confidence": round(conf, 3),
                    "position": {"center_x": cx, "center_y": cy, "bbox": scaled_bbox}
                })
        elements.sort(key=lambda e: (e["position"]["center_y"], e["position"]["center_x"]))
        full_text = "\n".join(e["text"] for e in elements)
        return _ok(f"Found {len(elements)} text elements",
                   screen_size={"width": lw, "height": lh, "coordinate_space": "logical"},
                   text_elements=elements, full_text=full_text)
    except Exception as e:
        return _fail(f"Screen read failed: {e}")


# ── 8. Terminal ───────────────────────────────────────────────────────────────

@mcp.tool()
def run_terminal_command(command: str, timeout_seconds: int = 30,
                         run_in_background: bool = False,
                         max_output_chars: int = 8000) -> Dict[str, Any]:
    """Execute a terminal command with configurable timeout and background mode.

    Args:
        command: Shell command to run.
        timeout_seconds: Max wait time in seconds (default 30, max 300).
        run_in_background: If true, start async and return the PID immediately.
                          Use this for dev servers, long builds, etc.
        max_output_chars: Maximum characters to return from stdout+stderr combined
                         (default 8000). Truncated output includes a notice.
                         Increase up to 50000 for commands with large output.
                         Set to 0 to disable truncation (use carefully).
    """
    timeout_seconds = max(1, min(timeout_seconds, 300))
    try:
        if run_in_background:
            proc = subprocess.Popen(command, shell=True, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, start_new_session=True)
            return _ok(f"Background process started (PID {proc.pid})", pid=proc.pid)
        r = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout_seconds)

        stdout = r.stdout
        stderr = r.stderr
        truncated = False
        cap = max(0, min(max_output_chars, 50000))

        if cap > 0:
            total = len(stdout) + len(stderr)
            if total > cap:
                stdout_limit = int(cap * 0.85)
                stderr_limit = cap - stdout_limit
                if len(stdout) > stdout_limit:
                    stdout = stdout[:stdout_limit] + f"\n... [TRUNCATED: {len(r.stdout) - stdout_limit} more chars] ..."
                if len(stderr) > stderr_limit:
                    stderr = stderr[:stderr_limit] + "\n... [TRUNCATED]"
                truncated = True

        extra = {"total_output_chars": len(r.stdout) + len(r.stderr)} if truncated else {}
        return _ok("Command completed",
                   stdout=stdout, stderr=stderr, exit_code=r.returncode,
                   truncated=truncated, **extra)
    except subprocess.TimeoutExpired:
        return _fail(f"Command timed out after {timeout_seconds}s", error_code="TIMEOUT")
    except Exception as e:
        return _fail(f"Execution failed: {e}", error_code="EXEC_ERROR")


# ── 9. Spotlight File Search ─────────────────────────────────────────────────

@mcp.tool()
def find_file(query: str, search_dir: str = "", file_type: str = "", sort_by: str = "", limit: int = 50, include_source: bool = False) -> Dict[str, Any]:
    """Find files using macOS Spotlight (mdfind) — millisecond results across the whole drive.

    NOTE: Returns a list of objects with metadata (path, name, last_modified, size_kb)
    instead of raw strings.

    QUERY STYLE — IMPORTANT:
    This tool uses Spotlight keyword matching (mdfind), NOT semantic/AI search.

    Queries that WORK (filename keywords, content keywords, exact terms):
       "automac_mcp"      → finds files with this name
       "Ambica Wooden"    → finds files containing these words
       "kind:pdf"         → Spotlight metadata query
       "date:today"       → files modified today

    Queries that DON'T WORK (conceptual/semantic):
       "python scripts"   → will not match .py files
       "study notes"      → won't find your notebook unless it literally says "study notes"
       "recent downloads" → use list_directory() with sort_by="date_desc" instead

    For semantic/meaning-based search, use vector_search() if the indexer is running.
    For regex-in-content search, use smart_search().
    For browsing by date or size, use list_directory().

    WARNING: Setting include_source to True will execute 'mdls' for each file found,
    which can significantly slow down the search. Use this only with a low 'limit'
    and for a small number of files when you need to find source URLs (e.g., origin domain).

    Args:
        query: Search query (filename, content keyword, etc.)
        search_dir: Optional directory to scope the search.
        file_type: Optional extension filter (e.g. "pdf", "zip").
        sort_by: Optional sort order ("date_desc", "date_asc", "size_desc", "size_asc", "name_asc", "name_desc").
        limit: Max number of results to return (default 50).
        include_source: If True, fetches the source URL (kMDItemWhereFroms) for each file.
    """
    if not query:
        return _fail("query is required")
    try:
        cmd = ["mdfind"]
        if search_dir:
            expanded = os.path.expanduser(search_dir)
            if os.path.isdir(expanded):
                cmd.extend(["-onlyin", expanded])
        
        # Smart Query Construction
        if "kMDItem" in query or ":" in query:
            search = query
        else:
            search = f"(kMDItemFSName == '*{query}*'cd || kMDItemTextContent == '*{query}*'cd)"
            
        if file_type:
            ext = file_type.lstrip('.')
            search = f"({search}) && kMDItemFSName == '*.{ext}'cd"
            
        cmd.append(search)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        paths = [f for f in r.stdout.strip().split("\n") if f]
        
        # Smarter Slicing
        needs_stat_for_sort = sort_by in ("date_desc", "date_asc", "size_desc", "size_asc")
        
        if not needs_stat_for_sort:
            # Sort paths directly if name-based or no sort
            if sort_by == "name_asc":
                paths.sort(key=lambda x: os.path.basename(x))
            elif sort_by == "name_desc":
                paths.sort(key=lambda x: os.path.basename(x), reverse=True)
            
            # Slice early
            paths = paths[:limit]
            
        files_data = []
        for p in paths:
            try:
                st = os.stat(p)
                item = {
                    "path": p,
                    "name": os.path.basename(p),
                    "last_modified": datetime.fromtimestamp(st.st_mtime).isoformat(),
                    "size_kb": round(st.st_size / 1024, 2)
                }
                files_data.append(item)
            except OSError:
                continue
                
        # If we needed stats for sort, we do it now on the full list, then slice
        if needs_stat_for_sort:
            if sort_by == "date_desc":
                files_data.sort(key=lambda x: x["last_modified"], reverse=True)
            elif sort_by == "date_asc":
                files_data.sort(key=lambda x: x["last_modified"])
            elif sort_by == "size_desc":
                files_data.sort(key=lambda x: x["size_kb"], reverse=True)
            elif sort_by == "size_asc":
                files_data.sort(key=lambda x: x["size_kb"])
                
            files_data = files_data[:limit]
            
        # Deferred Metadata Fetching (mdls)
        if include_source and files_data:
            for item in files_data:
                try:
                    mdls_r = subprocess.run(["mdls", "-name", "kMDItemWhereFroms", item["path"]], 
                                            capture_output=True, text=True, timeout=1.5)
                    if mdls_r.returncode == 0:
                        urls = re.findall(r'"(https?://.*?)"', mdls_r.stdout)
                        item["source_urls"] = urls
                    else:
                        item["source_urls"] = []
                except subprocess.TimeoutExpired:
                    item["source_urls"] = [] # Graceful timeout
                except Exception:
                    item["source_urls"] = []
                    
        return _ok(f"Found {len(files_data)} files", files=files_data)
    except Exception as e:
        return _fail(f"Search failed: {e}")


# ── 9.5 Vector Search ─────────────────────────────────────────────────────────

@mcp.tool()
def vector_search(query: str) -> Dict[str, Any]:
    """Perform a semantic/vector search across indexed files.
    
    This queries the Cloudflare RAG database for files matching the meaning of the query,
    even if the exact keywords are not present.
    
    Args:
        query: The search query or question.
    """
    if not query:
        return _fail("query is required")
    try:
        url = "https://mac-brain-worker.jb-brain.workers.dev/search"
        token = os.getenv("INGEST_TOKEN", "mac-brain-secret-key-123")
        config_path = os.path.expanduser("~/.config/mac-orchestrator/config.json")
        if os.path.exists(config_path):
            try:
                with open(config_path, "r") as f:
                    config = json.load(f)
                    token = config.get("INGEST_TOKEN", token)
            except Exception:
                pass
        headers = {"Authorization": f"Bearer {token}"}
        resp = requests.get(url, params={"q": query}, headers=headers, timeout=10)
        if resp.status_code == 200:
            return _ok(f"Found matches for: {query}", results=resp.json().get("results", []))
        else:
            return _fail(f"Search failed: {resp.status_code} - {resp.text}")
    except Exception as e:
        return _fail(f"Search failed: {e}")

# ── 10. File I/O ─────────────────────────────────────────────────────────────

@mcp.tool()
def read_file(path: str, preview: bool = False, preview_size_kb: int = 1, preview_lines: Optional[int] = None) -> Dict[str, Any]:
    """Read a file's contents.

    Args:
        path: Absolute or ~-relative path to the file.
        preview: If True, returns only the head and tail of the file to save context window.
        preview_size_kb: Size in KB to read from both head and tail in preview mode (default 1).
        preview_lines: If provided, returns the first N and last N lines using native tools.
    """
    try:
        p = os.path.expanduser(path)
        
        # Adaptive Previewing (Subprocess Fast Path)
        if preview_lines is not None:
            try:
                # Get head
                head_r = subprocess.run(["head", "-n", str(preview_lines), p], capture_output=True, text=True, timeout=5)
                # Get tail
                tail_r = subprocess.run(["tail", "-n", str(preview_lines), p], capture_output=True, text=True, timeout=5)
                
                content = head_r.stdout + f"\n\n... [TRUNCATED - PREVIEW MODE ({preview_lines} Lines Head/Tail)] ...\n\n" + tail_r.stdout
                return _ok(f"Read preview ({preview_lines} lines head/tail) from {p}", content=content)
            except Exception as e:
                return _fail(f"Fast preview failed: {e}")

        file_size = os.path.getsize(p)
        chunk_size = preview_size_kb * 1024
        
        if preview and file_size > (chunk_size * 2):
            with open(p, "rb") as f:
                head = f.read(chunk_size).decode('utf-8', errors='replace')
                f.seek(-chunk_size, os.SEEK_END)
                tail_bytes = f.read(chunk_size)
                
                # UTF-8 Resilience: find first newline and slice
                try:
                    first_nl = tail_bytes.index(b'\n')
                    tail_bytes = tail_bytes[first_nl + 1:]
                except ValueError:
                    # No newline found, just decode what we have
                    pass
                    
                tail = tail_bytes.decode('utf-8', errors='replace')
                
            content = head + f"\n\n... [TRUNCATED - PREVIEW MODE ({preview_size_kb}KB Head/Tail)] ...\n\n" + tail
            return _ok(f"Read preview ({preview_size_kb}KB head/tail) from {p}", content=content)
        else:
            with open(p, "r", encoding="utf-8") as f:
                content = f.read()
            return _ok(f"Read {len(content)} chars from {p}", content=content)
    except Exception as e:
        return _fail(f"Read failed: {e}")

@mcp.tool()
def write_file(path: str, content: str, mode: str = "overwrite") -> Dict[str, Any]:
    """Write content to a file.

    Args:
        path: Absolute or ~-relative file path. Parent dirs created automatically.
        content: The text content to write.
        mode: "overwrite" (default) replaces file contents entirely.
              "append" adds content to the end of an existing file (creates if absent).
    """
    try:
        p = os.path.expanduser(path)
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
        file_mode = "a" if mode == "append" else "w"
        with open(p, file_mode, encoding="utf-8") as f:
            f.write(content)
        verb = "Appended" if mode == "append" else "Wrote"
        return _ok(f"{verb} {len(content)} chars to {p}")
    except Exception as e:
        return _fail(f"Write failed: {e}")

@mcp.tool()
def list_directory(path: str, limit: int = 50, sort_by: str = "date_desc", summary_only: bool = False, offset: int = 0) -> Dict[str, Any]:
    """List contents of a directory.
    
    NOTE: Returns objects with metadata (name, path, last_modified, size_kb) 
    instead of raw strings.

    Args:
        path: Absolute or ~-relative directory path.
        limit: Max number of results to return (default 50).
        sort_by: Sort order ("date_desc", "date_asc", "size_desc", "size_asc", "name_asc", "name_desc").
        summary_only: If True, returns a high-level survey (counts, sizes, extensions, age) instead of file lists.
        offset: Number of items to skip (default 0).
    """
    from collections import Counter
    try:
        p = os.path.expanduser(path)
        if not os.path.isdir(p):
            return _fail(f"Not a directory: {p}")
            
        # Summary Mode Guard (O(1) memory)
        if summary_only:
            total_folders = 0
            total_files = 0
            total_size_kb = 0.0
            extensions = []
            age_distribution = {"< 1 day": 0, "1-7 days": 0, "8-30 days": 0, "31-365 days": 0, "> 1 year": 0}
            now = time.time()
            
            with os.scandir(p) as it:
                for entry in it:
                    try:
                        if entry.is_dir():
                            total_folders += 1
                        else:
                            total_files += 1
                            ext = os.path.splitext(entry.name)[1].lower()
                            if ext:
                                extensions.append(ext)
                                
                            st = entry.stat()
                            total_size_kb += st.st_size / 1024
                            
                            days_old = (now - st.st_mtime) / 86400
                            if days_old < 1: age_distribution["< 1 day"] += 1
                            elif days_old <= 7: age_distribution["1-7 days"] += 1
                            elif days_old <= 30: age_distribution["8-30 days"] += 1
                            elif days_old <= 365: age_distribution["31-365 days"] += 1
                            else: age_distribution["> 1 year"] += 1
                    except OSError:
                        continue
                        
            top_extensions = dict(Counter(extensions).most_common(5))
            return _ok(f"Summary for {p}", 
                       summary={
                           "total_folders": total_folders,
                           "total_files": total_files,
                           "total_size_mb": round(total_size_kb / 1024, 2),
                           "top_extensions": top_extensions,
                           "age_distribution": age_distribution
                       })
                       
        # Normal Mode
        entries = []
        with os.scandir(p) as it:
            for entry in it:
                entries.append(entry)
                
        needs_stat_for_sort = sort_by in ("date_desc", "date_asc", "size_desc", "size_asc")
        
        folders = []
        files = []
        
        # Pre-Stat Sorting (Fast Path)
        if not needs_stat_for_sort:
            # Separate and sort by name first
            for entry in entries:
                try:
                    if entry.is_dir():
                        folders.append({"name": entry.name, "path": entry.path})
                    else:
                        files.append({"name": entry.name, "path": entry.path})
                except OSError:
                    continue
                    
            if sort_by == "name_asc":
                folders.sort(key=lambda x: x["name"])
                files.sort(key=lambda x: x["name"])
            elif sort_by == "name_desc":
                folders.sort(key=lambda x: x["name"], reverse=True)
                files.sort(key=lambda x: x["name"], reverse=True)
                
            # Apply offset and limit
            folders = folders[offset:offset+limit]
            files = files[offset:offset+limit]
            
            # Now stat ONLY the sliced batch
            for item in folders:
                try:
                    st = os.stat(item["path"])
                    item["last_modified"] = datetime.fromtimestamp(st.st_mtime).isoformat()
                    item["size_kb"] = round(st.st_size / 1024, 2)
                except OSError:
                    item["last_modified"] = "unknown"
                    item["size_kb"] = 0
                    
            for item in files:
                try:
                    st = os.stat(item["path"])
                    item["last_modified"] = datetime.fromtimestamp(st.st_mtime).isoformat()
                    item["size_kb"] = round(st.st_size / 1024, 2)
                except OSError:
                    item["last_modified"] = "unknown"
                    item["size_kb"] = 0
                    
        else:
            # Need stat for sort
            all_items = []
            for entry in entries:
                try:
                    st = entry.stat()
                    item_data = {
                        "name": entry.name,
                        "path": entry.path,
                        "is_dir": entry.is_dir(),
                        "last_modified": datetime.fromtimestamp(st.st_mtime).isoformat(),
                        "size_kb": round(st.st_size / 1024, 2)
                    }
                    all_items.append(item_data)
                except OSError:
                    continue
                    
            # Separate
            folders = [x for x in all_items if x["is_dir"]]
            files = [x for x in all_items if not x["is_dir"]]
            
            # Sort
            if sort_by == "date_desc":
                folders.sort(key=lambda x: x["last_modified"], reverse=True)
                files.sort(key=lambda x: x["last_modified"], reverse=True)
            elif sort_by == "date_asc":
                folders.sort(key=lambda x: x["last_modified"])
                files.sort(key=lambda x: x["last_modified"])
            elif sort_by == "size_desc":
                folders.sort(key=lambda x: x["size_kb"], reverse=True)
                files.sort(key=lambda x: x["size_kb"], reverse=True)
            elif sort_by == "size_asc":
                folders.sort(key=lambda x: x["size_kb"])
                files.sort(key=lambda x: x["size_kb"])
                
            # Apply offset and limit
            folders = folders[offset:offset+limit]
            files = files[offset:offset+limit]
            
            # Clean up temporary "is_dir" key
            for x in folders: x.pop("is_dir", None)
            for x in files: x.pop("is_dir", None)
            
        return _ok(f"{len(folders)} folders, {len(files)} files in {p} (offset {offset}, limit {limit})",
                   folders=folders, files=files)
    except Exception as e:
        return _fail(f"Failed: {e}")


# ── 11. Regex Search ─────────────────────────────────────────────────────────

@mcp.tool()
def smart_search(directory: str, regex_pattern: str,
                 file_extension_filter: Optional[str] = None,
                 max_chars: int = 10000) -> Dict[str, Any]:
    """Search for a regex pattern inside files within a directory.

    Args:
        directory: Root directory to search recursively.
        regex_pattern: Regex pattern to match against file contents.
        file_extension_filter: Optional file extension (e.g. ".py").
        max_chars: Maximum total characters to return across all matches (default 10000).
                   Increase for larger codebases. Hard ceiling: 100000.
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
        MAX = max(1000, min(max_chars, 100000))
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
def clipboard(action: str, content: str = "") -> Dict[str, Any]:
    """Get or set the macOS clipboard (pasteboard) contents.

    Args:
        action: "get" to read clipboard contents, "set" to write to clipboard.
        content: Text to write to clipboard. Required for action="set".
                Ignored for action="get". Supports all Unicode characters.

    Examples:
        clipboard(action="get")                          → returns current clipboard text
        clipboard(action="set", content="Hello World")   → loads text into clipboard

    After set, use press_keystroke(key="v", modifiers=["command"]) to paste.
    After get, use the returned "content" field in your next action.

    Note: Only text content is accessible. Images or files in the clipboard
    will return an empty string from "get".
    """
    if action not in ("get", "set"):
        return _fail(f"Invalid action '{action}'. Use 'get' or 'set'.", error_code="INVALID_PARAM")
    try:
        if action == "get":
            r = subprocess.run(['pbpaste'], capture_output=True, text=True, timeout=5)
            if r.returncode != 0:
                return _fail(f"Failed to read clipboard: {r.stderr.strip()}", error_code="EXEC_ERROR")
            text = r.stdout
            preview = text[:100] + ("..." if len(text) > 100 else "")
            return _ok(f"Clipboard contents ({len(text)} chars)",
                       content=text, preview=preview, length=len(text))
        else:  # action == "set"
            r = subprocess.run(['pbcopy'], input=content, text=True,
                               capture_output=True, timeout=5)
            if r.returncode != 0:
                return _fail(f"Failed to set clipboard: {r.stderr.strip()}", error_code="EXEC_ERROR")
            return _ok(f"Clipboard set ({len(content)} chars)", length=len(content))
    except Exception as e:
        return _fail(f"Clipboard operation failed: {e}", error_code="EXEC_ERROR")

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
