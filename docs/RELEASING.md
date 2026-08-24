# Release and CI gates

This document defines the Phase 2 candidate release path. It validates an
immutable terminal bootstrap and its user-owned helper/runtime while preserving
the deterministic Wave 0/1 gates. It does not claim that a source branch,
unpublished asset, ad-hoc helper, Gatekeeper prompt, TCC approval, or ngrok
account test is a hosted public release.

## Release inputs

The release contract is represented by:

- `release/manifest.schema.json` — schema version 1 for the release manifest;
- `release/manifest.signature.schema.json` — strict v1 detached Ed25519 envelope schema;
- `release/manifest.template.json` — an intentionally incomplete maintainer
  template, never a distributable concrete manifest;
- `script/bootstrap.sh` — the Bash 3.2-compatible public installer;
- `script/build_release_artifacts.sh` — maintainer-only helper/manifest
  assembly;
- `script/sign_release_manifest.sh` — external-key-only raw-byte manifest
  signing;
- `script/generate_install_command.sh` — exact release-pinned install handoff; and
- `script/test_bootstrap.sh` — deterministic fixture coverage for validation,
  staging, recovery, and artifact boundaries.

The public bootstrap command is generated with a versioned release asset,
bootstrap SHA-256, manifest URL, and manifest SHA-256. It rejects mutable
branch URLs, empty, all-zero, or sentinel digests,
unsupported arm64/macOS combinations, bad helper/uv/runtime/ngrok hashes, lock
identity mismatches, editable metadata, missing imports, and failed local smoke
activation. Update discovery treats GitHub Releases as untrusted metadata:
`UpdateEngine` fetches the exact raw `manifest.json` and `manifest.sig`,
verifies the detached Ed25519 signature against the embedded public key, and
only then decodes and validates immutable version/platform/schema/compatibility
metadata. The signature covers the exact raw manifest bytes; no ad-hoc JSON
canonicalization is used.

Production signing private keys are supplied to the release job as an external
secret and are rejected by the signing script when located in the repository.
The repository contains only the embedded public verification key. The
externally pinned bootstrap + manifest SHA path remains available for Phase 2
fresh install and recovery, but a GitHub tag, release title, or discovered
version alone never authorizes an update.

The bootstrap keeps filesystem recovery armed only through verified staging,
payload promotion, promoted-install validation, and LaunchAgent installation.
After that installation transaction commits, TCC approval, local activation,
profile selection, and optional remote setup are resumable onboarding steps.
Their failure may leave the command nonzero, but it must not restore the
successfully installed helper/runtime; genuine pre-commit installation failure
still restores the previous payload.

The helper is ad-hoc signed, arm64, installed below the user's Application
Support directory, and does not contain ngrok. The bootstrap obtains ngrok from
the vendor, verifies its original Developer ID authority/team, and never
re-signs it. Config and Keychain state remain outside runtime promotion.

The release payload also does not contain Meridian's optional indexer. That
tool is a separate, release-pinned executable handoff installed under the
owned `meridian/` directory by the native helper's digest-checked optional
installer. Core release verification must continue to reject `src/indexer`,
`scripts/indexer.mjs`, Node dependencies, and document/embedding packages in
the Mac core payload. Optional-tool installation failures are non-destructive
to the prior tool and to the base MCP runtime.

## Phase 3C update and uninstall contract

The native maintenance layer persists `InstallationReceiptV1` at the install
root and records update transactions through durable states from discovery to
postflight. The staged helper archive is digest-checked and re-verified before
maintenance quiescing. Phase 3 deliberately does not execute an extracted
candidate helper: same-schema updates use the current authenticated helper,
while schema-changing or candidate-owned migration fails closed with
`migrationUnavailable` until a bounded candidate-helper handoff exists. The
current configuration schema remains 1.

