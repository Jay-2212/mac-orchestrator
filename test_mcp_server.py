#!/usr/bin/env python3

import subprocess
import time
import sys


def test_mcp_server():
    """Test the FastMCP server by running it and checking output"""
    print("Testing AutoMac MCP FastMCP Server")
    print("=" * 35)
    
    print("\n1. Starting MCP server...")
    try:
        # Start the server process
        process = subprocess.Popen(
            [sys.executable, "automac_mcp.py"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Give it a moment to start
        time.sleep(2)
        
        # Check if process is running
        if process.poll() is None:
            print("✓ MCP server started successfully")
            
            # Terminate the process
            process.terminate()
            try:
                process.wait(timeout=5)
                print("✓ MCP server terminated cleanly")
            except subprocess.TimeoutExpired:
                process.kill()
                print("! MCP server had to be forcefully killed")
        else:
            stdout, stderr = process.communicate()
            print(f"✗ MCP server failed to start")
            if stderr:
                print(f"Error: {stderr}")
            if stdout:
                print(f"Output: {stdout}")
            return False
            
    except Exception as e:
        print(f"✗ Error testing server: {e}")
        return False
    
    print("\n2. Testing server structure...")
    
    # Import the module to check for syntax errors
    try:
        import automac_mcp
        print("✓ Module imports successfully")
        
        # Check if the FastMCP instance exists
        if hasattr(automac_mcp, 'mcp'):
            print("✓ FastMCP instance found")
        else:
            print("✗ FastMCP instance not found")
            return False
            
        # Check for the refactored v2 tool set (18 tools, down from 46)
        v2_tools = [
            'press_keystroke', 'mouse_action', 'type_text', 'scroll',
            'execute_macro', 'focus_app', 'get_available_apps',
            'get_screen_size', 'get_screen_layout', 'get_screen_text',
            'run_terminal_command', 'find_file',
            'read_file', 'write_file', 'list_directory', 'smart_search',
            'play_sound_for_user_prompt', 'send_file_to_telegram'
        ]
        
        for func_name in v2_tools:
            if hasattr(automac_mcp, func_name):
                print(f"✓ Tool {func_name} found")
            else:
                print(f"✗ Tool {func_name} not found")
                return False
        
        print(f"\n   Total tools verified: {len(v2_tools)}")
        
        # Verify old tools are REMOVED
        old_tools = [
            'keyboard_shortcut_return_key', 'keyboard_shortcut_escape_key',
            'keyboard_shortcut_copy', 'keyboard_shortcut_paste',
            'mouse_move', 'mouse_single_click', 'mouse_double_click'
        ]
        
        for func_name in old_tools:
            if hasattr(automac_mcp, func_name):
                print(f"⚠ Old tool {func_name} still exists (should be removed)")
            else:
                print(f"✓ Old tool {func_name} correctly removed")
                
    except ImportError as e:
        print(f"✗ Failed to import module: {e}")
        return False
    except Exception as e:
        print(f"✗ Error checking module: {e}")
        return False
    
    print("\n3. Testing individual functions...")
    
    try:
        # Test get_available_apps (returns structured JSON now)
        result = automac_mcp.get_available_apps()
        if result and result.get("status") == "success":
            print(f"✓ get_available_apps: {result.get('message')}")
        else:
            print(f"✗ get_available_apps failed: {result}")
            
        # Test focus_app with a quick timeout
        try:
            result = automac_mcp.focus_app("Finder", 5)
            if result and "status" in result:
                print(f"✓ focus_app: {result.get('message')}")
            else:
                print(f"✗ focus_app failed: {result}")
        except Exception as e:
            print(f"✗ focus_app error: {e}")
        
        # Test press_keystroke (the new consolidated keyboard tool)
        try:
            result = automac_mcp.press_keystroke("escape")
            if result and "status" in result:
                print(f"✓ press_keystroke: {result.get('message')}")
            else:
                print(f"✗ press_keystroke failed: {result}")
        except Exception as e:
            print(f"✗ press_keystroke error: {e}")
            
        # Test get_screen_layout
        result = automac_mcp.get_screen_layout()
        if result and "status" in result:
            print(f"✓ get_screen_layout: {result.get('message')}")
        else:
            print(f"✗ get_screen_layout failed")
            
        # Test run_terminal_command with structured output
        result = automac_mcp.run_terminal_command("echo hello", timeout_seconds=5)
        if result and result.get("status") == "success":
            print(f"✓ run_terminal_command: exit_code={result.get('exit_code')}, stdout='{result.get('stdout', '').strip()}'")
        else:
            print(f"✗ run_terminal_command failed: {result}")
            
        # Test find_file
        result = automac_mcp.find_file("automac_mcp", search_dir="~/Documents/mac-orchestrator")
        if result and result.get("status") == "success":
            print(f"✓ find_file: {result.get('message')}")
        else:
            print(f"✗ find_file failed: {result}")
            
    except Exception as e:
        print(f"✗ Error testing functions: {e}")
        return False
    
    print("\nAll tests completed!")
    return True


def test_dependencies():
    """Test that all required dependencies are available"""
    print("\nTesting dependencies...")
    
    dependencies = [
        'mcp.server.fastmcp',
        'pyautogui',
        'easyocr',
        'numpy',
        'subprocess',
        'json'
    ]
    
    for dep in dependencies:
        try:
            __import__(dep)
            print(f"✓ {dep}")
        except ImportError:
            print(f"✗ {dep} - Missing dependency")
            return False
    
    return True


if __name__ == "__main__":
    print("AutoMac MCP Test Suite (v2)")
    print("==========================")
    
    # Test dependencies first
    if not test_dependencies():
        print("\n❌ Dependency test failed. Install dependencies with: uv sync")
        sys.exit(1)
    
    # Test the server
    if test_mcp_server():
        print("\n✅ All tests passed!")
    else:
        print("\n❌ Some tests failed!")
        sys.exit(1)