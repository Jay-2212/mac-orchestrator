# Phase 5C Meridian Mac Integration Design

## Goal

Add the Mac Orchestrator consumer boundary for Meridian's optional one-shot
indexer without copying Meridian's indexer or adding its dependencies to the
base runtime. The Mac side owns optional-tool placement, user configuration,
scheduling, process invocation, cancellation, and lifecycle receipts.

## Boundaries

The canonical indexer remains the exact artifact from Meridian Phase 5,
installed separately below the user-owned Mac Orchestrator support directory:

```text
~/Library/Application Support/Mac Orchestrator/meridian/indexer
```

Mac Orchestrator validates and atomically promotes that executable, but does
not bundle Node, copy `src/indexer`, parse documents, hash content, derive
source IDs, call Core endpoints, or write the indexer's state file. A failed
optional-tool installation leaves the previous executable available.

The Mac configuration stores only explicit source scopes (`scopeID`, absolute
local root, and relative selections), Meridian's nonsecret HTTPS URL, and a
bounded schedule interval. Absolute roots remain local configuration inputs;
they are sent only over the child stdin invocation to the locally installed
indexer and never enter logs, progress, support artifacts, or remote IDs.

## Components and data flow

1. `MeridianIndexerConfiguration` validates explicit source selections and a
   bounded interval. It has no token or provider-resource fields.
2. `MeridianIndexerToolInstaller` verifies a caller-supplied candidate digest,
   regular-file/executable ownership, and stages it under the optional tool
   root before atomic promotion.
3. `MeridianIndexerInvocation` encodes the Meridian `1.0.0` stdin shape:
   `baseUrl`, `statePath`, and explicit sources. The state path is local-only.
4. `MeridianIndexerCoordinator` serializes one child process, writes the
   invocation once, injects `MERIDIAN_CORE_TOKEN` only into the child
   environment, reads bounded allow-listed progress/result events, and maps
   exit/cancel/retry/rebuild outcomes to a Mac lifecycle snapshot.
5. `ProcessSupervisor` reconciles the coordinator after launch/configuration
   changes and stops it during quit/maintenance. The existing MCP and remote
   connector lifecycle remains unchanged.

The canonical indexer performs begin → ordered ingest → commit and updates its
local state only after commit. Mac Orchestrator records the outcome but never
claims a successful replacement from process exit alone when the indexer
reports reconciliation-required.

## Failure and privacy rules

- Missing URL, token, executable, or explicit sources disables a run with a
  stable classification and no process launch.
- A second run is rejected as `run_in_progress`; a running process is never
  overlapped or replaced silently.
- Cancel terminates only the owned process, invalidates its generation fence,
  and preserves the last receipt. Retry repeats the same deterministic
  invocation; rebuild sets the Meridian rebuild flag without changing Mac
  source identity.
- stdout is capped per line and decoded only as known protocol events. Unknown,
  malformed, oversized, path-bearing, token-bearing, provider-body-bearing,
  or document-bearing lines are dropped. stderr is not persisted.
- Result statuses `completed`, `partial_failure`, `cancelled`, and
  `reconciliation_required` remain distinct. A nonzero result never replaces
  the prior successful receipt.

## Verification

Automated tests cover configuration validation/round trips, optional tool
digest and atomic-promotion behavior, exact invocation shape, no-path/no-token
progress receipts, no-overlap, cancellation, retry/rebuild, bounded output,
and scheduler behavior. Hosted CI proves Swift build/test and static hygiene.
Manual evidence remains separate for a real signed/notarized optional indexer,
Gatekeeper, TCC, user-selected files, live Core authentication, provider
quotas, and an end-to-end replacement.