Pre-commit failures restore the transaction backup. A post-commit TCC or human
onboarding failure is reported as postflight and does not roll back structurally
valid installed files. Uninstall is plan-driven, defaults to preserving
configuration and all Keychain identity/credentials, and models explicit
helper/app, owned-process, managed-runtime, local-remote, cache, log/support,
LaunchAgent, configuration, and credential choices. Credential deletion is
available only through an explicit option. Every filesystem removal is
restricted to known project-owned roots with ownership, type, and symlink
checks; process removal fails closed without an integration-owned ownership
proof. No provider/ngrok account cleanup is attempted.

## Toolchain contract

The locked native dependency set requires CPython `3.13.14`; the project uses
uv `0.12.3`. Required Python jobs select those exact versions and run the
literal frozen sync against `.venv/bin/python`:

```bash
uv sync --managed-python --frozen --python .venv/bin/python
```

Action references are immutable and must update their displayed version and SHA
together:

| Component | Version or label | Enforcement |
| --- | --- | --- |
| Python | CPython `3.13.14` | managed uv installation and runtime assertion |
| uv | `0.12.3` | exact `astral-sh/setup-uv` input |
| `actions/checkout` | `v7.0.1` / `3d3c42e5aac5ba805825da76410c181273ba90b1` | immutable action reference |
| `astral-sh/setup-uv` | `v9.0.0` / `c771a70e6277c0a99b617c7a806ffedaca235ff9` | immutable action reference |
| Native runner | `macos-14` | Swift, Python, and bootstrap fixture jobs |
| Aggregation runner | `ubuntu-24.04` | required-gate aggregation and release validation |

