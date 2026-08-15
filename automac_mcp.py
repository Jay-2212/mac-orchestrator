#!/usr/bin/env python3
"""
Mac Orchestrator (AutoMac MCP) — A lean MCP server for macOS UI automation.

Exposes a small, powerful set of tools that allow any AI agent to control a
macOS desktop: press keys, move the mouse, read the screen, run commands,
and chain multiple UI actions into atomic macros with realistic timing.
"""

import atexit
import functools
import json
import logging
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Mapping, Optional
from urllib.parse import urlsplit

import requests
import pyautogui
from rich.console import Console
from rich.panel import Panel
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse
try:
    from Cocoa import NSWorkspace
    from Quartz import (CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly,
                        kCGNullWindowID, CGEventCreateScrollWheelEvent, CGEventPost,
                        kCGScrollEventUnitPixel, kCGHIDEventTap,
                        CGPreflightScreenCaptureAccess, CGSessionCopyCurrentDictionary)
    from ApplicationServices import (AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
                                     AXUIElementSetAttributeValue, AXUIElementPerformAction,
                                     AXUIElementCopyActionNames, AXUIElementSetMessagingTimeout,
                                     AXUIElementGetPid, AXValueGetValue, AXIsProcessTrusted,
                                     kAXWindowsAttribute, kAXTitleAttribute, kAXPositionAttribute,
                                     kAXSizeAttribute, kAXRoleAttribute, kAXChildrenAttribute,
                                     kAXValueCGPointType, kAXValueCGSizeType)
    ACCESSIBILITY_AVAILABLE = True
except ImportError:
    ACCESSIBILITY_AVAILABLE = False

CAPABILITY_SNAPSHOT_ENV = "MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT"
CAPABILITY_IDS = (
    "core.session",
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
)
_CAPABILITY_ID_SET = frozenset(CAPABILITY_IDS)
_CONTROL_PROFILES = frozenset({"guided", "full"})
_HEALTH_VALUES = frozenset({"ready", "disabled", "degraded", "unavailable"})
_MERIDIAN_CONTROL_ROUTE = "/api/v1/search"
_MERIDIAN_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_MERIDIAN_SAFE_GENERATION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")


class CapabilitySnapshotError(ValueError):
    """Raised when the supervisor capability contract cannot be trusted."""


class PolicyDenied(RuntimeError):
    """Raised by the centralized policy layer for a denied operation."""

    def __init__(self, operation: str, capability: str):
        self.operation = operation
        self.capability = capability
        super().__init__(
            f"{operation} is disabled by Mac Orchestrator policy. "
            "Ask the user to enable it through Mac Orchestrator."
        )


@dataclass(frozen=True)
class CapabilityState:
    desired: bool
    configured: bool
    ready: bool
    health: str
    dependencies: tuple[str, ...]
    reason: Optional[str]

    @property
    def enabled(self) -> bool:
        return self.desired and self.configured and self.ready and self.health == "ready"


@dataclass(frozen=True)
class CapabilityPolicyConfig:
    approved_file_roots: tuple[Path, ...]
    clipboard_mutation: bool


@dataclass(frozen=True)
class CapabilitySnapshot:
    """Validated, nonsecret capability state supplied by Swift or local dev."""

    snapshot_schema_version: int
    config_generation: int
    control_profile: str
    capabilities: Mapping[str, CapabilityState]
    policy: CapabilityPolicyConfig

    @classmethod
    def from_dict(cls, document: Mapping[str, Any]) -> "CapabilitySnapshot":
        if not isinstance(document, Mapping):
            raise CapabilitySnapshotError("capability snapshot must be a JSON object")

        expected_keys = {
            "snapshotSchemaVersion",
            "configGeneration",
            "controlProfile",
            "capabilities",
            "policy",
        }
        unknown_keys = set(document) - expected_keys
        if unknown_keys:
            raise CapabilitySnapshotError(
                f"capability snapshot contains unsupported fields: {sorted(unknown_keys)}"
            )

        schema_version = document.get("snapshotSchemaVersion")
        if isinstance(schema_version, bool) or not isinstance(schema_version, int):
            raise CapabilitySnapshotError("snapshotSchemaVersion must be an integer")
        if schema_version != 1:
            raise CapabilitySnapshotError(
                f"unsupported capability snapshot schema {schema_version}; expected 1"
            )

        config_generation = document.get("configGeneration")
        if isinstance(config_generation, bool) or not isinstance(config_generation, int):
            raise CapabilitySnapshotError("configGeneration must be an integer")
        if config_generation < 0:
            raise CapabilitySnapshotError("configGeneration must not be negative")

        control_profile = document.get("controlProfile")
        if control_profile not in _CONTROL_PROFILES:
            raise CapabilitySnapshotError(
                f"controlProfile must be one of {sorted(_CONTROL_PROFILES)}"
            )

        raw_capabilities = document.get("capabilities")
        if not isinstance(raw_capabilities, Mapping):
            raise CapabilitySnapshotError("capabilities must be an object")
        actual_ids = set(raw_capabilities)
        missing_ids = _CAPABILITY_ID_SET - actual_ids
        unknown_ids = actual_ids - _CAPABILITY_ID_SET
        if missing_ids:
            raise CapabilitySnapshotError(
                f"capability snapshot is missing IDs: {sorted(missing_ids)}"
            )
        if unknown_ids:
            raise CapabilitySnapshotError(
                f"capability snapshot contains unknown IDs: {sorted(unknown_ids)}"
            )

        capabilities: dict[str, CapabilityState] = {}
        for capability_id in CAPABILITY_IDS:
            raw_state = raw_capabilities[capability_id]
            if not isinstance(raw_state, Mapping):
                raise CapabilitySnapshotError(f"{capability_id} state must be an object")
            required_state_keys = {
                "desired", "configured", "ready", "health", "dependencies", "reason"
            }
            unknown_state_keys = set(raw_state) - required_state_keys
            if unknown_state_keys:
                raise CapabilitySnapshotError(
                    f"{capability_id} state contains unsupported fields: "
                    f"{sorted(unknown_state_keys)}"
                )
            booleans = {
                key: raw_state.get(key)
                for key in ("desired", "configured", "ready")
            }
            if any(isinstance(value, bool) is False for value in booleans.values()):
                raise CapabilitySnapshotError(
                    f"{capability_id} desired/configured/ready values must be booleans"
                )
            health = raw_state.get("health")
            if health not in _HEALTH_VALUES:
                raise CapabilitySnapshotError(
                    f"{capability_id} health must be one of {sorted(_HEALTH_VALUES)}"
                )
            dependencies = raw_state.get("dependencies")
            if not isinstance(dependencies, list) or any(
                not isinstance(item, str) or item not in _CAPABILITY_ID_SET
                for item in dependencies
            ):
                raise CapabilitySnapshotError(
                    f"{capability_id} dependencies must contain only canonical capability IDs"
                )
            reason = raw_state.get("reason")
            if reason is not None and (
                not isinstance(reason, str) or len(reason) > 512
            ):
                raise CapabilitySnapshotError(
                    f"{capability_id} reason must be null or a short string"
                )
            capabilities[capability_id] = CapabilityState(
                desired=booleans["desired"],
                configured=booleans["configured"],
                ready=booleans["ready"],
                health=health,
                dependencies=tuple(dependencies),
                reason=reason,
            )

        raw_policy = document.get("policy")
        if not isinstance(raw_policy, Mapping):
            raise CapabilitySnapshotError("policy must be an object")
        expected_policy_keys = {"approvedFileRoots", "clipboardMutation"}
        unknown_policy_keys = set(raw_policy) - expected_policy_keys
        if unknown_policy_keys:
            raise CapabilitySnapshotError(
                f"policy contains unsupported fields: {sorted(unknown_policy_keys)}"
            )
        raw_roots = raw_policy.get("approvedFileRoots")
        if not isinstance(raw_roots, list) or any(
            not isinstance(root, str) or not root.strip() for root in raw_roots
        ):
            raise CapabilitySnapshotError("policy.approvedFileRoots must be a list of paths")
        roots: list[Path] = []
        seen_roots: set[Path] = set()
        for raw_root in raw_roots:
            root = Path(raw_root)
            if (
                raw_root.startswith("~")
                or not root.is_absolute()
                or os.path.normpath(raw_root) != raw_root
            ):
                raise CapabilitySnapshotError(
                    "policy.approvedFileRoots must contain normalized absolute paths"
                )
            canonical_root = root.resolve(strict=False)
            if canonical_root not in seen_roots:
                seen_roots.add(canonical_root)
                roots.append(canonical_root)
        clipboard_mutation = raw_policy.get("clipboardMutation")
        if not isinstance(clipboard_mutation, bool):
            raise CapabilitySnapshotError("policy.clipboardMutation must be a boolean")

        return cls(
            snapshot_schema_version=schema_version,
            config_generation=config_generation,
            control_profile=control_profile,
            capabilities=dict(capabilities),
            policy=CapabilityPolicyConfig(
                approved_file_roots=tuple(roots),
                clipboard_mutation=clipboard_mutation,
            ),
        )

    @classmethod
    def from_json(cls, raw_json: str) -> "CapabilitySnapshot":
        try:
            document = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise CapabilitySnapshotError(
                f"{CAPABILITY_SNAPSHOT_ENV} contains malformed JSON: {exc.msg}"
            ) from exc
        return cls.from_dict(document)

    def is_ready(self, capability_id: str) -> bool:
        try:
            return self.capabilities[capability_id].enabled
        except KeyError as exc:
            raise CapabilitySnapshotError(f"unknown capability ID: {capability_id}") from exc

    def safe_reason(self, capability_id: str) -> str:
        state = self.capabilities[capability_id]
        if not state.desired:
            return "Disabled in Mac Orchestrator"
        if not state.configured:
            return "Not configured in Mac Orchestrator"
        if not state.ready or state.health != "ready":
            return "Not ready; ask the user to open Mac Orchestrator"
        return "Ready"


class CapabilityPolicy:
    """Central authorization layer shared by direct and aggregate operations."""

    def __init__(self, snapshot: CapabilitySnapshot):
        self.snapshot = snapshot

    def allows(self, capability_id: str) -> bool:
        return self.snapshot.is_ready(capability_id)

    def require(self, capability_id: str, operation: str) -> None:
        if not self.allows(capability_id):
            raise PolicyDenied(operation, capability_id)

    @staticmethod
    def _within(candidate: Path, root: Path) -> bool:
        return candidate == root or root in candidate.parents

    def canonical_path(self, raw_path: str) -> Path:
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise PolicyDenied("file operation", "mac.files.read")
        return Path(os.path.expanduser(raw_path)).resolve(strict=False)

    def authorize_path(self, raw_path: str, capability_id: str, operation: str) -> Path:
        self.require(capability_id, operation)
        candidate = self.canonical_path(raw_path)
        if self.snapshot.control_profile == "full":
            return candidate
        roots = self.snapshot.policy.approved_file_roots
        if not roots or not any(self._within(candidate, root) for root in roots):
            raise PolicyDenied(
                f"{operation} outside the approved file roots",
                capability_id,
            )
        return candidate

    def authorize_clipboard_mutation(self, operation: str) -> None:
        self.require("mac.clipboard.write", operation)
        if not self.snapshot.policy.clipboard_mutation:
            raise PolicyDenied(operation, "mac.clipboard.write")


