# Phase 5F Mac Meridian Product Hardening Implementation Plan

> Execute on `phase5f/mac-meridian-product-hardening`, based exactly on
> `48f19fbbcfeb0c8cbe77486237342704f4dbbeb6`.

## 1. Freeze the contract and red tests

- Add focused tests for the frozen `control_version`/action request shape,
  bounded final results, safe progress events, and the rule that exit 0 without
  a trusted final result is not success.
- Add readiness tests covering missing evidence, full proof, changed deployment
  or tool digest, and no token access when disabled.
- Preserve the existing Phase 5C tests and update only assertions made obsolete
  by the frozen Core contract.

## 2. Implement readiness evidence and lifecycle

- Add a bounded receipt/tool-proof model and atomic store.
- Extend the existing coordinator with an injected Meridian-owned probe seam.
- Replace the hard-coded `meridianSearchReady: false` with the complete proof.
- Update the existing indexer invocation, final-result parser, installer receipt,
  schedule modes, pause/resume, wake reconciliation, generation fences, and
  explicit control actions without adding a second state machine.
- Notify `ProcessSupervisor` when readiness evidence changes so the existing
  launch-contract/client-refresh machinery is reused.

## 3. Complete the Python seam and native UX

- Harden the existing `vector_search()` implementation against route drift,
  redirects, malformed responses, unsafe result fields, and raw error leakage.
- Keep Local Pattern Search independent.
- Extend the existing MenuController/ProcessSupervisor with explicit source
  selection, preview, scan/schedule/run controls, and confirmed data deletion.

## 4. Doctor and support privacy

- Add read-only Meridian facts/checks to the existing Doctor vocabulary.
- Ensure disabled checks skip without credential/network access.
- Add adversarial planted-data support tests and include only safe bounded
  Meridian metadata in the support plan.

## 5. Verification and delivery

- Run Swift debug/release builds, hosted-authoritative XCTest where local CLT
  lacks XCTest, Python deterministic tests, capability/policy/dependency tests,
  privacy scans, and `git diff --check`.
- Dispatch one fresh Luna Max reviewer with no implementation responsibility;
  fix substantiated findings.
- Push the exact branch, open a new draft PR to `main`, wait for exact-head
  hosted CI, repair bounded failures, and record `MAC_PHASE5F_SHA` only after
  the final head and CI evidence match.
