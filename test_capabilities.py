#!/usr/bin/env python3

"""Deterministic Wave 1 capability registration and policy tests.

These tests deliberately use the real FastMCP object returned by
``automac_mcp.build_mcp``.  macOS UI, OCR, Telegram, and Meridian I/O are
patched or never reached; the suite is intended for the required portable
Python gate.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import automac_mcp


CAPABILITY_IDS = tuple(automac_mcp.CAPABILITY_IDS)

INSTRUCTION_PREAMBLE = (
    "Mac Orchestrator gives you direct control of this macOS desktop.",
    "",
    "START HERE:",
    "- get_capabilities() — inspect the current capability snapshot and policy.",
    "- get_session_state() — inspect session and permissions before UI work.",
    "- describe(topic=...) — request the detailed guide for an enabled tool group.",
)
UI_INSTRUCTION_START = (
    "",
    "UI INSPECTION:",
    "- Prefer get_ui_tree() and its stable refs over coordinate guessing.",
    "- Use get_screen_layout() for a cheap window survey, then perform_ui_action(ref=...) when a ref exists.",
)
OCR_INSTRUCTION = (
    "- Use get_screen_text() as the OCR fallback for custom-drawn content.",
)
MACRO_INSTRUCTION = (
    "- Batch tightly related safe UI actions with execute_macro() when appropriate.",
)
LOCAL_SEARCH_INSTRUCTIONS = (
    "",
    "LOCAL SEARCH:",
    "- Use find_file() for Spotlight keyword/exact-content search.",
    "- Use Local Pattern Search (smart_search()) for regex or exact content within an approved directory.",
    "- Use list_directory() for browsing by date or size.",
)
MERIDIAN_INSTRUCTION = (
    "",
    "- Use vector_search() for semantic search only when it is registered.",
)
SHELL_INSTRUCTION = (
    "",
    "- Use run_terminal_command() only for an explicit task; use capability diagnostics rather than shell repair.",
)
WRITE_INSTRUCTION = (
    "- File writes are available only within the current policy boundary.",
)
UI_DISABLED_INSTRUCTION = (
    "",
    "UI operation is not enabled in this snapshot. Ask the user to open Mac Orchestrator if it is needed.",
)
INSTRUCTION_FOOTER = (
    "",
    "Disabled integrations are configured by the user through Mac Orchestrator; do not edit secrets or start services yourself.",
)


def exact_instructions(*sections):
    return "\n".join(line for section in sections for line in section)


def snapshot_document(
    enabled=(),
    *,
    profile="guided",
    approved_roots=(),
    clipboard_mutation=False,
    reasons=None,
):
    enabled = set(enabled) | {"core.session"}
    reasons = reasons or {}
    capabilities = {}
    for capability_id in CAPABILITY_IDS:
        if capability_id in enabled:
            capabilities[capability_id] = {
                "desired": True,
                "configured": True,
                "ready": True,
                "health": "ready",
                "dependencies": [],
                "reason": reasons.get(capability_id),
            }
        else:
            capabilities[capability_id] = {
                "desired": False,
                "configured": False,
                "ready": False,
                "health": "disabled",
                "dependencies": [],
                "reason": reasons.get(capability_id, "disabled in the user configuration"),
            }
    return {
        "snapshotSchemaVersion": 1,
        "configGeneration": 7,
        "controlProfile": profile,
        "capabilities": capabilities,
        "policy": {
            "approvedFileRoots": list(approved_roots),
            "clipboardMutation": clipboard_mutation,
        },
    }


def make_snapshot(*args, **kwargs):
    return automac_mcp.CapabilitySnapshot.from_dict(snapshot_document(*args, **kwargs))


def tool_names(server):
    return [tool.name for tool in asyncio.run(server.list_tools())]


def tool_map(server):
    return {tool.name: tool for tool in asyncio.run(server.list_tools())}


class CapabilityInventoryTests(unittest.TestCase):
    def assert_surface(
        self,
        snapshot,
        expected_tools,
        expected_instructions,
        secrets=None,
    ):
        server = automac_mcp.build_mcp(snapshot, secrets)
        names = tool_names(server)
        self.assertEqual(names, list(expected_tools))
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(server._mcp_server.instructions, expected_instructions)
        self.assertEqual(
            automac_mcp.describe_for_snapshot(snapshot, "overview"),
            expected_instructions,
        )
        return server

    def test_guided_inventory_hides_unready_groups_and_guidance(self):
        snapshot = make_snapshot(
            ["mac.ui", "mac.files.read"],
            reasons={
                "mac.screenOcr": "Screen OCR is disabled by the user",
                "mac.shell": "Shell is not approved",
            },
        )
        expected = (
            "describe",
            "get_capabilities",
            "get_session_state",
            "play_sound_for_user_prompt",
            "clipboard",
            "get_available_apps",
            "get_screen_size",
            "get_screen_layout",
            "get_ui_tree",
            "focus_app",
            "press_keystroke",
            "type_text",
            "mouse_action",
            "scroll",
            "perform_ui_action",
            "execute_macro",
            "find_file",
            "read_file",
            "list_directory",
            "smart_search",
        )
        expected_instructions = exact_instructions(
            INSTRUCTION_PREAMBLE,
            UI_INSTRUCTION_START,
            MACRO_INSTRUCTION,
            LOCAL_SEARCH_INSTRUCTIONS,
            INSTRUCTION_FOOTER,
        )
        server = self.assert_surface(snapshot, expected, expected_instructions)
        names = tool_names(server)
        self.assertNotIn("run_terminal_command", names)
        self.assertNotIn("write_file", names)
        self.assertNotIn("send_file_to_telegram", names)
        self.assertNotIn("vector_search", names)
        self.assertNotIn("get_screen_text", names)

        instructions = server._mcp_server.instructions
        self.assertNotIn("run_terminal_command", instructions)
        self.assertNotIn("write_file", instructions)
        self.assertNotIn("send_file_to_telegram", instructions)
        self.assertNotIn("vector_search", instructions)
        self.assertNotIn("get_screen_text", instructions)
        self.assertNotIn('"run_command"', instructions)
        self.assertNotIn('"write_file"', instructions)
        self.assertNotIn('"set_clipboard"', instructions)
        self.assertNotIn("vector_search", automac_mcp.describe_for_snapshot(snapshot, "overview"))

        descriptions = "\n".join(
            (tool.description or "") for tool in asyncio.run(server.list_tools())
        )
        describe_description = tool_map(server)["describe"].description or ""
        self.assertIn("Available topics in this snapshot", describe_description)
        self.assertNotIn("get_screen_text", describe_description)
        self.assertNotIn("vector_search()", descriptions)
        self.assertNotIn("get_screen_text()", descriptions)
        self.assertNotIn('"run_command"', descriptions)
        self.assertIn("approved file root", tool_map(server)["read_file"].description or "")

    def test_full_local_inventory_enables_local_groups_but_not_optional_integrations(self):
        snapshot = make_snapshot(
            [
                "mac.ui",
                "mac.screenOcr",
                "mac.files.read",
                "mac.files.write",
                "mac.shell",
                "mac.clipboard.write",
            ],
            profile="full",
            clipboard_mutation=True,
        )
        expected = (
            "describe",
            "get_capabilities",
            "get_session_state",
            "play_sound_for_user_prompt",
            "clipboard",
            "get_available_apps",
            "get_screen_size",
            "get_screen_layout",
            "get_ui_tree",
            "focus_app",
            "press_keystroke",
            "type_text",
            "mouse_action",
            "scroll",
            "perform_ui_action",
            "execute_macro",
            "get_screen_text",
            "run_terminal_command",
            "find_file",
            "read_file",
            "list_directory",
            "smart_search",
            "write_file",
        )
        expected_instructions = exact_instructions(
            INSTRUCTION_PREAMBLE,
            UI_INSTRUCTION_START,
            OCR_INSTRUCTION,
            MACRO_INSTRUCTION,
            LOCAL_SEARCH_INSTRUCTIONS,
            SHELL_INSTRUCTION,
            WRITE_INSTRUCTION,
            INSTRUCTION_FOOTER,
        )
        server = self.assert_surface(snapshot, expected, expected_instructions)
        names = tool_names(server)
        self.assertIn("run_terminal_command", names)
        self.assertIn("write_file", names)
        self.assertIn("get_screen_text", names)
        self.assertIn("execute_macro", names)
        self.assertNotIn("send_file_to_telegram", names)
        self.assertNotIn("vector_search", names)

        descriptions = tool_map(server)
        macro_description = descriptions["execute_macro"].description or ""
        self.assertIn('"run_command"', macro_description)
        self.assertIn('"write_file"', macro_description)
        self.assertIn('"set_clipboard"', macro_description)

    def test_telegram_is_registered_only_when_synthetic_snapshot_is_ready(self):
        disabled = make_snapshot(["mac.files.read"])
        secrets = automac_mcp.RuntimeSecrets(
            telegram_bot_token="synthetic-token",
            telegram_chat_id="synthetic-chat",
        )
        base_tools = (
            "describe",
            "get_capabilities",
            "get_session_state",
            "play_sound_for_user_prompt",
            "clipboard",
            "find_file",
            "read_file",
            "list_directory",
            "smart_search",
        )
        expected_instructions = exact_instructions(
            INSTRUCTION_PREAMBLE,
            LOCAL_SEARCH_INSTRUCTIONS,
            UI_DISABLED_INSTRUCTION,
            INSTRUCTION_FOOTER,
        )
        disabled_server = self.assert_surface(
            disabled,
            base_tools,
            expected_instructions,
            secrets,
        )
        self.assertNotIn("send_file_to_telegram", tool_names(disabled_server))

        ready = make_snapshot(["mac.files.read", "telegram.send"])
        ready_server = self.assert_surface(
            ready,
            base_tools + ("send_file_to_telegram",),
            expected_instructions,
            secrets,
        )
        self.assertIn(
            "send_file_to_telegram",
            tool_names(ready_server),
        )

    def test_meridian_registration_is_independent_of_local_search(self):
        disabled = make_snapshot(["mac.files.read"])
        secrets = automac_mcp.RuntimeSecrets(
            worker_url="https://synthetic.example/search",
            meridian_ingest_token="synthetic-token",
        )
        base_tools = (
            "describe",
            "get_capabilities",
            "get_session_state",
            "play_sound_for_user_prompt",
            "clipboard",
            "find_file",
            "read_file",
            "list_directory",
            "smart_search",
        )
        disabled_instructions = exact_instructions(
            INSTRUCTION_PREAMBLE,
            LOCAL_SEARCH_INSTRUCTIONS,
            UI_DISABLED_INSTRUCTION,
            INSTRUCTION_FOOTER,
        )
        disabled_server = self.assert_surface(
            disabled,
            base_tools,
            disabled_instructions,
            secrets,
        )
        self.assertNotIn("vector_search", tool_names(disabled_server))
        self.assertIn("smart_search", tool_names(disabled_server))

        ready = make_snapshot(["mac.files.read", "meridian.search"])
        ready_instructions = exact_instructions(
            INSTRUCTION_PREAMBLE,
            LOCAL_SEARCH_INSTRUCTIONS,
            MERIDIAN_INSTRUCTION,
            UI_DISABLED_INSTRUCTION,
            INSTRUCTION_FOOTER,
        )
        ready_server = self.assert_surface(
            ready,
            base_tools + ("vector_search",),
            ready_instructions,
            secrets,
        )
        names = tool_names(ready_server)
        self.assertIn("vector_search", names)
        self.assertIn("smart_search", names)

    def test_every_tool_capability_ready_has_exact_unique_inventory(self):
        snapshot = make_snapshot(
            [
                "mac.ui",
                "mac.screenOcr",
                "mac.files.read",
                "mac.files.write",
                "mac.shell",
                "mac.clipboard.write",
                "telegram.send",
                "meridian.search",
                "meridian.telegram",
                "remote.connector",
            ],
            profile="full",
            clipboard_mutation=True,
        )
        expected = (
            "describe",
            "get_capabilities",
            "get_session_state",
            "play_sound_for_user_prompt",
            "clipboard",
            "get_available_apps",
            "get_screen_size",
            "get_screen_layout",
            "get_ui_tree",
            "focus_app",
            "press_keystroke",
            "type_text",
            "mouse_action",
            "scroll",
            "perform_ui_action",
            "execute_macro",
            "get_screen_text",
            "run_terminal_command",
            "find_file",
            "read_file",
            "list_directory",
            "smart_search",
            "write_file",
            "send_file_to_telegram",
            "vector_search",
        )
        expected_instructions = exact_instructions(
            INSTRUCTION_PREAMBLE,
            UI_INSTRUCTION_START,
            OCR_INSTRUCTION,
            MACRO_INSTRUCTION,
            LOCAL_SEARCH_INSTRUCTIONS,
            MERIDIAN_INSTRUCTION,
            SHELL_INSTRUCTION,
            WRITE_INSTRUCTION,
            INSTRUCTION_FOOTER,
        )
        server = self.assert_surface(
            snapshot,
            expected,
            expected_instructions,
            automac_mcp.RuntimeSecrets(
                telegram_bot_token="synthetic-token",
                telegram_chat_id="synthetic-chat",
                worker_url="https://synthetic.example",
                meridian_ingest_token="synthetic-token",
            ),
        )
        self.assertEqual(len(tool_names(server)), 25)


class SnapshotValidationTests(unittest.TestCase):
    def test_shared_swift_python_schema_v1_fixture_is_accepted(self):
        fixture_path = (
            Path(__file__).resolve().parent
            / "Tests"
            / "Fixtures"
            / "capability_snapshot_v1.json"
        )

        snapshot = automac_mcp.CapabilitySnapshot.from_json(
            fixture_path.read_text(encoding="utf-8")
        )

        self.assertEqual(snapshot.snapshot_schema_version, 1)
        self.assertEqual(snapshot.control_profile, "guided")
        self.assertEqual(
            snapshot.capabilities["telegram.send"].health,
            "unavailable",
        )
        self.assertEqual(len(snapshot.policy.approved_file_roots), 1)
        self.assertTrue(snapshot.policy.approved_file_roots[0].is_absolute())
        self.assertEqual(snapshot.policy.approved_file_roots[0].name, "approved")

    def test_schema_v1_accepts_unavailable_health(self):
        document = snapshot_document(["mac.ui"])
        document["capabilities"]["telegram.send"].update(
            {
                "desired": True,
                "configured": False,
                "ready": False,
                "health": "unavailable",
                "reason": "Telegram credentials are not configured.",
            }
        )

        snapshot = automac_mcp.CapabilitySnapshot.from_dict(document)

        self.assertEqual(snapshot.capabilities["telegram.send"].health, "unavailable")
        self.assertFalse(snapshot.is_ready("telegram.send"))

    def test_schema_v1_rejects_every_noncanonical_legacy_health_value(self):
        for health in (
            "unconfigured",
            "not_ready",
            "error",
            "unknown",
            "future_health",
            "",
            None,
        ):
            with self.subTest(health=health):
                document = snapshot_document(["mac.ui"])
                document["capabilities"]["mac.ui"]["health"] = health
                with self.assertRaises(automac_mcp.CapabilitySnapshotError):
                    automac_mcp.CapabilitySnapshot.from_dict(document)

    def test_configured_roots_reject_blank_relative_tilde_and_unnormalized_paths(self):
        invalid_roots = (
            "",
            "   ",
            "relative/root",
            "~",
            "~/approved",
            "/tmp/../tmp/approved",
            "/tmp/./approved",
            "/tmp//approved",
            "/tmp/approved/",
        )
        for root in invalid_roots:
            with self.subTest(root=root):
                document = snapshot_document(
                    ["mac.files.read"],
                    approved_roots=[root],
                )
                with self.assertRaises(automac_mcp.CapabilitySnapshotError):
                    automac_mcp.CapabilitySnapshot.from_dict(document)

    def test_configured_roots_deduplicate_canonical_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            real_root = Path(tmp) / "real-root"
            alias_root = Path(tmp) / "alias-root"
            real_root.mkdir()
            alias_root.symlink_to(real_root, target_is_directory=True)
            document = snapshot_document(
                ["mac.files.read"],
                approved_roots=[str(real_root), str(alias_root), str(real_root)],
            )

            snapshot = automac_mcp.CapabilitySnapshot.from_dict(document)

        self.assertEqual(snapshot.policy.approved_file_roots, (real_root.resolve(),))

    def test_managed_snapshot_is_required_and_fail_closed(self):
        env = {"MAC_ORCHESTRATOR_MANAGED": "1"}
        with self.assertRaises(automac_mcp.CapabilitySnapshotError):
            automac_mcp.load_capability_snapshot(env)

    def test_malformed_and_future_snapshots_fail_closed(self):
        env = {"MAC_ORCHESTRATOR_MANAGED": "1", "MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT": "{"}
        with self.assertRaises(automac_mcp.CapabilitySnapshotError):
            automac_mcp.load_capability_snapshot(env)

        future = snapshot_document(["mac.ui"])
        future["snapshotSchemaVersion"] = 2
        env["MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT"] = json.dumps(future)
        with self.assertRaises(automac_mcp.CapabilitySnapshotError):
            automac_mcp.load_capability_snapshot(env)

    def test_invalid_profile_and_capability_shape_fail_closed(self):
        invalid_profile = snapshot_document(["mac.ui"])
        invalid_profile["controlProfile"] = "admin"
        with self.assertRaises(automac_mcp.CapabilitySnapshotError):
            automac_mcp.CapabilitySnapshot.from_dict(invalid_profile)

        invalid_capability = snapshot_document(["mac.ui"])
        invalid_capability["capabilities"]["mac.shell"]["ready"] = "yes"
        with self.assertRaises(automac_mcp.CapabilitySnapshotError):
            automac_mcp.CapabilitySnapshot.from_dict(invalid_capability)

    def test_import_in_managed_mode_without_snapshot_fails_before_server_start(self):
        env = os.environ.copy()
        env.update({"MAC_ORCHESTRATOR_MANAGED": "1"})
        env.pop("MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT", None)
        result = subprocess.run(
            [sys.executable, "-B", "-c", "import automac_mcp"],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT", result.stderr)


class PolicyBypassTests(unittest.TestCase):
    def test_full_control_bypasses_roots_only_after_capability_authorization(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "readable.txt"
            target.write_text("allowed", encoding="utf-8")
            authorized = make_snapshot(
                ["mac.files.read"],
                profile="full",
                approved_roots=[],
            )
            unauthorized = make_snapshot([], profile="full", approved_roots=[])

            with automac_mcp.use_runtime(authorized):
                allowed = automac_mcp.read_file(str(target))
            with automac_mcp.use_runtime(unauthorized):
                denied = automac_mcp.read_file(str(target))

        self.assertEqual(allowed["status"], "success")
        self.assertEqual(allowed["content"], "allowed")
        self.assertEqual(denied["error_code"], "POLICY_DENIED")

    def test_direct_and_macro_shell_paths_share_policy(self):
        snapshot = make_snapshot(["mac.ui"])
        with automac_mcp.use_runtime(snapshot):
            direct = automac_mcp.run_terminal_command("echo should-not-run")
            macro = automac_mcp.execute_macro(
                [{"action": "run_command", "command": "echo should-not-run"}],
                default_delay_ms=0,
            )
        self.assertEqual(direct["error_code"], "POLICY_DENIED")
        self.assertEqual(macro["steps"][0]["error_code"], "POLICY_DENIED")

    def test_direct_and_macro_file_writes_share_policy(self):
        snapshot = make_snapshot(["mac.ui", "mac.files.read"])
        with tempfile.TemporaryDirectory() as tmp:
            target = str(Path(tmp) / "out.txt")
            with automac_mcp.use_runtime(snapshot):
                direct = automac_mcp.write_file(target, "secret")
                macro = automac_mcp.execute_macro(
                    [{"action": "write_file", "path": target, "content": "secret"}],
                    default_delay_ms=0,
                )
            self.assertEqual(direct["error_code"], "POLICY_DENIED")
            self.assertEqual(macro["steps"][0]["error_code"], "POLICY_DENIED")
            self.assertFalse(Path(target).exists())

    def test_macro_file_reads_use_the_same_guided_root_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            approved = Path(tmp) / "approved"
            outside = Path(tmp) / "outside.txt"
            approved.mkdir()
            outside.write_text("secret", encoding="utf-8")
            snapshot = make_snapshot(
                ["mac.ui", "mac.files.read"],
                approved_roots=[str(approved)],
            )
            with automac_mcp.use_runtime(snapshot):
                macro = automac_mcp.execute_macro(
                    [{"action": "read_file", "path": str(outside)}],
                    default_delay_ms=0,
                )
            self.assertEqual(macro["steps"][0]["error_code"], "POLICY_DENIED")

    def test_clipboard_mutation_and_macro_set_are_denied_before_pbcopy(self):
        snapshot = make_snapshot(["mac.ui"])
        with patch.object(automac_mcp.subprocess, "run") as run:
            with automac_mcp.use_runtime(snapshot):
                direct = automac_mcp.clipboard(action="set", content="secret")
                macro = automac_mcp.execute_macro(
                    [{"action": "set_clipboard", "content": "secret"}],
                    default_delay_ms=0,
                )
        self.assertEqual(direct["error_code"], "POLICY_DENIED")
        self.assertEqual(macro["steps"][0]["error_code"], "POLICY_DENIED")
        run.assert_not_called()

    def test_unicode_typing_cannot_fallback_to_clipboard_when_disabled(self):
        snapshot = make_snapshot(["mac.ui"])
        with patch.object(automac_mcp.subprocess, "run") as run, patch.object(
            automac_mcp.pyautogui, "write"
        ) as write:
            with automac_mcp.use_runtime(snapshot):
                result = automac_mcp.type_text("café")
        self.assertEqual(result["error_code"], "POLICY_DENIED")
        run.assert_not_called()
        write.assert_not_called()

    def test_guided_paths_reject_parent_sibling_and_symlink_escapes(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "approved"
            sibling = Path(tmp) / "approved-barley"
            outside = Path(tmp) / "outside"
            base.mkdir()
            sibling.mkdir()
            outside.mkdir()
            (outside / "secret.txt").write_text("secret", encoding="utf-8")
            link = base / "link.txt"
            link.symlink_to(outside / "secret.txt")
            snapshot = make_snapshot(
                ["mac.files.read"],
                approved_roots=[str(base)],
            )
            with automac_mcp.use_runtime(snapshot):
                parent = automac_mcp.read_file(str(base / ".." / "outside" / "secret.txt"))
                sibling_result = automac_mcp.read_file(str(sibling / "secret.txt"))
                symlink = automac_mcp.read_file(str(link))
            self.assertEqual(parent["error_code"], "POLICY_DENIED")
            self.assertEqual(sibling_result["error_code"], "POLICY_DENIED")
            self.assertEqual(symlink["error_code"], "POLICY_DENIED")

    def test_guided_directory_and_regex_search_reject_symlink_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            approved = Path(tmp) / "approved"
            outside = Path(tmp) / "outside"
            approved.mkdir()
            outside.mkdir()
            (outside / "secret.txt").write_text("secret", encoding="utf-8")
            (approved / "outside-link").symlink_to(outside, target_is_directory=True)
            snapshot = make_snapshot(
                ["mac.files.read"],
                approved_roots=[str(approved)],
            )
            with automac_mcp.use_runtime(snapshot):
                listed = automac_mcp.list_directory(str(approved))
                searched = automac_mcp.smart_search(str(approved), "secret")
            self.assertEqual(listed["error_code"], "POLICY_DENIED")
            self.assertEqual(searched["error_code"], "POLICY_DENIED")

    def test_guided_spotlight_search_requires_an_explicit_approved_directory(self):
        snapshot = make_snapshot(["mac.files.read"], approved_roots=[])
        with patch.object(automac_mcp.subprocess, "run") as run:
            with automac_mcp.use_runtime(snapshot):
                result = automac_mcp.find_file("secret")
        self.assertEqual(result["error_code"], "POLICY_DENIED")
        run.assert_not_called()

    def test_telegram_file_send_obeys_file_roots_before_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            approved = Path(tmp) / "approved"
            outside = Path(tmp) / "outside.txt"
            approved.mkdir()
            outside.write_text("secret", encoding="utf-8")
            snapshot = make_snapshot(
                ["mac.files.read", "telegram.send"],
                approved_roots=[str(approved)],
            )
            secrets = automac_mcp.RuntimeSecrets(
                telegram_bot_token="synthetic-token",
                telegram_chat_id="synthetic-chat",
            )
            with patch.object(automac_mcp.requests, "post") as post:
                with automac_mcp.use_runtime(snapshot, secrets):
                    result = automac_mcp.send_file_to_telegram(str(outside))
            self.assertEqual(result["error_code"], "POLICY_DENIED")
            post.assert_not_called()

    def test_telegram_send_errors_never_expose_the_bot_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            approved = Path(tmp)
            attachment = approved / "attachment.txt"
            attachment.write_text("synthetic", encoding="utf-8")
            snapshot = make_snapshot(
                ["mac.files.read", "telegram.send"],
                approved_roots=[str(approved)],
            )
            token = "123456:synthetic-secret-token"
            secrets = automac_mcp.RuntimeSecrets(
                telegram_bot_token=token,
                telegram_chat_id="123456",
            )
            leaked_url = f"https://api.telegram.org/bot{token}/sendDocument"

            with patch.object(
                automac_mcp.requests,
                "post",
                side_effect=RuntimeError(f"connection failed for {leaked_url}"),
            ):
                with automac_mcp.use_runtime(snapshot, secrets):
                    exception_result = automac_mcp.send_file_to_telegram(str(attachment))

            response = type(
                "SyntheticTelegramResponse",
                (),
                {"status_code": 401, "text": f"unauthorized token={token}"},
            )()
            with patch.object(automac_mcp.requests, "post", return_value=response):
                with automac_mcp.use_runtime(snapshot, secrets):
                    response_result = automac_mcp.send_file_to_telegram(str(attachment))

        self.assertNotIn(token, json.dumps(exception_result, sort_keys=True))
        self.assertNotIn(token, json.dumps(response_result, sort_keys=True))

    def test_screenshot_write_is_not_a_write_policy_bypass(self):
        snapshot = make_snapshot(["mac.screenOcr"])
        with patch.object(automac_mcp.pyautogui, "screenshot") as screenshot:
            with automac_mcp.use_runtime(snapshot):
                result = automac_mcp.get_screen_text(screenshot=True)
        self.assertEqual(result["error_code"], "POLICY_DENIED")
        screenshot.assert_not_called()

    def test_disabled_meridian_cannot_be_resurrected_by_environment_or_secrets(self):
        snapshot = make_snapshot(["mac.files.read"])
        secrets = automac_mcp.RuntimeSecrets(
            worker_url="https://synthetic.example",
            meridian_ingest_token="secret-token-fragment",
        )
        with patch.object(automac_mcp.requests, "get") as get:
            with automac_mcp.use_runtime(snapshot, secrets):
                result = automac_mcp.vector_search("meaning")
        self.assertEqual(result["error_code"], "POLICY_DENIED")
        get.assert_not_called()

    def test_legacy_meridian_environment_values_do_not_register_a_disabled_tool(self):
        snapshot = make_snapshot(["mac.files.read"])
        with patch.dict(
            os.environ,
            {
                "MAC_ORCHESTRATOR_WORKER_URL": "https://legacy.example",
                "INGEST_TOKEN": "legacy-token",
            },
            clear=False,
        ):
            server = automac_mcp.build_mcp(snapshot)
        self.assertNotIn("vector_search", tool_names(server))

    def test_clipboard_policy_can_deny_mutation_even_if_capability_is_ready(self):
        snapshot = make_snapshot(["mac.ui", "mac.clipboard.write"], clipboard_mutation=False)
        with patch.object(automac_mcp.subprocess, "run") as run:
            with automac_mcp.use_runtime(snapshot):
                result = automac_mcp.clipboard(action="set", content="secret")
        self.assertEqual(result["error_code"], "POLICY_DENIED")
        run.assert_not_called()

    def test_guided_screenshot_requires_the_destination_to_be_approved(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = make_snapshot(
                ["mac.screenOcr", "mac.files.write"],
                approved_roots=[tmp],
            )
            with patch.object(automac_mcp.pyautogui, "screenshot") as screenshot:
                with automac_mcp.use_runtime(snapshot):
                    result = automac_mcp.get_screen_text(screenshot=True)
        self.assertEqual(result["error_code"], "POLICY_DENIED")
        screenshot.assert_not_called()

    def test_screenshot_authorizes_exact_timestamped_destination_before_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            desktop = Path(tmp) / "Desktop"
            desktop.mkdir()
            placeholder = desktop / "orchestrator_screenshot.png"
            snapshot = make_snapshot(
                ["mac.screenOcr", "mac.files.write"],
                approved_roots=[str(placeholder)],
            )
            with patch.dict(os.environ, {"HOME": tmp}), patch.object(
                automac_mcp.pyautogui, "screenshot"
            ) as screenshot, patch.object(
                automac_mcp.pyautogui, "size", return_value=(1920, 1080)
            ):
                with automac_mcp.use_runtime(snapshot):
                    result = automac_mcp.get_screen_text(screenshot=True)

        self.assertEqual(result["error_code"], "POLICY_DENIED")
        screenshot.assert_not_called()


class DiscoveryRedactionTests(unittest.TestCase):
    def test_get_capabilities_is_compact_and_redacts_reason_details(self):
        secret = "secret-token-fragment"
        snapshot = make_snapshot(
            ["mac.ui"],
            reasons={
                "meridian.search": f"provider account=123 token={secret}",
            },
        )
        with automac_mcp.use_runtime(snapshot):
            result = automac_mcp.get_capabilities()
        encoded = json.dumps(result, sort_keys=True)
        self.assertEqual(result["status"], "success")
        self.assertIn("meridian.search", encoded)
        self.assertNotIn(secret, encoded)
        self.assertNotIn("account=123", encoded)
        self.assertNotIn("MAC_ORCHESTRATOR_", encoded)
        self.assertNotIn("config.json", encoded)
        self.assertNotIn("Keychain", encoded)
        self.assertIn("Mac Orchestrator", result["setup_hint"])
        self.assertIn("do not edit secrets", result["setup_hint"])
        self.assertNotIn("vector_search", result["disabled"][0].get("reason", ""))


if __name__ == "__main__":
    unittest.main()