@dataclass(frozen=True)
class RuntimeSecrets:
    """Secrets injected explicitly by the supervisor; never loaded from disk."""

    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    meridian_ingest_token: str = ""
    worker_url: str = ""

    @classmethod
    def from_environment(cls, environ: Optional[Mapping[str, str]] = None) -> "RuntimeSecrets":
        env = os.environ if environ is None else environ
        return cls(
            telegram_bot_token=env.get("MAC_ORCHESTRATOR_TELEGRAM_BOT_TOKEN", "").strip(),
            telegram_chat_id=env.get("MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID", "").strip(),
            meridian_ingest_token=env.get(
                "MAC_ORCHESTRATOR_MERIDIAN_INGEST_TOKEN", ""
            ).strip(),
            worker_url=env.get("MAC_ORCHESTRATOR_WORKER_URL", "").strip(),
        )


def _valid_meridian_base_url(value: str):
    """Return a credential-safe HTTPS base URL, or None."""
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        return None
    parsed = urlsplit(value.strip())
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        return None
    if parsed.username is not None or parsed.password is not None:
        return None
    if parsed.query or parsed.fragment:
        return None
    try:
        _ = parsed.port
    except ValueError:
        return None
    return parsed


@dataclass(frozen=True)
class ServerRuntime:
    snapshot: CapabilitySnapshot
    secrets: RuntimeSecrets

    @property
    def policy(self) -> CapabilityPolicy:
        return CapabilityPolicy(self.snapshot)


def _local_snapshot(environ: Mapping[str, str]) -> CapabilitySnapshot:
    """Build the explicit loopback developer profile without reading config files."""
    secrets = RuntimeSecrets.from_environment(environ)
    telegram_opt_in = environ.get("MAC_ORCHESTRATOR_ENABLE_TELEGRAM") == "1"
    meridian_opt_in = environ.get("MAC_ORCHESTRATOR_ENABLE_MERIDIAN") == "1"
    telegram_ready = telegram_opt_in and bool(
        secrets.telegram_bot_token and secrets.telegram_chat_id
    )
    # Local developer mode still needs an explicit readiness marker. A URL and
    # token are configuration inputs, never proof that Core is compatible or
    # that the semantic probe succeeded.
    meridian_ready = (
        meridian_opt_in
        and environ.get("MAC_ORCHESTRATOR_MERIDIAN_READY") == "1"
        and _valid_meridian_base_url(secrets.worker_url) is not None
        and bool(secrets.meridian_ingest_token)
    )
    local_ready = {
        "core.session",
        "mac.ui",
        "mac.screenOcr",
        "mac.files.read",
        "mac.files.write",
        "mac.shell",
        "mac.clipboard.write",
    }
    if telegram_ready:
        local_ready.add("telegram.send")
    if meridian_ready:
        local_ready.add("meridian.search")
    profile = environ.get("MAC_ORCHESTRATOR_CONTROL_PROFILE", "full")
    raw_roots = environ.get("MAC_ORCHESTRATOR_APPROVED_FILE_ROOTS", "")
    roots = [root for root in raw_roots.split(os.pathsep) if root]
    capabilities = {}
    for capability_id in CAPABILITY_IDS:
        if capability_id in local_ready:
            capabilities[capability_id] = {
                "desired": True,
                "configured": True,
                "ready": True,
                "health": "ready",
                "dependencies": [],
                "reason": None,
            }
        else:
            capabilities[capability_id] = {
                "desired": False,
                "configured": False,
                "ready": False,
                "health": "disabled",
                "dependencies": [],
                "reason": "disabled in local developer mode",
            }
    return CapabilitySnapshot.from_dict({
        "snapshotSchemaVersion": 1,
        "configGeneration": 0,
        "controlProfile": profile,
        "capabilities": capabilities,
        "policy": {
            "approvedFileRoots": roots,
            "clipboardMutation": environ.get(
                "MAC_ORCHESTRATOR_CLIPBOARD_MUTATION", "1"
            ) == "1",
        },
    })


def load_capability_snapshot(
    environ: Optional[Mapping[str, str]] = None,
) -> CapabilitySnapshot:
    """Load a validated managed snapshot or deterministic loopback profile."""
    env = os.environ if environ is None else environ
    if env.get("MAC_ORCHESTRATOR_MANAGED") == "1":
        raw = env.get(CAPABILITY_SNAPSHOT_ENV)
        if not raw or not raw.strip():
            raise CapabilitySnapshotError(
                f"managed mode requires {CAPABILITY_SNAPSHOT_ENV}; refusing the historical full tool surface"
            )
        return CapabilitySnapshot.from_json(raw)
    return _local_snapshot(env)


def capability_report(snapshot: CapabilitySnapshot) -> Dict[str, Any]:
    enabled = [capability_id for capability_id in CAPABILITY_IDS if snapshot.is_ready(capability_id)]
    disabled = [
        {"id": capability_id, "reason": snapshot.safe_reason(capability_id)}
        for capability_id in CAPABILITY_IDS
        if not snapshot.is_ready(capability_id)
    ]
    return {
        "enabled": enabled,
        "disabled": disabled,
        "control_profile": snapshot.control_profile,
        "snapshot_schema_version": snapshot.snapshot_schema_version,
        "config_generation": snapshot.config_generation,
        "file_policy": (
            "approved_roots_only"
            if snapshot.control_profile == "guided"
            else "full_control"
        ),
        "clipboard_mutation": snapshot.policy.clipboard_mutation
        and snapshot.is_ready("mac.clipboard.write"),
        "setup_hint": (
            "Disabled integrations are configured by the user through Mac Orchestrator. "
            "Ask the user to open Mac Orchestrator; do not edit secrets or start services yourself."
        ),
    }

MANAGED_MODE = os.getenv("MAC_ORCHESTRATOR_MANAGED") == "1"
CONNECTOR_TOKEN = os.getenv("MAC_ORCHESTRATOR_CONNECTOR_TOKEN", "").strip()
if CONNECTOR_TOKEN and not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", CONNECTOR_TOKEN):
    raise RuntimeError("MAC_ORCHESTRATOR_CONNECTOR_TOKEN must be 32-128 URL-safe characters")

try:
    DEFAULT_SNAPSHOT = load_capability_snapshot()
except CapabilitySnapshotError as exc:
    raise RuntimeError(f"Mac Orchestrator capability startup failed: {exc}") from exc

DEFAULT_SECRETS = RuntimeSecrets.from_environment()
DEFAULT_RUNTIME = ServerRuntime(DEFAULT_SNAPSHOT, DEFAULT_SECRETS)
_RUNTIME_CONTEXT: ContextVar[Optional[ServerRuntime]] = ContextVar(
    "mac_orchestrator_runtime", default=None
)


def _runtime() -> ServerRuntime:
    return _RUNTIME_CONTEXT.get() or DEFAULT_RUNTIME


@contextmanager
def use_runtime(
    snapshot: CapabilitySnapshot,
    secrets: Optional[RuntimeSecrets] = None,
) -> Iterator[ServerRuntime]:
    """Bind an isolated snapshot for deterministic direct-function tests."""
    runtime = ServerRuntime(snapshot, secrets or RuntimeSecrets.from_environment())
    token = _RUNTIME_CONTEXT.set(runtime)
    try:
        yield runtime
    finally:
        _RUNTIME_CONTEXT.reset(token)


def _policy_guard(capability_id: str, operation: str) -> Optional[Dict[str, Any]]:
    try:
        _runtime().policy.require(capability_id, operation)
    except PolicyDenied as exc:
        return _fail(str(exc), error_code="POLICY_DENIED", capability=capability_id)
    return None


def _path_guard(
    path: str,
    capability_id: str,
    operation: str,
) -> tuple[Optional[Path], Optional[Dict[str, Any]]]:
    try:
        return _runtime().policy.authorize_path(path, capability_id, operation), None
    except PolicyDenied as exc:
        return None, _fail(str(exc), error_code="POLICY_DENIED", capability=capability_id)

MCP_PATH = f"/{CONNECTOR_TOKEN}/mcp" if CONNECTOR_TOKEN else "/mcp"

# A remote tunnel preserves its public Host header. Managed mode therefore uses
# a high-entropy capability path as the authentication boundary and disables
# Host validation. Direct local development keeps FastMCP's loopback defaults.
transport_security = (
    TransportSecuritySettings(enable_dns_rebinding_protection=False)
    if MANAGED_MODE
    else None
)
SERVER_PORT = int(os.getenv("MAC_ORCHESTRATOR_PORT", "8000"))
SERVER_INSTRUCTIONS = ""


async def _health_check(request: Request) -> JSONResponse:
    """Liveness probe for the native supervisor. Deliberately outside the
    capability path (FastMCP's custom_route bypasses it by design) and
    deliberately minimal: no token, no MCP path, no process state — just
    confirmation that this server, not merely something on the port, is up.
    """
    return JSONResponse({"status": "ok"})


pyautogui.FAILSAFE = True
_ocr_reader = None
_background_processes: dict[int, subprocess.Popen] = {}
_background_processes_lock = threading.Lock()


def _reap_background_processes() -> None:
    with _background_processes_lock:
        finished = [pid for pid, proc in _background_processes.items() if proc.poll() is not None]
        for pid in finished:
            _background_processes.pop(pid, None)


