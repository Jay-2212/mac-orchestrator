# Phase 2 terminal-first distribution feasibility spike

Date: 2026-08-11

Repository: `Jay-2212/mac-orchestrator`

Branch: `spike/phase2-terminal-bootstrap-feasibility`

Starting SHA: `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6`

This is an architecture and feasibility investigation. It does not implement
Phase 2 production behavior.

## Status

`PARTIALLY VERIFIED`

The decisions below are sufficient to rewrite the public-release blueprint and
start Phase 2. Clean-machine Gatekeeper approval and actual TCC grant survival
were not tested because no Developer ID artifact was available and the test
rules prohibit creating or resetting permissions. Those limitations are
explicit rather than design assumptions.

## Executive conclusion

- Do not require ordinary users to install Xcode, Command Line Tools, Python,
  `uv`, or Git. This is true only after CI supplies a complete prebuilt helper
  and the bootstrap never invokes the source-build scripts.
- A prebuilt ad-hoc helper is viable only for the proposed terminal-first trust
  model. It is not a normal Finder-launched, Gatekeeper-clean Mac app: the
  disposable ad-hoc bundle was valid to `codesign` but rejected by `spctl`, and
  the quarantined launch probe did not run to its marker.
- A self-signed certificate does not improve public distribution enough to
  recommend it. It produced a stable certificate-based designated requirement
  in the experiment, but the certificate was untrusted and Gatekeeper rejected
  the app.
- Revalidate both helper and Python TCC state after a helper replacement. The
  ad-hoc designated requirement is cdhash based, and changing only
  `CFBundleVersion` changed the cdhash; regrant if the actual requester no
  longer has its grant. The actual persistence of a previously granted TCC row
  was not tested.
- The Swift helper is not standalone. It requires the managed Python runtime
  under `~/Library/Application Support/Mac Orchestrator/runtime`; the bootstrap
  must create that runtime before starting the LaunchAgent.
- A private, pinned `uv` binary plus `uv python install --managed-python
  3.13.14` can bootstrap CPython on a stock Apple Silicon Mac without a
  pre-existing Python. The lock and current Torch wheels make CPython 3.13.14
  the honest first distribution target.
- Keep the canonical Application Support runtime root, but stage installs in a
  separate temporary directory, validate the frozen environment, and only then
  replace the active runtime. An interrupted install must not destroy a working
  runtime or Keychain/configuration state.
- The current Python environment is monolithic. `sentence-transformers`, the
  document parsers, and indexer-only HTTP/ML dependencies do not belong in the
  base runtime. EasyOCR is also a substantial optional capability, not a reason
  to retain Meridian dependencies.
- Acquire ngrok directly from its official archive, verify the published SHA-256
  and original Developer ID signature, and do not use `pyngrok` as the
  distribution mechanism. Do not re-sign the ngrok executable as the current
  packaging script does.
- The unavoidable remote-access interaction is an ngrok account login/signup
  and authtoken provision. Current official material documents dashboard token
  configuration, not a browser-based agent authorization flow. The installer
  can open the browser and resume at a hidden token prompt, but it cannot remove
  the token decision.
- The current free plan has one account-tied development domain, and ngrok’s
  official product guidance says the assigned domain stays fixed across agent
  restarts. That is stable enough for the intended host name, subject to account
  and plan state. Always re-query the live endpoint and re-display the full
  connector URL after a restart, sleep/wake recovery, or network change because
  endpoint availability is still live state. A paid reserved/custom domain is
  outside this hobby-project scope.
- The public entry point should be one copy-paste command targeting an immutable,
  versioned release bootstrap. Do not pipe an unpinned `main` branch into a
  shell. The bootstrap must verify a pinned manifest and every downloaded
  payload before installation.

## Experiments performed

### 1. Repository and architecture baseline

Purpose: establish that the investigation started from the requested Wave 1
merge and understand the actual runtime contract.

Procedure:

- Verified `git status`, `git rev-parse HEAD`, and `git log -1 --oneline` before
  investigation.
- Fetched the remote `main` ref and created the dedicated branch at
  `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6`.
- Read the repository instructions and the named Swift, Python, script,
  workflow, release, README, architecture, and test files.

Observed:

- `Package.swift` defines one executable, targets macOS 13+, and has no external
  Swift package dependency.
- `AppDelegate` and `NativeRuntimeCoordinator` own the Application Support
  directory, configuration/migrations, Keychain, readiness, and runtime
  preparation.
- `ProcessSupervisor` launches the managed Python interpreter from
  `runtime/.venv/bin/python`, starts ngrok only after local server health, owns
  both child processes, and builds the capability URL from the tunnel result.
- `ManagedRuntimeLaunchContract` passes the validated capability snapshot and
  secrets to Python; it does not construct a Python environment.
- `script/distribute.sh` currently requires an already-installed `uv`, copies
  both `automac_mcp.py` and `indexer.py`, performs a frozen sync, installs to
  `/Applications`, and creates a user LaunchAgent. It is a maintainer/developer
  script, not a stranger-friendly bootstrap.
