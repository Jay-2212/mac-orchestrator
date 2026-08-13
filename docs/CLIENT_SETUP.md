# Client setup

Complete this page only after the installer reports `Local connection ready.`
That message is emitted only after the authenticated health/MCP activation
oracle succeeds.
The connector URL is a capability credential: anyone who has it can use the
enabled Mac Orchestrator tools. Keep it private like a password.

## Get the current connector URL

Enable Remote in the helper only when a remote client is needed. Enter the
ngrok authtoken through the helper's hidden prompt or stdin handoff; never add
it to a command argument, shell history, configuration file, screenshot, or
issue. The helper stores it in Keychain and injects it only into the owned
ngrok child environment.

If the helper provides the command-line handoff, type the token at a hidden
prompt and pipe it over stdin. Replace the helper path with the installed app's
executable path; the token is never an argument:

```bash
read -r -s NGROK_AUTHTOKEN
printf '%s\n' "$NGROK_AUTHTOKEN" | \
  "/path/to/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator" \
  --store-ngrok-token
unset NGROK_AUTHTOKEN
```

The helper should acknowledge storage without echoing the token. If it does not,
stop and do not put the token in another command or file.

Use **Copy Connector URL** in the menu-bar app, or use the helper's supported
`--print-connector-url` mode. The helper queries the local ngrok Agent API
`GET /api/endpoints` and returns only the current HTTPS endpoint whose upstream
matches Mac Orchestrator's selected loopback port. The displayed URL is the
value to give to the client:

```text
https://<live-ngrok-host>/<capability-token>/mcp
```

Do not replace it with the bare ngrok hostname, `/mcp` without the capability
path, the Agent API URL, or an old URL copied from a previous run. Re-query the
live Agent API whenever the tunnel or its upstream is recreated. The current
Free plan gives an account-specific automatically assigned development domain;
the domain may remain the same across a lifecycle event or may change, and this
repository has no empirical guarantee of persistence across reboot, network
change, or account replacement.

The current [ngrok Free Plan Limits documentation](https://ngrok.com/docs/pricing-limits/free-plan-limits)
describes one assigned development domain and up to three online endpoints. It
does not provide a custom, reserved static, randomly generated, wildcard, or
customer-owned domain. These plan limits are provider documentation, not a
claim about what a particular Mac lifecycle event will do. The [ngrok usage and
plan metrics documentation](https://ngrok.com/docs/pricing-limits/how-ngrok-charges)
records the assigned-domain and Free-plan limits separately from endpoint
state.

## Client registration boundary

Phase 4C supports a generic Streamable HTTP handoff. Mac Orchestrator can show
or copy the current connector URL for you to paste into a client field; that is
different from automatic client registration. It does not inspect arbitrary
client settings, identify an unrecorded client as stale, edit private client
configuration files, or rewrite clients through UI automation. No named client
has a supported automatic registration contract in this repository, so the
Phase 4 automation count is zero.

## Generic Streamable HTTP clients

For a client that documents an MCP HTTP or Streamable HTTP URL field:

1. paste the complete current connector URL, including the capability path and
   `/mcp` suffix;
2. choose the client's normal HTTP/Streamable HTTP transport; and
3. save the client configuration without sharing the URL in telemetry or
   screenshots.

The first request should be the client's normal MCP initialization. If it
fails, confirm that Remote is enabled, the Mac is awake and unlocked as needed,
the URL was copied after the current endpoint was discovered, and Doctor's
authenticated-readiness evidence is current.

## Generic JSON-configured clients

Some generic clients document an `mcpServers` JSON object with a server `url`
value. Follow that client's current documentation and adapt only the
surrounding key names; do not alter the Mac Orchestrator URL itself:

```json
{
  "mcpServers": {
    "mac-orchestrator": {
      "url": "https://<live-ngrok-host>/<capability-token>/mcp"
    }
  }
}
```

Prefer the client's secret-store or environment-backed configuration when it
offers one. If it requires a plain JSON file, restrict that file's permissions,
keep it out of source control and backups you do not trust, and delete or rotate
the old entry if the URL is exposed.

This example is a manual recipe, not an automatic registration API. Do not
assume that an arbitrary client uses this JSON shape.

## Local-only use

Remote ingress is optional. A client running on the same Mac can use the
local capability-path endpoint exposed by the managed Python server if the
client supports an HTTP URL on loopback. The installer prints:

```text
Local MCP URL: http://127.0.0.1:<selected-port>/<capability-token>/mcp
```

You can request the same bounded confirmation from the installed helper with
`--wait-for-local-activation`. Use the exact URL shown for the current local
port and capability path; do not guess port `8000` or remove authentication.

The server remains loopback-bound. The public URL, when enabled, is the ngrok
forward to that loopback server; it is not a hosted Mac Orchestrator service.

## Control profile and macOS permissions

New installations start in Guided Control. Choose Full Control explicitly only
when the client and its operator should be allowed to use the broader tool
surface. The profile is local configuration, not an approval prompt for every
tool call.

UI and screen tools also depend on macOS Accessibility, Screen Recording,
Apple Events, an unlocked Mac, and an active console session. The helper runs
the permission probe in the managed Python child that performs the UI work;
its result and `get_session_state` are the evidence to use. Approving a
System Settings pane is not proof of access. Grant permissions to the exact
identity macOS shows for the managed helper/runtime, then use Restart and
recheck the status. Ad-hoc replacement builds can lose TCC grants. Gatekeeper
and TCC behavior in Phase 2 is intentionally documented as a limitation, not
hidden or bypassed.

## If a connector URL leaks

If the URL appears in a log, screenshot, browser history, chat, or untrusted
client:

1. disable Remote in the helper;
2. remove the old URL from every client and trusted copy; and
3. treat the connector credential as compromised and wait for the later
   supported rotation/revocation workflow before re-enabling Remote.

The ngrok provider credential and the connector capability credential are
different. Replacing the ngrok credential does not by itself rotate the
connector capability credential. If a supported workflow rotates the connector
capability credential, every previous full connector URL is invalid and the
recorded clients must be configured manually with the new current URL.
Phase 4C does not accept secret input, rotate credentials, inspect arbitrary
clients, or edit private client files.

Do not try to repair a leaked URL by editing only its hostname. The capability
path contains the credential, and a fresh full URL is required after supported
rotation. An account/domain change, endpoint replacement, or connector-token
rotation may require the same manual reconfiguration even when the hostname
looks unchanged.

## Troubleshooting checklist

- **No URL is displayed:** local activation must pass before Remote starts. Fix
  the local health/MCP probe first.
- **The URL may be stale:** request it again; endpoint discovery is based on
  live `/api/endpoints` data, not a cached hostname.
- **The client gets 404:** do not label the client stale from 404 alone. A 404
  can result from a credential/path mismatch, a stale route, or another ingress
  state. Check the complete capability path and `/mcp` suffix, current Agent
  API endpoint classification, and authenticated MCP readiness.
- **The client cannot connect:** confirm Remote is enabled, the Mac is awake,
  the ngrok token is present in Keychain, and the selected endpoint is HTTPS.
- **UI calls fail while terminal calls work:** check TCC grants, screen lock,
  active-console state, and the selected Guided/Full profile.
- **The helper is blocked:** follow macOS's normal Gatekeeper approval path;
  do not disable Gatekeeper or remove quarantine globally.

Do not include connector URLs, tokens, local file contents, or unredacted logs
when asking for help.
