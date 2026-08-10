# Release and CI gates

This document defines the supported Wave 0 release path for Mac Orchestrator.
It is intentionally narrower than the future signed/notarized app distribution
process: the current release mechanism publishes a source archive, while
packaging, signing, notarization, and public DMG work remain separate.

Wave 0 establishes the gate. It does not create a release, tag, source archive,
or public artifact.

## Toolchain contract

The project metadata declares Python `>=3.10`, but the complete locked native
dependency set is bounded by the wheels that actually exist for the lock. The
locked `torch==2.7.1` and `torchvision==0.22.1` packages have Apple Silicon
macOS wheels for CPython 3.10, 3.11, 3.12, and 3.13. They do not have a
CPython 3.14 wheel. The v0.2.1 CI failure selected CPython 3.14.6 implicitly
and uv stopped at `torch==2.7.1` before running the behavioral suite.

CI therefore uses this deliberate toolchain:

| Component | Version or label | Enforcement |
| --- | --- | --- |
| Python | CPython `3.13.14` | `setup-uv` input, `uv python install --managed-python`, `uv venv --managed-python --python`, and a runtime version assertion |
| uv | `0.12.3` | Exact `astral-sh/setup-uv` input |
| `actions/checkout` | `v7.0.1` / `3d3c42e5aac5ba805825da76410c181273ba90b1` | Immutable action reference |
| `astral-sh/setup-uv` | `v9.0.0` / `c771a70e6277c0a99b617c7a806ffedaca235ff9` | Immutable action reference |
| Native runner | `macos-14` | Swift and Python native jobs |
| Orchestration runner | `ubuntu-24.04` | Gate aggregation and release validation/publication |

The required Python jobs create `.venv` with CPython 3.13.14 and run
`uv sync --managed-python --frozen --python .venv/bin/python`. Installing a
Python version without passing it to uv is not sufficient and is not the CI
contract.

Action updates must change the displayed version and immutable SHA together.
Validate the new action metadata and rerun the complete workflow before
updating this table.

## Required versus informational checks

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`, and is
also callable by the release workflow at an explicit commit SHA.

| Job name | Required for release? | Responsibility |
| --- | --- | --- |
| `Swift build gate (macOS 14)` | Yes | Prints the Swift toolchain and runs debug and release SwiftPM builds. |
| `Python hygiene gate (required)` | Yes | Uses the pinned Python to compile every tracked Python file and runs the existing secret/personal-path scan. |
| `Python dependency gate (required)` | Yes | Uses the pinned Python, performs a frozen lock sync, and imports the locked EasyOCR/Torch/Torchvision native stack without exercising UI automation. |
| `All required release gates` | Yes | Runs after the three deterministic jobs and exits nonzero unless every one has result `success`. This is the stable aggregate check to require in branch protection. |
| `Python UI checks (informational; TCC-dependent)` | No | Attempts the full behavioral suite for evidence. Its result is non-blocking because hosted macOS does not supply the Accessibility, Screen Recording, and interactive-console grants needed to interpret UI checks authoritatively. |

The informational job is visibly separate and retains the full suite. Its
non-blocking status does not make dependency setup authoritative: the required
Python dependency gate performs the same pinned frozen synchronization and
fails the aggregate if that deterministic setup fails.

The existing `test_mcp_server.py` suite remains authoritative only on a real,
unlocked Mac with the required permissions granted to the exact Python binary
running it. A hosted-runner permission skip is evidence about the runner, not
proof that the UI behavior passed.

## Session 1 deterministic-test integration

This branch deliberately does not name a test file or command that has not
landed yet. After Session 1's deterministic/offline Python entry point is
merged:

1. Add a new step named `Run deterministic Python tests (required)` immediately
   after `Sync the locked dependency set with the exact interpreter` in the
   `python-dependency-gate` job.
2. Use Session 1's exact committed command, invoking the pinned
   `.venv/bin/python` (or `uv run --python .venv/bin/python` if that is the
   entry point's documented contract).
3. Do not add `continue-on-error` to the step or job. A deterministic failure
   must make `python-dependency-gate` fail and therefore make
   `All required release gates` fail.
4. Keep the command out of `python-ui-informational`; TCC-dependent evidence
   must not be used as a release gate.
5. Record the final command and its source path in this guide after the
   integration merge. Because the release workflow calls the reusable CI
   workflow, no second release-workflow copy of the command is needed.

The integration must not modify Session 1's test implementation as part of the
CI wiring, and it must not pull Session 1's unmerged files into this branch.

## Supported release path

Use `.github/workflows/release.yml` for an official release. Do not create the
tag first and rely on a later push workflow to discover a failure.

1. Merge the intended source commit to `main` and wait for its normal CI result.
2. In GitHub Actions, choose the `Release` workflow, select the `main` branch,
   and provide a new `vMAJOR.MINOR.PATCH` tag input. Do not dispatch it from a
   tag, another branch, or a local checkout.
3. The workflow captures `github.sha` as `RELEASE_SHA`. Validation checks that
   the dispatch ref is exactly `refs/heads/main`, the checked-out `HEAD` is
   that SHA, the SHA is the current remote `main` commit, the tag matches the
   semantic `vMAJOR.MINOR.PATCH` form, and the tag is absent.
4. Only after validation succeeds does the workflow call the reusable CI
   workflow with `checkout_ref: ${{ github.sha }}`. Every source checkout in
   that workflow therefore tests the same immutable commit.
5. The publication job depends on validation and the reusable CI caller job.
   It rechecks the exact SHA, current remote `main`, and tag absence. If `main`
   moved or any required gate failed, publication is skipped or fails before
   the release command.
6. Only after those checks does the job run `gh release create` with
   `--target "$RELEASE_SHA"`. This creates the tag/release at the verified
   commit; it does not retarget a mutable branch.

The workflow publishes GitHub's source archive and generated release notes via
the normal GitHub Release mechanism. It does not build or upload a public DMG,
and this Wave 0 task does not invoke it.

## Enforcement boundary

The supported automated path fails closed for a failed required job, a failed
aggregate, a non-`main` dispatch, a mismatched or moved target SHA, an invalid
tag, or an existing tag. The publication job has no `always()` condition and
cannot run unless its `needs` jobs succeed.

At the Wave 0 inspection on 2026-08-10, GitHub reported:

- `main` branch protection: not protected (`404`, `Branch not protected`);
- repository rulesets: empty list;
- tag protection endpoint: not configured (`404`).

Workflow code cannot prevent a repository administrator from manually creating
a tag or release, editing the workflow, pushing around the supported path, or
bypassing Actions. To close that repository-level boundary, an administrator
must later configure rules outside this repository change:

- protect `main` and require the `CI / All required release gates` check before
  merging or allowing direct updates; and
- restrict creation of `v*` tags to the supported release identity or approved
  maintainers.

Those settings are recommendations and are not claimed to exist until verified
through GitHub repository settings.
