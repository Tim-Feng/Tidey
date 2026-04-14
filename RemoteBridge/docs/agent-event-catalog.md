# Agent Event Catalog

這份文件整理 RemoteBridge 目前對 Claude / Codex transcript 的事件映射，以及 Tidey-Remote iOS 端目前怎麼消化這些事件。A1 UI phase 後續做 markdown、tool diff、tool cell 配色和交互前，先以這份 catalog 當規格基線。

## 主表

| vendor | source event / payload type | published `AgentEvent.Kind` | 關鍵 metadata 欄位 | iOS 目前處理方式 | UI 呈現 | 已知缺口 / edge cases |
| --- | --- | --- | --- | --- | --- | --- |
| claude | synthetic session bootstrap / registry migration | `session_started` | `panel_id`, `cwd` | `ChatTranscriptState.insertLiveEvent` 直接清掉既有 transcript；`ChatResponseState` 重設 pending / placeholder | 不顯示 row；作為 transcript reset 邊界 | seq 是 synthetic，非 transcript line offset |
| claude | synthetic stop / tailer end | `session_ended` | `panel_id` | reducer 只把 `isThinking = false`；controller 也把 placeholder expectation 清掉 | 不顯示 row | 不代表單輪回應結束，只代表整個 session 結束 |
| claude | transcript version mismatch | `status` | `reason=unsupported_version`, `panel_id` | reducer 只有在 `text` 含 `thinking` 或 `working` 時才會動到 thinking 狀態；這類 status 其實不會進 UI | 無可見 UI | 目前屬於 silent drop；只能靠 debug / logs 看見 |
| claude | `assistant.message.content[].type == text` | `assistant_message` | `panel_id` | `handleAgentEventEnvelope` 過 panel filter 後插入 transcript；reducer 追加 assistant message bubble 並清 thinking | Assistant bubble | Claude 沒有對應 `assistant_final` |
| claude | `assistant.message.content[].type == thinking` | `thinking` | `panel_id` | reducer 把 `isThinking = true`；controller 另外有 stable placeholder 橋接 | Thinking row / placeholder | thinking 內容文字本身目前不顯示，只顯示 placeholder |
| claude | `assistant.message.content[].type == tool_use` | `tool_call` | `panel_id` | reducer 追加到最後一個 tool group，或建立新 tool group | Tool group header + tool call entry | raw `name` 直接傳給 UI；沒有 vendor-aware schema 層 |
| claude | `user.message.content` plain string | `user_message` | `panel_id` | `ChatResponseState` 會嘗試 ACK pending；`ChatTranscriptState` 以 seq / eventID 去重；reducer 以 pending localID 原地收斂 | User bubble | 目前仍用 text-based pending ACK；多筆相同文字時語意較弱 |
| claude | `user.message.content[].type == text` | `user_message` | `panel_id` | 同上 | User bubble | 同上 |
| claude | `user.message.content[].type == tool_result` | `tool_result` | `panel_id`, `is_error`, `tool_use_id` | reducer 反向搜尋 matching `toolCallID`，把 output 填回既有 tool call entry | Tool output text | 沒 matching `toolCallID` 時直接掉資料；`is_error` 目前沒進 UI |
| codex | synthetic session bootstrap / registry migration | `session_started` | `panel_id`, `cwd` | 同 Claude：清 transcript、重設 pending / placeholder | 不顯示 row；作為 transcript reset 邊界 | seq 是 synthetic |
| codex | synthetic stop / tailer end | `session_ended` | `panel_id` | 同 Claude：清 thinking / placeholder | 不顯示 row | 不代表單輪回應結束 |
| codex | `session_meta.cli_version` mismatch | `status` | `reason=unsupported_version`, `panel_id` | 同 Claude unsupported version status | 無可見 UI | silent drop |
| codex | `response_item.payload.type == message`, `role=assistant`, `phase != commentary/final_answer` | `assistant_message` | `panel_id`, `phase` | controller merge 後，reducer 追加 assistant bubble 並清 thinking | Assistant bubble | 這條是 non-commentary/non-final assistant message；和 `event_msg.agent_message` 會共存，靠 `publishedAssistantTextKeys` 去重 |
| codex | `response_item.payload.type == message`, `role=user` | `user_message` | `panel_id` | 同 Claude user_message | User bubble | bootstrap user message 可能被 `shouldPublishUserMessage` 過濾 |
| codex | `response_item.payload.type == function_call` | `tool_call` | `panel_id`, `call_id` | reducer 建 / 續接 tool group | Tool group | `arguments` 目前直接當 raw JSON string 傳給 UI formatter |
| codex | `response_item.payload.type == function_call_output` | `tool_result` | `panel_id`, `source=function_call_output`, `call_id` | reducer 找 matching `toolCallID` 回填 output | Tool output text | 同一 `call_id` 只收第一筆；後續 duplicate output 會被 `resolvedToolCallIDs` 擋掉 |
| codex | `event_msg.payload.type == agent_message`, `phase=commentary` | `assistant_message` | `panel_id`, `phase=commentary` | 同 assistant bubble 路徑 | Assistant bubble | 這是 Codex 最常見的中途回應型態 |
| codex | `event_msg.payload.type == agent_message`, `phase=final_answer` | `assistant_final` | `panel_id`, `phase=final_answer` | reducer 跟 `assistant_message` 走同一 bubble 路徑；只是在事件型別上保留 final distinction | Assistant bubble | Claude 沒這種 event，所以跨 vendor 不可依賴 |
| codex | `event_msg.payload.type == exec_command_end` | `tool_result` | `panel_id`, `source=exec_command_end`, `exit_code`, `status`, `call_id` | reducer 回填 tool output | Tool output text | `exit_code` / `status` 目前沒進 UI |
| codex | `event_msg.payload.type == patch_apply_end` | `tool_result` | `panel_id`, `source=patch_apply_end`, `success`, `status`, `call_id` | reducer 回填 tool output | Tool output text | `success` / `status` 目前沒進 UI |

