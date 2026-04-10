# Tidey Socket API

## Overview

Tidey exposes a Unix domain socket that accepts newline-delimited messages.

There are two protocol modes on the same socket:

- Legacy fire-and-forget messages from shell integration and agent hooks
- JSON request/response control messages used by RemoteBridge

As of 2026-04-10, the implemented request/response actions are:

- `ping`
- `list_workspaces`
- `send_input`
- `get_recent_output`

The sections below also define the next-step contract for panel-scoped control, workspace/panel CRUD, and server-pushed sync events. Those parts are design targets until the corresponding ObjC implementation lands.

## Connection

**Socket path:** `~/Library/Application Support/Tidey/tidey.sock`

The directory is created with mode `0700` and the socket file with mode `0600` (owner read/write only).

### Environment Variables Injected by Tidey

| Variable | Description |
|---|---|
| `TIDEY_SOCKET_PATH` | Absolute path to the Unix domain socket. |
| `TIDEY_WORKSPACE_ID` | Identifier for the current workspace (tab/split). Used to scope status, notifications, and titles to a specific pane. |
| `TIDEY_PANEL_ID` | Planned addition. Stable identifier for the current terminal panel. Agent wrappers should write this into their session registry so ownership is panel-scoped rather than workspace-scoped. |
| `TIDEY_BIN_DIR` | Directory containing the `tidey` CLI binary and the `claude` wrapper. Prepended to `PATH` by shell integration. |
| `LC_TERMINAL` | Set to `"Tidey"`. Survives SSH forwarding (unlike `TERM_PROGRAM`), so remote shells can detect they are running inside Tidey. |

### Protocol

1. Open a `SOCK_STREAM` connection to `TIDEY_SOCKET_PATH`.
2. Write one or more messages, each terminated by `\n`.
3. For fire-and-forget messages, close the connection after writing.
4. For request/response or subscription flows, keep the connection open and continue reading newline-delimited JSON responses/events.

Behavior depends on payload shape:

- Messages without an `id` are fire-and-forget. No response is sent.
- JSON messages with an `id` are treated as requests. Tidey replies with one JSON response line.
- Long-lived clients may later subscribe to server-pushed event streams. Those events are also sent as newline-delimited JSON objects on the same connection.

## Message Formats

The server accepts two formats per line. It tries JSON first, then falls back to plaintext.

### JSON Format

A single JSON object on one line:

```json
{"action":"<command>","workspace_id":"abc123","key":"value",...}
```

Request/response actions use this shape:

```json
{"id":"req-123","action":"list_workspaces","params":{...}}
```

Successful response:

```json
{"id":"req-123","ok":true,"result":{...}}
```

Error response:

```json
{"id":"req-123","ok":false,"error":{"code":"invalid_params","message":"..."}}
```

### Plaintext Format

Space-delimited tokens. The first token is the action, the second is a positional argument (typically `state`), followed by optional `--key=value` pairs:

```
<action> <state> [--key=value ...]
```

Example:
```
report_shell_state running --workspace_id=abc123
```

The parser splits on spaces, assigns `parts[0]` to `action`, `parts[1]` to `state`, and parses remaining `--key=value` tokens into dictionary keys.

## Identifier Model

### `workspace_id`

- Backed by `Workspace.identifier.UUIDString` in `PseudoTerminal`
- Stable for the lifetime of a workspace object
- Opaque to clients
- Not guaranteed to survive close/reopen or app restart

### `panel_id`

- Planned contract: backed by `PTYTab.stringUniqueIdentifier`
- Stable for the lifetime of a panel object
- Opaque to clients
- This is the source of truth for terminal I/O, recent output, and agent ownership

### `window_guid`

- Backed by `PseudoTerminal.terminalGuid`
- Identifies the owning macOS terminal window
- Useful for grouping workspaces, but not a replacement for `workspace_id` or `panel_id`

## Implemented Request / Response Actions

These actions are implemented today.

### `ping`

Request:

```json
{"id":"req-1","action":"ping"}
```

Response:

```json
{"id":"req-1","ok":true,"result":{"pong":true}}
```

### `list_workspaces`

Returns one summary per workspace.

Current response fields:

- `workspace_id`
- `title`
- `subtitle`
- `state`
- `selected`
- `window_guid`
- `panel_count`
- `cwd` when available

