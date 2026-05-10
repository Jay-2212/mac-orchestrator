#!/usr/bin/env python3

import subprocess
import json
import time
import os
import sys
import re
import requests
from pathlib import Path
from pyngrok import ngrok, conf
from rich.console import Console
from rich.prompt import Prompt
from rich.panel import Panel
from typing import Any, Dict, List, Optional
import pyautogui
import easyocr
import numpy as np
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import TransportSecuritySettings
try:
    from Cocoa import NSWorkspace
    from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID, CGEventCreateScrollWheelEvent, CGEventPost, kCGScrollEventUnitPixel, kCGHIDEventTap
    from ApplicationServices import AXUIElementCreateApplication, AXUIElementCopyAttributeValue, kAXWindowsAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute
    ACCESSIBILITY_AVAILABLE = True
except ImportError:
    ACCESSIBILITY_AVAILABLE = False

TELEGRAM_BOT_TOKEN = ""
TELEGRAM_CHAT_ID = ""

# Initialize the MCP server (streamable-http transport on localhost:8000, path /mcp)
# We disable DNS rebinding protection because ngrok forwards requests with the ngrok Host header.
mcp = FastMCP(
    "AutoMac MCP - macOS UI Automation", 
    host="127.0.0.1", 
    port=8000,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False)
)

# Initialize pyautogui settings
pyautogui.FAILSAFE = True
_ocr_reader = None

def get_ocr_reader():
    global _ocr_reader
    if _ocr_reader is None:
        import easyocr
        _ocr_reader = easyocr.Reader(['en'])
    return _ocr_reader


def _scale_coordinates_for_display(x: int, y: int) -> tuple[int, int]:
    """Scale coordinates for retina/high-DPI displays."""
    try:
        # Get the actual screen size from pyautogui
        screen_width, screen_height = pyautogui.size()
        
        # Take a screenshot to get the logical size
        screenshot = pyautogui.screenshot()
        logical_width, logical_height = screenshot.size
        
        # Calculate scaling factors
        scale_x = screen_width / logical_width
        scale_y = screen_height / logical_height
        
        # Scale the coordinates
        scaled_x = int(x * scale_x)
        scaled_y = int(y * scale_y)
        
        return scaled_x, scaled_y
    except Exception:
        # If scaling fails, return original coordinates
        return x, y

@mcp.tool()
def get_screen_size() -> Dict[str, Any]:
    try:
        screen_width, screen_height = pyautogui.size()
        return {"success": True, "message": f"Screen size = ({screen_width}, {screen_height})"}
    except Exception as e:
        return {"success": False, "error": f"Failed to get screen size: {str(e)}"}


@mcp.tool()
def mouse_move(x: int, y: int) -> Dict[str, Any]:
    """Move mouse to the specified screen coordinates."""
    if x is None or y is None:
        return {"success": False, "error": "x and y coordinates are required"}
    
    try:
        # Scale coordinates for retina displays
        scaled_x, scaled_y = _scale_coordinates_for_display(x, y)
        pyautogui.moveTo(x=scaled_x, y=scaled_y)
        return {"success": True, "message": f"Moved mouse pointer to ({x}, {y})"}
    except Exception as e:
        return {"success": False, "error": f"Failed to move mouse: {str(e)}"}


@mcp.tool()
def mouse_single_click(x: int, y: int) -> Dict[str, Any]:
    """Single click at the specified screen coordinates."""
    if x is None or y is None:
        return {"success": False, "error": "x and y coordinates are required"}
    
    try:
        # Scale coordinates for retina displays
        scaled_x, scaled_y = _scale_coordinates_for_display(x, y)
        pyautogui.click(x=scaled_x, y=scaled_y, clicks=1)
        return {"success": True, "message": f"Single clicked at ({x}, {y})"}
    except Exception as e:
        return {"success": False, "error": f"Failed to click: {str(e)}"}


@mcp.tool()
def mouse_double_click(x: int, y: int) -> Dict[str, Any]:
    """Double click at the specified screen coordinates."""
    if x is None or y is None:
        return {"success": False, "error": "x and y coordinates are required"}
    
    try:
        # Scale coordinates for retina displays
        scaled_x, scaled_y = _scale_coordinates_for_display(x, y)
        pyautogui.click(x=scaled_x, y=scaled_y, clicks=2)
        return {"success": True, "message": f"Double clicked at ({x}, {y})"}
    except Exception as e:
        return {"success": False, "error": f"Failed to double click: {str(e)}"}


