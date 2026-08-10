# Wave 0 Release Gates Design

**Date:** 2026-08-10
**Baseline:** `cde0912f6d704080ba34a3824be867440d5c46b3` (`v0.2.1`)
**Branch:** `wave0/release-gates`

## Goal

Make the repository's CI and supported release path deterministic and
truthful without changing product code, packaging implementation, signing,
notarization, or the Python/Swift test implementations owned by parallel
sessions.

## Evidence that drives the design

- The v0.2.1 push workflow failed on both Swift compilation and Python
  dependency synchronization, but the GitHub Release was published anyway.
- The failed hosted run selected CPython 3.14.6 because the workflow did not
  select an interpreter. uv reported that locked `torch==2.7.1` had wheels for
  `cp310`, `cp311`, `cp312`, and `cp313`, but not `cp314`.
- The locked native stack has arm64 macOS wheels for CPython 3.10 through
  3.13. A complete frozen sync was verified locally with CPython 3.13.14.
- GitHub API inspection found no branch protection, repository rulesets, or
  tag protection. Workflow code therefore cannot prevent an administrator
  from bypassing it with a manual tag or release.

## CI shape

`.github/workflows/ci.yml` is a reusable workflow as well as the push/PR CI
workflow. Every checkout accepts an immutable `checkout_ref` input; ordinary
push/PR runs default to the event SHA, while the release workflow passes its
fixed dispatch SHA explicitly.

The required jobs are:

1. `Swift build gate (macOS 14)` — pinned checkout, Swift toolchain evidence,
   debug build, and release build.
2. `Python hygiene gate (required)` — compile every tracked Python file with
   the selected interpreter and run the existing secret/personal-path scan.
3. `Python dependency gate (required)` — install CPython 3.13.14, create the
   environment with that exact interpreter, run `uv sync --frozen` against the
   environment's explicit interpreter path, and assert the resulting runtime
   is 3.13.14. It also imports the locked native dependencies without running
   UI actions.
4. `All required release gates` — an `always()` aggregation job that fails
   unless each required job's result is exactly `success`. This gives branch
   protection one stable aggregate check to require and makes failure
   propagation explicit.

The full existing behavioral suite remains in
`Python UI checks (informational)`. It uses the same pinned environment but is
allowed to fail because hosted macOS does not provide the Accessibility,
Screen Recording, or interactive-console grants needed to interpret those
checks authoritatively. Its failure remains visible as an informational job;
the separate required dependency gate prevents setup/toolchain failures from
being treated as acceptable evidence.

The Session 1 integration point is a new required step immediately after the
frozen sync in `Python dependency gate (required)`. Once Session 1's committed
deterministic/offline command exists, the integrator should add that exact
command there with no `continue-on-error`, preserve the pinned `.venv/bin/python`
invocation, and document its final command in the release guide. This branch
does not invent a future file or command.

## Toolchain policy

The workflow pins:

- CPython `3.13.14`, selected through `setup-uv` and then explicitly installed
  and used by `uv venv`, `uv sync`, and the verification command.
- uv `0.12.3` through `astral-sh/setup-uv`.
- `actions/checkout` `v7.0.1` at commit
  `3d3c42e5aac5ba805825da76410c181273ba90b1`.
- `astral-sh/setup-uv` `v9.0.0` at commit
  `c771a70e6277c0a99b617c7a806ffedaca235ff9`.
- Hosted runner labels `macos-14` for Swift/Python native checks and
  `ubuntu-24.04` for orchestration-only validation/publication jobs.

The action SHAs are immutable; the adjacent version comments make updates
auditable. A future update should change the displayed version and SHA
together, validate the action metadata/release, and rerun the full workflow.
The Swift package's existing `// swift-tools-version: 5.9` declaration remains
the source-level minimum; the hosted macOS image still supplies the installed
Swift/Xcode patch version, which the workflow prints for evidence.

## Release flow

`.github/workflows/release.yml` is the supported release mechanism and is
manual-only. The operator must dispatch it from `main` with a new `vMAJOR.MINOR.PATCH`
tag input.

1. The workflow captures `github.sha` as the release SHA and publishes it as
   the validation job's `release_sha` output. Validation checks
   that the dispatch ref is exactly `refs/heads/main`, `HEAD` equals that SHA,
   the SHA is the current remote `main` commit, the tag is valid and unused,
   and the tag has not already been created remotely.
2. The reusable CI workflow is called with
   `needs.validate-release.outputs.release_sha` as `checkout_ref`.
   Every required CI checkout therefore tests the exact source that the
   release job will target. No mutable branch ref is used for the gate.
3. The publication job depends on target validation and the reusable workflow.
   It rechecks the remote `main` SHA and tag absence, then runs
   `gh release create "$TAG" --target "$RELEASE_SHA"`. The tag/release is the
   first publication-side effect and only occurs after the checks succeed.

There is no release, tag, or artifact publication in this Wave 0 task.

## Enforcement boundary

The automated path fails closed for a failed required job, a changed/mismatched
target SHA, an invalid tag, or an existing tag. It cannot stop a repository
administrator from manually creating a tag or release, editing workflow files,
or bypassing Actions entirely. Repository administrators should later add
branch protection/rulesets requiring `All required release gates` on `main`
and restrict creation of `v*` tags. Those settings are deployment controls,
not claims made by this repository change.