### `send_input`

Current contract:

- Requires `workspace_id`
- Sends input to the selected panel in that workspace
- Returns `workspace_not_found` if no interactive terminal session accepts the input

### `get_recent_output`

Current contract:

- Requires `workspace_id`
- Reads recent output from the selected panel in that workspace
- Supports `max_lines` and `max_chars`
- Returns `workspace_not_found` if no interactive terminal session produces output

## Next-Step Control Contract

The following additions define the contract for Tidey Remote workspace/panel control. They are not all implemented yet.

### Workspace Summary

`list_workspaces` will grow these optional fields:

- `selected_panel_id`
- `has_agent_session`
- `agent_panel_id`

Target shape:

```json
{
  "workspace_id": "ws-uuid",
  "window_guid": "pty-uuid",
  "title": "api-server",
  "subtitle": "~/GitHub/project",
  "state": "idle",
  "selected": true,
  "panel_count": 2,
  "selected_panel_id": "tab-guid",
  "has_agent_session": true,
  "agent_panel_id": "tab-guid",
  "cwd": "/Users/timfeng/GitHub/project"
}
```

### Panel Summary

Panels are listed in visual order within a workspace.

Target shape:

```json
{
  "panel_id": "tab-guid",
  "workspace_id": "ws-uuid",
  "window_guid": "pty-uuid",
  "title": "zsh",
  "subtitle": "~/GitHub/project",
  "state": "idle",
  "selected": true,
  "is_browser": false,
  "cwd": "/Users/timfeng/GitHub/project",
  "agent_session": {
    "vendor": "claude",
    "session_id": "session-uuid"
  }
}
```

`agent_session` is optional. When present, it is owned by `panel_id`, not just `workspace_id`.

### Action Semantics

- Actions that accept `panel_id` operate on that exact panel
- `workspace_id` remains supported for backwards compatibility
- For `send_input` and `get_recent_output`, `panel_id` wins over `workspace_id` when both are present
- When only `workspace_id` is provided, Tidey uses the selected panel in that workspace

### `list_panels`

Request:

```json
{"id":"req-2","action":"list_panels","params":{"workspace_id":"ws-uuid"}}
```

Success result:

```json
{
  "workspace_id": "ws-uuid",
  "selected_panel_id": "tab-guid",
  "panels": [ ...panel summaries... ]
}
```

### `select_workspace`

Request params:

- `workspace_id` required

Result:

- `selected: true`
- latest workspace summary

### `create_workspace`

Minimal contract:

- no required params
- creates a new shell workspace using Tidey's default terminal profile
- new workspace starts with one terminal panel

Optional params:

- `title`
- `make_selected` default `true`

Result:

- created workspace summary
- created panel summary as `panel`

### `close_workspace`

Request params:

- `workspace_id` required

Result:

- `closed: true`
- closed `workspace_id`

### `rename_workspace`

Request params:

- `workspace_id` required
- `title` required

Semantics:

- non-empty `title` sets `Workspace.customTitle`
- empty `title` clears the custom title and falls back to the derived display title

Result:

- updated workspace summary

### `select_panel`

Request params:

- `panel_id` required

Semantics:

- selects the containing workspace if needed
- updates that workspace's `selectedPanelIndex`

Result:

- updated panel summary
- updated workspace summary

### `create_panel`

Request params:

- `workspace_id` required

Optional params:

- `make_selected` default `true`

Minimal contract:

- creates a new shell terminal panel in the target workspace
- uses Tidey's default terminal profile
- if possible, inherits the current directory from the selected panel in that workspace

Result:

- created panel summary
- updated workspace summary

### `close_panel`

Request params:

- `panel_id` required

Semantics:

- closes the exact panel
- if it was the last panel in the workspace, the workspace closes too

Result:

- `closed: true`
- `panel_id`
- `workspace_closed: true|false`
- `workspace_id`

### Panel-Scoped `send_input`

New request shape:

```json
{"id":"req-3","action":"send_input","params":{"panel_id":"tab-guid","input":"ls\r"}}
```

Backwards-compatible request shape remains valid:

```json
{"id":"req-4","action":"send_input","params":{"workspace_id":"ws-uuid","input":"ls\r"}}
```

Errors:

- `panel_not_found`
- `workspace_not_found`
- `panel_not_interactive`
- `invalid_params`

