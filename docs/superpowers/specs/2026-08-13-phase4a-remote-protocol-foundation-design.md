# Mac Orchestrator Phase 4A: Remote Protocol / Provider Foundation

## Goal

Create deterministic, isolated primitives for the ngrok remote connector and a canonical authenticated remote MCP activation probe without wiring either primitive into `ProcessSupervisor`.

## Confirmed provider facts

The current official ngrok documentation confirms:

- The local Agent API defaults to `http://127.0.0.1:4040/api`, has no authentication, and moves with the configured `web_addr`: <https://ngrok.com/docs/agent/api>.
- `GET /api/endpoints` returns an `endpoints` array whose endpoint objects contain `url` and `upstream.url`: <https://ngrok.com/docs/agent/api>.
- The Agent API promises that breaking changes are opt-in; additive resources, methods, and fields are non-breaking: <https://ngrok.com/docs/agent/api>.
- Agent configuration v3 uses `version: 3`, `agent`, and `endpoints`; `tunnels` is deprecated: <https://ngrok.com/docs/agent/config/v3>.
- The free plan supplies an assigned development domain. Its browser interstitial does not affect programmatic endpoint access, so the connector client has no reason to send `ngrok-skip-browser-warning`: <https://ngrok.com/docs/pricing-limits/free-plan-limits>.

These facts do not contradict the Phase 4A design.

## Architecture

### Remote connector adapter

`RemoteConnectorAdapter` is a deliberately small protocol covering only launch-relevant prerequisite validation, launch specification construction, local Agent API inspection, endpoint reconciliation, and safe provider diagnostics. `NgrokRemoteConnectorAdapter` is the only implementation.

The adapter accepts an injected Agent API base URL and URL session. Its production default is `http://127.0.0.1:4040/api`; no inspector-port configuration field is added. The adapter creates the existing ngrok process arguments and environment in memory, but owns no `Process`, PID, retry, or lifecycle state.

`RemoteEndpointReconciliation` is a typed result with these cases:

- `current(publicURL:)` — exactly one valid HTTPS endpoint matches the normalized expected upstream;
- `missing` — a valid response contains no endpoints;
- `foreign` — endpoints exist but none match the expected upstream;
- `ambiguous` — multiple valid HTTPS candidates match;
- `agentAPIUnavailable` — the local Agent API could not be read as an HTTP success;
- `invalidAgentAPIResponse` — the response is malformed, deprecated tunnel-shaped, or has an invalid matching public endpoint.

The compatibility methods on `NgrokEndpointParser` remain available for current callers. They delegate to the typed reconciliation rather than reimplementing matching.

### Shared MCP activation engine

`MCPActivationProtocolEngine` owns the common MCP sequence:

1. initialize with the existing protocol version and client identity;
2. require a valid `Mcp-Session-Id`;
3. send `notifications/initialized`;
4. call `tools/list`;
5. validate either required-only or exact inventory according to an explicit policy;
6. call `get_session_state` and require an application-level success.

The engine rejects redirects by both using the no-redirect URL session and checking that each HTTP response URL equals the request URL. Each request has a bounded timeout and the engine performs exactly one request per protocol step.

`LocalActivationProbe` retains its existing public types, exact local health status/body check, optional interactive-UI requirement, error text, and outcome phases. It delegates only the MCP portion to the shared engine. Local inventory remains required-only to preserve current callers that expose optional tools.

### Remote activation probe

`RemoteActivationProbe` receives a complete HTTPS MCP URL and an explicit expected safe tool inventory. The URL is retained only in the probe/engine object graph while the attempt runs. It has no URL-bearing result, error, `description`, or `debugDescription`.

The remote probe maps all shared-engine failures to URL-free `RemoteActivationProbeError` values. It uses a non-browser Mac Orchestrator User-Agent, never adds `ngrok-skip-browser-warning`, does not inspect local Accessibility/session-lock state, and does not retry.

The successful detail contains only the exposed tool names, session-established fact, and safe-call success. Phase 4D can combine the uncredentialed public endpoint from adapter reconciliation with the capability token at its integration boundary; the probe itself never returns that constructed connector URL.

## Error and security rules

- Do not interpolate credential URLs, capability tokens, response bodies, or `URLSession` errors into remote error values or logs.
- Do not print or retain `URLRequest` debug descriptions.
- Treat every remote HTTP response URL mismatch as a redirect failure, including initialize, initialized notification, tools/list, and safe call.
- Treat exact inventory mismatch as a readiness failure; no privileged tool is accepted merely because `get_session_state` exists.
- Keep retries/backoff outside both the adapter and probe.
- Use the current `/api/endpoints` contract only; reject `/api/tunnels` payloads.

## Verification boundary

All new tests use `URLProtocol` fixtures and pure JSON data. No test starts ngrok, reaches the network, or persists credentials. Verification includes focused red-green tests, the existing LocalActivationProbe suite, `swift test`, relevant Python protocol tests if available, `git diff --check`, and a source-level adversarial review for URL/token leakage.
