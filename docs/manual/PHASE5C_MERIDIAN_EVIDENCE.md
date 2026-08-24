# Phase 5C Meridian Mac evidence

This document keeps deterministic consumer evidence separate from observations
that require a real Mac, an installed optional tool, or a live Meridian Core.

## Automated evidence

- `swift build` and `swift build -c release` compile the native consumer.
- `swift test` covers configuration, invocation, optional-tool digest/promotion,
  progress redaction, no-overlap, cancellation, and lifecycle seams when a
  full XCTest-capable Xcode toolchain is available.
- Static scans confirm that the Mac core payload has no Meridian indexer source,
  Node dependency, token, provider body, vector, or personal resource.
- Tests assert that Core-facing data is produced by the canonical Meridian
  executable boundary and that Mac only retains bounded outcome metadata.

## Toolchain-blocked evidence

The local Command Line Tools checkout may be able to run `swift build` while
failing `swift test` because XCTest is unavailable to dependency scanning. That
is an environment limitation, not a production-code bypass. Hosted macOS CI or
full Xcode is required for the authoritative XCTest result.

## Manual evidence still required

On a clean arm64 Mac with the separately distributed Meridian executable:

1. Verify the executable's release digest and normal Gatekeeper/signing state.
2. Install it through the optional boundary and confirm a failed candidate
   leaves `indexer.previous` usable.
3. Configure one explicit root and selected relative file/folder paths. Confirm
   no default home-directory scan occurs.
4. Run against a test Core deployment using a test token. Confirm Core receives
   opaque source IDs and relative paths only, and that the prior generation
   remains searchable after an interrupted or failed replacement.
5. Exercise cancellation, retry, rebuild, empty files, unsupported/encrypted/
   unreadable files, URL/auth failures, and a state-write/reconciliation
   failure. Review logs and support output for absence of tokens, document
   contents, vectors, provider bodies, personal identifiers, and absolute roots.
6. Verify scheduled execution after sleep/wake and that a second run cannot
   overlap the first.

No hosted CI job can prove these Gatekeeper, TCC, filesystem-selection,
provider, token, or live-replacement observations.