### Panel-Scoped `get_recent_output`

New request shape:

```json
{"id":"req-5","action":"get_recent_output","params":{"panel_id":"tab-guid","max_lines":200,"max_chars":12000}}
```

Success result includes the resolved target:

```json
{
  "panel_id": "tab-guid",
  "workspace_id": "ws-uuid",
  "output": "..."
}
```

## Push Events Contract

Desktop and mobile sync needs server-pushed events on the same socket connection.

### `subscribe_workspace_events`

Request params:

- `workspace_id` optional filter

Success result:

```json
{"subscribed":true}
```

### `unsubscribe_workspace_events`

Success result:

```json
{"subscribed":false}
```

### Event Envelope

```json
{
  "type": "workspace_event",
  "v": 1,
  "replay": false,
  "event": {
    "event_id": "evt-123",
    "seq": 42,
    "timestamp": "2026-04-10T03:15:00Z",
    "kind": "panel_selected",
    "window_guid": "pty-uuid",
    "workspace_id": "ws-uuid",
    "panel_id": "tab-guid",
    "workspace": { ...optional workspace summary... },
    "panel": { ...optional panel summary... }
  }
}
```

### Event Kinds

- `workspace_created`
- `workspace_updated`
- `workspace_closed`
- `workspace_selected`
- `panel_created`
- `panel_updated`
- `panel_closed`
- `panel_selected`
- `agent_session_started`
- `agent_session_updated`
- `agent_session_ended`

### Agent Session Ownership

Agent ownership is panel-scoped.

Contract:

- Tidey injects `TIDEY_PANEL_ID` into the panel's shell environment
- Claude/Codex wrappers write `panel_id` into their local registry/session metadata
- Bridge adapters use `panel_id` as the authoritative mapping key
- `workspace_id` is only for grouping and fallback targeting

## Fire-and-Forget Commands

### `report_shell_state`

Reports the shell's current execution state. Tidey displays this as a status badge on the workspace.

**Typically sent in plaintext format.**

| Field | Required | Description |
|---|---|---|
| `action` | yes | `"report_shell_state"` |
| `state` | yes | One of the values below |
| `workspace_id` | no | Scope to a specific workspace. When absent, broadcasts to all workspaces (`"*"`). |

**State values:**

| State | Display | Icon | Color |
|---|---|---|---|
| `running` / `busy` / `command` | "Running" | `bolt.fill` | `#007AFF` (blue) |
| `prompt` / `idle` | "Idle" | `pause.circle.fill` | `#8E8E93` (gray) |
| `unknown` / `clear` | *(clears the status)* | | |

**Example:**
```
report_shell_state running --workspace_id=abc123
```

### `set_status`

Sets an arbitrary key/value status entry for a workspace. Unlike `report_shell_state`, this gives full control over the display.

**JSON format only (requires `workspace_id`).**

| Field | Required | Description |
|---|---|---|
| `action` | yes | `"set_status"` |
| `workspace_id` | yes | Target workspace. |
| `key` | yes | Status key (e.g., `"shell_state"`). Multiple keys can coexist. |
| `value` | yes | Display text. |
| `icon` | no | SF Symbol name (e.g., `"bell.fill"`). |
| `color` | no | Hex color string (e.g., `"#4C8DFF"`). |

**Example:**
```json
{"action":"set_status","workspace_id":"abc123","key":"shell_state","value":"Needs input","icon":"bell.fill","color":"#4C8DFF"}
```

### `clear_status`

Removes a status entry for a workspace.

| Field | Required | Description |
|---|---|---|
| `action` | yes | `"clear_status"` |
| `workspace_id` | yes | Target workspace. |
| `key` | yes | Status key to remove. |

**Example:**
```json
{"action":"clear_status","workspace_id":"abc123","key":"shell_state"}
```

### `notification.create`

Creates a notification that is not scoped to any specific workspace. Displays as a macOS system notification and appears in Tidey's notification list.

| Field | Required | Description |
|---|---|---|
| `action` | yes | `"notification.create"` |
| `workspace_id` | no | When absent, the notification broadcasts to all workspaces (`"*"`). When present, replaces any existing notification for that workspace. |
| `title` | yes | Notification title. Must be non-empty. |
| `subtitle` | no | Notification subtitle. |
| `body` | no | Notification body text. |