def cleanup_background_processes() -> None:
    """Terminate only background commands launched by this server instance."""
    with _background_processes_lock:
        processes = list(_background_processes.values())
        _background_processes.clear()

    for proc in processes:
        if proc.poll() is not None:
            continue
        try:
            if MANAGED_MODE:
                # Managed children share the server's process group. The native
                # supervisor terminates that entire group on forced shutdown.
                proc.terminate()
            else:
                os.killpg(proc.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            pass

    deadline = time.monotonic() + 2.0
    for proc in processes:
        if proc.poll() is not None:
            continue
        remaining = max(0.0, deadline - time.monotonic())
        try:
            proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            try:
                if MANAGED_MODE:
                    proc.kill()
                else:
                    os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass


atexit.register(cleanup_background_processes)

def get_ocr_reader():
    """Lazy-load the EasyOCR reader so startup stays fast."""
    global _ocr_reader
    if _ocr_reader is None:
        import easyocr
        _ocr_reader = easyocr.Reader(['en'])
    return _ocr_reader


def screenshot_array(screenshot):
    """Import NumPy only when OCR is actually requested."""
    import numpy as np
    return np.array(screenshot)

# ── Response Helpers ──────────────────────────────────────────────────────────

def _ok(message: str, **data) -> Dict[str, Any]:
    return {"status": "success", "message": message, **data}

def _fail(message: str, error_code: str = "GENERIC", **data) -> Dict[str, Any]:
    # error_code values: PERMISSION, TIMEOUT, NOT_FOUND, INVALID_PARAM, EXEC_ERROR, GENERIC
    return {"status": "error", "error_code": error_code, "message": message, **data}

# ── Permission Error Classification ───────────────────────────────────────────

_PERMISSION_ERROR_PATTERNS = (
    ("not authorized to send apple events", "Automation"),
    ("not allowed assistive access", "Accessibility"),
    ("assistive access", "Accessibility"),
    ("-1743", "Automation"),
    ("-25211", "Accessibility"),
)

def _classify_applescript_error(stderr: str) -> Optional[str]:
    """Return the permission name a known TCC-denial error message maps to, else None."""
    low = stderr.lower()
    for pattern, permission in _PERMISSION_ERROR_PATTERNS:
        if pattern in low:
            return permission
    return None

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
            stderr = r.stderr.strip()
            missing_permission = _classify_applescript_error(stderr)
            if missing_permission:
                return _fail(
                    f"{missing_permission} permission required: {stderr}. Grant it in "
                    f"System Settings → Privacy & Security → {missing_permission}, then restart "
                    "the server. Call get_session_state() to confirm current grant status.",
                    error_code="PERMISSION", missing_permission=missing_permission)
            return _fail(f"AppleScript error: {stderr}", error_code="EXEC_ERROR")
        return _ok(f"Executed: {body.strip()}")
    except subprocess.TimeoutExpired:
        return _fail(f"AppleScript timed out after {timeout}s", error_code="TIMEOUT")
    except Exception as e:
        return _fail(f"Execution failed: {e}", error_code="EXEC_ERROR")

# ── Internal Action Implementations ──────────────────────────────────────────
# These are called by individual MCP tools AND by execute_macro.

def _do_keystroke(key: str, modifiers: list = None) -> Dict[str, Any]:
    denied = _policy_guard("mac.ui", "press_keystroke")
    if denied:
        return denied
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
    denied = _policy_guard("mac.ui", "mouse_action")
    if denied:
        return denied
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
    denied = _policy_guard("mac.ui", "type_text")
    if denied:
        return denied
    if not text:
        return _fail("text is required", error_code="INVALID_PARAM")
    is_pure_ascii = all(ord(c) < 128 for c in text)
    should_use_clipboard = use_clipboard if use_clipboard is not None else not is_pure_ascii
    if should_use_clipboard:
        denied = _policy_guard("mac.clipboard.write", "type_text clipboard fallback")
        if denied:
            return denied
        if not _runtime().snapshot.policy.clipboard_mutation:
            return _fail(
                "type_text would require clipboard mutation, which is disabled by policy.",
                error_code="POLICY_DENIED",
                capability="mac.clipboard.write",
            )
    elif not is_pure_ascii:
        return _fail(
            "Unicode typing requires clipboard mutation or a supported native text path; "
            "clipboard mutation is disabled by policy.",
            error_code="POLICY_DENIED",
            capability="mac.clipboard.write",
        )
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
    denied = _policy_guard("mac.ui", "scroll")
    if denied:
        return denied
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
    denied = _policy_guard("mac.ui", "focus_app")
    if denied:
        return denied
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
                aa = ws.frontmostApplication()  # activeApplication() is deprecated/unreliable
                if aa:
                    an = str(aa.localizedName() or "")
                    if an.lower() == app_name.lower():
                        el = round(time.time() - start, 2)
                        return _ok(f"Focused '{app_name}' ({el}s)", elapsed_time=el,
                                   active_app={"name": an,
                                               "bundle_id": str(aa.bundleIdentifier() or ""),
                                               "pid": int(aa.processIdentifier())})
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

# ── 0. Documentation on demand ────────────────────────────────────────────────
#
# Tool descriptions below are kept short by design so connecting doesn't cost a
# lot of context. describe() holds the longer version of anything that got
# trimmed — call it before improvising against an unfamiliar tool.

def _macro_actions_text(snapshot: CapabilitySnapshot) -> str:
    if not snapshot.is_ready("mac.ui"):
        return "Macro guidance is unavailable because UI operation is disabled in this snapshot."
    actions = [
        '{"action": "keystroke", "key": "space", "modifiers": ["command"]}',
        '{"action": "type", "text": "Hello World"}',
        '{"action": "click", "x": 100, "y": 200}',
        '{"action": "double_click", "x": 100, "y": 200}',
        '{"action": "right_click", "x": 100, "y": 200}',
        '{"action": "move", "x": 100, "y": 200}',
        '{"action": "drag", "x": 200, "y": 300, "end_x": 800, "end_y": 400}',
        '{"action": "scroll", "dx": 0, "dy": -300}',
        '{"action": "focus_app", "app": "Notes"}',
        '{"action": "delay", "ms": 2000}',
    ]
    if snapshot.is_ready("mac.shell"):
        actions.append('{"action": "run_command", "command": "ls ~/Desktop", "timeout_seconds": 30}')
    if snapshot.is_ready("mac.files.write"):
        actions.append('{"action": "write_file", "path": "~/Desktop/out.txt", "content": "hello", "mode": "overwrite"}')
    if snapshot.is_ready("mac.files.read"):
        actions.append('{"action": "read_file", "path": "~/Desktop/in.txt", "max_chars": 4000}')
    if snapshot.policy.clipboard_mutation and snapshot.is_ready("mac.clipboard.write"):
        actions.append('{"action": "set_clipboard", "content": "text to paste later"}')
    return (
        'execute_macro() action dict reference — supported "action" values:\n\n'
        + "\n".join(actions)
        + '\n\nx/y are logical screen coordinates. The macro stops at the first failed '
        "step; partial progress and a recovery_hint are always returned."
    )


def _local_search_scope(snapshot: CapabilitySnapshot) -> str:
    return (
        "an approved directory"
        if snapshot.control_profile == "guided"
        else "the directory you want to search"
    )


def _local_search_instruction(snapshot: CapabilitySnapshot) -> str:
    return (
        "- Use Local Pattern Search (smart_search()) for regex or exact content "
        f"within {_local_search_scope(snapshot)}."
    )


def build_server_instructions(snapshot: CapabilitySnapshot) -> str:
    """Generate agent guidance from exactly the snapshot used for registration."""
    lines = [
        "Mac Orchestrator gives you direct control of this macOS desktop.",
        "",
        "START HERE:",
        "- get_capabilities() — inspect the current capability snapshot and policy.",
        "- get_session_state() — inspect session and permissions before UI work.",
        "- describe(topic=...) — request the detailed guide for an enabled tool group.",
    ]
    if snapshot.is_ready("mac.ui"):
        lines.extend([
            "",
            "UI INSPECTION:",
            "- Prefer get_ui_tree() and its stable refs over coordinate guessing.",
            "- Use get_screen_layout() for a cheap window survey, then perform_ui_action(ref=...) when a ref exists.",
        ])
        if snapshot.is_ready("mac.screenOcr"):
            lines.append("- Use get_screen_text() as the OCR fallback for custom-drawn content.")
        # The macro tool is registered with mac.ui; keep this line concise.
        lines.append("- Batch tightly related safe UI actions with execute_macro() when appropriate.")
    if snapshot.is_ready("mac.files.read"):
        lines.extend([
            "",
            "LOCAL SEARCH:",
            "- Use find_file() for Spotlight keyword/exact-content search.",
            _local_search_instruction(snapshot),
            "- Use list_directory() for browsing by date or size.",
        ])
    if snapshot.is_ready("meridian.search"):
        lines.extend([
            "",
            "- Use vector_search() for semantic search only when it is registered.",
        ])
    if snapshot.is_ready("mac.shell"):
        lines.extend([
            "",
            "- Use run_terminal_command() only for an explicit task; use capability diagnostics rather than shell repair.",
        ])
    if snapshot.is_ready("mac.files.write"):
        lines.append("- File writes are available only within the current policy boundary.")
    if not snapshot.is_ready("mac.ui"):
        lines.extend([
            "",
            "UI operation is not enabled in this snapshot. Ask the user to open Mac Orchestrator if it is needed.",
        ])
    lines.extend([
        "",
        "Disabled integrations are configured by the user through Mac Orchestrator; do not edit secrets or start services yourself.",
    ])
    return "\n".join(lines)


def _describe_topics(snapshot: CapabilitySnapshot) -> Dict[str, str]:
    topics = {"overview": build_server_instructions(snapshot)}
    if snapshot.is_ready("mac.ui"):
        topics["macro_actions"] = _macro_actions_text(snapshot)
        ui_text = """Three ways to find something on screen, in order of preference:

1. get_ui_tree(app=...) — the accessibility tree. Precise, gives you a stable ref
   for perform_ui_action(). Use role_filter/actionable_only to narrow a busy window.
2. get_screen_layout() — a cheap top-level window survey with no children.
"""
        if snapshot.is_ready("mac.screenOcr"):
            ui_text += "3. get_screen_text() — OCR fallback for custom-drawn content; it is slower and coordinate-based.\n"
        ui_text += """
Prefer a ref from get_ui_tree() over blind coordinate clicks. If the tree is empty
or errors, call get_session_state() before assuming the app has no UI."""
        topics["ui_inspection"] = ui_text
        topics["coordinate_system"] = """All screen tools use logical points, not raw pixels.

get_screen_size() returns logical dimensions for mouse_action(). Positions from
get_ui_tree() and OCR are already in logical space. Do not mix Retina pixel values
with logical coordinates."""
    if snapshot.is_ready("mac.files.read"):
        search_text = f"""find_file() uses Spotlight keyword matching (mdfind), not semantic search.

Use filename/content keywords or Spotlight metadata queries such as "kind:pdf".
Use list_directory() for browsing by date or size and Local Pattern Search
(smart_search()) for regex content search inside {_local_search_scope(snapshot)}."""
        if snapshot.is_ready("meridian.search"):
            search_text += "\nUse vector_search() for semantic search when the registered integration is ready."
        topics["find_file_query_syntax"] = search_text
    return topics


def describe_for_snapshot(snapshot: CapabilitySnapshot, topic: str = "overview") -> str:
    return _describe_topics(snapshot).get(topic, "")

def describe(topic: str = "overview") -> Dict[str, Any]:
    """Get the full-length guide for a topic that tool descriptions only summarize.

    Args:
        topic: A topic advertised by this server's current capability snapshot.
               Unknown or unavailable topics return the available list instead of
               an error.
    """
    topics = _describe_topics(_runtime().snapshot)
    if topic not in topics:
        return _ok(f"Unknown or unavailable topic '{topic}'.", available_topics=sorted(topics))
    return _ok(f"describe({topic!r})", topic=topic, text=topics[topic])


def get_capabilities() -> Dict[str, Any]:
    """Report the compact, nonsecret capability and policy state."""
    report = capability_report(_runtime().snapshot)
    return _ok(
        "Capability snapshot loaded; disabled integrations are user-managed.",
        **report,
    )


# ── 1. Keyboard ───────────────────────────────────────────────────────────────

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

def execute_macro(actions: list[dict], default_delay_ms: int = 750) -> Dict[str, Any]:
    """Run a sequence of UI actions as one batch, instead of a separate round-trip per step.

    Args:
        actions: List of dicts, each with an "action" key. Common ones:
            {"action": "keystroke", "key": "space", "modifiers": ["command"]}
            {"action": "type", "text": "Hello World"}
            {"action": "click", "x": 100, "y": 200}
            {"action": "focus_app", "app": "Notes"}
            {"action": "delay", "ms": 2000}
            Also supported: double_click, right_click, move, drag, and scroll. Optional
            shell, file, and clipboard actions are policy-controlled; the registered
            tool description is authoritative for which of those actions are available.
        default_delay_ms: Pause between actions in ms (default 750) so macOS UI has
                          time to animate. Increase for slow transitions.

    On failure: status="partial_success" if some steps ran first, "error" if the first
    step failed. Check "steps" and "recovery_hint" in the response either way.

    Example: [{"action": "focus_app", "app": "Notes"},
              {"action": "keystroke", "key": "n", "modifiers": ["command"]},
              {"action": "type", "text": "Hello from AI!"}]
    """
    denied = _policy_guard("mac.ui", "execute_macro")
    if denied:
        return denied
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
                res = run_terminal_command(
                    cmd,
                    timeout_seconds=timeout_s,
                    run_in_background=False,
                    max_output_chars=3500,
                )
        elif action_type == "write_file":
            wf_path = act.get("path", "")
            if not wf_path:
                res = _fail("write_file step requires 'path' key", error_code="INVALID_PARAM")
            else:
                res = write_file(
                    wf_path,
                    act.get("content", ""),
                    mode=act.get("mode", "overwrite"),
                )
        elif action_type == "read_file":
            rf_path = act.get("path", "")
            if not rf_path:
                res = _fail("read_file step requires 'path' key", error_code="INVALID_PARAM")
            else:
                res = read_file(rf_path)
                if res.get("status") == "success":
                    max_c = max(100, min(act.get("max_chars", 4000), 20000))
                    content = res.get("content", "")
                    truncated = len(content) > max_c
                    if truncated:
                        content = content[:max_c]
                    res = _ok(
                        f"Read {len(content)} chars from {rf_path}",
                        content=content,
                        truncated=truncated,
                    )
        elif action_type == "set_clipboard":
            clip_content = act.get("content", "")
            res = clipboard(action="set", content=clip_content)
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

def focus_app(app_name: str, timeout: int = 30) -> Dict[str, Any]:
    """Bring an application to the foreground and wait for it to become active.

    Args:
        app_name: Name of the app (e.g. "Safari", "Notes", "Finder").
        timeout: Max seconds to wait (default 30).
    """
    return _do_focus_app(app_name, timeout)

def get_available_apps() -> Dict[str, Any]:
    """List all currently running (non-background) applications.

    Returns the same app set as get_screen_layout() and get_ui_tree() — use the
    "pid" from apps_detail as a stable target for those tools instead of name,
    since names can collide across multiple running instances.

    This includes many invisible menu-bar/system agents alongside ordinary apps.
    Filter apps_detail to activation_policy == "regular" for Dock-visible apps
    that are meaningful focus_app() targets.
    """
    denied = _policy_guard("mac.ui", "get_available_apps")
    if denied:
        return denied
    if ACCESSIBILITY_AVAILABLE:
        try:
            apps_detail = _list_running_apps()
            regular_count = sum(1 for a in apps_detail if a["activation_policy"] == "regular")
            return _ok(f"Found {len(apps_detail)} running apps ({regular_count} regular, "
                      f"{len(apps_detail) - regular_count} accessory/background)",
                       apps=[a["name"] for a in apps_detail], apps_detail=apps_detail)
        except Exception as e:
            return _fail(f"Execution failed: {e}")
    # Fallback when pyobjc is unavailable: AppleScript enumeration (names only).
    script = 'tell application "System Events"\nget name of (processes where background only is false)\nend tell'
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return _fail(f"Failed to get apps: {r.stderr}")
        apps = [a.strip() for a in r.stdout.split(", ")]
        return _ok(f"Found {len(apps)} running apps", apps=apps)
    except Exception as e:
        return _fail(f"Execution failed: {e}")


# ── 6.5 Session & Permission Diagnostics ──────────────────────────────────────

def _probe_automation_permission() -> Optional[bool]:
    """Run one harmless Apple Events read as the managed Python requester."""
    if sys.platform != "darwin":
        return None
    script = (
        'tell application "System Events" to '
        'get name of first application process whose frontmost is true'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return None

def get_session_state() -> Dict[str, Any]:
    """Check whether this Mac can currently do interactive GUI work, and whether the
    permissions UI automation depends on are actually granted (not just theoretically
    available). Cheap and safe — call this first when starting UI work, or whenever a
    tool fails in a way that might be permission- or session-related.

    Distinguishes cases agents otherwise can't tell apart from a generic failure:
    - screen locked / at login window / on a background session → GUI actions will
      silently no-op or fail even though the process itself is running fine.
    - Accessibility or Screen Recording permission not granted → the specific tools
      that need each one.

    File I/O, terminal commands, and clipboard access are separate from TCC
    permissions, but their availability is still controlled by the capability
    snapshot and policy returned by get_capabilities().
    """
    session: Dict[str, Any] = {"on_console": None, "is_locked": None}
    try:
        info = CGSessionCopyCurrentDictionary()
        if info:
            d = dict(info)
            session["on_console"] = bool(d.get("kCGSSessionOnConsoleKey", False))
            # Absence of this key is Apple's documented convention for "not locked".
            session["is_locked"] = bool(d.get("CGSSessionScreenIsLocked", False))
        else:
            session["note"] = "No session dictionary — likely at the login window (no user session)."
    except Exception as e:
        session["error"] = str(e)

    accessibility_granted = None
    try:
        accessibility_granted = bool(AXIsProcessTrusted())
    except Exception:
        pass

    screen_recording_granted = None
    try:
        screen_recording_granted = bool(CGPreflightScreenCaptureAccess())
    except Exception:
        pass

    ui_capability_requested = _runtime().snapshot.capabilities.get("mac.ui")
    automation_granted = (
        _probe_automation_permission()
        if ui_capability_requested is not None and ui_capability_requested.desired
        else None
    )
    gui_available = bool(session.get("on_console")) and not bool(session.get("is_locked")) \
        and accessibility_granted is True \
        and automation_granted is True

    notes = []
    if session.get("is_locked"):
        notes.append("Screen is locked — mouse/keyboard/screen tools will fail or no-op. "
                     "Background capabilities remain policy-controlled.")
    if session.get("on_console") is False:
        notes.append("This session is not the active console session (fast user switch or "
                     "remote/background session) — GUI actions target a session the user isn't "
                     "looking at.")
    if accessibility_granted is False:
        notes.append("Accessibility permission not granted — press_keystroke, mouse_action, "
                     "get_ui_tree, perform_ui_action, get_screen_layout, and focus_app polling "
                     "will fail. Grant it to the running server process in System Settings → "
                     "Privacy & Security → Accessibility, then restart the server.")
    if screen_recording_granted is False:
        if _runtime().policy.allows("mac.screenOcr"):
            notes.append("Screen Recording permission not granted — the registered OCR/screenshot "
                         "capability will fail or return blank. Grant it in System Settings → "
                         "Privacy & Security → Screen Recording, then restart the server.")
        else:
            notes.append("Screen Recording permission not granted, and the OCR capability is not "
                         "registered in this snapshot. Ask the user to open Mac Orchestrator.")
    if automation_granted is False:
        notes.append("Automation / Apple Events permission not granted — AppleScript-backed UI "
                     "actions will fail. Grant Automation access to the managed server in "
                     "System Settings → Privacy & Security → Automation, then restart the server.")
    elif automation_granted is None and ui_capability_requested is not None and ui_capability_requested.desired:
        notes.append("Automation / Apple Events readiness could not be verified for the managed "
                     "server process.")

    return _ok(
        "GUI interaction available" if gui_available else "GUI interaction constrained — see notes",
        gui_interaction_available=gui_available,
        session=session,
        permissions={
            "accessibility": accessibility_granted,
            "screen_recording": screen_recording_granted,
            "automation": automation_granted,
        },
        background_capabilities_available={
            "file_read": _runtime().policy.allows("mac.files.read"),
            "file_write": _runtime().policy.allows("mac.files.write"),
            "shell": _runtime().policy.allows("mac.shell"),
            "clipboard_read": True,
            "clipboard_mutation": (
                _runtime().policy.allows("mac.clipboard.write")
                and _runtime().snapshot.policy.clipboard_mutation
            ),
        },
        notes=notes,
    )


# ── 7. Screen Comprehension ──────────────────────────────────────────────────

def get_screen_size() -> Dict[str, Any]:
    """Get screen dimensions in both logical and pixel coordinates.

    IMPORTANT for agents: Always use logical_width/logical_height when specifying
    coordinates for mouse_action(), press_keystroke(), or scroll(). The pixel
    dimensions are only needed if you are processing raw screenshot images.
    Coordinates from get_screen_text() are already in logical space.
    """
    denied = _policy_guard("mac.ui", "get_screen_size")
    if denied:
        return denied
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

AX_ELEMENT_TIMEOUT_SECONDS = 2.0

def _ax_set_timeout(elem, seconds: float = AX_ELEMENT_TIMEOUT_SECONDS) -> None:
    """Bound how long a single AX call can block on a wedged/beachballing app."""
    try:
        AXUIElementSetMessagingTimeout(elem, seconds)
    except Exception:
        pass

def _ax_get(elem, attr: str):
    """Safely retrieve an AX attribute value. Returns None on any failure."""
    try:
        err, val = AXUIElementCopyAttributeValue(elem, attr, None)
        return val if err == 0 else None
    except Exception:
        return None

def _ax_point(val) -> Optional[tuple]:
    """Unwrap an AXValueRef of type CGPoint into (x, y). None on failure.

    AXPosition/AXSize come back as opaque AXValueRef objects, not plain structs —
    accessing .x/.y directly raises AttributeError. Must go through AXValueGetValue.
    """
    if val is None:
        return None
    try:
        ok, point = AXValueGetValue(val, kAXValueCGPointType, None)
        return (point.x, point.y) if ok else None
    except Exception:
        return None

def _ax_size(val) -> Optional[tuple]:
    """Unwrap an AXValueRef of type CGSize into (width, height). None on failure."""
    if val is None:
        return None
    try:
        ok, size = AXValueGetValue(val, kAXValueCGSizeType, None)
        return (size.width, size.height) if ok else None
    except Exception:
        return None

def _ax_json_safe(v):
    """AXValue can be a string, number, bool, or an exotic pyobjc/CF object
    (AXValueRef structs, NSArray, ...) depending on the control. Only pass
    through JSON-native types; stringify anything else rather than letting an
    unserializable object blow up the tool response."""
    if v is None or isinstance(v, (str, int, float, bool)):
        return v
    try:
        return str(v)
    except Exception:
        return None

_ACTIVATION_POLICY_NAMES = {0: "regular", 1: "accessory"}  # 2 (prohibited) is excluded entirely

def _list_running_apps() -> List[Dict[str, Any]]:
    """Canonical app enumeration, keyed on pid. Used by get_available_apps,
    get_screen_layout, and get_ui_tree so all three agree on what an 'app' is.

    Includes menu-bar-only "accessory" apps (many system agents, some utilities)
    alongside Dock-visible "regular" apps — activation_policy tells them apart,
    since only "regular" apps are generally meaningful focus_app() targets.
    """
    ws = NSWorkspace.sharedWorkspace()
    out = []
    for app in ws.runningApplications():
        try:
            policy = app.activationPolicy()
            if policy == 2:  # NSApplicationActivationPolicyProhibited
                continue
            out.append({
                "name": str(app.localizedName() or "Unknown"),
                "bundle_id": str(app.bundleIdentifier() or ""),
                "pid": int(app.processIdentifier()),
                "activation_policy": _ACTIVATION_POLICY_NAMES.get(policy, "unknown"),
            })
        except Exception:
            continue
    return out

def _resolve_app_pid(app: str = "", pid: Optional[int] = None) -> Dict[str, Any]:
    """Resolve an app target to a single pid. Returns {"pid": int} or a _fail() dict.

    Disambiguates by pid when a name matches more than one running process, instead
    of silently picking one — agents should pass the pid back for a stable target.
    """
    if pid is not None:
        return {"pid": pid}
    if not app:
        return _fail("Provide either 'app' (name) or 'pid'.", error_code="INVALID_PARAM")
    apps = _list_running_apps()
    matches = [a for a in apps if a["name"].lower() == app.lower()]
    if not matches:
        return _fail(f"No running app named '{app}'. Call get_available_apps() for the current list.",
                     error_code="NOT_FOUND")
    if len(matches) > 1:
        return _fail(f"'{app}' matches {len(matches)} running processes; pass pid= to disambiguate.",
                     error_code="INVALID_PARAM", candidates=matches)
    return {"pid": matches[0]["pid"]}

def get_screen_layout() -> Dict[str, Any]:
    """Get window titles and bounds for all visible apps via Accessibility APIs.

    Cheap top-level survey: one row per window, no children. For buttons, fields,
    and other interactive elements inside a window, use get_ui_tree(pid=...).

    Note: Requires Accessibility permission — check get_session_state() first if
    this returns empty results or a PERMISSION error.
    Passwords in secure text fields are automatically redacted by macOS.
    """
    denied = _policy_guard("mac.ui", "get_screen_layout")
    if denied:
        return denied
    if not ACCESSIBILITY_AVAILABLE:
        return _fail(
            "macOS Accessibility frameworks not available (pyobjc import failed). "
            "This is a runtime install issue, not a permission issue.",
            error_code="GENERIC"
        )
    if not AXIsProcessTrusted():
        return _fail(
            "Accessibility permission not granted to this process. Grant it in "
            "System Settings → Privacy & Security → Accessibility, then restart the server. "
            "Call get_session_state() for full permission detail.",
            error_code="PERMISSION"
        )
    try:
        ws = NSWorkspace.sharedWorkspace()
        active_app_obj = ws.frontmostApplication()

        windows_out = []

        for app_info in _list_running_apps():
            pid, app_name = app_info["pid"], app_info["name"]
            try:
                app_elem = AXUIElementCreateApplication(pid)
                _ax_set_timeout(app_elem)
                windows_raw = _ax_get(app_elem, "AXWindows")
                if not windows_raw:
                    continue

                for win in windows_raw:
                    title = str(_ax_get(win, "AXTitle") or "")
                    point = _ax_point(_ax_get(win, "AXPosition"))
                    size  = _ax_size(_ax_get(win, "AXSize"))

                    win_data = {"app": app_name, "pid": pid, "title": title}
                    if point is not None and size is not None:
                        win_data["bounds"] = {
                            "x": int(point[0]), "y": int(point[1]),
                            "width": int(size[0]), "height": int(size[1])
                        }
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


# ── 7.5 UI Element Tree (progressive-disclosure accessibility inspection) ────
#
# Elements are opaque AXUIElementRef objects — they can't cross the JSON
# boundary. get_ui_tree() hands back a small "ref" string per element and
# keeps the real object in this in-process registry; perform_ui_action()
# resolves a ref back to the retained object rather than re-walking a path,
# so an action targets the exact element the agent saw, not whatever now
# lives at the same tree position.

AX_REGISTRY_CAP = 5000
AX_DEFAULT_DEPTH = 3
AX_MAX_DEPTH = 6
AX_DEFAULT_LIMIT = 50
AX_MAX_LIMIT = 200
AX_DEFAULT_NODE_BUDGET = 800
AX_MAX_NODE_BUDGET = 2000

_ax_registry: "dict[str, Any]" = {}
_ax_registry_order: "list[str]" = []
_ax_registry_lock = threading.Lock()
_ax_ref_seq = 0

def _ax_register(elem, pid: int) -> str:
    """Store an AXUIElementRef and hand back an opaque ref string for it."""
    global _ax_ref_seq
    with _ax_registry_lock:
        _ax_ref_seq += 1
        ref = f"el_{pid}_{_ax_ref_seq}"
        _ax_registry[ref] = elem
        _ax_registry_order.append(ref)
        while len(_ax_registry_order) > AX_REGISTRY_CAP:
            oldest = _ax_registry_order.pop(0)
            _ax_registry.pop(oldest, None)
        return ref

def _ax_resolve(ref: str):
    with _ax_registry_lock:
        return _ax_registry.get(ref)

def _ax_label(elem) -> str:
    """Best available human-readable label: title, then description, then string value."""
    for attr in ("AXTitle", "AXDescription"):
        v = _ax_get(elem, attr)
        if v:
            return str(v)
    v = _ax_get(elem, "AXValue")
    if isinstance(v, str) and v:
        return v
    return ""

def _ax_action_names(elem) -> List[str]:
    try:
        err, names = AXUIElementCopyActionNames(elem, None)
        return list(names) if err == 0 and names else []
    except Exception:
        return []

class _AXWalkState:
    """Shared traversal budget/output for one get_ui_tree() call.

    Two walk functions share this: _ax_walk_tree() (no filters — full nested
    hierarchy) and _ax_walk_flat() (role_filter/actionable_only set — matches
    can be nested arbitrarily deep under non-matching containers, so hierarchy
    is dropped in favor of a flat list of everything that matched).
    """
    def __init__(self, role_filter, actionable_only, limit, node_budget, skip):
        self.role_filter = set(r.lower() for r in role_filter) if role_filter else None
        self.actionable_only = actionable_only
        self.filtering = bool(self.role_filter or actionable_only)
        self.limit = limit
        self.node_budget = node_budget
        self.skip = skip
        self.visited = 0
        self.emitted = 0
        # `stop` is the internal recursion-control signal: true once EITHER the
        # limit or node_budget boundary is crossed, and used everywhere traversal
        # needs to halt. `node_budget_exhausted` is the public-facing field and
        # means only "node_budget ran out" — hitting `limit` is normal, expected
        # pagination, not something an agent should react to by raising node_budget.
        # Conflating the two previously told agents to widen node_budget on every
        # single full page, which was never the actual cause.
        self.stop = False
        self.node_budget_exhausted = False
        self.more_available = False
        self.flat_results: List[Dict[str, Any]] = []
        # Visit-position of the last node actually emitted this call. The next
        # continuation_token must resume here, NOT at the last *visited* position:
        # a node can be visited-but-rejected (limit hit right as we reached it),
        # and visited-position would then skip it forever — emitted-neither-page.
        self.last_emitted_pos = 0

    def visit(self) -> bool:
        """Call once per element entered. False means stop — node_budget is spent."""
        if self.visited >= self.node_budget:
            self.node_budget_exhausted = True
            self.stop = True
            self.more_available = True
            return False
        self.visited += 1
        return True

    def want_more(self) -> bool:
        return self.emitted < self.limit

    def matches(self, role: str, actions: List[str]) -> bool:
        if self.role_filter is not None and role.lower() not in self.role_filter:
            return False
        if self.actionable_only and not actions:
            return False
        return True

    def try_emit(self, elem, pid: int, role: str, actions: List[str]) -> Optional[Dict[str, Any]]:
        """Build+register a node dict for this element, honoring the pagination
        skip window and the per-call limit. None means "don't include this one"."""
        if self.visited <= self.skip:
            return None
        if not self.want_more():
            self.stop = True  # page full — routine, NOT node_budget_exhausted
            self.more_available = True
            return None
        node = {"ref": _ax_register(elem, pid), "role": role, "label": _ax_label(elem), "actions": actions}
        enabled = _ax_get(elem, "AXEnabled")
        if enabled is not None:
            node["enabled"] = bool(enabled)
        point = _ax_point(_ax_get(elem, "AXPosition"))
        size = _ax_size(_ax_get(elem, "AXSize"))
        if point is not None and size is not None:
            node["bounds"] = {"x": int(point[0]), "y": int(point[1]),
                              "width": int(size[0]), "height": int(size[1])}
        self.emitted += 1
        self.last_emitted_pos = self.visited
        return node

def _ax_walk_tree(elem, pid: int, depth_remaining: int, state: "_AXWalkState") -> List[Dict[str, Any]]:
    """Unfiltered mode: returns a list (0 or 1 items unless a skipped ancestor's
    matching descendants bubble up — see below), not a single node, so pagination
    can skip a node's own emission while still descending into its children.

    Without this, resuming with continuation_token would re-walk each top-level
    window, immediately hit its own skip window, and stop — never reaching node
    101 just because node 1 (its ancestor) was the one skipped.
    """
    if not state.visit():
        return []
    role = str(_ax_get(elem, "AXRole") or "Unknown")
    actions = _ax_action_names(elem)
    node = state.try_emit(elem, pid, role, actions)  # None: skipped-by-pagination OR over-limit
    if state.stop and node is None:
        return []  # over limit (or node_budget) — genuinely stop, don't descend

    child_out: List[Dict[str, Any]] = []
    children_raw = None
    if depth_remaining > 0:
        children_raw = _ax_get(elem, "AXChildren")
        if children_raw:
            for child in children_raw:
                child_out.extend(_ax_walk_tree(child, pid, depth_remaining - 1, state))
                if state.stop:
                    break

    if node is not None:
        if child_out:
            node["children"] = child_out
        elif children_raw:
            node["children_truncated"] = len(children_raw)
        return [node]
    else:
        # This element was skipped by the pagination window (not emitted), but its
        # matching descendants still need to surface — there's no parent dict to
        # nest them under, so they bubble up to become their parent's siblings.
        return child_out

def _ax_walk_flat(elem, pid: int, depth_remaining: int, state: "_AXWalkState") -> None:
    """Filtered mode: descend through every container regardless of whether it
    matched (matches can be nested arbitrarily deep), collecting matches into
    state.flat_results. No hierarchy in the output.

    Deliberately does NOT gate recursion on want_more(): stopping the instant
    emitted==limit means no node past the boundary is ever visited, so try_emit()
    never gets a chance to flip state.stop — has_more silently comes back False
    even when more matches exist. One extra node must be visited-and-rejected
    past the limit to correctly detect "there's more" (bounded by node_budget
    regardless, via state.visit()).
    """
    if not state.visit():
        return
    role = str(_ax_get(elem, "AXRole") or "Unknown")
    actions = _ax_action_names(elem)
    if state.matches(role, actions):
        node = state.try_emit(elem, pid, role, actions)
        if node is not None:
            state.flat_results.append(node)
    if depth_remaining > 0 and not state.stop:
        children_raw = _ax_get(elem, "AXChildren")
        if children_raw:
            for child in children_raw:
                _ax_walk_flat(child, pid, depth_remaining - 1, state)
                if state.stop:
                    break

def get_ui_tree(app: str = "", pid: Optional[int] = None, ref: str = "",
                depth: int = AX_DEFAULT_DEPTH, role_filter: list[str] = [],
                actionable_only: bool = False, limit: int = AX_DEFAULT_LIMIT,
                continuation_token: str = "", node_budget: int = AX_DEFAULT_NODE_BUDGET) -> Dict[str, Any]:
    """Inspect the accessibility element tree — buttons, fields, labels — with a stable
    "ref" per element you can pass to perform_ui_action(). Prefer this over OCR
    (get_screen_text) for anything that isn't custom-drawn. Full guide, including
    pagination and ref-lifetime detail: describe(topic="ui_inspection").

    Args:
        app / pid / ref: Target — pick one, or omit all three to inspect the frontmost
                        app. "app" errors with candidates if the name is ambiguous;
                        "ref" (from a prior call) inspects just that element's subtree.
        depth: Levels of children to descend (default 3, max 6).
        role_filter: Only these AX roles, e.g. ["AXButton", "AXTextField"] — matches
                    nested anywhere in the subtree.
        actionable_only: Only elements with at least one AX action (buttons, fields,
                        links — not static text/containers).
        limit: Max elements returned (default 50, max 200).
        node_budget: Max elements *visited* while searching, independent of limit —
                    bounds latency on huge/slow trees (default 800, max 2000). If
                    "node_budget_exhausted" comes back true, narrow with role_filter /
                    actionable_only (or use continuation_token) rather than raising this.
        continuation_token: Pass back the value from a "has_more": true response to
                           get the next page (best-effort — omit to refresh from the top
                           if the UI changed; a resumed page's bubbled-up elements may
                           appear without their original parent for context).
    """
    denied = _policy_guard("mac.ui", "get_ui_tree")
    if denied:
        return denied
    if not ACCESSIBILITY_AVAILABLE:
        return _fail("macOS Accessibility frameworks not available (pyobjc import failed).",
                     error_code="GENERIC")
    if not AXIsProcessTrusted():
        return _fail(
            "Accessibility permission not granted to this process. Call get_session_state() "
            "for detail, or grant it in System Settings → Privacy & Security → Accessibility.",
            error_code="PERMISSION")

    depth = max(0, min(depth, AX_MAX_DEPTH))
    limit = max(1, min(limit, AX_MAX_LIMIT))
    node_budget = max(1, min(node_budget, AX_MAX_NODE_BUDGET))
    try:
        skip = int(continuation_token) if continuation_token else 0
    except ValueError:
        return _fail("Invalid continuation_token.", error_code="INVALID_PARAM")

    state = _AXWalkState(role_filter, actionable_only, limit, node_budget, skip)

    try:
        if ref:
            elem = _ax_resolve(ref)
            if elem is None:
                return _fail(f"Unknown or expired ref '{ref}'. Call get_ui_tree(app=...) again for fresh refs.",
                             error_code="NOT_FOUND")
            _ax_set_timeout(elem)  # a ref's timeout isn't inherited from its app element
            try:
                _pid_err, _pid_val = AXUIElementGetPid(elem, None)
                origin_pid = int(_pid_val) if _pid_err == 0 else 0
            except Exception:
                origin_pid = 0
            if state.filtering:
                _ax_walk_flat(elem, origin_pid, depth, state)
                elements = state.flat_results
            else:
                elements = _ax_walk_tree(elem, origin_pid, depth, state)
            target_desc = f"subtree of {ref}"
        else:
            resolved = _resolve_app_pid(app, pid)
            if "pid" not in resolved:
                if not app and pid is None:
                    front = NSWorkspace.sharedWorkspace().frontmostApplication()
                    if not front:
                        return _fail("No frontmost app to inspect.", error_code="NOT_FOUND")
                    target_pid = int(front.processIdentifier())
                    target_desc = str(front.localizedName() or "frontmost app")
                else:
                    return resolved  # _fail(...) dict
            else:
                target_pid = resolved["pid"]
                target_desc = app or f"pid {target_pid}"

            app_elem = AXUIElementCreateApplication(target_pid)
            _ax_set_timeout(app_elem)
            windows_raw = _ax_get(app_elem, "AXWindows") or []
            elements = []
            if state.filtering:
                for win in windows_raw:
                    _ax_walk_flat(win, target_pid, depth, state)
                    if state.stop:
                        break
                elements = state.flat_results
            else:
                for win in windows_raw:
                    elements.extend(_ax_walk_tree(win, target_pid, depth, state))
                    if state.stop:
                        break

        result = _ok(f"{state.emitted} elements ({target_desc})",
                     elements=elements, node_budget_exhausted=state.node_budget_exhausted,
                     visited=state.visited, has_more=state.more_available)
        if state.more_available:
            # Resume at the last *emitted* position, not the last *visited* one:
            # a node can be visited-and-rejected right as the limit is hit, and
            # resuming past it (at its visit-position) would drop it from every
            # page. Fall back to min(skip, visited) if nothing emitted this call
            # at all (e.g. node_budget ran out mid-skip-window) so we retry the
            # same position instead of skipping unconfirmed nodes.
            token_pos = state.last_emitted_pos if state.last_emitted_pos > 0 else min(skip, state.visited)
            result["continuation_token"] = str(token_pos)
        return result
    except Exception as e:
        return _fail(f"UI tree inspection failed: {e}")


AX_ACTION_ALIASES = {
    "click": "AXPress", "press": "AXPress",
    "increment": "AXIncrement", "decrement": "AXDecrement",
    "confirm": "AXConfirm", "cancel": "AXCancel",
    "pick": "AXPick", "select": "AXPick",
    "show_menu": "AXShowMenu",
}

def perform_ui_action(ref: str, action: str = "click", value: Optional[str] = None) -> Dict[str, Any]:
    """Act on an element previously returned by get_ui_tree(), then report what changed.

    Prefer this over mouse_action() when you have a ref — it targets the exact element
    you inspected (not whatever is now at those coordinates), and confirms the result
    instead of leaving you to guess.

    Args:
        ref: An element ref from get_ui_tree().
        action: "click"/"press" (default — the element's primary action), "focus"
               (move keyboard focus to it without activating), "set_value" (requires
               value= — text fields, sliders), "select"/"pick" (menu items, list rows),
               or a raw AX action name (e.g. "AXShowMenu") from the element's "actions" list.
        value: Required for action="set_value". Ignored otherwise.

    Returns whether the action ran, and a lightweight before/after comparison of the
    element's label/value/focused state so you can tell if it actually took effect.
    """
    denied = _policy_guard("mac.ui", "perform_ui_action")
    if denied:
        return denied
    elem = _ax_resolve(ref)
    if elem is None:
        return _fail(f"Unknown or expired ref '{ref}'. Call get_ui_tree(...) again for a fresh ref.",
                     error_code="NOT_FOUND")
    if not AXIsProcessTrusted():
        return _fail("Accessibility permission not granted. Call get_session_state() for detail.",
                     error_code="PERMISSION")

    before = {"label": _ax_label(elem), "value": _ax_json_safe(_ax_get(elem, "AXValue")),
             "focused": _ax_json_safe(_ax_get(elem, "AXFocused"))}

    try:
        if action == "focus":
            err = AXUIElementSetAttributeValue(elem, "AXFocused", True)
            if err != 0:
                return _fail(f"Focus failed (AXError {err}). Element may not be focusable.",
                             error_code="EXEC_ERROR", ax_error=err)
        elif action == "set_value":
            if value is None:
                return _fail("action='set_value' requires value=", error_code="INVALID_PARAM")
            err = AXUIElementSetAttributeValue(elem, "AXValue", value)
            if err != 0:
                return _fail(f"Set value failed (AXError {err}). Element may be read-only.",
                             error_code="EXEC_ERROR", ax_error=err)
        else:
            ax_action = AX_ACTION_ALIASES.get(action, action)
            available = _ax_action_names(elem)
            if ax_action not in available:
                return _fail(
                    f"'{ax_action}' is not available on this element. Available actions: {available or 'none'}.",
                    error_code="INVALID_PARAM")
            err = AXUIElementPerformAction(elem, ax_action)
            if err != 0:
                return _fail(f"Action '{ax_action}' failed (AXError {err}).",
                             error_code="EXEC_ERROR", ax_error=err)
    except Exception as e:
        return _fail(f"Action failed: {e}", error_code="EXEC_ERROR")

    time.sleep(0.1)  # let the app process the action before re-reading state
    after = {"label": _ax_label(elem), "value": _ax_json_safe(_ax_get(elem, "AXValue")),
             "focused": _ax_json_safe(_ax_get(elem, "AXFocused"))}
    changed = {k: {"before": before[k], "after": after[k]}
              for k in before if before[k] != after[k]}

    return _ok(f"Performed '{action}' on {ref}", changed=changed, current_state=after)


def get_screen_text(screenshot: bool = False) -> Dict[str, Any]:
    """Read all text currently visible on screen using OCR, or capture a screenshot.

    Args:
        screenshot: If False (default), run OCR and return text elements with
                   coordinates. If True, skip OCR — capture a screenshot instead,
                   save it to a timestamped file on the Desktop, and return the
                   file path. Use screenshots when you need visual context that
                   OCR cannot capture (charts, images, custom UI graphics).

    Returns for screenshot=False: text_elements list with position data, full_text string.
    Returns for screenshot=True:  screenshot_path, width, height.

    COORDINATE NOTE: All position values returned are in LOGICAL screen coordinates
    (matching what mouse_action() expects). On Retina displays, these are half
    the raw pixel values. First OCR call is slow (~5s) due to EasyOCR model load.
    """
    denied = _policy_guard("mac.screenOcr", "get_screen_text")
    if denied:
        return denied
    screenshot_path: Optional[Path] = None
    if screenshot:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        requested_path = Path.home() / "Desktop" / f"orchestrator_screenshot_{ts}.png"
        screenshot_path, path_error = _path_guard(
            str(requested_path),
            "mac.files.write",
            "get_screen_text screenshot",
        )
        if path_error:
            return path_error
    try:
        ss = pyautogui.screenshot()

        if screenshot:
            save_path = str(screenshot_path)
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
        arr = screenshot_array(ss)
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
    denied = _policy_guard("mac.shell", "run_terminal_command")
    if denied:
        return denied
    timeout_seconds = max(1, min(timeout_seconds, 300))
    try:
        if run_in_background:
            _reap_background_processes()
            proc = subprocess.Popen(command, shell=True, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    start_new_session=not MANAGED_MODE)
            with _background_processes_lock:
                _background_processes[proc.pid] = proc
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
        if r.returncode != 0:
            return _fail(
                f"Command failed (exit {r.returncode})",
                error_code="EXEC_ERROR",
                stdout=stdout,
                stderr=stderr,
                exit_code=r.returncode,
                truncated=truncated,
                **extra,
            )
        return _ok("Command completed",
                   stdout=stdout, stderr=stderr, exit_code=r.returncode,
                   truncated=truncated, **extra)
    except subprocess.TimeoutExpired:
        return _fail(f"Command timed out after {timeout_seconds}s", error_code="TIMEOUT")
    except Exception as e:
        return _fail(f"Execution failed: {e}", error_code="EXEC_ERROR")


# ── 9. Spotlight File Search ─────────────────────────────────────────────────

def find_file(query: str, search_dir: str = "", file_type: str = "", sort_by: str = "", limit: int = 50, include_source: bool = False) -> Dict[str, Any]:
    """Find files using macOS Spotlight (mdfind) — millisecond results across the whole drive.

    Keyword matching only, NOT semantic. Use describe(topic="find_file_query_syntax")
    for the full query-style guide including Spotlight metadata queries like "kind:pdf".

    Args:
        query: Filename or content keyword, or a Spotlight metadata query (e.g. "kind:pdf").
        search_dir: Optional directory to scope the search.
        file_type: Optional extension filter (e.g. "pdf", "zip").
        sort_by: Optional sort order ("date_desc", "date_asc", "size_desc", "size_asc", "name_asc", "name_desc").
        limit: Max number of results to return (default 50).
        include_source: If True, fetches the source URL for each file. Slow — use with a low limit.
    """
    denied = _policy_guard("mac.files.read", "find_file")
    if denied:
        return denied
    if not query:
        return _fail("query is required")
    try:
        cmd = ["mdfind"]
        if search_dir:
            expanded, path_error = _path_guard(search_dir, "mac.files.read", "find_file")
            if path_error:
                return path_error
            if not expanded.is_dir():
                return _fail(f"Not a directory: {expanded}", error_code="NOT_FOUND")
            cmd.extend(["-onlyin", str(expanded)])
        elif _runtime().snapshot.control_profile == "guided":
            return _fail(
                "Guided file search requires an explicit approved search directory.",
                error_code="POLICY_DENIED",
                capability="mac.files.read",
            )
        
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
                canonical, path_error = _path_guard(p, "mac.files.read", "find_file result")
                if path_error:
                    return path_error
                st = os.stat(canonical)
                item = {
                    "path": str(canonical),
                    "name": canonical.name,
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

def vector_search(query: str) -> Dict[str, Any]:
    """Perform a semantic/vector search across indexed files.

    This queries the configured indexing backend for files matching the meaning of
    the query, even if the exact keywords are not present. Readiness and credentials
    are supplied by Mac Orchestrator; this function never reads product config files.

    Args:
        query: The search query or question.
    """
    denied = _policy_guard("meridian.search", "vector_search")
    if denied:
        return denied
    if not query:
        return _fail("query is required")
    if not isinstance(query, str) or len(query) > 2_000 or "\x00" in query:
        return _fail("query is invalid", error_code="INVALID_PARAM")
    if (
        query.startswith("/")
        or query.startswith("~")
        or "\\" in query
        or re.match(r"^[A-Za-z]:/", query)
        or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", query)
        or any(segment in {".", ".."} for segment in query.split("/"))
    ):
        return _fail("query is invalid", error_code="INVALID_PARAM")

    worker_url = _runtime().secrets.worker_url
    token = _runtime().secrets.meridian_ingest_token
    parsed_base = _valid_meridian_base_url(worker_url)
    if parsed_base is None or not token:
        return _fail(
            "Meridian search credentials were not supplied by Mac Orchestrator.",
            error_code="NOT_CONFIGURED",
        )

    base_path = parsed_base.path.rstrip("/")
    url = f"{parsed_base.scheme.lower()}://{parsed_base.netloc}{base_path}{_MERIDIAN_CONTROL_ROUTE}"
    expected = urlsplit(url)
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    try:
        resp = requests.post(
            url,
            json={"query": query, "top_k": 10},
            headers=headers,
            timeout=8,
            allow_redirects=False,
        )
    except requests.Timeout:
        return _fail("Meridian search timed out.", error_code="TIMEOUT")
    except requests.RequestException:
        return _fail("Meridian search is temporarily unavailable.", error_code="REMOTE_UNAVAILABLE")
    except Exception:
        return _fail("Meridian search failed safely.", error_code="REMOTE_ERROR")

    response_url = getattr(resp, "url", None)
    if not response_url:
        return _fail("Meridian search response origin was unavailable.", error_code="REDIRECT_BLOCKED")
    try:
        actual = urlsplit(str(response_url))
        actual_port = actual.port
    except (TypeError, ValueError):
        return _fail("Meridian search redirect was blocked.", error_code="REDIRECT_BLOCKED")
    if (
        actual.scheme.lower() != expected.scheme.lower()
        or (actual.hostname or "").lower() != (expected.hostname or "").lower()
        or actual_port != expected.port
        or actual.username is not None
        or actual.password is not None
        or actual.query
        or actual.fragment
        or actual.path.rstrip("/") != expected.path.rstrip("/")
    ):
        return _fail("Meridian search redirect was blocked.", error_code="REDIRECT_BLOCKED")
    if 300 <= getattr(resp, "status_code", 0) < 400:
        return _fail("Meridian search redirect was blocked.", error_code="REDIRECT_BLOCKED")
    if getattr(resp, "status_code", 0) != 200:
        status = getattr(resp, "status_code", 0)
        code = "REMOTE_UNAUTHORIZED" if status in {401, 403} else (
            "REMOTE_UNAVAILABLE" if status in {408, 429, 500, 502, 503, 504} else "REMOTE_ERROR"
        )
        return _fail("Meridian search returned an unusable response.", error_code=code)
    try:
        body = resp.json()
    except Exception:
        return _fail("Meridian search returned malformed JSON.", error_code="INVALID_RESPONSE")
    if not isinstance(body, Mapping) or set(body) - {"results"} or not isinstance(body.get("results"), list):
        return _fail("Meridian search returned an invalid result shape.", error_code="INVALID_RESPONSE")

    safe_results: list[dict[str, Any]] = []
    for raw in body["results"][:50]:
        if not isinstance(raw, Mapping):
            return _fail("Meridian search returned an invalid result.", error_code="INVALID_RESPONSE")
        identifier = raw.get("id")
        score = raw.get("score")
        source_id = raw.get("sourceId")
        generation = raw.get("generation")
        ordinal = raw.get("ordinal")
        relative_path = raw.get("relativePath")
        display_name = raw.get("displayName")
        snippet = raw.get("snippet")
        if (
            not isinstance(identifier, str) or not re.fullmatch(r"[0-9a-f]{64}", identifier)
            or (score is not None and (isinstance(score, bool) or not isinstance(score, (int, float)) or not math.isfinite(score)))
            or not isinstance(source_id, str) or not _MERIDIAN_SAFE_ID.fullmatch(source_id)
            or not isinstance(generation, str) or not _MERIDIAN_SAFE_GENERATION.fullmatch(generation)
            or isinstance(ordinal, bool) or not isinstance(ordinal, int) or not 0 <= ordinal <= 1_000_000_000
            or not isinstance(relative_path, str) or not _safe_meridian_relative_path(relative_path)
            or not isinstance(display_name, str) or not _safe_meridian_display_name(display_name)
            or not isinstance(snippet, str) or len(snippet) > 1_000 or "\x00" in snippet
        ):
            return _fail("Meridian search returned an invalid result.", error_code="INVALID_RESPONSE")
        safe_results.append({
            "id": identifier,
            "score": score,
            "sourceId": source_id,
            "generation": generation,
            "ordinal": ordinal,
            "relativePath": relative_path,
            "displayName": display_name,
            "snippet": snippet,
        })
    return _ok("Meridian semantic search completed.", results=safe_results)


def _safe_meridian_relative_path(value: str) -> bool:
    return bool(
        value
        and len(value) <= 512
        and not value.startswith(("/", "~", "./"))
        and not value.endswith("/")
        and "\\" not in value
        and "\x00" not in value
        and "//" not in value
        and "://" not in value
        and not any(part in {".", ".."} for part in value.split("/"))
    )


def _safe_meridian_display_name(value: str) -> bool:
    return bool(
        value
        and len(value) <= 255
        and "\x00" not in value
        and "/" not in value
        and "\\" not in value
        and value not in {".", ".."}
    )

# ── 10. File I/O ─────────────────────────────────────────────────────────────

def read_file(path: str, preview: bool = False, preview_size_kb: int = 1, preview_lines: Optional[int] = None) -> Dict[str, Any]:
    """Read a file's contents.

    Args:
        path: Absolute or ~-relative path to the file.
        preview: If True, returns only the head and tail of the file to save context window.
        preview_size_kb: Size in KB to read from both head and tail in preview mode (default 1).
        preview_lines: If provided, returns the first N and last N lines using native tools.
    """
    p, path_error = _path_guard(path, "mac.files.read", "read_file")
    if path_error:
        return path_error
    try:
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

def write_file(path: str, content: str, mode: str = "overwrite") -> Dict[str, Any]:
    """Write content to a file.

    Args:
        path: Absolute or ~-relative file path. Parent dirs created automatically.
        content: The text content to write.
        mode: "overwrite" (default) replaces file contents entirely.
              "append" adds content to the end of an existing file (creates if absent).
    """
    p, path_error = _path_guard(path, "mac.files.write", "write_file")
    if path_error:
        return path_error
    try:
        os.makedirs(p.parent, exist_ok=True)
        file_mode = "a" if mode == "append" else "w"
        with open(p, file_mode, encoding="utf-8") as f:
            f.write(content)
        verb = "Appended" if mode == "append" else "Wrote"
        return _ok(f"{verb} {len(content)} chars to {p}")
    except Exception as e:
        return _fail(f"Write failed: {e}")

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
    p, path_error = _path_guard(path, "mac.files.read", "list_directory")
    if path_error:
        return path_error
    try:
        if not p.is_dir():
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
                        _, entry_error = _path_guard(
                            entry.path, "mac.files.read", "list_directory entry"
                        )
                        if entry_error:
                            return entry_error
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
                _, entry_error = _path_guard(
                    entry.path, "mac.files.read", "list_directory entry"
                )
                if entry_error:
                    return entry_error
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
    d, path_error = _path_guard(directory, "mac.files.read", "smart_search")
    if path_error:
        return path_error
    try:
        if not d.is_dir():
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
            kept_dirs = []
            for dirname in dirs:
                if dirname.startswith('.') or dirname in ignore:
                    continue
                _, entry_error = _path_guard(
                    os.path.join(root, dirname),
                    "mac.files.read",
                    "smart_search directory entry",
                )
                if entry_error:
                    return entry_error
                kept_dirs.append(dirname)
            dirs[:] = kept_dirs
            for fname in files:
                if fname.startswith('.'):
                    continue
                if file_extension_filter and not fname.endswith(file_extension_filter):
                    continue
                fp = os.path.join(root, fname)
                canonical, entry_error = _path_guard(
                    fp, "mac.files.read", "smart_search file entry"
                )
                if entry_error:
                    return entry_error
                try:
                    with open(canonical, "r", encoding="utf-8") as f:
                        lines = f.readlines()
                    matches = []
                    for i, line in enumerate(lines):
                        if pat.search(line):
                            matches.append({"line": i + 1, "content": line.strip()})
                    if matches:
                        entry = {"file": str(canonical), "matches": matches}
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

def play_sound_for_user_prompt() -> Dict[str, Any]:
    """Play the macOS system bell sound to alert the user."""
    try:
        r = subprocess.run(["osascript", "-e", "beep"], capture_output=True, text=True, timeout=5)
        if r.returncode != 0:
            return _fail(f"Bell failed: {r.stderr.strip()}")
        return _ok("System bell played")
    except Exception as e:
        return _fail(f"Failed: {e}")

def clipboard(action: str, content: str = "") -> Dict[str, Any]:
    """Read the macOS clipboard; mutation is available only when policy allows it.

    Args:
        action: "get" to read clipboard contents, "set" to request a clipboard write.
        content: Text to write to clipboard. Required for action="set".
                Ignored for action="get". Supports all Unicode characters.

    Note: Only text content is accessible. Images or files in the clipboard
    will return an empty string from "get".
    """
    if action not in ("get", "set"):
        return _fail(f"Invalid action '{action}'. Use 'get' or 'set'.", error_code="INVALID_PARAM")
    if action == "set":
        try:
            _runtime().policy.authorize_clipboard_mutation("clipboard set")
        except PolicyDenied as exc:
            return _fail(str(exc), error_code="POLICY_DENIED", capability="mac.clipboard.write")
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

def send_file_to_telegram(file_path: str, caption: str = "") -> Dict[str, Any]:
    """Send a file to the user via Telegram.

    Args:
        file_path: Path to the file to send.
        caption: Optional caption for the file.
    """
    denied = _policy_guard("telegram.send", "send_file_to_telegram")
    if denied:
        return denied
    p, path_error = _path_guard(file_path, "mac.files.read", "send_file_to_telegram file")
    if path_error:
        return path_error
    secrets = _runtime().secrets
    if not secrets.telegram_bot_token or not secrets.telegram_chat_id:
        return _fail(
            "Telegram credentials were not supplied by Mac Orchestrator.",
            error_code="NOT_CONFIGURED",
        )
    try:
        if not p.exists():
            return _fail(f"File not found: {p}")
        sz = p.stat().st_size
        if sz > 50 * 1024 * 1024:
            return _fail(f"File too large ({sz / 1048576:.1f}MB > 50MB limit)")
        url = f"https://api.telegram.org/bot{secrets.telegram_bot_token}/sendDocument"
        with open(p, "rb") as f:
            data = {"chat_id": secrets.telegram_chat_id}
            if caption:
                data["caption"] = caption
            resp = requests.post(url, data=data, files={"document": f}, timeout=60)
        if resp.status_code == 200:
            return _ok(f"Sent '{os.path.basename(p)}' to Telegram")
        return _fail(f"Telegram API error ({resp.status_code}).")
    except Exception:
        return _fail("Telegram request failed.")


# ═══════════════════════════════════════════════════════════════════════════════
#  SERVER SETUP & MAIN
# ═══════════════════════════════════════════════════════════════════════════════

console = Console()

def setup_telegram(interactive: bool = False) -> bool:
    """Return whether explicit in-memory Telegram credentials are available.

    The old interactive/config-file persistence path is intentionally gone.
    Swift supplies managed credentials through the dedicated child environment
    variables documented by RuntimeSecrets; local development uses the same
    environment-only contract.
    """
    secrets = _runtime().secrets
    return bool(secrets.telegram_bot_token and secrets.telegram_chat_id)


def _bind_tool(fn: Callable[..., Any], runtime: ServerRuntime) -> Callable[..., Any]:
    """Bind one immutable runtime to a tool without changing its MCP signature."""
    @functools.wraps(fn)
    def bound(*args, **kwargs):
        token = _RUNTIME_CONTEXT.set(runtime)
        try:
            return fn(*args, **kwargs)
        finally:
            _RUNTIME_CONTEXT.reset(token)

    return bound


def _session_tool_description(snapshot: CapabilitySnapshot) -> str:
    return (
        "Inspect active-console/lock state and current Accessibility and Screen Recording "
        "permission observations before UI work. Capability and policy availability is "
        "reported by get_capabilities()."
    )


def _screen_size_tool_description(snapshot: CapabilitySnapshot) -> str:
    return (
        "Get logical and physical screen dimensions for coordinate-aware UI work. "
        "Use logical coordinates for mouse actions."
    )


def _ui_tree_tool_description(snapshot: CapabilitySnapshot) -> str:
    return (
        "Inspect the macOS Accessibility tree and return stable refs for precise UI actions. "
        "Use role_filter, actionable_only, and pagination to keep inspection focused."
    )


def _type_tool_description(snapshot: CapabilitySnapshot) -> str:
    clipboard_note = (
        "Clipboard fallback for Unicode is allowed by the current policy."
        if snapshot.policy.clipboard_mutation and snapshot.is_ready("mac.clipboard.write")
        else "If clipboard mutation would be required (for example Unicode fallback), the call returns POLICY_DENIED."
    )
    return (
        "Type text into the focused input field using direct key synthesis when possible. "
        + clipboard_note
    )


def _clipboard_tool_description(snapshot: CapabilitySnapshot) -> str:
    if snapshot.policy.clipboard_mutation and snapshot.is_ready("mac.clipboard.write"):
        return "Read or set the macOS text clipboard; clipboard mutation is enabled by the current policy."
    return (
        "Read the macOS text clipboard. Clipboard mutation is disabled by the current policy; "
        "action='set' returns POLICY_DENIED."
    )


def _find_file_tool_description(snapshot: CapabilitySnapshot) -> str:
    description = (
        "Find files using macOS Spotlight keyword and metadata queries. In Guided Control, "
        "provide an explicit approved search directory."
    )
    if snapshot.is_ready("meridian.search"):
        description += " Semantic search is available through the registered Meridian tool."
    return description


def _describe_tool_description(snapshot: CapabilitySnapshot) -> str:
    topics = ", ".join(sorted(_describe_topics(snapshot)))
    return (
        "Get detailed guidance for the capability groups registered by this server. "
        f"Available topics in this snapshot: {topics}."
    )


def _file_tool_description(snapshot: CapabilitySnapshot, operation: str) -> str:
    boundary = (
        " In Guided Control, the path must resolve inside an approved file root."
        if snapshot.control_profile == "guided"
        else " Full Control permits broader paths when the capability is ready."
    )
    return f"{operation}.{boundary}"


def _telegram_tool_description(snapshot: CapabilitySnapshot) -> str:
    return (
        "Send a file through the user-configured Telegram integration. "
        "The file must pass the current file-read and path policy."
    )


def _screen_text_tool_description(snapshot: CapabilitySnapshot) -> str:
    return (
        "Read visible screen text with OCR. screenshot=True captures a screenshot only when "
        "the file-write capability and path policy authorize the destination."
    )


def build_mcp(
    validated_snapshot: CapabilitySnapshot,
    secrets: Optional[RuntimeSecrets] = None,
) -> FastMCP:
    """Construct one isolated FastMCP server from a validated capability snapshot."""
    if not isinstance(validated_snapshot, CapabilitySnapshot):
        raise TypeError("build_mcp requires a validated CapabilitySnapshot")
    runtime = ServerRuntime(
        validated_snapshot,
        secrets if secrets is not None else RuntimeSecrets.from_environment(),
    )
    server = FastMCP(
        "AutoMac MCP - macOS UI Automation",
        host="127.0.0.1",
        port=SERVER_PORT,
        streamable_http_path=MCP_PATH,
        transport_security=transport_security,
        instructions=build_server_instructions(validated_snapshot),
    )
    server.custom_route("/__mac_orchestrator_health", methods=["GET"])(_health_check)

    def add(fn: Callable[..., Any], *, description: Optional[str] = None) -> None:
        server.add_tool(_bind_tool(fn, runtime), description=description)

    # Orientation and harmless local diagnostics are always visible after the
    # snapshot itself has been validated.
    add(describe, description=_describe_tool_description(validated_snapshot))
    add(get_capabilities)
    add(get_session_state, description=_session_tool_description(validated_snapshot))
    add(play_sound_for_user_prompt)
    add(clipboard, description=_clipboard_tool_description(validated_snapshot))

    if validated_snapshot.is_ready("mac.ui"):
        for fn in (
            get_available_apps,
            get_screen_size,
            get_screen_layout,
            get_ui_tree,
            focus_app,
            press_keystroke,
            type_text,
            mouse_action,
            scroll,
            perform_ui_action,
        ):
            if fn is get_screen_size:
                add(fn, description=_screen_size_tool_description(validated_snapshot))
            elif fn is get_ui_tree:
                add(fn, description=_ui_tree_tool_description(validated_snapshot))
            elif fn is type_text:
                add(fn, description=_type_tool_description(validated_snapshot))
            else:
                add(fn)
        add(execute_macro, description=_macro_actions_text(validated_snapshot))

    if validated_snapshot.is_ready("mac.screenOcr"):
        add(get_screen_text, description=_screen_text_tool_description(validated_snapshot))

    if validated_snapshot.is_ready("mac.shell"):
        add(run_terminal_command)

    if validated_snapshot.is_ready("mac.files.read"):
        add(find_file, description=_find_file_tool_description(validated_snapshot))
        add(read_file, description=_file_tool_description(validated_snapshot, "Read a file"))
        add(list_directory, description=_file_tool_description(validated_snapshot, "List a directory"))
        add(smart_search, description=_file_tool_description(validated_snapshot, "Run Local Pattern Search"))

    if validated_snapshot.is_ready("mac.files.write"):
        add(write_file)

    if validated_snapshot.is_ready("telegram.send"):
        add(send_file_to_telegram, description=_telegram_tool_description(validated_snapshot))

    if validated_snapshot.is_ready("meridian.search"):
        add(vector_search)

    return server


# The default runtime is the only server process actually served. Tests and
# callers can create additional isolated FastMCP instances through build_mcp.
mcp = build_mcp(DEFAULT_SNAPSHOT, DEFAULT_SECRETS)
SERVER_INSTRUCTIONS = build_server_instructions(DEFAULT_SNAPSHOT)

# NOTE: there is deliberately no interactive "expose via ngrok" flow here.
# That used to live in a setup_ngrok() function called from main() for
# unmanaged/interactive runs, defaulting the exposure prompt to "yes" and
# mounting the plain, tokenless /mcp path. FastMCP's own loopback default
# (transport_security=None -> Host/Origin allowlist restricted to
# 127.0.0.1/localhost) meant that path never actually worked end-to-end
# through a tunnel (see SECURITY.md), but it was misleading and an easy
# thing to accidentally fix into a real hole later. Public ingress is only
# wired through the Swift supervisor's managed mode, which always mounts a
# random capability token. Advanced users who want to run a tunnel by hand
# against an unmanaged server must opt in to both things that make that
# safe-ish themselves: export MAC_ORCHESTRATOR_CONNECTOR_TOKEN (mounts
# /<token>/mcp instead of plain /mcp) *and* MAC_ORCHESTRATOR_MANAGED=1
# (disables the loopback-only Host/Origin allowlist that would otherwise
# reject tunnelled requests — see SECURITY.md), then run their own tunnel
# tool pointed at the port. This file does neither implicitly.

def main():
    if "--permission-probe" in sys.argv:
        # This is intentionally a child-process probe. TCC decisions are
        # identity-sensitive, so Swift preflight alone is not authoritative
        # for the managed Python server that actually performs UI work.
        result = get_session_state()
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return

    owner = ""
    if "--managed-owner" in sys.argv:
        try:
            owner = sys.argv[sys.argv.index("--managed-owner") + 1]
        except IndexError:
            raise SystemExit("--managed-owner requires a value")

    if MANAGED_MODE:
        # Make the server the leader of a process group. The native supervisor
        # can then terminate this server and every command child it owns without
        # touching unrelated processes.
        try:
            os.setpgrp()
        except OSError:
            pass
        logging.getLogger("uvicorn.access").disabled = True

    console.print(Panel.fit(
        "[bold magenta]Mac Orchestrator[/bold magenta]\n"
        "Your local MCP server for macOS UI automation.",
        border_style="magenta"
    ))
    if MANAGED_MODE:
        console.print("\n[bold green]Mac Orchestrator is starting in managed mode.[/bold green]")
        console.print("The authenticated connector URL is available from the menu-bar app.")
    else:
        console.print("\n[bold green]Mac Orchestrator is starting locally.[/bold green]")
        console.print(f"🔗 [bold underline cyan]http://localhost:{SERVER_PORT}{MCP_PATH}[/bold underline cyan]")
        if not CONNECTOR_TOKEN:
            console.print(
                "[dim]Loopback only — this process does not expose itself to the "
                "public internet. See SECURITY.md for the managed-mode connector "
                "flow if you need remote access.[/dim]"
            )
    console.print("\n[dim]Press Ctrl+C to stop the server[/dim]\n")
    try:
        mcp.run(transport="streamable-http")
    except KeyboardInterrupt:
        pass
    finally:
        console.print("\n[yellow]Shutting down...[/yellow]")
        cleanup_background_processes()

if __name__ == "__main__":
    main()
