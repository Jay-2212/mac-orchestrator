# Phase 5F Mac Meridian Product Hardening

## Scope

This change hardens the existing optional Meridian consumer in Mac Orchestrator
from the exact Phase 5C candidate commit `48f19fbbcfeb0c8cbe77486237342704f4dbbeb6`.
Meridian Core remains authoritative for its control protocol, compatibility
checks, diagnostics, migrations, indexing, search, and destructive data scope.
Mac Orchestrator owns local configuration, explicit source selection, process
lifecycle, scheduling, capability projection, Doctor presentation, and support
privacy.

The frozen Core contract is consumed from Meridian SHA
`544604255b70e1c0d2be9435e69e6e965074318d`. Mac does not duplicate Core HTTP,
schema, migration, or search logic.

## Readiness proof

`meridian.search` is ready only when the existing capability/readiness
architecture has all of the following bounded evidence:

1. Meridian is explicitly enabled and has at least one validated explicit
   source selection.
2. The deployment URL is structurally valid HTTPS and the Core credential is
   present in Keychain.
3. The installed optional indexer is a regular, executable, owned tool whose
   SHA-256 matches the pinned receipt and whose control protocol is the frozen
   `1.0.0` contract.
4. A real user-selected `index` or `rebuild` action completed with a trusted
   final control result.
5. A live Meridian-owned `probe` completed successfully. The probe owns
   authenticated version, diagnostics, D1/Vectorize/Workers AI, migration,
   compatibility, synthetic ingest, semantic search, and cleanup checks.

The receipt stores only bounded classifications, timestamps, versions, and
digests. It never stores tokens, URLs, roots, selected paths, document text,
vectors, provider bodies, or probe content. A changed deployment identity or
tool digest invalidates the old proof until the live probe succeeds again.

## Control and lifecycle

The existing one-shot process seam sends one JSON request containing the frozen
`control_version`, `action`, `baseUrl`, `statePath`, and explicit `sources`.
Preview, index, rebuild, probe, source deletion, and data deletion all use the
same Meridian-owned executable. Exit status is not sufficient evidence of
success; a bounded, validated final result is required. Cancellation remains a
distinct outcome.

The existing lifecycle scheduler owns one-shot callbacks. User-facing schedule
modes are manual, every six hours, and daily; the enabled default is every six
hours, while the whole Meridian integration remains disabled until explicitly
configured. A scheduled callback is fenced by generation and desired state.
Wake handling produces at most one missed-run execution, never overlaps an
active run, and cannot resurrect a disabled or stale callback. Retry is explicit
and does not create a generic retry storm. Dynamic progress is kept out of the
managed launch contract.

## Runtime secret boundary

The Core token is held only in memory and injected into the optional indexer
process. The Python MCP receives its semantic-search token and deployment URL
only when `meridian.search` is actually ready. It is not present in capability
snapshots, unrelated child environments, logs, support bundles, or persisted
receipts. Python calls only the frozen `/api/v1/search` route with a bounded
timeout, redirect protection, response validation, and safe error classes.

## Product surface

The existing native status-menu/AppKit surface gains a compact Meridian section:
explicit Configure Sources / Choose Folders, preview, Scan Now, schedule
selection, pause/resume, retry, rebuild, source deletion, and Delete All
Meridian Data with clear confirmation. No default Desktop, Documents,
Downloads, home-directory, or silent expansion is allowed. Delete All targets
indexed document data through Meridian's exact control contract and never
Cloudflare infrastructure. Disabling cancels local scheduling/runs and removes
the semantic capability without deleting cloud data.

## Doctor and support

The existing Doctor remains read-only and reports bounded PASS/WARN/FAIL/SKIP
facts for Meridian configuration, explicit sources, credentials, tool trust,
Core compatibility/diagnostics, last successful index, semantic probe,
scheduler/overlap, and reconciliation. It does not run mutating probes, delete
data, rotate credentials, or delete infrastructure. Disabled Meridian checks
skip without token or network access.

Support output is adversarially redacted and excludes absolute Meridian roots,
private selected paths, document text, vectors, tokens, provider bodies, raw
errors, synthetic probe content, and credential-bearing temporary files. Only
bounded status metadata is eligible for inclusion.

## Verification

Tests cover exact protocol encoding and result validation, readiness proof and
stale-receipt invalidation, schedule/wake/cancellation fences, secret
partitioning, Python search behavior, capability transitions, Doctor read-only
behavior, and support-bundle privacy. Local Swift XCTest availability is
reported separately from hosted macOS CI, which is authoritative for XCTest.
