# Phase 5F Independent Review Record

Reviewed branch: `phase5f/mac-meridian-product-hardening`

Reviewed starting SHA: `66978e1df84f0b66653293b79f66828b11b53559`

Required Phase 5C ancestor: `48f19fbbcfeb0c8cbe77486237342704f4dbbeb6`

Meridian contract: `544604255b70e1c0d2be9435e69e6e965074318d`

## Confirmed defects and bounded fixes

1. `vector_search()` rejected legitimate semantic query text beginning with a
   URL or filesystem path. The path/URL heuristic was removed; type, length,
   NUL, remote-origin, response-shape, metadata, timeout, redirect, and safe
   error validation remain. Regression coverage exercises `https://example.com`,
   `/usr/bin`, and `C:/docs`.
2. The native status-menu flow had no normal-user path to provide the required
   Meridian Core credential. A secure text prompt now stores a normalized value
   through the existing Keychain store and reloads the managed runtime without
   persisting or displaying the secret. Keychain tests cover canonical storage
   and rejection of blank/control-bearing input.
3. A manual Meridian action requested while paused was silently lost on Resume.
   Resume now runs the queued action once; the scheduler remains one-shot,
   generation-fenced, and non-overlapping. A focused scheduler regression test
   covers this path.

No other source changes were made for review activity.

## Verification

- ancestry includes the Phase 5C candidate;
- Python capability/policy suite: 37 tests passed locally;
- `swift build`: passed locally;
- hosted XCTest and required CI remain authoritative because this environment's
  Command Line Tools installation cannot resolve the XCTest module;
- the existing Phase 5F checks cover readiness evidence, tool digest pinning,
  secret partitioning, lifecycle, Doctor, support redaction, and thin-client
  architecture;
- no merge, tag, release, auto-merge, or Phase 6 work is part of this review.

The exact final tree SHA is the immutable pushed branch head reported in the
Phase 5 closeout after the final exact-head hosted CI run.
