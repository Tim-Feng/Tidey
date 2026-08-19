# Tidey Browser Automation

## Status

This document is the source of truth for Tidey's first-party browser automation path. It covers the Tidey macOS app and the Codex CLI processes launched inside a Tidey workspace. It does not claim that the Codex desktop app uses this adapter or MCP internally.

## Product model

Codex CLI remains the agent runtime. Tidey owns the browser runtime and exposes a bounded set of typed browser operations through its existing local Unix socket. A bundled stdio MCP adapter translates Codex tool calls into that socket protocol.

Browser work has two distinct surfaces:

- User-visible tabs continue to appear in Tidey's Browser UI. An agent must atomically claim a visible tab before operating it.
- Agent-private tabs use the same `TideyBrowserEngine` and `WKWebView` implementation but do not appear in the tab strip, tab count, or any inventory badge. They become visible only through an explicit `present` operation.

`present` adopts the same canonical tab ID and the same live WebKit engine. It does not reload, clone, or replay the page.

## Boundaries

```text
Codex CLI
  -> bundled stdio MCP adapter
  -> Tidey workspace Unix socket
  -> typed browser protocol
  -> ownership/lifecycle controller
  -> TideyBrowserEngine / WKWebView
```

The MCP adapter is intentionally thin. It inherits `TIDEY_SOCKET_PATH` and `TIDEY_WORKSPACE_ID`, forwards typed requests, and translates results and stable errors. It does not own tabs, store browser state, execute JavaScript, or connect to websites itself.

The socket connection supplies a stable owner-session ID. Callers cannot choose or spoof this ID.

## Tab identity and ownership

Every controlled tab has a canonical `tab_id`. Private state records:

- `tab_id`
- live `TideyBrowserEngine`
- `owner_session`
- `workspace_id`
- navigation epoch
- disconnect mark

Ownership checks and state transitions are atomic in `TideyBrowserAutomationState`. Requests fail closed when the tab is missing, the workspace differs, or another session owns the tab.

Visible tabs are never implicitly claimed. Private popups and links that open a new browsing context remain hidden and inherit the parent tab's workspace and owner. The triggering result reports their IDs in `tabs_created`.

## Lifecycle

Private tabs support three disconnect marks:

- `none`: close immediately when the owning socket disconnects.
- `deliverable`: adopt into the visible Browser UI on disconnect.
- `handoff`: retain privately without an owner for 30 minutes so another session can explicitly reclaim it.

Visible-tab claims are released on disconnect. Expired handoff tabs are closed. Normal user Browser tabs are otherwise unchanged.

## Protocol

The socket action is `browser_automation`. Its request carries the workspace ID, a typed operation, and operation-specific parameters. Supported operations are:

- lifecycle: `tabs`, `open`, `claim`, `release`, `reclaim`, `mark`, `close`, `present`
- navigation: `navigate`, `back`, `forward`, `reload`, `current_url`
- page interaction: `snapshot`, `click`, `fill`, `type`, `key`, `scroll`, `wait`, `screenshot`

Only HTTP and HTTPS URLs are accepted. There is no arbitrary-JavaScript operation.

`snapshot` returns bounded page text and interactive elements. Element IDs are meaningful only with the returned `navigation_epoch`; any navigation commit invalidates prior references.

Waits are capped at 30 seconds. Snapshots are capped at 500 interactive elements and 50,000 text characters. The in-memory action log is capped at 200 entries and never records typed or filled text.

## Capacity and fairness

The app-wide navigation gate allows at most four active agent-initiated navigations, at most two per origin, and at most 32 queued operations. It scans for the first eligible waiter, so a saturated origin does not block another origin that still has capacity. A full queue returns `busy`.

Permits remain held until WebKit finishes loading. Explicit navigation, private popup loads, link clicks, and key actions that can submit a page use the same gate. A non-navigating click or key releases its permit after a short startup grace period.

## Codex registration

The Tidey Codex wrapper generates this server entry in its session-scoped profile:

```toml
[mcp_servers.tidey_browser]
command = "/path/inside/Tidey.app/Contents/Resources/bin/tidey-browser-mcp"
env_vars = ["TIDEY_SOCKET_PATH", "TIDEY_WORKSPACE_ID"]
required = true
startup_timeout_sec = 5
tool_timeout_sec = 45
default_tools_approval_mode = "approve"
```

The adapter speaks newline-delimited MCP JSON-RPC over stdin/stdout and uses one Tidey socket connection for its lifetime. That connection is the ownership boundary for the Codex session.

## Verification matrix

- pure state tests cover private ownership, visible claims, marks, disconnect cleanup, reclaim, TTL, workspace mismatch, and tab limits
- protocol tests cover every command plus malformed input, URL schemes, wait bounds, and stable error codes
- WebKit tests cover snapshot, click, fill, type, stale references, waits, and screenshots on an unattached engine
- controller tests cover hidden creation, same-engine presentation, popups, command routing, cleanup, and navigation admission
- socket tests cover workspace/session binding, async responses, and disconnect cleanup
- MCP tests cover initialization, exact tool inventory, call forwarding, workspace inheritance, error mapping, missing environment, and generated Codex profile registration
- the navigation-gate suite covers global, per-origin, fairness, and bounded-queue behavior

## Non-goals for v1

- exposing private tabs in Browser UI before `present`
- mirroring a hidden-tab count or activity inventory in the tab strip
- arbitrary JavaScript evaluation
- non-HTTP(S) navigation
- remote/cloud MCP transport
- assuming implementation details of the Codex desktop app
