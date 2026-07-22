# Agent Transcript Streaming MVP

This document records the MVP architecture for structured agent transcript streaming in Tidey Remote.

## Goals

- Preserve the existing desktop workflow.
- Tail the agent's native JSONL session log instead of changing how the CLI is launched.
- Normalize Claude Code and Codex transcript events into one bridge protocol.
- Push live events over the existing RemoteBridge WebSocket connection.

## Transcript Sources

- Claude Code: `~/.claude/projects/<project>/<session-id>.jsonl`
- Codex: `~/.codex/sessions/<date>/rollout-<id>.jsonl`

Current implementation supports both Claude Code and Codex.

## Unified Event Protocol

Bridge pushes `agent_event` envelopes:

```json
{
  "type": "agent_event",
  "v": 1,
  "replay": false,
  "event": {
    "event_id": "claude:...",
    "seq": 12,
    "vendor": "claude",
    "workspace_id": "ws-123",
    "session_id": "6d22e1a7-...",
    "timestamp": "2026-04-09T12:18:49.907Z",
    "type": "tool_call",
    "role": "assistant",
    "name": "Skill",
    "input": "{\"skill\":\"continuity\"}"
  }
}
```

Supported event types:

- `session_started`
- `session_ended`
- `assistant_message`
- `assistant_final`
- `user_message`
- `thinking`
- `tool_call`
- `tool_result`
- `status`

## Workspace to Session Mapping

Bridge does not guess from `cwd` or from Codex sqlite state.

It reads explicit registry files from:

- `~/Library/Application Support/Tidey Remote Bridge/agent-sessions/claude/*.json`
- `~/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex/*.json`

Registry record shape:

```json
{
  "version": 1,
  "vendor": "claude",
  "workspace_id": "ws-123",
  "session_id": "6d22e1a7-2d28-4b47-bc98-ec023c9f8c76",
  "pid": 12345,
  "cwd": "/Users/timfeng/GitHub/genesis",
  "created_at": "2026-04-09T12:18:49Z"
}
```

The Claude wrapper owns this file:

- create before launching Claude
- remove after Claude exits

The Codex wrapper owns the Codex registry file:

- start a background monitor before `exec`-ing the real `codex`
- resolve the active `rollout-*.jsonl` path
- write `rollout_path` / `transcript_path` plus `panel_id`
- remove the registry file after `codex` exits

Bridge treats missing or dead `pid` records as stale and drops them.

## Bridge Components

- `AgentSessionRegistryMonitor`
  - scans registry files
  - starts or stops transcript watchers
- `ClaudeTranscriptSession`
  - resolves `session_id -> transcript path`
  - tails the JSONL incrementally
  - converts Claude transcript lines into normalized events
- `CodexTranscriptSession`
  - resolves `session_id -> rollout path`
  - tails the JSONL incrementally
  - converts Codex transcript lines into normalized events
- `AgentEventHub`
  - stores a bounded replay buffer
  - fans out live events to WebSocket subscribers

## WebSocket Flow

Existing request/response actions stay intact.

New actions:

- `fetch_agent_events`
- `subscribe_agent_events`
- `unsubscribe_agent_events`

### Fetching agent events

Agent event sequence numbers are scoped to one agent session. They are not workspace-global cursors, and a cursor from one session must not be reused for another session.

`fetch_agent_events` accepts:

- `workspace_id` required
- `limit` required; must be an integer from `1` through `2000`
- `session_id` optional when fetching the latest workspace snapshot; required when `before_seq` or `after_seq` is present
- `before_seq` optional; selects the newest transcript page whose stored event sequences are strictly less than the cursor
- `after_seq` optional; selects the earliest transcript page whose stored event sequences are strictly greater than the cursor
- `max_bytes` optional; applies a soft page-size budget after the count limit (an individually oversized event may be replaced by a bounded placeholder)

`before_seq` and `after_seq` are mutually exclusive. Each cursor must be an integral numeric value representable by the bridge. A malformed cursor, both cursor fields in one request, or a cursor request without `session_id` returns `invalid_request`.

Without a cursor, the bridge returns the newest matching events. Results are returned in ascending order. A session-scoped cursor request may read older transcript records to cover the requested range; concurrent history requests for the same session are isolated from one another.

It returns:

```json
{
  "events": [ ...agent events... ],
  "oldest_seq": 701,
  "newest_seq": 1000,
  "has_more": true
}
```

`has_more` reports whether the bridge's currently materialized matching window contains more events than this count- or byte-limited page; it is not an authoritative end-of-transcript marker.

### Subscribing to agent events

`subscribe_agent_events` accepts optional filters:

- `workspace_id`
- `session_id`
- `since_seq`; selects buffered replay events from that session whose stored sequences are strictly greater than the cursor
- `no_replay`; when true, skips the initial buffered replay and delivers only subsequent live events

Because `since_seq` is session-scoped, it requires `session_id` and must be an integral numeric value representable by the bridge. A malformed `since_seq`, or `since_seq` without `session_id`, returns `invalid_request`. A workspace-wide subscription remains valid when no `since_seq` is supplied. `no_replay` may also be used without `session_id` because it does not compare sequence numbers.

`subscribe_agent_events` responds with:

```json
{
  "subscribed": true,
  "workspace_id": "ws-123",
  "session_id": "6d22e1a7-...",
  "no_replay": false,
  "replay_count": 12
}
```

After subscription, bridge sends:

- matching buffered events with `"replay": true`, unless `no_replay` is true
- subsequent live events with `"replay": false`

Cursor filtering applies to the stored transcript page or replay. To preserve actionable UI state, the bridge may additionally include an active Codex approval snapshot whose sequence lies outside that cursor range. Clients must deduplicate by `event_id` and advance polling cursors from `oldest_seq`/`newest_seq` rather than from an injected snapshot.

`unsubscribe_agent_events` takes no cursor and ends the connection's current agent-event subscription.

## Filtering

Bridge deliberately ignores transcript lines that contain raw prompt payloads or internal metadata, for example:

- Claude `queue-operation`
- Codex `session_meta`

Only normalized user-visible events are pushed.

## Compatibility Rules

- Claude accepts versionless legacy records and string versions starting with `2.`.
- An unsupported major version is reported once as a `status` event. Unsupported, explicitly non-string, malformed JSON, and invalid UTF-8 records make source-wide closure knowledge unknown; cached interactive openers are hidden from fetch, replay, and submission rather than treated as safely open.
- Unknown shapes inside an otherwise supported, valid record are skipped without killing the stream.

## Known Gaps

- Claude resume flows without a concrete `session_id` cannot be mapped reliably.
- Codex bootstrap `role=user` messages contain injected instructions and are filtered with heuristics.
- Replay buffers are bounded by the event hub. Claude's first cross-page closure lookup lazily indexes the current source, then indexes only appended suffixes; each external fetch is limited to 2000 events.
