# Wave 0 Release Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CI authoritative for deterministic checks and make the supported release workflow publish only the exact SHA whose required gates passed.

**Architecture:** Convert the existing CI workflow into a reusable workflow with immutable checkout-ref propagation, three required native gates, one explicitly informational UI/TCC job, and a final aggregate required-gates job. Add a manual `main`-only release workflow that captures `github.sha`, calls the reusable CI workflow at that SHA, rechecks the remote ref immediately before publication, and creates the tag/release only after every required result succeeds.

**Tech Stack:** GitHub Actions YAML, macOS 14 hosted runners, Ubuntu 24.04 orchestration runners, SwiftPM, CPython 3.13.14, uv 0.12.3, GitHub CLI, Markdown documentation.

## Global Constraints

- Base the branch on `cde0912f6d704080ba34a3824be867440d5c46b3` / `origin/main`.
- Work only on `wave0/release-gates` in the isolated worktree.
- Pin CPython to `3.13.14` because the locked Torch/Torchvision wheel set supports CPython 3.10–3.13 and not 3.14.
- Pin uv to `0.12.3`, `actions/checkout` to commit `3d3c42e5aac5ba805825da76410c181273ba90b1`, and `astral-sh/setup-uv` to commit `c771a70e6277c0a99b617c7a806ffedaca235ff9`.
- Every uv command that creates, syncs, or verifies the environment must receive the exact interpreter or exact environment interpreter path.
- Required jobs must not use `continue-on-error`; only the hosted-macOS behavioral/UI job may be non-blocking.
- Do not edit `test_mcp_server.py`, `automac_mcp.py`, `Package.swift`, Swift production sources, Swift tests, or `uv.lock`.
- Do not create, publish, delete, replace, or retag a GitHub release or tag.
- Do not claim branch protection, rulesets, or tag protection; document the verified absence and the resulting administrator bypass boundary.

---

### Task 1: Replace ambiguous CI with reusable, named release gates

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: repository source at the event SHA for push/PR runs, or the caller-provided `workflow_call` input `checkout_ref` for release runs.
- Produces: required job results `swift-build-gate`, `python-hygiene-gate`, `python-dependency-gate`, aggregate job `required-gates`, and informational job `python-ui-informational`.

- [ ] **Step 1: Define the workflow triggers and immutable checkout input.**

Add `workflow_call` with an optional string input named `checkout_ref`. Keep push and pull-request triggers for `main`. Set workflow-level `permissions: contents: read`, and use `ref: ${{ inputs.checkout_ref || github.sha }}` in every source checkout.

- [ ] **Step 2: Implement the Swift required gate.**

Use `runs-on: macos-14` and checkout `actions/checkout` at the pinned SHA with `fetch-depth: 1`. Print `swift --version`, then run both:

```yaml
- name: Swift debug build
  run: swift build
- name: Swift release build
  run: swift build -c release
```

Do not change `Package.swift` or Swift source to make this job pass.

- [ ] **Step 3: Implement the required Python hygiene gate.**

Use the pinned setup-uv action with `version: 0.12.3` and `python-version: 3.13.14`. Explicitly run `uv python install 3.13.14`, create `.venv` with `uv venv --python 3.13.14 .venv`, and compile tracked Python files with `.venv/bin/python -B -m py_compile`. Preserve the existing secret-shaped-string and personal-absolute-path scan, with `set -euo pipefail` and explicit failure on a match.

- [ ] **Step 4: Implement the required Python dependency gate.**

Repeat the pinned uv/Python setup. Run:

```bash
uv python install "$PYTHON_VERSION"
uv venv --python "$PYTHON_VERSION" .venv
uv sync --frozen --python .venv/bin/python
.venv/bin/python -c 'import sys; assert sys.version_info[:3] == (3, 13, 14); import easyocr, torch, torchvision; print(sys.executable); print(torch.__version__); print(torchvision.__version__)'
```

The existing Session 1 deterministic command must later be added as a separate required step immediately after the frozen sync; do not invent that command or a future test filename on this branch.

- [ ] **Step 5: Keep the full suite explicitly informational.**

Create `python-ui-informational` on `macos-14` with `continue-on-error: true`, the same pinned environment setup and frozen sync, and the existing `PYTHONDONTWRITEBYTECODE=1 uv run python -B test_mcp_server.py` behavioral command. Name the job and step as TCC/UI-dependent. Do not move this command into any required job.

