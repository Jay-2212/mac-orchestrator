#!/usr/bin/env python3

"""Deterministic get_ui_tree pagination tests.

These tests replace only the live AX provider boundary with dictionary-backed
elements.  The public get_ui_tree() entry point, traversal, continuation-token
handling, response schema, ref registration, and traversal budgets remain real.
"""

from contextlib import contextmanager
from unittest import TestCase, main
from unittest.mock import patch

import automac_mcp


PID = 4242


def _node(label, role="AXGroup", actions=(), children=()):
    return {
        "AXRole": role,
        "AXTitle": label,
        "AXActionNames": list(actions),
        "AXChildren": list(children),
    }


def _fixture_tree():
    """Return 12 deterministic nodes, including four nested actionable nodes."""
    window_one = _node(
        "window-1",
        role="AXWindow",
        children=[
            _node(
                "panel-1",
                children=[
                    _node("save", role="AXButton", actions=("AXPress",)),
                    _node("description", role="AXStaticText"),
                ],
            ),
            _node(
                "panel-2",
                children=[
                    _node(
                        "deep-container",
                        children=[
                            _node("target", role="AXButton", actions=("AXPress",)),
                        ],
                    ),
                ],
            ),
        ],
    )
    window_two = _node(
        "window-2",
        role="AXWindow",
        children=[
            _node(
                "panel-3",
                children=[
                    _node("next", role="AXButton", actions=("AXPress",)),
                    _node("label", role="AXStaticText"),
                ],
            ),
            _node("last", role="AXButton", actions=("AXPress",)),
        ],
    )
    return {"AXWindows": [window_one, window_two]}


def _semantic_sequence(nodes):
    """Flatten response nodes while deliberately ignoring per-call refs."""
    sequence = []
    for node in nodes:
        sequence.append((node["role"], node["label"], tuple(node["actions"])))
        sequence.extend(_semantic_sequence(node.get("children", [])))
    return sequence


@contextmanager
def _deterministic_ax_provider():
    """Install a dictionary-backed AX provider for one test."""
    app_element = _fixture_tree()

    def fake_ax_get(element, attribute):
        if isinstance(element, dict):
            return element.get(attribute)
        return None

    def fake_action_names(element):
        return list(element.get("AXActionNames", []))

    original_registry = dict(automac_mcp._ax_registry)
    original_order = list(automac_mcp._ax_registry_order)
    original_ref_seq = automac_mcp._ax_ref_seq
    automac_mcp._ax_registry.clear()
    automac_mcp._ax_registry_order.clear()
    automac_mcp._ax_ref_seq = 0
    try:
        with patch.object(automac_mcp, "ACCESSIBILITY_AVAILABLE", True), \
                patch.object(automac_mcp, "AXIsProcessTrusted", lambda: True), \
                patch.object(automac_mcp, "_resolve_app_pid", lambda app, pid: {"pid": PID}), \
                patch.object(automac_mcp, "AXUIElementCreateApplication", lambda pid: app_element), \
                patch.object(automac_mcp, "_ax_set_timeout", lambda element: None), \
                patch.object(automac_mcp, "_ax_get", fake_ax_get), \
                patch.object(automac_mcp, "_ax_action_names", fake_action_names), \
                patch.object(automac_mcp, "_ax_label", lambda element: element["AXTitle"]):
            yield
    finally:
        automac_mcp._ax_registry.clear()
        automac_mcp._ax_registry.update(original_registry)
        automac_mcp._ax_registry_order.clear()
        automac_mcp._ax_registry_order.extend(original_order)
        automac_mcp._ax_ref_seq = original_ref_seq


