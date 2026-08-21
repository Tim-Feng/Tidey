# Tidey Browser Automation

## Status

This document is the source of truth for Tidey's first-party browser automation path. It covers the Tidey macOS app and Codex CLI or Claude Code processes launched inside a Tidey workspace. It does not claim that the Codex desktop app or Claude Desktop uses this adapter or MCP internally, and it makes no claim about upstream client internals.

## Product model

A Tidey-launched Codex CLI or Claude Code process remains the agent runtime. Tidey owns the browser runtime and exposes a bounded set of typed browser operations through its existing local Unix socket. A bundled stdio MCP adapter translates agent tool calls into that socket protocol.

Browser work has two distinct surfaces:

- User-visible tabs continue to appear in Tidey's Browser UI. An agent must atomically claim a visible tab before operating it.
- Agent-private tabs use the same `TideyBrowserEngine` and `WKWebView` implementation but do not appear in the tab strip, tab count, or any inventory badge. They become visible only through an explicit `present` operation.

`present` adopts the same canonical tab ID and the same live WebKit engine. It does not reload, clone, or replay the page.

## Boundaries

```text
Tidey-launched agent CLI
  (Codex CLI or Claude Code)
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

The automation engine and the regular Browser share one response-download policy. A navigation or click whose HTTP response is an attachment, or whose content type is not displayable by WebKit, becomes a `WKDownload`. Tidey keeps the current page in place and hands the transfer to the existing Browser download pipeline, which chooses the Downloads destination and applies quarantine after completion.

Waits are capped at 30 seconds. Snapshots are capped at 500 interactive elements and 50,000 text characters. The in-memory action log is capped at 200 entries and never records typed or filled text.

## Capacity and fairness

The app-wide navigation gate allows at most four active agent-initiated navigations, at most two per origin, and at most 32 queued operations. It scans for the first eligible waiter, so a saturated origin does not block another origin that still has capacity. A full queue returns `busy`.

Permits remain held until WebKit finishes loading. Explicit navigation, private popup loads, link clicks, and key actions that can submit a page use the same gate. A non-navigating click or key releases its permit after a short startup grace period.

## Registration

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

The Tidey Claude wrapper passes the same adapter as one session-local inline JSON argument to `--mcp-config`:

```json
{"mcpServers":{"tidey_browser":{"type":"stdio","command":"/path/inside/Tidey.app/Contents/Resources/bin/tidey-browser-mcp","args":[],"env":{"TIDEY_SOCKET_PATH":"<socket-path>","TIDEY_WORKSPACE_ID":"<workspace-id>"}}}}
```

The Claude wrapper injects this additive config only when `TIDEY_WORKSPACE_ID` is non-empty and `TIDEY_SOCKET_PATH` names a live socket. It does not pass `--strict-mcp-config`, alter the user's persistent MCP or settings files, or auto-approve the browser tools; Claude Code's normal permission flow remains in effect.

The adapter speaks newline-delimited MCP JSON-RPC over stdin/stdout and uses one Tidey socket connection for its lifetime. That connection is the ownership boundary for the agent session.

## Verification matrix

- pure state tests cover private ownership, visible claims, marks, disconnect cleanup, reclaim, TTL, workspace mismatch, and tab limits
- protocol tests cover every command plus malformed input, URL schemes, wait bounds, and stable error codes
- WebKit tests cover snapshot, click, fill, type, stale references, waits, screenshots, and attachment/non-displayable response policy on an unattached engine
- controller tests cover hidden creation, same-engine presentation, popups, command routing, cleanup, and navigation admission
- socket tests cover workspace/session binding, async responses, and disconnect cleanup
- MCP and wrapper tests cover initialization, exact tool inventory, agent-neutral descriptions, call forwarding, workspace inheritance, error mapping, missing environment, generated Codex profile registration, and Claude's exact inline config argument
- the navigation-gate suite covers global, per-origin, fairness, and bounded-queue behavior

## Non-goals for v1

- exposing private tabs in Browser UI before `present`
- mirroring a hidden-tab count or activity inventory in the tab strip
- arbitrary JavaScript evaluation
- non-HTTP(S) navigation
- remote/cloud MCP transport
- assuming implementation details of the Codex desktop app or Claude Desktop