**Example:**
```json
{"action":"notification.create","title":"Build Complete","body":"All tests passed"}
```

### `notification.create_for_workspace`

Creates a workspace-scoped notification. Requires `workspace_id`.

| Field | Required | Description |
|---|---|---|
| `action` | yes | `"notification.create_for_workspace"` |
| `workspace_id` | yes | Must be non-empty. |
| `title` | yes | Must be non-empty. |
| `subtitle` | no | Notification subtitle. |
| `body` | no | Notification body text. |

Workspace-scoped notifications replace any prior notification for the same `workspace_id`. Broadcast (`"*"`) notifications are exempt from replacement.

**Example:**
```json
{"action":"notification.create_for_workspace","workspace_id":"abc123","title":"Claude Code","body":"Task completed"}
```

### `set_title`

Overrides the tab/workspace title. Send an empty `title` to clear the override.

| Field | Required | Description |
|---|---|---|
| `action` | yes | `"set_title"` |
| `workspace_id` | yes | Target workspace. |
| `title` | no | Title string. Empty or absent clears the title. |

**Example:**
```json
{"action":"set_title","workspace_id":"abc123","title":"Claude Code"}
```

## Claude Code Integration

### Claude Wrapper

`Resources/bin/claude` is a bash wrapper that intercepts `claude` invocations inside Tidey. It is placed on `PATH` via `TIDEY_BIN_DIR`.

**Behavior:**

1. If `TIDEY_SOCKET_PATH` is unset or the socket file doesn't exist, the wrapper passes through to the real `claude` binary unchanged.
2. Subcommands `mcp`, `config`, and `api-key` always pass through (they don't support hooks).
3. Otherwise, the wrapper injects `--settings` with a JSON hooks configuration and (unless the user specified `--resume`, `--continue`, `-r`, `-c`, or `--session-id`) generates a new `--session-id`.

### Hook Events

The wrapper registers these Claude Code hooks, all handled by `tidey claude-hook <event>`:

| Hook | Event | What It Does |
|---|---|---|
| `SessionStart` | `session-start` | Sets shell state to `prompt`. Sets tab title to "Claude Code". |
| `UserPromptSubmit` | `prompt-submit` | Sets shell state to `running`. |
| `Notification` | `notification` | Sets status to "Needs input" with `bell.fill` icon (blue). |
| `Stop` | `stop` | Creates a notification with the last assistant message (truncated to 200 chars) from the transcript. Resets shell state to `prompt`. |
| `SessionEnd` | `session-end` | Clears the `shell_state` status entry. Clears the tab title override. |

### tidey CLI Binary

`TideyCLI/main.swift` compiles to the `tidey` binary placed in `TIDEY_BIN_DIR`. Two subcommands:

**`tidey send <message>`** -- Sends a raw plaintext message to the socket. Used by shell integration hooks.

**`tidey claude-hook <event>`** -- Handles Claude Code hook events (see table above). The `stop` event reads JSON from stdin (provided by Claude Code) to extract `transcript_path` and parse the last assistant message.

## Shell Integration

The Tidey-specific section of `iterm2_shell_integration.zsh` does three things:

### 1. tmux Environment Forwarding

When `TIDEY_SOCKET_PATH` is set, the script tells tmux to inherit Tidey's environment variables into new sessions:

```zsh
tmux set-option -ga update-environment " TIDEY_SOCKET_PATH TIDEY_WORKSPACE_ID TIDEY_BIN_DIR LC_TERMINAL"
```

### 2. PATH Injection

When `TIDEY_BIN_DIR` is set, a one-shot `precmd` hook prepends it to `PATH`. This ensures the `claude` wrapper and `tidey` binary take precedence. The hook removes itself after running once (via `add-zsh-hook -d`).

### 3. Shell State Reporting

When the socket is available, two hooks are registered:

- **`_tidey_precmd`** (runs after each command finishes, before the prompt): sends `report_shell_state prompt`.
- **`_tidey_preexec`** (runs just before a command executes): sends `report_shell_state running`. Terminal multiplexers (`tmux`, `screen`) are excluded to avoid a permanent "Running" state on the outer shell.

Both hooks append `--workspace_id=$TIDEY_WORKSPACE_ID` when set and dispatch via `tidey send` in a background job (`&!`).