## Required versus informational checks

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`, and is
callable by `release.yml` at an explicit commit SHA.

| Job | Required? | Responsibility |
| --- | --- | --- |
| `Swift build gate (macOS 14)` | Yes | Swift toolchain, debug/release builds, and ordinary `swift test`. |
| `Phase 2 bootstrap contract gate (required)` | Yes | Manifest/bootstrap JSON and Bash syntax, immutable URL and path checks, public-path boundary checks, helper fixture checks, and the clean/repeat/failed-download/interrupted-promotion harness. |
| `Python hygiene gate (required)` | Yes | Exact interpreter selection, compile checks, secret-shaped value scan, personal/build path scan. |
| `Python dependency gate (required)` | Yes | Frozen sync, `uv lock --check`, core/indexer partition test, deterministic pagination/capability tests, and locked native imports. |
| `All required release gates` | Yes | Runs after every deterministic gate and exits nonzero unless every required result is `success`. |
| `Python UI checks (informational; TCC-dependent)` | No | Attempts the full behavioral suite for evidence only. |

The required aggregate uses `if: ${{ always() }}` only to inspect all required
results and fail closed. No required deterministic step uses
`continue-on-error`. The only non-blocking behavior is the full UI suite in the
separate TCC-dependent job; its setup, interpreter selection, and dependency
sync remain visible failures.

## Phase 2 contract assertions

The required contract job checks that all release inputs exist, are executable
where appropriate, parse as JSON, and pass `bash -n`. It also rejects:

- mutable `main`/`master` bootstrap or manifest URLs;
- source-build prerequisites in the public bootstrap path;
- `indexer.py` copied into the core payload;
- hardcoded user, Xcode `DerivedData`, private-var, or transient build paths;
- secret-shaped values including private keys, GitHub/OpenAI/Slack/AWS-like
  tokens, and literal ngrok authtokens; and
- a missing or non-executable helper/artifact fixture harness.

The harness is authoritative for clean installation, repeat installation,
failed-download preservation, and interrupted-promotion recovery. It must use
temporary fixture roots and must not launch a real helper, tunnel, or external
account. The public payload boundary is also covered by the dependency
partition test: core dependencies retain MCP/UI/OCR, while `pyngrok`, document
parsers, and indexer embedding packages live only under the explicit `indexer`
extra. The core bootstrap never copies `indexer.py`.

## Deterministic Wave 0/1 gates

The required Swift contract remains:

```bash
swift build
swift build -c release
swift test
```

The required Python contract remains based on the actual locked environment:

```bash
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B test_pagination.py
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B test_capabilities.py
.venv/bin/python -B -c 'import easyocr, torch, torchvision'
```

`test_pagination.py` uses a fixed offline AX fixture and is authoritative for
pagination. Live Finder/Accessibility observations are mutable and are not
release evidence. The capability and policy tests remain required and are not
weakened by adding the Phase 2 contract job.

## Supported release path

Do not create a tag first and rely on a later push workflow to find a failure.

1. Merge the reviewed source commit to `main` and wait for ordinary CI.
2. In GitHub Actions, dispatch `Release` from `main` with a new semantic
   `vMAJOR.MINOR.PATCH` tag. Do not dispatch from a tag, another branch, or a
   local checkout.
3. `validate-release` confirms the dispatch ref is `refs/heads/main`, the
   checked-out `HEAD` equals `github.sha`, the SHA is the current remote
   `origin/main` commit, the tag is semantic and unused, and the Phase 2
   manifest/bootstrap contract parses and passes static checks.
4. The reusable CI workflow receives the validated SHA as `checkout_ref`; every
   required job therefore tests that same immutable commit, including the
   bootstrap harness and dependency partition.
5. The asset-assembly job runs on arm64 macOS, builds the ad-hoc helper, creates
   the core payload, downloads the exact vendor ngrok ZIP for temporary
   validation, checks its digest and original signature, and asks
   `script/build_release_artifacts.sh` to emit `bootstrap.sh`, `manifest.json`,
   the raw-byte detached `manifest.sig`, `install-command.sh`, the pinned
   `release-body.md` snippet, `SHA256SUMS`, and the release payloads. The
   external signing key is never checked into the checkout. The ngrok ZIP itself is not copied into or
   uploaded as a project release asset.
6. Publication depends on validation, required CI, and asset assembly. It
   rechecks the SHA, current remote `main`, and tag absence before uploading the
   assembled assets with GitHub's release command and `--target "$RELEASE_SHA"`.
   The generated release body is supplied as the leading `--notes` content
   while GitHub-generated notes remain enabled, so the release page itself
   contains the supported one-copy-paste command.

The current workflow does not dispatch a release, create a tag, or claim that a
public artifact exists. Dispatch remains maintainer-controlled and requires
explicit ngrok version, direct `bin.equinox.io` URL, digest, authority, and team
inputs; the workflow refuses to assemble a release from a non-vendor ngrok URL
or an unverified archive.

## Trust and evidence boundaries

Phase 2 is not Developer ID signed or notarized. Gatekeeper may warn on first
launch. The installer does not silently weaken Gatekeeper or delete quarantine.
TCC grants are tied to a particular helper identity; replacing an ad-hoc helper
can require new Accessibility, Screen Recording, or Apple Events approval.
Opening System Settings is not a passing test. Real permission, unlocked
console, and authenticated ngrok-account evidence must be gathered manually on
an appropriate Mac and reported separately from hosted CI.

The connector URL and token are credentials. CI, release notes, logs, client
examples, screenshots, and diagnostics must contain placeholders only. The
helper reads the ngrok token from Keychain, passes it only in the owned child
environment, discovers the current endpoint through `/api/endpoints`, and never
uses the deprecated `/api/tunnels` route.

The generated `install-command.sh` is the consumer-facing handoff. Its
bootstrap and manifest URLs must remain the exact same-tag GitHub release
assets, and its two SHA-256 values must match those assets. Do not publish a
manual command with a branch URL or an unpinned manifest.

## Maintainer-only scripts and deferred work

`script/package_app.sh`, `script/distribute.sh`, and legacy
`script/bootstrap_ngrok.sh` are source-build/assembly workflows for maintainers.
They are not public onboarding instructions and do not replace the immutable
bootstrap contract.

Developer ID/notarization, DMG packaging, Intel, Meridian/provider changes, and
mature remote recovery remain outside this phase. Workflow code also cannot
prevent a repository administrator from bypassing Actions or manually creating
a tag; repository rulesets and branch/tag protections must be configured and
verified outside this change.
