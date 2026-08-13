# Phase 4B Remote Credential and State Transactions

## Goal

Add security-sensitive, independently testable primitives for connector capability-token rotation, ngrok authtoken candidate replacement, and nonsecret remote-connector state persistence without changing `AppConfiguration` or wiring production lifecycle/UI layers.

## Scope and boundaries

- The implementation starts from `584259c44370d7d83f3a2764c94518b862a3c4ff` on `phase4/credential-recovery`.
- `AppConfiguration` remains schema v1. Remote operational state is a separate `RemoteConnectorStateV1` file.
- `ProcessSupervisor`, lifecycle state, activation probes, ngrok support, capability coordination, terminal/menu/diagnostic/repair code, updater/uninstaller/release code, and Meridian remain unchanged.
- No live credential rotation, provider mutation, endpoint deletion, account mutation, or resource cleanup is performed.

## State model and store

`RemoteConnectorStateV1` is a strict `Codable` model with only nonsecret fields:

- exact state schema version;
- provider identifier (`ngrok`);
- connector credential generation;
- optional pending connector generation and a recovery phase (`stable`, `cutoverPendingValidation`, `degraded`);
- validated bare public HTTPS origin/hostname;
- last successful remote probe timestamp;
- last remote result classification;
- last connector handoff generation.

The model has no URL, token, credential, request-body, or arbitrary dictionary fields. `RemotePublicOrigin` rejects user-info, path, query, fragment, whitespace, and non-HTTPS URL forms. Decoding rejects unknown keys and unsupported schema versions.

`RemoteConnectorStateStore` writes `remote-connector-state-v1.json` below `ConfigurationStore.defaultDirectoryURL()`. Before every read/write it validates every existing path component with `lstat`, rejects unsafe symlinks and non-directory ancestors, verifies the current user owns the store directory/file, and requires `0700`/`0600` permissions. It creates an exclusive private temporary file in the same directory, writes and synchronizes it, atomically renames it, synchronizes the directory, and removes temporary state files on normal completion. Temporary state data is nonsecret; no credential is ever written to a file.

The store serializes access with a lock and rejects provider changes or generation regressions. A pending generation is persisted before connector Keychain cutover. If the process stops after cutover, the pending/degraded state is interpreted as not-ready and requires forward recovery; the old token is never restored.

## Keychain seams

`KeychainStore` remains the existing named-item facade and receives only minimal additions:

- an injected `SecureRandomByteGenerating` seam for deterministic tests;
- `generateConnectorToken()` that returns a 32-byte lowercase hexadecimal token without persistence;
- `replaceConnectorToken(expectedCurrent:with:)` that compare-checks and updates the single canonical Keychain item, never creating a second accepted connector token;
- `replaceNgrokAuthtoken(expectedCurrent:with:)` for explicit candidate commit, plus local deletion through the existing Keychain client for compromised-old fail-closed handling.

All new Keychain and transaction errors contain only fixed safe categories/statuses. Secret values are not embedded in `Error`, `LocalizedError`, result, state, or log text.

## Connector capability-token rotation

The engine receives a `KeychainStore`, `RemoteConnectorStateStore`, and protocol-driven lifecycle hooks. Hooks are synchronous at this layer so Phase 4D can adapt its asynchronous supervisor/probe machinery without coupling this primitive to `ProcessSupervisor`.

The engine performs:

```text
stable state
  -> validate prerequisites
  -> generate fresh token in memory
  -> persist pending generation
  -> compare-and-replace canonical Keychain token
  -> restart local MCP with new token
  -> validate canonical local activation
  -> validate old local route is rejected
  -> reconcile remote endpoint
  -> validate authenticated remote readiness with new token
  -> validate old remote route is rejected
  -> persist stable/new generation/handoff/ready state
```

The canonical Keychain update is irreversible for this transaction. Before cutover failures leave the old token canonical. After cutover failures persist best-effort degraded state, keep the new token canonical, and never call a rollback API. The old token is held only in a bounded local scope for the two negative-validation hooks and is released before returning.

Because Keychain and the filesystem are independent stores, there is no pretend two-resource atomic commit. The recoverable ordering is:

1. no pending marker: old Keychain token remains authoritative;
2. pending marker with cutover not observed: remote is not ready and the next repair must reconcile rather than assume success;
3. cutover observed: new Keychain token is authoritative, remote remains disabled/degraded until validation succeeds;
4. final stable state: new generation and handoff are recorded as ready.

If final state persistence fails, the existing pending marker is safer than a false ready state. Phase 4D must inspect/reconcile the Keychain and perform a fresh forward rotation or validation; it must not restore the old token.

## Ngrok authtoken candidate replacement

The ngrok engine receives the candidate only as an in-memory argument and a `KeychainStore`, plus protocol hooks that launch a candidate session using the `NGROK_AUTHTOKEN` environment override, reconcile the exact public endpoint, and validate authenticated remote MCP readiness.

The candidate is committed to the canonical `.ngrokAuthtoken` item only after all validation hooks succeed. In normal repair mode, any pre-commit failure leaves the old provider credential unchanged and may invoke a local prior-session restart hook. In explicit compromised-old mode, failures never restore/restart the old credential and instead clear the local old Keychain item; no provider-side deletion or account/resource mutation is expressible by the protocol.

## Phase 4D integration hooks

Phase 4D must provide:

- prerequisite validation and serialized operation ownership;
- quiesce/stop-and-await semantics before and after connector cutover;
- local MCP restart using the new connector token and canonical activation validation;
- positive new-token remote reconciliation/readiness and negative old local/remote route checks;
- ngrok candidate launch with `NGROK_AUTHTOKEN` in the child environment, exact endpoint reconciliation, authenticated readiness, and normal prior-session restoration when policy permits;
- generation/operation fencing for stale lifecycle completions;
- remote-disabled/degraded behavior for every post-cutover failure and every interrupted pending state.

## Verification design

Dedicated tests cover initial state creation, atomic round trips, permissions, malformed/unsupported/unknown-key state, symlinked state/directory paths, strict nonsecret origin encoding, generation monotonicity, deterministic token shape/entropy, all connector cutover failure boundaries, old-token negative-hook scoping, no rollback after cutover, ngrok delayed commit, normal preservation, compromised-old fail-closed behavior, safe errors/results, and the absence of provider-destructive operations from the hook interfaces.