- `script/package_app.sh` builds from source, expects a pre-existing ngrok binary,
  embeds it in the app, and ad-hoc signs both the nested binary and the app by
  default.

Classification: empirical repository inspection.

### 2. Prebuilt Swift helper and ad-hoc signature

Purpose: determine whether a user needs Xcode or local Swift compilation and
whether a zero-cost helper has a usable identity.

Procedure:

- Built debug and release binaries with the installed Apple Silicon Swift
  toolchain and inspected them with `file`.
- Created a disposable minimal AppKit `.app` outside the repository, copied a
  release binary into it, generated an `Info.plist`, and signed it with
  `codesign --sign -`.
- Checked the signature and designated requirement with `codesign` and assessed
  it with `spctl`.
- Added a disposable `com.apple.quarantine` attribute and compared `open` launch
  behavior with the unquarantined copy. The probe wrote a marker only while the
  unquarantined copy remained running.
- Changed only the bundle version and re-signed the ad-hoc app.

Observed:

- Swift debug and release builds completed and produced arm64 Mach-O binaries.
  This proves a release builder needs Swift tooling; it does not impose that
  tooling on users who receive a complete prebuilt helper/runtime/ngrok payload
  and whose bootstrap never invokes the source-build scripts.
- The ad-hoc bundle was valid on disk to `codesign --verify --deep --strict`.
- Its CodeDirectory had `flags=0x2(adhoc)`, no Team ID, no signing authority,
  and a cdhash-based designated requirement.
- `spctl --assess --type execute` rejected the ad-hoc bundle both before and
  after the quarantine attribute was added.
- `open` returned zero for both probes, but only the unquarantined probe reached
  its marker. An `open` exit code is therefore not launch evidence.
- Changing only `CFBundleVersion` changed the ad-hoc cdhash.