@mcp.tool()
def type_text(text: str) -> Dict[str, Any]:
    """Type the specified text."""
    if not text:
        return {"success": False, "error": "text is required"}
    
    try:
        pyautogui.write(text)
        return {"success": True, "message": f"Typed: {text}"}
    except Exception as e:
        return {"success": False, "error": f"Failed to type text: {str(e)}"}


@mcp.tool()
def scroll(dx: int = 0, dy: int = 0) -> Dict[str, Any]:
    """Scroll with the specified pixel delta values.
    Args:
        dx: Horizontal scroll pixel delta (positive = right, negative = left)
        dy: Vertical scroll pixel delta (positive = down, negative = up)
    """
    try:
        if dy != 0:
            CGEventPost(kCGHIDEventTap, CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 1, -dy))
        if dx != 0:
            pyautogui.hscroll(clicks=dx)
        return {"success": True, "message": f"Scrolled dx={dx}, dy={dy}"}
    except Exception as e:
        return {"success": False, "error": f"Failed to scroll: {str(e)}"}


@mcp.tool()
def play_sound_for_user_prompt() -> Dict[str, Any]:
    """Play the system bell sound to alert the user."""
    try:
        result = subprocess.run(
            ["osascript", "-e", "beep"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode != 0:
            return {
                "success": False, 
                "error": f"Failed to play system bell: {result.stderr.strip()}"
            }
        
        return {"success": True, "message": "System bell played"}
    except Exception as e:
        return {"success": False, "error": f"Execution failed: {str(e)}"}


def _execute_applescript_keystroke(keystroke_command: str, description: str) -> Dict[str, Any]:
    """Helper function to execute AppleScript keystrokes."""
    script = f'''
    tell application "System Events"
        {keystroke_command}
    end tell
    '''
    
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            return {"success": False, "error": f"AppleScript error: {result.stderr.strip()}"}
        
        return {"success": True, "message": f"Executed: {description}"}
    except Exception as e:
        return {"success": False, "error": f"Execution failed: {str(e)}"}


@mcp.tool()
def keyboard_shortcut_return_key() -> Dict[str, Any]:
    """Press the Return/Enter key."""
    return _execute_applescript_keystroke('keystroke return', "Return key")


@mcp.tool()
def keyboard_shortcut_escape_key() -> Dict[str, Any]:
    """Press the Escape key."""
    return _execute_applescript_keystroke('key code 53', "Escape key")


@mcp.tool()
def keyboard_shortcut_tab_key() -> Dict[str, Any]:
    """Press the Tab key."""
    return _execute_applescript_keystroke('keystroke tab', "Tab key")


@mcp.tool()
def keyboard_shortcut_space_key() -> Dict[str, Any]:
    """Press the Space key."""
    return _execute_applescript_keystroke('keystroke " "', "Space key")


@mcp.tool()
def keyboard_shortcut_delete_key() -> Dict[str, Any]:
    """Press the Delete key (backspace)."""
    return _execute_applescript_keystroke('key code 51', "Delete key")


@mcp.tool()
def keyboard_shortcut_forward_delete_key() -> Dict[str, Any]:
    """Press the Forward Delete key."""
    return _execute_applescript_keystroke('key code 117', "Forward Delete key")


@mcp.tool()
def keyboard_shortcut_arrow_up() -> Dict[str, Any]:
    """Press the Up Arrow key."""
    return _execute_applescript_keystroke('key code 126', "Up Arrow key")


@mcp.tool()
def keyboard_shortcut_arrow_down() -> Dict[str, Any]:
    """Press the Down Arrow key."""
    return _execute_applescript_keystroke('key code 125', "Down Arrow key")


@mcp.tool()
def keyboard_shortcut_arrow_left() -> Dict[str, Any]:
    """Press the Left Arrow key."""
    return _execute_applescript_keystroke('key code 123', "Left Arrow key")


@mcp.tool()
def keyboard_shortcut_arrow_right() -> Dict[str, Any]:
    """Press the Right Arrow key."""
    return _execute_applescript_keystroke('key code 124', "Right Arrow key")


@mcp.tool()
def keyboard_shortcut_select_all() -> Dict[str, Any]:
    """Select all text (Cmd+A)."""
    return _execute_applescript_keystroke('keystroke "a" using {command down}', "Select All (Cmd+A)")


@mcp.tool()
def keyboard_shortcut_copy() -> Dict[str, Any]:
    """Copy selected content (Cmd+C)."""
    return _execute_applescript_keystroke('keystroke "c" using {command down}', "Copy (Cmd+C)")


@mcp.tool()
def keyboard_shortcut_paste() -> Dict[str, Any]:
    """Paste from clipboard (Cmd+V)."""
    return _execute_applescript_keystroke('keystroke "v" using {command down}', "Paste (Cmd+V)")


@mcp.tool()
def keyboard_shortcut_cut() -> Dict[str, Any]:
    """Cut selected content (Cmd+X)."""
    return _execute_applescript_keystroke('keystroke "x" using {command down}', "Cut (Cmd+X)")


@mcp.tool()
def keyboard_shortcut_undo() -> Dict[str, Any]:
    """Undo last action (Cmd+Z)."""
    return _execute_applescript_keystroke('keystroke "z" using {command down}', "Undo (Cmd+Z)")


@mcp.tool()
def keyboard_shortcut_redo() -> Dict[str, Any]:
    """Redo last undone action (Cmd+Shift+Z)."""
    return _execute_applescript_keystroke('keystroke "z" using {command down, shift down}', "Redo (Cmd+Shift+Z)")


@mcp.tool()
def keyboard_shortcut_save() -> Dict[str, Any]:
    """Save current document (Cmd+S)."""
    return _execute_applescript_keystroke('keystroke "s" using {command down}', "Save (Cmd+S)")


@mcp.tool()
def keyboard_shortcut_new() -> Dict[str, Any]:
    """Create new document (Cmd+N)."""
    return _execute_applescript_keystroke('keystroke "n" using {command down}', "New (Cmd+N)")


@mcp.tool()
def keyboard_shortcut_open() -> Dict[str, Any]:
    """Open document (Cmd+O)."""
    return _execute_applescript_keystroke('keystroke "o" using {command down}', "Open (Cmd+O)")


@mcp.tool()
def keyboard_shortcut_find() -> Dict[str, Any]:
    """Find in document (Cmd+F)."""
    return _execute_applescript_keystroke('keystroke "f" using {command down}', "Find (Cmd+F)")


@mcp.tool()
def keyboard_shortcut_close_window() -> Dict[str, Any]:
    """Close current window (Cmd+W)."""
    return _execute_applescript_keystroke('keystroke "w" using {command down}', "Close Window (Cmd+W)")


@mcp.tool()
def keyboard_shortcut_quit_app() -> Dict[str, Any]:
    """Quit current application (Cmd+Q)."""
    return _execute_applescript_keystroke('keystroke "q" using {command down}', "Quit App (Cmd+Q)")


@mcp.tool()
def keyboard_shortcut_minimize_window() -> Dict[str, Any]:
    """Minimize current window (Cmd+M)."""
    return _execute_applescript_keystroke('keystroke "m" using {command down}', "Minimize Window (Cmd+M)")


@mcp.tool()
def keyboard_shortcut_hide_app() -> Dict[str, Any]:
    """Hide current application (Cmd+H)."""
    return _execute_applescript_keystroke('keystroke "h" using {command down}', "Hide App (Cmd+H)")


@mcp.tool()
def keyboard_shortcut_switch_app_forward() -> Dict[str, Any]:
    """Switch to next application (Cmd+Tab)."""
    return _execute_applescript_keystroke('keystroke tab using {command down}', "Switch App Forward (Cmd+Tab)")


@mcp.tool()
def keyboard_shortcut_switch_app_backward() -> Dict[str, Any]:
    """Switch to previous application (Cmd+Shift+Tab)."""
    return _execute_applescript_keystroke('keystroke tab using {command down, shift down}', "Switch App Backward (Cmd+Shift+Tab)")


@mcp.tool()
def keyboard_shortcut_spotlight_search() -> Dict[str, Any]:
    """Open Spotlight search (Cmd+Space)."""
    return _execute_applescript_keystroke('keystroke " " using {command down}', "Spotlight Search (Cmd+Space)")


@mcp.tool()
def keyboard_shortcut_force_quit() -> Dict[str, Any]:
    """Open Force Quit dialog (Cmd+Option+Esc)."""
    return _execute_applescript_keystroke('key code 53 using {command down, option down}', "Force Quit (Cmd+Option+Esc)")


@mcp.tool()
def keyboard_shortcut_refresh() -> Dict[str, Any]:
    """Refresh/Reload (Cmd+R)."""
    return _execute_applescript_keystroke('keystroke "r" using {command down}', "Refresh (Cmd+R)")


@mcp.tool()
def focus_app(app_name: str, timeout: int = 30) -> Dict[str, Any]:
    """Bring the specified application to the foreground and wait for it to become active.
    
    Args:
        app_name: Name of the application to focus
        timeout: Maximum time to wait for app to become active (default: 30 seconds)
    """
    if not app_name:
        return {"success": False, "error": "app_name is required"}
    
    if timeout <= 0:
        return {"success": False, "error": "timeout must be positive"}
    
    try:
        # First, try to activate the app
        script = f'tell application "{app_name}" to activate'
        
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            return {
                "success": False, 
                "error": f"Failed to activate app '{app_name}': {result.stderr.strip()}"
            }
    except Exception as e:
        return {"success": False, "error": f"Execution failed: {str(e)}"}
    
    # Wait for the app to become the active application
    start_time = time.time()
    last_active_app = None
    
    while time.time() - start_time < timeout:
        try:
            if ACCESSIBILITY_AVAILABLE:
                # Use Cocoa NSWorkspace to check active app
                workspace = NSWorkspace.sharedWorkspace()
                active_app = workspace.activeApplication()
                if active_app:
                    active_app_name = active_app.get("NSApplicationName", "")
                    if active_app_name.lower() == app_name.lower():
                        elapsed_time = round(time.time() - start_time, 2)
                        return {
                            "success": True, 
                            "message": f"Successfully focused '{app_name}' (took {elapsed_time}s)",
                            "elapsed_time": elapsed_time,
                            "active_app": {
                                "name": active_app_name,
                                "bundle_id": active_app.get("NSApplicationBundleIdentifier", "Unknown"),
                                "pid": active_app.get("NSApplicationProcessIdentifier", -1)
                            }
                        }
                    last_active_app = active_app_name
            else:
                # Fallback: use AppleScript to check frontmost app
                check_script = 'tell application "System Events" to get name of first application process whose frontmost is true'
                check_result = subprocess.run(
                    ["osascript", "-e", check_script],
                    capture_output=True,
                    text=True
                )
                
                if check_result.returncode == 0:
                    frontmost_app = check_result.stdout.strip()
                    if frontmost_app.lower() == app_name.lower():
                        elapsed_time = round(time.time() - start_time, 2)
                        return {
                            "success": True, 
                            "message": f"Successfully focused '{app_name}' (took {elapsed_time}s)",
                            "elapsed_time": elapsed_time,
                            "active_app": {"name": frontmost_app}
                        }
                    last_active_app = frontmost_app
        
        except Exception as e:
            # Continue waiting even if we can't check the active app
            pass
        
        # Wait a bit before checking again
        time.sleep(0.5)
    
    # Timeout reached
    return {
        "success": False,
        "message": f"Timeout waiting for '{app_name}' to become active after {timeout}s",
        "timeout": timeout,
        "last_active_app": last_active_app,
        "elapsed_time": timeout
    }


@mcp.tool()
def get_screen_layout() -> str:
    """Get information about windows and applications currently visible on the screen."""
    return _get_screen_content_accessibility()


@mcp.tool()
def get_screen_text() -> str:
    """Get all text currently visible on the screen using OCR."""
    return _get_screen_content_ocr()


def _get_screen_content_accessibility() -> str:
    """Get screen content using macOS accessibility APIs."""
    if not ACCESSIBILITY_AVAILABLE:
        return json.dumps({
            "success": False,
            "error": "macOS accessibility frameworks not available",
            "message": "Install pyobjc-framework-Cocoa and pyobjc-framework-Quartz"
        }, indent=2)
    
    try:
        screen_info = {
            "mode": "accessibility",
            "timestamp": str(subprocess.run(["date"], capture_output=True, text=True).stdout.strip()),
            "windows": [],
            "active_app": None
        }
        
        # Get active application
        try:
            workspace = NSWorkspace.sharedWorkspace()
            active_app = workspace.activeApplication()
            if active_app:
                screen_info["active_app"] = {
                    "name": active_app.get("NSApplicationName", "Unknown"),
                    "bundle_id": active_app.get("NSApplicationBundleIdentifier", "Unknown"),
                    "pid": active_app.get("NSApplicationProcessIdentifier", -1)
                }
        except Exception as e:
            screen_info["active_app_error"] = str(e)
        
        # Get window information using Quartz
        try:
            window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
            
            for window in window_list:
                # Skip windows without titles or that are too small
                window_name = window.get('kCGWindowName', '')
                window_bounds = window.get('kCGWindowBounds', {})
                
                if (window_name and 
                    window_bounds.get('Width', 0) > 50 and 
                    window_bounds.get('Height', 0) > 50):
                    
                    window_info = {
                        "title": window_name,
                        "app": window.get('kCGWindowOwnerName', 'Unknown'),
                        "bounds": {
                            "x": int(window_bounds.get('X', 0)),
                            "y": int(window_bounds.get('Y', 0)),
                            "width": int(window_bounds.get('Width', 0)),
                            "height": int(window_bounds.get('Height', 0))
                        },
                        "layer": window.get('kCGWindowLayer', 0),
                        "pid": window.get('kCGWindowOwnerPID', -1)
                    }
                    screen_info["windows"].append(window_info)
        
        except Exception as e:
            screen_info["windows_error"] = str(e)
        
        # Sort windows by layer (front to back)
        screen_info["windows"].sort(key=lambda w: w.get("layer", 0))
        
        # Get screen size
        try:
            screenshot = pyautogui.screenshot()
            screen_info["screen_size"] = {
                "width": screenshot.width,
                "height": screenshot.height
            }
        except Exception as e:
            screen_info["screen_size_error"] = str(e)
        
        return json.dumps({
            "success": True,
            "screen_info": screen_info,
            "message": f"Found {len(screen_info['windows'])} visible windows"
        }, indent=2)
        
    except Exception as e:
        return json.dumps({
            "success": False,
            "error": str(e),
            "message": "Failed to get screen content using accessibility"
        }, indent=2)


def _get_screen_content_ocr() -> str:
    """Get screen content using OCR to read all text on screen."""
    try:
        # Take screenshot
        screenshot = pyautogui.screenshot()
        
        # Convert PIL Image to numpy array for easyocr
        screenshot_array = np.array(screenshot)
        
        # Use OCR to extract all text
        ocr_reader = get_ocr_reader()
        results = ocr_reader.readtext(screenshot_array)
        
        screen_info = {
            "mode": "ocr",
            "timestamp": str(subprocess.run(["date"], capture_output=True, text=True).stdout.strip()),
            "screen_size": {
                "width": screenshot.width,
                "height": screenshot.height
            },
            "text_elements": [],
            "full_text": ""
        }
        
        all_text_lines = []
        
        for (bbox, detected_text, confidence) in results:
            if confidence > 0.3:  # Lower threshold for general screen reading
                x1, y1 = bbox[0]
                x2, y2 = bbox[2]
                center_x = int((x1 + x2) / 2)
                center_y = int((y1 + y2) / 2)
                
                text_element = {
                    "text": detected_text.strip(),
                    "confidence": round(confidence, 3),
                    "position": {
                        "center_x": center_x,
                        "center_y": center_y,
                        "bbox": [[int(point[0]), int(point[1])] for point in bbox]
                    }
                }
                
                screen_info["text_elements"].append(text_element)
                all_text_lines.append(detected_text.strip())
        
        # Sort text elements by vertical position (top to bottom, then left to right)
        screen_info["text_elements"].sort(key=lambda x: (x["position"]["center_y"], x["position"]["center_x"]))
        
        # Create full text representation
        screen_info["full_text"] = "\n".join([elem["text"] for elem in screen_info["text_elements"]])
        
        return json.dumps({
            "success": True,
            "screen_info": screen_info,
            "message": f"Found {len(screen_info['text_elements'])} text elements on screen"
        }, indent=2)
        
    except Exception as e:
        return json.dumps({
            "success": False,
            "error": str(e),
            "message": "Failed to get screen content using OCR"
        }, indent=2)



@mcp.tool()
def get_available_apps() -> str:
    """Get a list of all running applications."""
    script = '''
    tell application "System Events"
        get name of (processes where background only is false)
    end tell
    '''
    
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            return json.dumps({"success": False, "error": f"Failed to get apps: {result.stderr}"}, indent=2)
        
        apps = [app.strip() for app in result.stdout.split(", ")]
        return json.dumps({"success": True, "apps": apps}, indent=2)
    except Exception as e:
        return json.dumps({"success": False, "error": f"Execution failed: {str(e)}"}, indent=2)


@mcp.tool()
def run_terminal_command(command: str) -> str:
    """Execute a terminal command with a 30-second timeout."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return result.stdout if result.stdout else "Command executed successfully with no output."
        else:
            return f"Command failed with return code {result.returncode}:\n{result.stderr}"
    except subprocess.TimeoutExpired as e:
        return f"TimeoutExpired: Command took longer than 30 seconds.\n{str(e)}"
    except Exception as e:
        return f"Exception: {str(e)}"


@mcp.tool()
def read_file(path: str) -> str:
    """Read the contents of a file."""
    try:
        expanded_path = os.path.expanduser(path)
        with open(expanded_path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"Exception: {str(e)}"


@mcp.tool()
def write_file(path: str, content: str) -> str:
    """Write or overwrite the contents of a file."""
    try:
        expanded_path = os.path.expanduser(path)
        # Ensure directory exists
        os.makedirs(os.path.dirname(os.path.abspath(expanded_path)), exist_ok=True)
        with open(expanded_path, "w", encoding="utf-8") as f:
            f.write(content)
        return f"Successfully wrote to {expanded_path}"
    except Exception as e:
        return f"Exception: {str(e)}"


@mcp.tool()
def list_directory(path: str) -> str:
    """List directory contents, distinguishing between files and folders."""
    try:
        expanded_path = os.path.expanduser(path)
        if not os.path.exists(expanded_path):
            return f"Error: Directory '{expanded_path}' does not exist."
        if not os.path.isdir(expanded_path):
            return f"Error: Path '{expanded_path}' is not a directory."
            
        items = os.listdir(expanded_path)
        folders = []
        files = []
        for item in items:
            item_path = os.path.join(expanded_path, item)
            if os.path.isdir(item_path):
                folders.append(item)
            else:
                files.append(item)
                
        folders.sort()
        files.sort()
        
        output = [f"Contents of {expanded_path}:\n"]
        if folders:
            output.append("Folders:")
            for folder in folders:
                output.append(f"  📁 {folder}/")
            output.append("")
        if files:
            output.append("Files:")
            for file in files:
                output.append(f"  📄 {file}")
                
        if not folders and not files:
            output.append("(Empty directory)")
            
        return "\n".join(output)
    except Exception as e:
        return f"Exception: {str(e)}"


@mcp.tool()
def smart_search(directory: str, regex_pattern: str, file_extension_filter: Optional[str] = None) -> str:
    """Recursively search for a regex pattern in files within a directory."""
    try:
        expanded_dir = os.path.expanduser(directory)
        if not os.path.isdir(expanded_dir):
            return f"Error: '{expanded_dir}' is not a valid directory."
            
        # Ignore these common junk/hidden directories completely
        ignore_dirs = {".git", "node_modules", "venv", ".venv", "__pycache__", ".idea", ".vscode"}
        
        try:
            pattern = re.compile(regex_pattern)
        except re.error as e:
            return f"Error: Invalid regex pattern '{regex_pattern}': {str(e)}"
            
        results = []
        char_count = 0
        MAX_CHARS = 10000
        truncated = False
        
        for root, dirs, files in os.walk(expanded_dir):
            # Modifying dirs in-place to prune hidden and ignored directories
            dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ignore_dirs]
            
            for file in files:
                if file.startswith('.'):
                    continue
                    
                if file_extension_filter and not file.endswith(file_extension_filter):
                    continue
                    
                file_path = os.path.join(root, file)
                
                try:
                    with open(file_path, "r", encoding="utf-8") as f:
                        lines = f.readlines()
                        
                    file_matches = []
                    for i, line in enumerate(lines):
                        if pattern.search(line):
                            file_matches.append(f"  Line {i+1}: {line.strip()}")
                            
                    if file_matches:
                        match_str = f"File: {file_path}\n" + "\n".join(file_matches) + "\n\n"
                        
                        if char_count + len(match_str) > MAX_CHARS:
                            results.append(match_str[:MAX_CHARS - char_count] + "\n...[TRUNCATED due to length limit]")
                            truncated = True
                            break
                        else:
                            results.append(match_str)
                            char_count += len(match_str)
                            
                except (PermissionError, UnicodeDecodeError):
                    # Silently skip files we can't read or decode (e.g. binary files)
                    continue
                except Exception:
                    # Silently skip other read errors per the prompt
                    continue
                    
            if truncated:
                break
                
        if not results:
            return f"No matches found for '{regex_pattern}' in {expanded_dir}"
            
        return "".join(results)
    except Exception as e:
        return f"Exception: {str(e)}"


@mcp.tool()
def send_file_to_telegram(file_path: str, caption: str = "") -> str:
    """Send a file to the user via Telegram."""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return "Error: Telegram is not configured. Please restart Mac Orchestrator and provide credentials."
        
    try:
        expanded_path = os.path.expanduser(file_path)
        
        if not os.path.exists(expanded_path):
            return f"Error: File '{expanded_path}' does not exist."
            
        file_size = os.path.getsize(expanded_path)
        if file_size > 50 * 1024 * 1024:
            return f"Error: File is {file_size / (1024 * 1024):.2f}MB, which exceeds Telegram's 50MB bot limit."
            
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument"
        
        with open(expanded_path, "rb") as f:
            files = {"document": f}
            data = {"chat_id": TELEGRAM_CHAT_ID}
            if caption:
                data["caption"] = caption
                
            response = requests.post(url, data=data, files=files, timeout=60)
            
        if response.status_code == 200:
            return f"Successfully sent '{os.path.basename(expanded_path)}' to Telegram."
        else:
            return f"Error from Telegram API (Status {response.status_code}): {response.text}"
            
    except Exception as e:
        return f"Exception: {str(e)}"


console = Console()

def setup_telegram():
    """Sets up Telegram configuration securely."""
    global TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
    
    config_dir = os.path.expanduser("~/.config/mac-orchestrator")
    config_path = os.path.join(config_dir, "config.json")
    
    # Try to load existing config
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
                            try:
                                config_data = json.load(f)
                            except:
                                pass
                    config_data["TELEGRAM_BOT_TOKEN"] = TELEGRAM_BOT_TOKEN
                    config_data["TELEGRAM_CHAT_ID"] = TELEGRAM_CHAT_ID
                    with open(config_path, "w") as f:
                        json.dump(config_data, f, indent=4)
                    console.print("[green]✓ Telegram credentials saved successfully![/green]")
                except Exception as e:
                    console.print(f"[yellow]Could not save config to {config_path}: {e}[/yellow]")
            else:
                console.print("[red]Incomplete Telegram setup. File sending will not work.[/red]")
        else:
            console.print("[yellow]Skipping Telegram setup.[/yellow]")

def setup_ngrok():
    """Sets up ngrok tunnel, prompting for auth token if not configured."""
    try:
        # First check if ngrok is already running globally or from a previous session
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
            console.print("[yellow]Skipping ngrok setup. Server will only be available locally.[/yellow]")
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
                "1. Sign up / Log in at [link=https://dashboard.ngrok.com/get-started/your-authtoken]https://dashboard.ngrok.com[/link]\n"
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
    # Automatically kill any existing process running on port 8000 so we can start fresh
    try:
        subprocess.run("kill -9 $(lsof -t -i:8000)", shell=True, check=False, stderr=subprocess.DEVNULL)
        time.sleep(0.5) # Give it a moment to free the port
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
        # Serve MCP over streamable HTTP at /mcp on localhost:8000
        mcp.run(transport="streamable-http", mount_path="/mcp")
    except KeyboardInterrupt:
        pass
    finally:
        console.print("\n[yellow]Shutting down...[/yellow]")
        if public_url:
            ngrok.kill()

if __name__ == "__main__":
    main()
