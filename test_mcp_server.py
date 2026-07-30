#!/usr/bin/env python3

import subprocess
import sys
import os


def test_mcp_server():
    """Test the FastMCP server by running it and checking output"""
    print("Testing AutoMac MCP FastMCP Server")
    print("=" * 35)
    
    print("\n1. Checking server syntax...")
    try:
        result = subprocess.run(
            [sys.executable, "-B", "-m", "py_compile", "automac_mcp.py"],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            print("✓ automac_mcp.py syntax OK")
        else:
            print(f"✗ Syntax error in automac_mcp.py")
            if result.stderr:
                print(f"Error: {result.stderr}")
            return False
    except Exception as e:
        print(f"✗ Error checking syntax: {e}")
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
            
        # Check for the refactored v2 tool set (20 tools, down from 46)
        v2_tools = [
            'press_keystroke', 'mouse_action', 'type_text', 'scroll',
            'execute_macro', 'focus_app', 'get_available_apps',
            'get_screen_size', 'get_screen_layout', 'get_screen_text',
            'run_terminal_command', 'find_file', 'vector_search',
            'read_file', 'write_file', 'list_directory', 'smart_search',
            'play_sound_for_user_prompt', 'clipboard', 'send_file_to_telegram'
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
            
        # Test vector_search
        result = automac_mcp.vector_search("test")
        if result and result.get("status") == "success":
            print(f"✓ vector_search: {result.get('message')} (Found {len(result.get('results', []))} matches)")
        else:
            print(f"✗ vector_search failed: {result}")

        # Test write_file append mode
        import tempfile, os
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as tf:
            tmp_path = tf.name
        try:
            r1 = automac_mcp.write_file(tmp_path, "line1\n")
            r2 = automac_mcp.write_file(tmp_path, "line2\n", mode="append")
            with open(tmp_path) as f:
                txt = f.read()
            if r1.get("status") == "success" and r2.get("status") == "success" and txt == "line1\nline2\n":
                print("✓ write_file append mode: works correctly")
            else:
                print(f"✗ write_file append mode failed: {txt!r}")
        finally:
            os.unlink(tmp_path)

        # Test clipboard get/set
        r_set = automac_mcp.clipboard(action="set", content="test-clipboard-42")
        r_get = automac_mcp.clipboard(action="get")
        if r_set.get("status") == "success" and r_get.get("content") == "test-clipboard-42":
            print("✓ clipboard get/set: works correctly")
        else:
            print(f"✗ clipboard failed: set={r_set}, get={r_get}")

        # Test clipboard invalid action
        r_bad = automac_mcp.clipboard(action="invalid")
        if r_bad.get("status") == "error" and r_bad.get("error_code") == "INVALID_PARAM":
            print("✓ clipboard invalid action: returns correct error")
        else:
            print(f"✗ clipboard invalid action error not raised: {r_bad}")

        # Test execute_macro rollback reporting
        macro_result = automac_mcp.execute_macro([
            {"action": "run_command", "command": "echo hello"},
            {"action": "run_command", "command": "exit 99"},
            {"action": "run_command", "command": "echo skipped"},
        ])
        if (macro_result.get("status") == "partial_success"
                and macro_result.get("completed_steps") == 1
                and macro_result.get("stopped_at_step") == 2
                and "recovery_hint" in macro_result):
            print("✓ execute_macro rollback reporting: partial_success correct")
        else:
            print(f"✗ execute_macro rollback reporting failed: {macro_result}")

        # Test execute_macro run_command step
        macro_cmd = automac_mcp.execute_macro([
            {"action": "run_command", "command": "echo macro-test"}
        ])
        if (macro_cmd.get("status") == "success"
                and macro_cmd["steps"][0].get("stdout", "").strip() == "macro-test"):
            print("✓ execute_macro run_command step: works correctly")
        else:
            print(f"✗ execute_macro run_command step failed: {macro_cmd}")

        # Test execute_macro first-step failure → status="error"
        macro_first_fail = automac_mcp.execute_macro([
            {"action": "run_command", "command": "exit 1"},
        ])
        if macro_first_fail.get("status") == "error" and macro_first_fail.get("completed_steps") == 0:
            print("✓ execute_macro first-step failure: status=error, completed_steps=0")
        else:
            print(f"✗ execute_macro first-step failure wrong: {macro_first_fail}")

        # Managed connector paths are high-entropy and URL-safe.
        managed_env = os.environ.copy()
        managed_env.update({
            "MAC_ORCHESTRATOR_MANAGED": "1",
            "MAC_ORCHESTRATOR_CONNECTOR_TOKEN": "a" * 64,
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        managed = subprocess.run(
            [sys.executable, "-B", "-c", "import automac_mcp; print(automac_mcp.MCP_PATH)"],
            capture_output=True,
            text=True,
            env=managed_env,
            timeout=15,
        )
        if managed.returncode == 0 and managed.stdout.strip() == f"/{'a' * 64}/mcp":
            print("✓ managed connector capability path configured")
        else:
            print(f"✗ managed connector path failed: {managed.stderr or managed.stdout}")
            return False

        # Background commands are registered and terminated by server cleanup.
        bg = automac_mcp.run_terminal_command("sleep 30", run_in_background=True)
        bg_pid = bg.get("pid")
        automac_mcp.cleanup_background_processes()
        if bg_pid and not automac_mcp._background_processes:
            print("✓ background command ownership cleanup works")
        else:
            print(f"✗ background command cleanup failed: {bg}")
            return False

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