The result matches Apple’s description of [ad-hoc code
signing](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc):
there is no signing identity, and identity-constrained code requirements cannot
be used. Apple’s [Gatekeeper guidance](https://support.apple.com/en-ae/guide/security/sec5599b66df/web)
describes the normal downloaded-app path as identified-developer plus
notarization and first-launch approval. This experiment does not claim that a
terminal-launched, unquarantined ad-hoc executable can never run; it proves that
the artifact is not a Gatekeeper-clean public app and that the bootstrap cannot
silently assume Finder/Open behavior.

Classification: helper launch and signature observations empirical; the
distribution interpretation is supported by Apple documentation.

### 3. Self-signed certificate

Purpose: check whether a zero-cost local certificate is a practical public
distribution alternative.

Procedure:

- Created a disposable self-signed code-signing certificate and temporary
  keychain.
- Signed a disposable app with that certificate, inspected its designated
  requirement, ran `codesign --verify`, and ran `spctl`.
- Deleted the temporary keychain without changing the user’s existing
  keychains.

Observed:

- The app had a certificate-based designated requirement and a stable identity
  in the signed artifact.
- The certificate was not trusted by the system and `spctl` rejected the app.
- The app was therefore no better than ad-hoc for ordinary public Gatekeeper
  onboarding, while adding certificate-generation and trust-installation
  friction.

Classification: empirical.

### 4. TCC and permission attribution

Purpose: determine what the installer can truthfully promise about Accessibility,
Screen Recording, and Automation.

Procedure:

- Inspected `CapabilityReadinessCoordinator.swift`, `ProcessSupervisor.swift`,
  `automac_mcp.py`, the TCC-dependent Python tests, and the release notes.
- Inspected the ad-hoc and self-signed designated requirements above.
- Did not create, reset, or delete any TCC grant.

Observed:

- Swift calls `AXIsProcessTrusted()` and
  `CGPreflightScreenCaptureAccess()` for readiness.
- Those Swift checks describe the supervisor process, not automatically the
  Python child. The Python child independently reaches the same TCC-sensitive
  APIs and must report its own readiness in the future onboarding contract.
- Python itself imports PyObjC and `pyautogui`, calls Accessibility/AppleScript
  and screen APIs, and is the interpreter exercised by the TCC-dependent test
  suite. The existing release documentation explicitly says the permissions
  must be granted to the exact Python binary running the suite.
- `automac_mcp.py` classifies Automation and Accessibility failures and reports
  them rather than treating a missing permission as success.
- No experiment in this environment can prove a real TCC grant survives an
  upgrade without first creating and then changing such a grant. That was
  intentionally not done.

Decision consequence: the terminal UI must not say “permissions granted” based
only on the Swift readiness check. Phase 2 must show which exact process needs
each permission and re-check the actual process that will perform the action.
Terminal permission does not imply helper permission, and helper permission
must not be assumed to imply Python permission. Accessibility, Screen Recording,
and Automation remain user actions in System Settings or in the first real
Apple Events flow.

Classification: source behavior empirical; TCC persistence remains unverified;
the identity/designated-requirement implication is documentation-supported.

### 5. Managed Python bootstrap

Purpose: prove that the installer can own Python without system Python or a
pre-existing `uv`.

Procedure:

- Used a disposable directory as `UV_PYTHON_INSTALL_DIR` and a separate cache.
- Ran `uv python install --managed-python 3.13.14`.
- Created a disposable venv with
  `uv venv --managed-python --python <managed-interpreter> <runtime>/.venv`.
- Compared `uv sync --frozen --dry-run` with
  `uv sync --frozen --no-editable --dry-run` against the current lock.
- Printed Python version, architecture, and executable path, then removed the
  temporary directory.

Observed:

- uv downloaded and installed the Apple Silicon CPython 3.13.14 managed build
  without using the system Python.
- The venv reported Python `3.13.14`, machine `arm64`, and an executable under
  the disposable runtime.
- uv warned only that an unrelated unmanaged `python3.13` executable already
  existed in the user PATH; it did not replace it.
- `uv lock --check` passed and `uv sync --frozen --dry-run` reported no changes
  for the repository environment.
- The no-editable dry run would replace the editable root project with a
  non-editable file install. Because `uv.lock` records the root as
  `source = { editable = "." }`, the future staged installer must use
  `--no-editable` or verify that no promoted `.pth`/dist-info path still points
  at the staging directory.

Astral documents both the [standalone uv installer and version-pinned
installer URL](https://docs.astral.sh/uv/getting-started/installation/) and
[managed Python installation](https://docs.astral.sh/uv/guides/install-python/).
The latter also documents that uv uses `python-build-standalone` distributions,
not a system Python supplied by macOS.

Classification: bootstrap mechanics empirical; the release artifact and
checksum design is a recommendation.

### 6. Dependency and import audit

Purpose: identify what the first runtime actually needs and avoid shipping
Meridian/indexer weight as core.

Procedure:

- Audited imports and call sites in `automac_mcp.py` and `indexer.py`.
- Inspected `pyproject.toml`, `uv.lock`, `uv tree --frozen --no-dev`, CI imports,
  and test imports.
- Imported the MCP server in the current environment and separately imported
  EasyOCR/Torch/Torchvision.
- Measured the existing environment’s major installed directories.

Observed:

- `automac_mcp.py` imports `mcp`, Rich, Starlette, PyAutoGUI, PyObjC, and
  `requests` at startup. EasyOCR and NumPy are imported lazily by the OCR path,
  although the current PyAutoGUI stack can cause NumPy to be loaded during UI
  import.
- File search, file reads/writes, shell, and clipboard use pathlib, macOS
  utilities (`mdfind`, `mdls`, `pbcopy`, `pbpaste`), and `subprocess`; office
  document parsers are not used by ordinary MCP file tools.
- `requests` is used for Telegram Send and Meridian HTTP search, not core local
  file/UI operations. A future dependency split must move its import behind the
  optional integration path or replace it with a standard-library HTTP client.
- `indexer.py` imports Torch and Sentence Transformers at top level, and its
  optional parser imports cover PDF, DOCX, XLSX, and PPTX. It is not launched by
  the Swift supervisor.
- `pyngrok` is used only by the current acquisition helper, not by the MCP
  server.
- The current lock has no direct source import for `fastapi`; it is a candidate
  for removal only after a fresh lock and runtime validation. `uvicorn` is both
  directly declared and present in the MCP dependency tree, so its final direct
  declaration also requires dependency-tree/runtime validation.
- The existing venv is approximately 837 MB. Representative directories are
  Torch 320 MB, OpenCV 100 MB, SciPy 72 MB, Transformers 50 MB, and
  scikit-image 29 MB. These are installation observations, not promised final
  artifact sizes.
- The locked native stack has Apple Silicon Torch/Torchvision wheels for the
  supported Python 3.10–3.13 range but not CPython 3.14; CI therefore pins
  3.13.14.

Classification: source/lock/import observations empirical; exact post-split size
requires implementation and a fresh lock.

### 7. ngrok acquisition and unauthenticated behavior

Purpose: establish the current download, signature, authentication, config, and
free-plan constraints without using a real account or token.

Procedure:

- Downloaded the current Apple Silicon agent from the official archive index
  into a disposable directory.
- Verified its SHA-256, Mach-O architecture, version, and code signature.
- Ran an isolated agent with a valid minimal config but no credential.
- Inspected `ngrok config check`, `ngrok status`, the current Swift launch args,
  and `pyngrok.install_ngrok()` behavior in an isolated location.
- Read current official agent, config, Agent API, free-plan, FAQ, archive, and
  Terms of Service material.

Observed:

- The archive index currently exposed ngrok `3.39.10`, macOS arm64 ZIP SHA-256
  `907cb61b6fa5837e3ac2cfa4ab8e8b1efe85c6e7cd11c99974a5607b5ea21ceb`.
- The extracted binary was an arm64 Mach-O, reported `ngrok version 3.39.10`,
  passed `codesign --verify --deep --strict`, and retained ngrok’s Developer ID
  chain (`Developer ID Application: ngrok, Inc. (TEX8MHRDQ9)`).
- A repeat probe of the moving
  `ngrok-v3-stable-darwin-arm64.zip` alias returned HTTP 404 while the official
  archive index supplied an exact versioned `bin.equinox.io` URL. An earlier
  isolated probe saw the moving alias succeed. This drift is a reason to pin a
  reviewed version and hash rather than depend on the moving alias.
- Starting `ngrok http` without an authtoken produced
  `ERR_NGROK_4018` and no public tunnel. The local inspector was available at
  `127.0.0.1:4040`.
- `ngrok status` is not a local credential/status probe in the current agent;
  it prints CLI help. `ngrok config check` does validate config presence and
  format.
- `pyngrok.install_ngrok()` can create a v2 config with mode 0644 in addition to
  downloading the binary. It is not a state-neutral acquisition primitive.
- The current Swift process launches the nested ngrok binary after server health,
  polls `/api/tunnels`, and redacts the Mac Orchestrator capability token. The
  official [Agent API](https://ngrok.com/docs/agent/api) now marks that endpoint
  deprecated and recommends `/api/endpoints`.
- The current app does not pass `--config`, so ngrok uses its default macOS
  config path. The installer must use an app-owned config or Keychain-backed
  environment instead of silently mixing with an unrelated user config.
- The current package script force-signs the embedded ngrok binary. That removes
  the original ngrok Developer ID/hardened-runtime signature and is not
  acceptable for a verified distribution artifact.
- Current [free-plan limits](https://ngrok.com/docs/pricing-limits/free-plan-limits)
  say a free account has one automatically assigned development domain tied to
  the account, up to three online endpoints, and no reserved/custom static
  domain. ngrok’s [product guidance](https://ngrok.com/blog?page=9) says the
  assigned free dev domain stays fixed across agent restarts. This was not
  independently exercised with an account in this spike.
- The current [ngrok Terms of Service](https://ngrok.com/tos) permit agent
  distribution in some cases where the distributor maintains the account, but
  require prior written consent to distribute to customers who maintain their
  own ngrok accounts. Direct customer-side download is the conservative
  open-source path; legal review is required before choosing a maintainer-owned
  redistribution model.

Classification: download/signature/auth/config observations empirical; plan,
domain, API, and licensing constraints are current official documentation.

## Menu-bar helper finding

### Decision

Use a prebuilt Apple Silicon ad-hoc-signed helper for the terminal-first hobby
distribution. Do not require local compilation. Do not call the helper
notarized, Developer ID signed, Gatekeeper-clean, or equivalent to a normal
commercial Mac app.

The helper should be built once by the project’s release machinery and installed
by the bootstrap at a stable user-owned path under
`~/Library/Application Support/Mac Orchestrator/app/`. A user-owned path avoids
asking for administrator credentials; the LaunchAgent can execute that exact
helper. A later convenience symlink in `~/Applications` is optional, but is not
needed for the menu-bar supervisor.

This is a deliberate terminal-first trade-off:

- Users receive a binary and do not need Xcode or SwiftPM.
- The terminal bootstrap is the trust boundary and can verify the release
  manifest before launch.
- macOS may still require an explicit first-run approval for the ad-hoc,
  downloaded artifact. The installer must not silently strip quarantine or tell
  the user that Gatekeeper has accepted it.
- A helper replacement can invalidate ad-hoc TCC recognition. The status flow
  must revalidate both helper and Python, then guide re-approval only if the
  actual requester no longer has its grant.
- A self-signed helper is not the public fallback: it is untrusted on other
  Macs, needs certificate/trust choreography, and still failed `spctl` here.
- A paid Developer ID certificate and notarization would remove most of this
  friction, but are explicitly outside the maintainer’s constraints.

Apple’s notarization documentation explicitly requires Developer ID signing and
does not accept ad-hoc or local-development identities for notarization; see
[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [Developer ID support](https://developer.apple.com/support/developer-id/).

### TCC implications

The bootstrap can explain and verify permissions; it cannot grant them. It must
show separate, truthful states for:

- Accessibility: add the exact helper and, because the current Python process
  performs UI calls, the exact managed Python executable where required.
- Screen & System Audio Recording: add the exact process that captures the
  screen. The Python OCR/screenshot path is a real consumer.
- Automation: the user must approve Apple Events to System Events or another
  target application when macOS presents the prompt. The current
  `NSAppleEventsUsageDescription` is descriptive, not a grant.

The installer should open the relevant System Settings pane or present the
current manual path, wait, re-run readiness checks, and report which process is
still blocked. It must not copy Terminal’s permission state to the helper or
infer Python’s permission from Swift’s check. No TCC database editing belongs in
the installer.

## Terminal bootstrap finding

### Recommended sequence

1. The README publishes a versioned, immutable bootstrap command for a reviewed
   release. The command downloads the small bootstrap into a temporary file,
   verifies its expected SHA-256, and executes it. The URL must not point to
   mutable `main` content.
2. The bootstrap checks Apple Silicon (`arm64`), macOS 13 or newer, writable
   user directories, network availability, and whether a previous install is
   running. Intel is rejected in this phase rather than silently entering an
   untested path.
3. It downloads a project-pinned standalone `uv` binary into a temporary or
   versioned private bootstrap directory. It does not install `uv` into the
   user’s PATH or run Astral’s mutable latest installer as an implicit
   dependency. The selected uv version should be aligned with the CI contract
   (the current repository pins `0.12.3`).
4. It creates a staging directory under the user-owned Application Support
   location and installs CPython `3.13.14` there with
   `UV_PYTHON_INSTALL_DIR=<runtime>/python` and `--managed-python`.
5. It sets the managed-Python requirement for every subsequent uv invocation
   (for example `UV_MANAGED_PYTHON=1` plus explicit `--managed-python`) so a
   missing managed interpreter cannot silently fall back to system Python.
6. It copies only the selected runtime source and lock files into staging and
   runs `uv venv --managed-python` followed by
   `uv sync --frozen --managed-python --no-editable` against the exact managed
   interpreter. User uv config and system Python must not affect resolution.
7. It runs a smoke test: interpreter version/architecture, frozen lock check,
   `import automac_mcp`, capability snapshot validation, and a local health
   probe. It writes a manifest containing the release, interpreter, lock hash,
   package/add-on selection, and payload hashes. It also verifies that editable
   metadata does not point at the staging directory.
8. The helper, runtime, ngrok binary, and manifest are treated as one verified
   release set. Only after all components validate does the installer promote
   the active set. A failed or
   interrupted first install leaves a resumable marker and no partially
   installed active runtime. A repeat install preserves the existing config,
   Keychain, helper path, and ngrok credential while replacing only a validated
   runtime.
9. It installs the prebuilt helper at a stable user-owned path and creates the
   existing user LaunchAgent contract. It starts the helper only after the
   runtime smoke test succeeds.
10. It acquires ngrok separately from the official archive, verifies it, and
   makes it available to the supervisor without re-signing it. The tunnel starts
   only after the local server is healthy.
11. It guides permissions, then asks whether to enable public ingress. If the
   user opts in, it opens the ngrok dashboard when authentication is missing,
    accepts the authtoken through a hidden prompt or approved credential flow,
    starts the agent, and reads the current endpoint URL from the local Agent
    API.
12. It displays the authenticated MCP URL once and gives client-specific setup
    instructions. The capability token is never written to logs or included in
    diagnostics. The URL is re-generated/displayed whenever the active endpoint
    changes.

### Runtime layout

Keep the frozen Wave 1 canonical root:

```text
~/Library/Application Support/Mac Orchestrator/
  runtime/
    python/<managed-cpython>/
    .venv/
    manifest.json
    install-state.json
  remote/ngrok/<reviewed-version>/ngrok
  logs/
```

The helper can be in
`~/Library/Application Support/Mac Orchestrator/app/Mac Orchestrator.app`.
`remote/ngrok` is separate from the app bundle so its
original Developer ID signature can be verified and preserved. Full
updater/version-pointer design is deferred; Phase 2 only needs staging,
validation, repeat installation, and safe recovery.

### Repeat install and recovery

- Never delete or recreate the Keychain connector item during a runtime repair.
- Never overwrite the active runtime until the staged runtime passes its smoke
  test.
- Keep the helper bundle identifier and path stable, then revalidate both helper
  and Python TCC state after replacement.
- If the actual requester no longer has Accessibility, Screen Recording, or
  Automation access, surface it as pending and guide the user again.
- If the installer is interrupted, a later run should detect the marker, discard
  only the incomplete staging directory, and either resume or rebuild it.
- A later updater may use versioned runtime directories and an atomic pointer;
  that is not part of this spike.

## Runtime dependency finding

### Proposed boundaries

| Boundary | Contents | Recommendation |
| --- | --- | --- |
| Core server | `mcp`, Rich, direct Starlette/required MCP transitives, standard library | Always install. Keep diagnostics, local policy, files, shell, and clipboard here. `fastapi` is a removal candidate only after a fresh lock/import/test; `uvicorn` needs final dependency-tree/runtime validation. |
| UI/control | `pyautogui`, PyObjC Cocoa/Quartz/ApplicationServices, Pillow, and UI transitives | Core only if UI control is promised in the first-run product; otherwise a first-party capability add-on. Pillow is shared with screenshots and is not OCR-only. |
| OCR | EasyOCR, NumPy, OpenCV, SciPy, scikit-image, Shapely, PyClipper, Torch, TorchVision, and related lock packages | Separate optional add-on unless screen OCR is explicitly part of the base promise. The source already lazy-loads OCR; reuse the UI Pillow install. |
| Telegram Send | `requests` or a small standard-library HTTP implementation, plus the existing secret contract | Optional integration. No Telegram SDK is used. Do not import `requests` at core startup. |
| Meridian/indexer | `sentence-transformers`, Transformers, Tokenizers, Hugging Face Hub, scikit-learn, Torch/SciPy as needed, `requests`, SQLite | Separate process/environment. Do not copy `indexer.py` into the core runtime. |
| Document parsing | `pypdf`, `python-docx`, `openpyxl`, `python-pptx`, `lxml`, XlsxWriter | Indexer-only in the inspected source; do not install for ordinary MCP file reading. |
| Acquisition | `pyngrok` | Remove from the runtime and use a direct, verified ngrok download. It is only a historical bootstrap helper. |

The exact split requires later source seams because `automac_mcp.py` currently
imports `pyautogui` and `requests` eagerly. This spike does not change those
imports. It does establish that the current `pyproject.toml` is not a truthful
minimal core manifest.

## ngrok finding

### Recommended acquisition and configuration

- Resolve a reviewed ngrok version from the official archive index and pin the
  exact macOS arm64 URL and SHA-256 in the installer manifest.
- Download into a temporary directory, check SHA-256, run
  `codesign --verify --deep --strict`, inspect the Developer ID authority, then
  move the exact binary into the app-owned `remote/ngrok/<version>` directory.
- The recommended Phase 2 shape is an external agent path so the original
  signature remains untouched. If a future artifact embeds ngrok as nested code,
  the release pipeline must verify and preserve that nested signature while
  signing the outer bundle; it must not repeat the current force-signing step.
- Do not commit or embed the proprietary agent in the open-source repository or
  public app by default. The current terms make direct download safer for users
  who maintain their own accounts; legal review is still required before any
  redistribution mode.
- Preserve ngrok’s original signature. The current `package_app.sh` behavior of
  force-signing `Contents/Resources/ngrok` must not be copied into Phase 2.
- Use a per-app config path or Keychain-backed credential. Prefer storing the
  authtoken in the macOS Keychain and injecting it into the owned child through
  `NGROK_AUTHTOKEN`; if a config file is required, create a v3 config with
  `umask 077`, mode 0600, atomic replacement, and no token in command arguments,
  shell history, logs, or status output.
- Do not use `ngrok service install`; the Swift LaunchAgent owns the child
  lifecycle. Start ngrok only after the local server’s health contract passes.
- Query the current local Agent API and migrate the supervisor’s future
  discovery from deprecated `/api/tunnels` to `/api/endpoints` as part of the
  narrow Phase 2 integration work.

### Unavoidable user interaction

The near-automatic flow is:

```text
Setting up secure remote access…
→ open the ngrok dashboard if no credential is configured
→ user signs up/logs in and retrieves an authtoken
→ user pastes it once into a hidden installer prompt, or approves the chosen
  Keychain flow
→ installer validates config and resumes
→ supervisor starts ngrok and reads the live endpoint
→ installer shows the full capability URL and client instructions
```

There is no evidence of a documented browser-based ngrok-agent OAuth/device
authorization that would eliminate token provision. The browser can remove
account-navigation friction, not the credential decision. Invalid or expired
credentials must produce a clear “remote access not ready” state while leaving
the local server and menu-bar supervisor usable.

### Domain persistence

The free plan’s account-tied development domain is more favorable than the old
README claim that a random hostname necessarily changes on every restart. That
old claim should be removed. Current ngrok product guidance says the assigned
free dev domain stays fixed across agent restarts, which is stable enough for
the intended host name. This spike did not use a real account to test
reboot/reconnect behavior, so the implementation must still treat the full URL
as live state: read it after every agent start/restart and display the current
value. A reserved/custom domain is only needed for a custom domain or stronger
commercial plan guarantees, not for the basic free assigned host.

## Security/trust model

The bootstrap itself executes code from the network, so the user’s first copied
command is necessarily a high-trust action. The safe practical contract is:

- publish the bootstrap only as an immutable release asset, never from a
  mutable branch;
- anchor the bootstrap’s expected SHA-256 or signature out of band: for the
  one-line README command, include the digest of the immutable bootstrap asset
  in the command itself or verify a signed manifest with a pinned public key. A
  hash fetched from the same release location as the script does not
  authenticate that script by itself;
- have the bootstrap verify every downloaded payload before extraction or
  execution, including the pinned uv binary, the managed-Python distribution
  selected by uv (or a directly pinned CPython archive), helper, source files,
  lockfile, and ngrok;
- prefer an offline/private-key-signed manifest in Phase 2 if the maintainer is
  willing to operate a signing key. HTTPS plus an immutable release hash is a
  useful minimum integrity check, not a proof against a compromised release
  account;
- use temporary files, restrictive umasks, atomic writes, and explicit
  architecture/version checks;
- never put the connector capability token, ngrok authtoken, or Keychain value
  in command-line arguments, logs, screenshots, URLs outside the trusted client,
  or crash diagnostics;
- keep ngrok acquisition separate from open-source source distribution and
  preserve its vendor signature;
- make every install step inspectable with a verbose/troubleshooting mode while
  keeping technical progress hidden by default.

The recommended README entry point is a single copy-paste shell line that
downloads a versioned bootstrap to a temporary file, verifies an out-of-band
bootstrap hash or signature, and runs it. A shorter unpinned `curl | bash`
command is not worth the mutable-branch trust and update problem. The release
can also publish the equivalent explicit download/inspect/verify sequence for
users who want to audit before execution.

## Revised Phase 2 proposal

Phase 2 should contain these workstreams and no general product expansion:

1. **Release artifact contract**: arm64 prebuilt Swift helper, stable bundle
   path/identifier, helper checksum/manifest, ad-hoc signature disclosure, and
   no source-build requirement for users.
2. **Terminal bootstrap**: stock-macOS checks, pinned private uv, managed CPython
   3.13.14, frozen lock sync, staged runtime, smoke tests, resumable failure
   marker, repeat install, and no Keychain/config destruction.
3. **Core runtime packaging**: separate core manifest from OCR and indexer
   manifests; keep Meridian out of the base environment; do not yet build a
   generalized plugin/provider system.
4. **Helper and permission onboarding**: start the existing Swift supervisor,
   guide Accessibility/Screen Recording/Automation, test the actual requesting
   process, and expose pending/denied states truthfully.
5. **ngrok onboarding**: verified direct acquisition, original signature
   preservation, app-owned credential/config path, browser dashboard handoff,
   hidden token entry, local endpoint health, current URL discovery, and
   capability URL display.
6. **Client handoff**: show the current authenticated MCP URL and exact setup
   instructions only after the local server and tunnel are ready.
7. **Fresh-machine validation**: no Python/uv/Xcode install, arm64/macOS 13+
   checks, interrupted install, repeat install, missing/invalid ngrok auth,
   quarantined helper, permission denial, endpoint restart, and token redaction.

The Wave 1 Swift control plane, managed Python contract, capability snapshot,
Keychain connector token, lifecycle ownership, persisted port, and existing
status UI remain the foundation. This proposal does not redesign them.

## Blueprint sections that must change

Rewrite or remove the following assumptions in the previous public-release
blueprint and current README/release documentation:

- **Distribution headline**: replace “signed/notarized DMG → GUI-first onboarding”
  with “immutable one-command terminal bootstrap → guided terminal setup →
  prebuilt ad-hoc helper.”
- **Prerequisites**: remove user requirements for Xcode/CLT, Python, uv, Git,
  and source compilation. Keep Apple Silicon and supported macOS as explicit
  checks.
- **Signing and notarization**: remove the claim that a self-signed identity is
  a public distribution solution and the implication that an ad-hoc app is
  Gatekeeper-normal. State the approval/regrant trade-off plainly.
- **TCC/upgrades**: remove the guarantee that self-signed or ad-hoc upgrades
  preserve Accessibility/Screen Recording grants. Preserve the helper path and
  Keychain/config, then re-check/re-guide after helper replacement.
- **Runtime packaging**: replace the “copy checkout and run user uv” flow with
  the staged managed-Python sequence and manifest/checksum contract.
- **Dependency story**: remove indexer/Sentence Transformers and office parsers
  from base-runtime rationale; define core, OCR, Telegram, and Meridian
  boundaries.
- **ngrok acquisition**: remove pyngrok-as-installer, default shared config,
  embedded/re-signed binary, undocumented browser-auth expectation, and the
  unconditional free-hostname-rotation claim. Add direct official acquisition,
  signature/hash checks, credential friction, live endpoint discovery, and
  terms review.
- **Onboarding and troubleshooting**: add permission states per process, ngrok
  auth absence/expiry, quarantine/first-run approval, interrupted install
  recovery, and URL refresh after endpoint restart.
- **Release CI**: later add a hosted arm64 artifact/manifest job and a clean
  stock-macOS bootstrap matrix. Do not weaken the existing Swift/Python gates.

## Deferred work

Explicitly outside this spike and the minimum Phase 2 feasibility contract:

- paid Developer ID enrollment, notarization, DMG signing, and a commercial Mac
  distribution pipeline;
- full updater, uninstaller, rollback product, and support bundle;
- Intel support;
- complete polished TUI and general settings UI;
- redesign of supervisor health/retry behavior beyond the narrow current ngrok
  endpoint discovery compatibility check;
- Meridian provisioning, scheduling, API, Telegram, and indexer deployment;
- expanded Telegram setup;
- remote-provider abstraction, Cloudflare/Tailscale work, hosted relays, and
  Cloudflare resource changes;
- public release/tag/production deployment.

## Validation evidence

Commands run from the dedicated branch:

| Command/check | Result |
| --- | --- |
| `swift build` | Pass; debug build completed. |
| `swift build -c release` | Pass; production build completed. |
| `swift test` | Not pass locally: the installed Command Line Tools environment could not resolve `XCTest` and reported the missing `/Library/Developer/CommandLineTools/Developer/Library/Frameworks` path. No source change was made to hide this environment failure. Hosted macOS 14 CI remains the required suite environment. |
| Python `py_compile` for all tracked Python files | Pass. |
| `PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B test_pagination.py` | Pass; 5 tests. |
| `PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B test_capabilities.py` | Pass; 32 tests. |
| EasyOCR/Torch/Torchvision import check | Pass; EasyOCR 1.7.2, Torch 2.7.1, Torchvision 0.22.1. |
| `uv lock --check` | Pass. |
| `uv sync --frozen --dry-run --python .venv/bin/python` | Pass; no changes. |
| `uv sync --frozen --no-editable --dry-run --python .venv/bin/python` | Pass as a feasibility probe; it showed the editable root would be replaced by a non-editable file install, which the staged installer must use or otherwise validate. |
| repository secret/personal-path scan from CI | Pass. |
| `git diff --check` | Pass on the committed source diff. |

Experimental state was disposable. No existing TCC grant was reset, no Keychain
value or connector token was read, no ngrok token/account was used, no Telegram
message was sent, no external resource was created, and no Meridian or
Cloudflare resource was changed.

## Adversarial review findings

A fresh Luna-family reviewer was asked to challenge the synthesis against the
repository and the current official constraints, specifically for hidden Xcode,
runtime-path, system-Python, Gatekeeper/TCC, curl-pipe, ngrok-secret,
redistribution, dependency, and scope errors.

The material objections and resolutions are:

| Challenge | Resolution |
| --- | --- |
| A prebuilt helper might still imply Xcode/CLT for the user. | Resolved: only a release builder with Swift tooling supplies the complete prebuilt helper/runtime/ngrok set; the bootstrap must never invoke the source-build scripts. The tested arm64 binary then runs without a user build step, but the terminal path is explicitly not a Gatekeeper-clean app path. |
| The helper alone is not a complete install and `/Applications` requires a different privilege assumption. | Resolved: promote helper, runtime, ngrok, and manifest as one verified release set under a stable user-owned Application Support path; `/Applications` is not required. |
| Ad-hoc launch evidence could be overclaimed from `open` exit status. | Resolved: the report records the marker-based result and says `open` exit zero is not evidence. It does not promise launch on every clean Mac. |
| Stable TCC survival was inferred without a granted row. | Resolved: actual grant survival is marked unverified; both helper and Python are revalidated after replacement, and regrant is guided only if the actual requester no longer has its grant. |
| Swift readiness could hide that Python is the TCC requester. | Resolved: helper checks are treated as hints; Phase 2 must identify and check the actual Python/helper processes. No permission transfer is claimed. |
| The moving ngrok URL and pyngrok config behavior are non-reproducible. | Resolved: exact archive URL/hash, direct acquisition, private config/Keychain, and no pyngrok state mutation are required. |
| The current packaging path embeds and re-signs ngrok, while the recommendation preserves ngrok’s vendor signature. | Resolved: Phase 2 must choose the external verified-agent path, or explicitly preserve valid nested code; it must not mix the current force-signing behavior with the new claim. |
| The current supervisor has no ngrok Keychain integration or `NGROK_AUTHTOKEN` injection. | Resolved: that is future Phase 2 behavior, not current functionality; the report requires interactive authentication, restrictive storage, no arguments, and no logs. |
| Pillow is also used by core screenshot paths, and `fastapi`/`uvicorn` need resolver validation. | Resolved: Pillow is shared UI/OCR; `fastapi` is only a removal candidate and `uvicorn` remains a direct-declaration/runtime validation question. |
| A staged `uv sync` could leave editable metadata pointing back at the staging directory. | Resolved: use `--no-editable` for the promoted runtime and assert there are no staging paths in `.pth`/dist-info metadata before promotion. |
| A later uv invocation could silently fall back to system Python. | Resolved: set the managed-Python requirement for every uv invocation and assert version, architecture, and executable path after promotion. |
| Free ngrok URL stability was based on stale README language. | Resolved: the old every-restart claim is removed; current ngrok product guidance documents the assigned dev domain as fixed across restarts. Live endpoint discovery remains mandatory because availability is separate from host stability. |
| A checksum fetched from the same compromised origin is not a complete trust model. | Resolved: anchor the bootstrap digest/signature out of band, use an immutable versioned command, verify every payload, and prefer a signed manifest as the stronger Phase 2 option. |
| Dependency split conclusions could silently become a Phase 2 rewrite. | Resolved: only boundaries and required source seams are decided here; implementation of separate manifests/environments is a Phase 2 workstream, not part of this commit. |

No material objection required changing the architecture decision. The remaining
uncertainties are recorded below rather than converted into guarantees.

## GitHub state

- Branch: `spike/phase2-terminal-bootstrap-feasibility`
- Starting SHA: `a6bd52b8d0e41e580dc5b748522fc1d6897fd6a6`
- Expected source change: this report only.
- The report is committed and the branch is pushed after final diff, secret,
  artifact, and gate checks. No merge, tag, release, or `main` update is part
  of this spike.

## Remaining unknowns

- Actual TCC grant persistence across an ad-hoc helper upgrade and across a
  managed Python runtime replacement; deliberately not tested because it would
  require creating/resetting permissions.
- Clean-machine Gatekeeper behavior for a released, quarantined ad-hoc helper
  launched through the exact future bootstrap and LaunchAgent path; no
  Developer ID/notarized artifact exists for comparison.
- Empirical confirmation with a real account that the assigned development
  domain remains identical after restart, reboot, sleep/wake, and account/plan
  change; current ngrok product guidance says it remains fixed across agent
  restarts, but no account was used here.
- Final post-split lock size and whether PyAutoGUI’s platform import path keeps
  any NumPy/Pillow components in the UI core; this needs the later dependency
  seam implementation and fresh lock.
- The exact ngrok redistribution posture for a future public prebuilt app if the
  maintainer, rather than each end user, were to maintain accounts; obtain legal
  confirmation before choosing that model.