## iOS 消化路徑

### 事件進入點

- `ChatViewController.handleAgentEventEnvelope(_:)`
  - 先用 `event.metadata["panel_id"]` 做 panel filter
  - `user_message` 會先把展開中的 tool group 收起來
  - `responseState.handleEventMutating(event)` 處理 pending ACK / expecting assistant placeholder
  - `transcriptState.insertLiveEvent(event)` 做 seq/eventID 去重與排序
  - 任一 state 變動後都會 `rebuildTranscript()` 再 refresh table

### reducer / state

- `ChatTranscriptState`
  - `orderedEvents` 以 `seq -> timestamp -> eventID` 排序
  - live / fetch merge 都走 idempotent upsert
  - matching key：先 `eventID`，再 fallback `sessionID + seq`
- `ChatTranscriptReducer`
  - `assistant_message` / `assistant_final`：追加 assistant bubble，清 `isThinking`
  - `user_message`：若 `acknowledgedPendingMessages[eventID]` 存在，沿用 pending `localID`，做原地 ACK
  - `thinking`：只開 `isThinking = true`
  - `tool_call`：續接最後一個 tool group 或建立新 group
  - `tool_result`：用 `toolCallID` 回填既有 tool entry output
  - `session_started`：清掉既有 items / seen IDs / `isThinking`
  - `session_ended`：只清 `isThinking`
  - `status`：只有 text 含 `thinking` 或 `working` 時才影響 `isThinking`

### UI 呈現

- message events -> `ChatMessageCell`
- tool events -> `ChatToolGroupCell` + `ToolCallEntryView`
- thinking / expecting assistant response -> `ChatThinkingCell`
- `status` / `session_started` / `session_ended` 沒有直接 row

## Tool events

### 實際看過的 tool names

本機 transcript 掃描結果分成兩類：

#### Claude transcripts（`tool_use.name`）

實際高頻名稱：

- `Read`
- `Bash`
- `Write`
- `Edit`
- `Grep`
- `Glob`
- `Skill`
- `ToolSearch`
- `Agent`
- `WebSearch`
- `WebFetch`

也看過較低頻的 MCP-style 工具名稱：

- `mcp__computer-use__screenshot`
- `mcp__computer-use__left_click`
- `mcp__computer-use__request_access`
- `mcp__computer-use__open_application`
- `mcp__computer-use__key`
- `mcp__zhtw-mcp__zhtw`

#### Codex transcripts（`function_call.name`）

本機目前實際看過的高頻名稱大多是 Codex agent 自己呼叫的 integration 工具：

- `exec_command`
- `write_stdin`
- `update_plan`
- `view_image`
- `wait_agent`
- `mcp__codex_apps__github_search`
- `mcp__codex_apps__github_fetch`
- `mcp__codex_apps__github_fetch_file`
- `mcp__codex_apps__github_get_repo`

