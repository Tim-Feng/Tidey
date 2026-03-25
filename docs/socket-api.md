# Tidey Socket API

## Overview

Tidey exposes a Unix domain socket that accepts newline-delimited messages. Processes inside Tidey terminal sessions use this socket to report shell state, set status indicators, create notifications, and override tab titles. The protocol is fire-and-forget: clients connect, write one or more newline-terminated messages, and close. There are no responses.

## Connection

**Socket path:** `~/Library/Application Support/Tidey/tidey.sock`

The directory is created with mode `0700` and the socket file with mode `0600` (owner read/write only).

### Environment Variables Injected by Tidey

| Variable | Description |
|---|---|
| `TIDEY_SOCKET_PATH` | Absolute path to the Unix domain socket. |
| `TIDEY_WORKSPACE_ID` | Identifier for the current workspace (tab/split). Used to scope status, notifications, and titles to a specific pane. |
| `TIDEY_BIN_DIR` | Directory containing the `tidey` CLI binary and the `claude` wrapper. Prepended to `PATH` by shell integration. |
| `LC_TERMINAL` | Set to `"Tidey"`. Survives SSH forwarding (unlike `TERM_PROGRAM`), so remote shells can detect they are running inside Tidey. |

### Protocol

1. Open a `SOCK_STREAM` connection to `TIDEY_SOCKET_PATH`.
2. Write one or more messages, each terminated by `\n`.
3. Close the connection.

No acknowledgment is sent. Invalid or unrecognized messages are silently dropped.

## Message Formats

The server accepts two formats per line. It tries JSON first, then falls back to plaintext.

### JSON Format

A single JSON object on one line:

```json
{"action":"<command>","workspace_id":"abc123","key":"value",...}
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

## Commands

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