class GetUITreePaginationTests(TestCase):
    def _get(self, **kwargs):
        kwargs.setdefault("depth", 6)
        kwargs.setdefault("node_budget", 100)
        result = automac_mcp.get_ui_tree(
            app="Deterministic Fixture",
            **kwargs,
        )
        self.assertEqual(result.get("status"), "success", result)
        return result

    def _paginate(self, limit, **kwargs):
        pages = []
        token = None
        seen_tokens = set()
        while True:
            page_kwargs = {"limit": limit, **kwargs}
            if token is not None:
                page_kwargs["continuation_token"] = token
            page = self._get(**page_kwargs)
            pages.append(page)
            if not page["has_more"]:
                self.assertNotIn("continuation_token", page)
                break
            next_token = page.get("continuation_token")
            self.assertIsNotNone(next_token, page)
            self.assertNotIn(next_token, seen_tokens, page)
            if token is not None:
                self.assertGreater(int(next_token), int(token), page)
            seen_tokens.add(next_token)
            token = next_token
            self.assertLessEqual(len(pages), 20, "pagination did not terminate")
        return pages

    def test_tree_pagination_matches_stable_unpaginated_preorder(self):
        with _deterministic_ax_provider():
            baseline = self._get(limit=200)
            baseline_sequence = _semantic_sequence(baseline["elements"])
            self.assertEqual(len(baseline_sequence), 12)
            self.assertFalse(baseline["node_budget_exhausted"])

            pages = self._paginate(limit=3)
            paginated_sequence = [
                item
                for page in pages
                for item in _semantic_sequence(page["elements"])
            ]

            self.assertEqual(len(pages), 4)
            self.assertEqual([len(_semantic_sequence(page["elements"])) for page in pages], [3, 3, 3, 3])
            self.assertEqual(paginated_sequence, baseline_sequence)
            self.assertEqual(len(paginated_sequence), len(set(paginated_sequence)))
            self.assertTrue(all(page["has_more"] for page in pages[:-1]))
            self.assertFalse(pages[-1]["has_more"])

            repeated_sequence = [
                item
                for page in self._paginate(limit=3)
                for item in _semantic_sequence(page["elements"])
            ]
            self.assertEqual(repeated_sequence, baseline_sequence)

    def test_flat_actionable_pagination_discovers_nested_matches_after_boundary(self):
        with _deterministic_ax_provider():
            baseline = self._get(limit=200, actionable_only=True)
            baseline_sequence = _semantic_sequence(baseline["elements"])
            self.assertEqual(
                [label for _role, label, _actions in baseline_sequence],
                ["save", "target", "next", "last"],
            )

            pages = self._paginate(limit=2, actionable_only=True)
            paginated_sequence = [
                item
                for page in pages
                for item in _semantic_sequence(page["elements"])
            ]

            self.assertEqual(len(pages), 2)
            self.assertEqual(paginated_sequence, baseline_sequence)
            self.assertEqual(len(paginated_sequence), len(set(paginated_sequence)))
            self.assertTrue(pages[0]["has_more"])
            self.assertGreater(pages[0]["visited"], len(_semantic_sequence(pages[0]["elements"])))
            self.assertFalse(pages[-1]["has_more"])
            self.assertEqual(len(_semantic_sequence(pages[-1]["elements"])), 2)

    def test_flat_role_filter_preserves_the_same_match_order(self):
        with _deterministic_ax_provider():
            baseline = self._get(limit=200, role_filter=["AXButton"])
            pages = self._paginate(limit=2, role_filter=["AXButton"])
            sequence = [
                item
                for page in pages
                for item in _semantic_sequence(page["elements"])
            ]

            self.assertEqual(sequence, _semantic_sequence(baseline["elements"]))
            self.assertTrue(all(role == "AXButton" for role, _label, _actions in sequence))
            self.assertTrue(pages[0]["has_more"])
            self.assertFalse(pages[-1]["has_more"])

    def test_node_budget_exhaustion_is_distinct_from_page_limit(self):
        with _deterministic_ax_provider():
            result = self._get(limit=20, node_budget=3)

            self.assertEqual(result["visited"], 3)
            self.assertEqual(len(_semantic_sequence(result["elements"])), 3)
            self.assertTrue(result["node_budget_exhausted"])
            self.assertTrue(result["has_more"])
            self.assertEqual(result["continuation_token"], "3")

    def test_malformed_continuation_token_is_rejected(self):
        with _deterministic_ax_provider():
            result = automac_mcp.get_ui_tree(
                app="Deterministic Fixture",
                depth=6,
                limit=3,
                node_budget=100,
                continuation_token="not-an-integer",
            )

            self.assertEqual(result.get("status"), "error")
            self.assertEqual(result.get("error_code"), "INVALID_PARAM")


if __name__ == "__main__":
    main()
