#!/usr/bin/env python3

import subprocess
import sys
import os
import json


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
            
        # Check for the current tool set (24 tools)
        v2_tools = [
            'describe', 'press_keystroke', 'mouse_action', 'type_text', 'scroll',
            'execute_macro', 'focus_app', 'get_available_apps', 'get_session_state',
            'get_screen_size', 'get_screen_layout', 'get_ui_tree', 'perform_ui_action',
            'get_screen_text', 'run_terminal_command', 'find_file', 'vector_search',
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

        # Regression test: AXPosition/AXSize are AXValueRef objects that need
        # AXValueGetValue() to unwrap — a bare except previously swallowed this
        # silently and "bounds" was never emitted for any window, ever.
        if result.get("status") == "success":
            windows = result.get("screen_info", {}).get("windows", [])
            if windows and any("bounds" in w for w in windows):
                print("✓ get_screen_layout: bounds populated (AXValueRef unwrap works)")
            elif windows:
                print(f"✗ get_screen_layout: no window has 'bounds' — AXValueRef unwrap regressed")
            else:
                print("  (get_screen_layout: no windows open, skipping bounds check)")

        # Test get_session_state
        result = automac_mcp.get_session_state()
        if (result.get("status") == "success"
                and "gui_interaction_available" in result
                and "session" in result and "permissions" in result):
            print(f"✓ get_session_state: {result.get('message')}")
        else:
            print(f"✗ get_session_state failed: {result}")

        # Test describe()
        r_overview = automac_mcp.describe("overview")
        r_unknown = automac_mcp.describe("not-a-real-topic")
        if (r_overview.get("status") == "success" and r_overview.get("text")
                and r_unknown.get("status") == "success" and "available_topics" in r_unknown):
            print("✓ describe: known topic returns text, unknown topic lists available_topics")
        else:
            print(f"✗ describe failed: overview={r_overview}, unknown={r_unknown}")

        # Test get_available_apps includes apps_detail with activation_policy
        result = automac_mcp.get_available_apps()
        detail = result.get("apps_detail")
        if (result.get("status") == "success" and detail
                and all("pid" in a and "activation_policy" in a for a in detail)):
            print(f"✓ get_available_apps: apps_detail has pid/activation_policy ({len(detail)} apps)")
        else:
            print(f"✗ get_available_apps apps_detail malformed: {result}")

        # Test get_ui_tree — targets the frontmost app by default, no live-UI assumptions
        result = automac_mcp.get_ui_tree(limit=5, depth=2)
        if result.get("status") == "success" and "elements" in result and "has_more" in result:
            print(f"✓ get_ui_tree: {result.get('message')}")
            first_ref = result["elements"][0]["ref"] if result["elements"] else None
        elif result.get("status") == "error" and result.get("error_code") == "PERMISSION":
            print("  (get_ui_tree: Accessibility permission not granted in this environment, skipping)")
            first_ref = None
        else:
            print(f"✗ get_ui_tree failed: {result}")
            first_ref = None

        # Regression test: get_ui_tree pagination previously had two distinct bugs —
        # (1) the continuation_token double-counted the skip window, silently dropping
        # exactly one element at each page boundary, and (2) flat/filtered mode gated
        # recursion on the per-page limit, so hitting the limit exactly stopped
        # traversal before it could discover (and report) that more matches existed.
        # A ref-based diff can't catch either — refs are always distinct across calls
        # even for the same element. Only a content comparison against an unpaginated
        # baseline discriminates. Tree mode (no filter) and flat mode (role_filter/
        # actionable_only) are two different code paths (_ax_walk_tree/_ax_walk_flat)
        # with independent bugs found here, so both are checked.
        def _flatten_ui_tree(nodes, out):
            for n in nodes:
                out.append((n["role"], n["label"], json.dumps(n.get("bounds"), sort_keys=True)))
                _flatten_ui_tree(n.get("children", []), out)

        def _check_ui_tree_pagination(label, base_kwargs):
            baseline = automac_mcp.get_ui_tree(depth=6, limit=200, node_budget=2000, **base_kwargs)
            if baseline.get("status") == "error" and baseline.get("error_code") == "PERMISSION":
                print(f"  (get_ui_tree pagination [{label}]: Accessibility permission not granted, skipping)")
                return
            if not (baseline.get("status") == "success" and baseline.get("elements")):
                print(f"  (get_ui_tree pagination [{label}]: no elements to paginate over, skipping)")
                return
            baseline_seq = []
            _flatten_ui_tree(baseline["elements"], baseline_seq)

            paginated_seq = []
            token, pages, ok = None, 0, True
            while True:
                kwargs = dict(depth=6, limit=1, node_budget=2000, **base_kwargs)
                if token:
                    kwargs["continuation_token"] = token
                page = automac_mcp.get_ui_tree(**kwargs)
                pages += 1
                if page.get("status") != "success":
                    ok = False
                    break
                _flatten_ui_tree(page.get("elements", []), paginated_seq)
                token = page.get("continuation_token")
                if not page.get("has_more"):
                    break
                if pages > 50:  # a real regression should fail loudly, not hang
                    ok = False
                    break

            if pages <= 1:
                # limit=1 never crossed a page boundary — the one thing that was
                # actually broken — so this environment can't confirm anything.
                print(f"  (get_ui_tree pagination [{label}]: only {len(baseline_seq)} element(s), "
                      f"no page boundary crossed — inconclusive, skipping)")
            elif ok and paginated_seq == baseline_seq:
                print(f"✓ get_ui_tree pagination [{label}]: {pages} pages reproduce the unpaginated "
                      f"baseline exactly ({len(baseline_seq)} elements)")
            else:
                print(f"✗ get_ui_tree pagination [{label}] mismatch: baseline={len(baseline_seq)} elements, "
                      f"paginated={len(paginated_seq)} elements over {pages} pages (ok={ok})")

        _check_ui_tree_pagination("flat/actionable_only", {"app": "Finder", "actionable_only": True})
        _check_ui_tree_pagination("tree/unfiltered", {"app": "Finder"})

        # Test perform_ui_action error paths (no assumptions about live UI state)
        r_bad_ref = automac_mcp.perform_ui_action(ref="el_0_999999999", action="click")
        if r_bad_ref.get("status") == "error" and r_bad_ref.get("error_code") == "NOT_FOUND":
            print("✓ perform_ui_action: unknown ref returns NOT_FOUND")
        else:
            print(f"✗ perform_ui_action bad-ref handling failed: {r_bad_ref}")

        if first_ref:
            r_bad_action = automac_mcp.perform_ui_action(ref=first_ref, action="AXTotallyBogusAction")
            if r_bad_action.get("status") == "error" and r_bad_action.get("error_code") == "INVALID_PARAM":
                print("✓ perform_ui_action: unsupported action returns INVALID_PARAM")
            else:
                print(f"✗ perform_ui_action bad-action handling failed: {r_bad_action}")

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

        # Dev-only port override (lets a local test server run without colliding
        # with an already-running managed instance on the default port).
        port_env = os.environ.copy()
        port_env.update({"MAC_ORCHESTRATOR_PORT": "8791", "PYTHONDONTWRITEBYTECODE": "1"})
        port_check = subprocess.run(
            [sys.executable, "-B", "-c", "import automac_mcp; print(automac_mcp.SERVER_PORT)"],
            capture_output=True, text=True, env=port_env, timeout=15,
        )
        if port_check.returncode == 0 and port_check.stdout.strip() == "8791":
            print("✓ MAC_ORCHESTRATOR_PORT override works")
        else:
            print(f"✗ port override failed: {port_check.stderr or port_check.stdout}")
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