- [ ] **Step 6: Add the aggregate required-gates job.**

Run it on `ubuntu-24.04` with `if: always()` and `needs` containing only `swift-build-gate`, `python-hygiene-gate`, and `python-dependency-gate`. Compare each of `needs.swift-build-gate.result`, `needs.python-hygiene-gate.result`, and `needs.python-dependency-gate.result` to `success` in a `set -euo pipefail` shell step. Print the three results and exit 1 if any is not exactly `success`; exit 0 only when all three are successful.

- [ ] **Step 7: Validate the workflow structure before moving on.**

Run `actionlint .github/workflows/ci.yml` if available. Also parse the YAML with an available parser and inspect the rendered job IDs/names. Confirm the file contains no `continue-on-error` under required jobs, every checkout uses the pinned SHA, and every Python setup includes both the pinned uv version and Python version.

- [ ] **Step 8: Commit the CI change.**

```bash
git add .github/workflows/ci.yml
git diff --cached --check
git commit -m "ci: split deterministic and informational release gates"
```

The commit body must state why Python 3.13.14 is selected, which jobs are required, why UI checks remain informational, and how the aggregate job fails closed.

### Task 2: Add exact-SHA manual release automation

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `workflow_dispatch` input `tag`, selected workflow ref, and immutable `github.sha`.
- Produces: a GitHub tag/release only from the exact dispatch SHA after the reusable CI workflow and validation succeed. This task must not invoke the workflow.

- [ ] **Step 1: Define a manual-only, main-only workflow.**

Use `workflow_dispatch` with a required `tag` string input. Set top-level `permissions: contents: read` and a concurrency group keyed by the requested tag. The validation and publication jobs must reject any dispatch whose `github.ref` is not exactly `refs/heads/main`.

- [ ] **Step 2: Validate the target SHA and tag before CI.**

On `ubuntu-24.04`, checkout `ref: ${{ github.sha }}` with `fetch-depth: 0` using the pinned checkout SHA. In a `set -euo pipefail` step, verify:

```bash
test "$GITHUB_REF" = "refs/heads/main"
test "$RELEASE_SHA" = "$(git rev-parse HEAD)"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]]
git fetch --no-tags origin main
test "$RELEASE_SHA" = "$(git rev-parse origin/main^{commit})"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
test -z "$(git ls-remote --refs origin "refs/tags/$RELEASE_TAG")"
```

Use environment variables rather than interpolating untrusted input into shell source.

- [ ] **Step 3: Call reusable CI at the fixed SHA.**

Add a reusable-workflow job that calls `./.github/workflows/ci.yml` and passes the `validate-release` job's `release_sha` output as `checkout_ref`. Give the caller job a clear name such as `required-ci-at-release-sha`. Do not call CI on `main`, `HEAD`, or a tag ref without the explicit SHA input.

- [ ] **Step 4: Gate publication on validation and reusable CI.**

Make the publication job depend on both validation and the reusable CI caller job. Do not use `always()` on publication. Re-check `refs/heads/main` and the remote main SHA in the publication job, re-check that the requested tag is still absent, and verify the checked-out `HEAD` remains `$GITHUB_SHA`.

- [ ] **Step 5: Create the future release only after all checks.**

Use job-level `permissions: contents: write` only for publication and run:

```bash
set -euo pipefail
gh release create "$RELEASE_TAG" --target "$RELEASE_SHA" --title "$RELEASE_TAG" --generate-notes
```

Pass `GH_TOKEN: ${{ github.token }}` through the environment. Do not add a release trigger, tag trigger, artifact upload, or dry-run publication command that could create state during this task.

- [ ] **Step 6: Validate failure propagation without publishing.**

Use a local shell harness or extracted command fragments to prove that a failed validation or required-gates result exits before the `gh release create` line. Confirm the committed workflow has no `if: always()` on publication and that publication’s `needs` includes both validation and CI.

- [ ] **Step 7: Commit the release workflow.**

```bash
git add .github/workflows/release.yml
git diff --cached --check
git commit -m "ci: gate releases on the exact verified commit"
```

The commit body must explain immutable SHA propagation, fail-closed dependencies, the no-tag-before-gates invariant, and the repository-settings limitation.

### Task 3: Document CI/release responsibilities and integration

