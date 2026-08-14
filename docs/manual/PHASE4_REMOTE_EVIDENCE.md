# Phase 4 Remote Doctor / Client-Recovery Evidence Matrix

This is a maintainer/manual test record for remote lifecycle behavior. The
Phase 4D implementation has deterministic adapter, lifecycle, handoff, and
credential-transaction seams, but this file contains no fabricated live
provider observations. Until a maintainer performs a row on a real dedicated
Mac/account, mark that row `MANUAL EVIDENCE REQUIRED`.

Record only public hostname observations and typed Doctor outcomes. Never paste
a capability path, connector URL, capability credential, ngrok credential, MCP
request body, response body, or client-private configuration into this record.
If a result needs more detail, record a redacted event identifier or a status
category, not the secret-bearing value.

## Result vocabulary

- Public hostname: `same`, `changed`, or `unavailable`; record the hostname only
  if the maintainer's approved test log already treats it as public, and never
  record its path or credential-bearing suffix.
- Agent API classification: `available`, `unavailable`, `malformed`,
  `noExpectedUpstream`, `foreignOnly`, `ambiguous`, or `established`.
- Authenticated MCP result: `notRun`, `authenticationRejected`,
  `initializeSessionFailed`, `inventoryMismatch`, `safeCallFailed`, or `ready`.
- Client handoff: `notAvailable`, `unchanged`, or `changed`; `changed` is valid
  only when a known/manual handoff receipt is available.

## Matrix

Current status: all real provider/lifecycle rows below are
`MANUAL EVIDENCE REQUIRED`. Hosted XCTest and deterministic fakes do not prove
sleep/wake, reboot, network transitions, account replacement, or live ngrok
domain behavior.

| Case | Preconditions | Public hostname observation only | Expected Agent API classification | Expected authenticated MCP result | Expected client-handoff state | Result fields to fill |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline | Local MCP is fully ready; managed helper and ngrok are running; record a handoff receipt if the test has one. | `same` or `unavailable` before the first live query; do not infer persistence. | `available` followed by `established` for exactly one expected upstream. | `ready` only after the full nonsecret probe runs; otherwise `notRun`. | `unchanged` with a receipt, otherwise `notAvailable`. | `hostname=<same/changed/unavailable>; agent=<...>; auth=<...>; handoff=<...>` |
| ngrok agent restart | Baseline is healthy; restart only the managed ngrok agent. | Record whether the public hostname is `same`, `changed`, or `unavailable`. | May be `unavailable` during restart; after re-query expect `available` and then `established`, or an explicitly observed failure state. | Re-run the probe after endpoint state is re-established; do not reuse the prior PASS. | `unchanged` if the recorded connector identity is unchanged; otherwise `changed`; with no receipt use `notAvailable`. | `hostname=<...>; agentBefore=<...>; agentAfter=<...>; authAfter=<...>; handoff=<...>` |
| Helper restart | Baseline is healthy; restart the Mac Orchestrator helper through its supported lifecycle. | Record public hostname state after startup; no assumption that restart changes it. | Re-query Agent API; expect `available`/`established` only after the managed process is owned and live. | `notRun` until the current endpoint is probed; then record the typed result. | Compare only with the known handoff receipt. | `hostname=<...>; process=<missing/owned/ambiguous>; agent=<...>; auth=<...>; handoff=<...>` |
| Sleep/wake | Baseline is healthy; put the Mac to sleep, wake it, and wait for the supported helper recovery window. | Record public hostname state after wake. | May be `unavailable` during wake recovery; re-query and record the resulting classification. | Re-probe current endpoint; never infer that the previous client URL remains valid. | `unchanged`/`changed` only with a receipt; otherwise `notAvailable`. | `hostname=<...>; agent=<...>; auth=<...>; handoff=<...>` |
| Wi-Fi/network down-up | Baseline is healthy; disconnect the active network and restore it without changing accounts. | Record `unavailable`, `same`, or `changed` hostname state after reconnection. | Expect a fresh query; record transient `unavailable` or final `established`/other state. | Probe only after endpoint establishment; record failure stage if it does not recover. | Compare the current connector identity with the receipt, not the hostname alone. | `hostname=<...>; agent=<...>; auth=<...>; handoff=<...>` |
| Network change | Baseline is healthy; move between networks or materially change the route. | Record only public hostname state before and after the move. | Re-query Agent API and expected upstream; do not treat a 404 or hostname difference as sufficient diagnosis. | `notRun` until current endpoint is confirmed; then record the typed result. | Receipt-backed comparison only. | `hostnameBefore=<...>; hostnameAfter=<...>; agent=<...>; auth=<...>; handoff=<...>` |
| Full reboot | Baseline is healthy; record supported installation/lifecycle preconditions, then reboot. | Record public hostname state after the managed helper is back. | Do not assume domain or endpoint persistence; expect live re-query and record the actual state. | Full probe required after startup; record `notRun` until it occurs. | Receipt-backed `unchanged`/`changed`; absent evidence is `notAvailable`. | `hostname=<...>; agent=<...>; auth=<...>; handoff=<...>` |
| Same-account ngrok authtoken replacement | Baseline is healthy; replace the provider credential through the protected maintainer workflow while keeping the same account. | Record public hostname state after recovery; do not record the credential. | Record provider credential accepted/rejected and the resulting endpoint state; do not infer from hostname alone. | Re-probe the current connector; record the actual stage result. | `unchanged` if connector identity is unchanged; `changed` only with receipt evidence; otherwise `notAvailable`. | `hostname=<...>; providerCredential=<accepted/rejected>; agent=<...>; auth=<...>; handoff=<...>` |
| Different-account credential replacement | Baseline is healthy; replace the provider credential with one from a different account through protected input. | Record only whether the public hostname is `same`, `changed`, or `unavailable`. | Record provider acceptance/rejection plus exact-upstream classification; account/domain changes are live observations. | Probe only the current established endpoint and record the result. | A changed handoff requires known receipt evidence; without it, report `notAvailable`, never “client X is stale.” | `hostname=<...>; providerCredential=<accepted/rejected>; agent=<...>; auth=<...>; handoff=<...>` |
| Invalid credential then recovery | Start from baseline; submit an intentionally invalid provider credential, then restore a valid one through protected input. | Record hostname state without recording either credential. | During failure expect provider rejection or managed-process/Agent API unavailability; after recovery re-query to classify the endpoint. | During failure expect `notRun` or the actual rejection stage; after recovery record the full probe result. | No client conclusion without a handoff receipt; record `notAvailable` when absent. | `failureAgent=<...>; failureAuth=<...>; recoveryAgent=<...>; recoveryAuth=<...>; handoff=<...>` |
| Connector capability-token rotation | Baseline is healthy with a known/manual client handoff receipt; rotate through the supported credential workflow when available. | Record public hostname state only; rotation may be independent of hostname. | Re-query and record current endpoint state; do not use raw 404 as the diagnosis. | Current connector probe may be `ready`; old client behavior is not a Doctor probe of arbitrary client settings. | With the receipt, expect `changed` and a manual reconfiguration warning; without it, `notAvailable`. | `hostname=<...>; agent=<...>; auth=<...>; handoff=<...>; reconfigure=<required/not-established>` |

## Interpretation rules

1. A matching Agent API endpoint is not authenticated remote readiness.
2. A current endpoint plus a changed connector identity is a client-handoff
   warning, not a remote-service failure, when the current remote probe is
   healthy.
3. A raw HTTP 404 is not sufficient to call a client stale; it may represent a
   credential/path mismatch, stale route, or another ingress state.
4. No row authorizes editing a private client configuration or recording a
   capability-bearing URL.
