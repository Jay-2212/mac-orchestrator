# Wave 1 Configuration, Capability, and Keychain Foundation

## Goal

Make Swift the single owner of Mac Orchestrator's nonsecret product
configuration, capability policy, and secret references while providing a
stable capability snapshot contract for the later Python integration.

## Architecture

`ConfigurationStore` owns a version-1 `config.json` under the Mac Orchestrator
Application Support directory. It validates before use, writes through a
same-directory temporary file, preserves the previous primary as
`config.json.backup`, and recovers a malformed primary from that known-good
backup without silently resetting to defaults. Unsupported future schemas are
rejected. The store accepts an injected directory URL, so tests never use the
real Application Support tree.

`AppConfiguration` contains only nonsecret values: schema and generation,
control profile, local port, process desired state and owner identity,
capability desired flags, approved roots/excludes, scheduling placeholders,
Meridian URL/alias settings, and onboarding/migration markers. New
configurations are Guided with port 8000, server desired, local UI desired,
and all privilege-expanding or optional integrations disabled. A legacy
UserDefaults install is explicitly detected by its existing owner/settings
keys and migrates to Full Control to preserve the old unrestricted behavior;
this is recorded as a migration marker rather than inferred for fresh installs.

`CapabilityRegistry` is a pure domain layer. It resolves the fixed capability
IDs against configuration and injected `CapabilityReadinessFacts`; it never
performs network, provider, Keychain, or process-supervision work. Each state
contains desired/configured/ready/health/dependencies/reason. Profile rules
and dependency failures are explicit, including the Meridian Search →
Meridian Telegram dependency and the requirement for stable compatibility and
index facts before Meridian Search can be ready.

`CapabilitySnapshotCodec` emits JSON with sorted keys and the independent
`snapshotSchemaVersion` 1. The snapshot contains only capability state and
policy roots/clipboard policy; it omits integration URLs, account IDs, and all
secret material. Its semantic shape is the contract consumed later through
`MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT`.

## Keychain and migration

`KeychainStore` keeps the existing connector item identity exactly unchanged
and adds named items for Telegram Send, Meridian ingest, and future Meridian
Telegram credentials. A `KeychainClient` protocol separates Security.framework
from tests. The Meridian ingest accessor first understands the existing
service/account convention (`com.jay.mac-orchestrator.ingest-token` plus the
current user account) and does not create a duplicate identity when that item
already exists.

`LegacySecretMigrator` reads only known keys from an injected legacy JSON file:
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, and `INGEST_TOKEN`. It writes and
reads back each Keychain item, persists cleanup-pending state before attempting
the writes, records completion only after every write is verified, and never
deletes the plaintext file or unrelated JSON keys. A failed Keychain write
therefore leaves cleanup pending without a false completion marker; rerunning
is safe and reuses existing Keychain values.

`UserDefaultsMigrator` maps `serverDesired`, `tunnelDesired`, and `ownerID` into
the canonical configuration. It maps the existing tunnel intent to
`remote.connector` desired state and records an idempotent marker. It never
changes an already migrated profile or desired values on a second run.

## Error and safety rules

- Port values must be in 1...65535; malformed values and unsupported schemas
  fail closed.
- A corrupt primary is preserved as a sidecar before backup recovery. If no
  valid backup exists, loading fails instead of producing permissive defaults.
- Backups are prepared before replacing an existing primary; a failed backup
  preparation aborts the replacement.
- Secret values are represented only by Keychain operations and migration
  reports containing item names, never serialized configuration, snapshots,
  reasons, or error text.
- Guided policy denies shell and file-write capabilities; clipboard mutation
  requires its explicit policy flag. Full Control is only selected by an
  explicit persisted profile or the documented legacy-preservation migration.
- Meridian and remote readiness depend on injected facts, not URL/token or
  process presence alone.

## Test strategy

XCTest covers fresh Guided defaults, port validation/round trips, atomic
replacement and backup/recovery paths, schema and migration idempotence,
UserDefaults migration, fake-Keychain create/read/update behavior, connector
identity preservation, legacy secret migration and failure retry behavior,
secret exclusion, capability profile/dependency resolution, and deterministic
snapshot encoding/decoding. Every test uses a temporary directory, a dedicated
UserDefaults suite, or an in-memory Keychain fake.

## Deferred integration

This branch does not modify `ProcessSupervisor.swift`, AppDelegate,
MenuController, Python, workflows, packaging, or Meridian. A later integration
session must supply the encoded snapshot to Python, replace the supervisor's
port/desired-state reads with the canonical store, and remove Python's legacy
plaintext fallback after the UI offers cleanup.