**Files:**
- Create: `docs/RELEASING.md`
- Modify: `CONTRIBUTING.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: final workflow job IDs/names and exact command behavior from Tasks 1 and 2.
- Produces: operator instructions that distinguish gates from evidence and explain the Session 1 integration step without naming a nonexistent command.

- [ ] **Step 1: Write the release guide.**

Document the pinned versions, evidence for CPython 3.13.14, required job names, informational UI/TCC rationale, manual dispatch from `main`, exact SHA capture/propagation/recheck, tag validation, and the fact that no release is cut in Wave 0.

- [ ] **Step 2: Document the Session 1 integration point.**

State that after Session 1 merges its deterministic/offline test entry point, the integrator adds that exact command as a required step immediately after `uv sync --frozen --python .venv/bin/python` in `python-dependency-gate`. The command must use the pinned environment, have no `continue-on-error`, and remain outside `python-ui-informational`. Record the final command in the release guide after integration.

- [ ] **Step 3: Document GitHub-setting limitations.**

State that the repository currently has no branch protection, rulesets, or tag protection, based on the checked API results. Recommend requiring the aggregate `All required release gates` check on `main` and restricting `v*` tag creation, while explicitly saying workflow code cannot prevent an administrator bypass.

- [ ] **Step 4: Update existing contributor/README test references.**

Keep local behavioral-test instructions and their TCC requirements. Replace the old statement that the full Python run is merely a general best-effort CI job with the final required/informational job names and the release-guide link. Do not alter product setup, package versions, or release version numbers.

- [ ] **Step 5: Review docs for scope and stale claims.**

Run `rg -n -i 'continue-on-error|informational|required|release|tag|3\.14|3\.13\.14|branch protection|ruleset' README.md CONTRIBUTING.md docs/RELEASING.md`. Ensure no documentation says v0.2.1 passed CI, says tag protection exists, or presents the UI job as authoritative.

- [ ] **Step 6: Commit the documentation change.**

```bash
git add docs/RELEASING.md CONTRIBUTING.md README.md
git diff --cached --check
git commit -m "docs: define release gates and CI enforcement limits"
```

### Task 4: Full verification and adversarial review

**Files:**
- Verify: `.github/workflows/ci.yml`
- Verify: `.github/workflows/release.yml`
- Verify: `docs/RELEASING.md`, `CONTRIBUTING.md`, `README.md`

- [ ] **Step 1: Validate all workflow YAML.**

Run `actionlint .github/workflows/ci.yml .github/workflows/release.yml` when available; otherwise use a YAML parser plus targeted structural assertions for triggers, job IDs, pinned SHAs, `needs`, `if`, and `continue-on-error` placement. Record the exact tool and outcome.

- [ ] **Step 2: Re-run the pinned dependency sync locally.**

In a temporary environment outside the repository’s working tree, record the available local uv version, create `tmp_dir="$(mktemp -d)"`, run `uv venv --python 3.13.14 "$tmp_dir/.venv"`, then run `UV_PROJECT_ENVIRONMENT="$tmp_dir/.venv" uv sync --project "$PWD" --frozen --python "$tmp_dir/.venv/bin/python"` and the exact runtime assertion/import check. Confirm the repository’s `uv.lock` remains unchanged; the CI workflow itself is the authority for uv 0.12.3 because it installs that version through setup-uv.

- [ ] **Step 3: Run equivalent required commands locally where possible.**

Run the Python hygiene compile/secret scan and `git diff --check`. Run `swift build` and `swift build -c release` on this baseline branch; if the known Session 2 Swift source still fails, record the exact failure and do not modify Swift files to make it green.

- [ ] **Step 4: Simulate failed required gates.**

Run a shell-only harness with one required result set to `failure` and verify the aggregate logic exits nonzero. Run a second harness with validation failure before a stubbed publication marker and verify the marker is not reached. Do not execute `gh release create` and do not commit the harness.

- [ ] **Step 5: Inspect for secret leakage and release side effects.**

Review workflow logs/commands for absence of token values, search the diff for secret-like strings, verify no `gh release create` command was executed, inspect `gh release list` and `git tag` after work, and confirm only the intended branch/worktree changed.

- [ ] **Step 6: Perform final self-review and commit status check.**

Read both workflows top-to-bottom as an operator. Confirm publication cannot run when any required gate fails, every gate checks the same SHA, UI/TCC checks are not authoritative, the Python interpreter is explicit at every uv boundary, action versions are immutable, and Session 1/2 files are absent from the diff. Run `git diff --check`, `git status --short --branch`, and `git log --oneline --decorate -5`.