另外還會有非 `function_call` 的 `event_msg` 工具相關結束事件：

- `exec_command_end`
- `patch_apply_end`
- `mcp_tool_call_end`

### input / output schema

#### Claude tool input

Claude `tool_use.input` 是 JSON object，Bridge 直接 stringify 後塞進 `AgentEvent.input`。本機樣本包含：

- `Bash`
  - `{"command": "...", "description": "..."}`
- `Read`
  - `{"file_path": "..."}`
- `Write`
  - `{"file_path": "...", "content": "..."}`
- `Edit`
  - `{"file_path": "...", "old_string": "...", "new_string": "...", "replace_all": false}`
- `Grep`
  - `{"pattern": "...", "path": "...", "output_mode": "content"}`
- `Glob`
  - `{"pattern": "...", "path": "..."}`

Claude tool result來自 user block `tool_result`：

- `output` 會是 compact string 或 JSON stringify
- metadata 目前只有：
  - `is_error=true/false`

#### Codex tool input

Codex `function_call.arguments` 目前是 raw JSON string。常見樣本：

- `exec_command`
  - `{"cmd":"git ...","workdir":"...","yield_time_ms":1000,"max_output_tokens":4000}`
- `write_stdin`
  - `{"session_id":46641,"chars":"","max_output_tokens":6000,"yield_time_ms":1000}`
- `update_plan`
  - `{"plan":[...]}`
- GitHub app calls
  - `{"org":"...","repository_name":"...","query":"...","topn":20}`

Codex tool result有三條來源：

1. `function_call_output`
   - metadata: `source=function_call_output`
2. `exec_command_end`
   - metadata: `source=exec_command_end`, `exit_code`, `status`
3. `patch_apply_end`
   - metadata: `source=patch_apply_end`, `success`, `status`

### iOS 目前對 tool name 的顯示

`ToolCallFormatter` 目前只做很小的 mapping：

- `exec_command` / `run_command` / `shell` -> `Bash`
- 其他名稱原樣顯示

input 摘要規則：

- JSON object 會優先挑以下 key：
  - `cmd`
  - `command`
  - `input`
  - `text`
  - `path`
  - `args`
  - `argv`
  - `script`
- 沒命中時才把整個 dictionary 的 value 依 key 排序後串起來

## Event lifecycle notes

### Claude vs Codex 差異

- Claude 沒有 `assistant_final`
  - A1 UI 不應把「final answer 特別樣式」當成跨 vendor 必有資料
- Codex 常見兩條 assistant 路徑：
  - `response_item.message`
  - `event_msg.agent_message(commentary/final_answer)`
- Codex 目前沒有被 Bridge publish 成 `thinking` 的事件
  - `response_item.reasoning` 目前直接忽略
- Claude 有明確 `thinking` block，但 UI 目前只顯示 placeholder，不顯示 thinking 文字本身

### transient event 與 UI 穩定層

- `.thinking` 是 event-stream 暫態，不適合直接綁定 row 存亡
- 目前 iOS 會用 `ChatResponseState` 把它橋接成 stable placeholder
- pending user bubble 也會在 echo 到來時原地 ACK，不再 remove+insert

### silent drops / 未使用資訊

目前有幾類資訊已經進到 event payload，但 UI 沒用：

- `status` unsupported version 訊息
- Claude `tool_result.metadata.is_error`
- Codex `exec_command_end.exit_code`
- Codex `patch_apply_end.success`
- Codex `assistantMessage.metadata.phase`
- Claude thinking 文字內容

另外，Codex transcript 裡還看得到一些 `event_msg` 類型目前完全沒 publish：

- `token_count`
- `user_message`
- `task_started`
- `task_complete`
- `context_compacted`
- `agent_reasoning`
- `turn_aborted`
- `error`

這些如果未來要做 richer status / progress / notification，可能要先決定是否提升到 `AgentEvent.Kind`。

### 對 A1 UI 的直接影響

- tool UI 不能只假設 `Bash / Read / Write / Edit / Grep`
  - Claude 有 MCP-style 名稱
  - Codex 有 app / planner / shell integration 名稱
- markdown renderer 目前主要吃 assistant / user `text`
- tool diff renderer 要先決定：
  - 是直接 parse `tool_result.output`
  - 還是先在 Bridge 抽成更結構化 event
- final answer 專屬視覺若要做，只能當 Codex enhancement，不能當 shared contract
