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

- `subscribe_agent_events`
- `unsubscribe_agent_events`

`subscribe_agent_events` responds with:

```json
{
  "subscribed": true,
  "workspace_id": "ws-123",
  "replay_count": 12
}
```

After subscription, bridge sends:

- replayed buffered events with `"replay": true`
- live events with `"replay": false`

## Filtering

Bridge deliberately ignores transcript lines that contain raw prompt payloads or internal metadata, for example:

- Claude `queue-operation`
- Codex `session_meta`

Only normalized user-visible events are pushed.

## Compatibility Rules

- Claude MVP accepts transcript versions starting with `2.`
- unknown transcript versions are reported as `status` events and ignored
- unknown line shapes are skipped without killing the stream

## Known Gaps

- Claude resume flows without a concrete `session_id` cannot be mapped reliably.
- Codex bootstrap `role=user` messages contain injected instructions and are filtered with heuristics.
- Transcript replay is bounded in memory by the bridge event hub.
