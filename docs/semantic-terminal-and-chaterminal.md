# 語意 Terminal 與 Chaterminal

這份文件記錄目前對「AI agent 年代的 terminal 介面」的產品思考。這還不是實作規格。

## 名詞

### 語意 Terminal

語意 Terminal 是系統模型。

它把 terminal 活動視為一串有語意的事件，而不只是字元格畫面。原始 terminal 仍然保留，但 Tidey 也能理解更高層級的事件：

- 使用者送出一段 prompt。
- agent 回覆訊息。
- tool call 開始或結束。
- 出現檔案路徑、diff、圖片或權限請求。
- slash command 產生結構化的 status 或 context 報告。
- shell command 產生一段應該被分組的輸出。
- terminal session 正在等待使用者輸入、確認或選項。

這層模型讓 Mac UI、Remote UI、未來的多 agent 功能都能重用 terminal 工作狀態，而不是只能讀畫面。

### Chaterminal

Chaterminal 是介面概念。

它是 chat 形狀的 terminal 表面。它保留 terminal 能力，但把工作呈現成訊息、卡片、控制項和可展開的原始輸出。這個名字目前只是 `chat + terminal` 的工作名稱；公開命名可以之後再定。

目前先把兩件事分清楚：

- 語意 Terminal：資料模型與事件層。
- Chaterminal：使用者看到的介面。

## 為什麼要做

Tidey 現在已經從 terminal 周邊拿到不少結構化來源：

- Claude Code 與 Codex 的 JSONL transcript。
- wrapper hooks 與 pane identity。
- Bridge routing 與 input logs。
- `/status`、`/context` 這類已知 slash command 輸出。
- tool call、file reference、diff、image upload、command summary。

這些來源比抓 terminal 畫面可靠。terminal 畫面仍然必要，因為它是相容性基礎；但它不是好的產品資料來源。畫面會失去 intent、identity 與結構。

方向是保留 terminal 相容性，同時在旁邊建立語意層。

## 目前不重寫 terminal emulator

如果 Tidey 自己掌控 terminal emulator，確實能更完整控制 PTY input/output、selection、rendering 與 link detection。但成本很高：

- ANSI escape handling。
- Alternate screen mode。
- Mouse reporting。
- Shell integration。
- tmux 行為。
- Vim、less、top、ssh、REPL、full-screen TUI。
- 字型 shaping、wrap、scrollback、search、selection、clipboard、accessibility。

下一階段應該先保留 iTerm2 作為成熟 terminal renderer，然後在旁邊增加 semantic capture。

terminal emulator 繼續當 fallback surface。Semantic UI 從 Tidey 已經有可靠結構訊號的地方開始長出來。

## 資料來源

語意 Terminal 不應該依賴單一來源。

### Agent Transcript

Claude Code 與 Codex JSONL 是目前最好的 agent 對話來源。它們保留 message role、tool call、時間與部分 metadata。

這應該繼續作為 chat-mode panel 的主要來源。

### Wrapper 與 Pane Identity

wrapper scripts 與 tmux pane options 可以把 agent process 綁到：

- workspace id
- panel id
- vendor
- session id
- process id
- tmux socket / session / window / pane

這是 identity layer。Bridge 與 Remote 需要這層，才能把 transcript 對到正確的 visual panel。

### Bridge Event Log

Bridge 可以維護一些 vendor JSONL 不會自然保存的事件：

- Remote chat submit request id。
- paste / enter routing result。
- Remote 用的 slash command summary。
- upload result。
- connection route 與 recovery state。
- permission / selection state。

這能補上 terminal process 行為與產品 UI 之間的缺口。

### PTY / Terminal Observation

PTY observation 仍然有用，但它應該是 fallback 與驗證來源：

- 偵測可見 prompt。
- 抓最近 terminal output。
- 驗證 paste 是否真的落到 pane。
- 摘要 raw terminal output block。
- semantic parsing 不可用時提供 raw mode。

它不應該成為 agent transcript 語意的主要來源。

### Known Command Templates

對於使用者價值穩定、輸出可判讀的 command，Tidey 可以提供 Remote 結構化卡片：

- Codex `/status`
- Claude `/context`
- 之後可能是 `/usage`、`/model`、permission prompts、selection prompts

Mac terminal 仍然收到真正的 command。Remote 顯示的是 Bridge 判讀後的 companion card。

### App Server / Private Protocol

如果第一方 CLI 提供穩定的 local API，Tidey 可以使用。現階段不應依賴未公開或不穩定的 app-server 行為。

目前 app-server 類路徑只能當研究方向，不適合當產品基礎。

## Event Model 草圖

未來的 semantic event log 可以包含：

```text
agent.user_message
agent.assistant_message
agent.tool_call
agent.tool_result
agent.permission_request
agent.option_prompt
agent.slash_command_summary
terminal.output_block
terminal.input_submitted
terminal.command_detected
file.reference
file.diff
image.uploaded
connection.route_changed
connection.recovered
chatspace.agent_joined
chatspace.decision_recorded
chatspace.action_item_created
```

每個 event 需要能回答：

- 屬於哪個 workspace？
- 屬於哪個 panel？
- 對應哪個 process 或 agent session？
- 哪個來源產生這個 event？
- 是否可以顯示在 Remote？
- 使用者能不能對它操作？
- 是否有 raw terminal output 可以 fallback？

## Chaterminal UI 原則

Chaterminal 不應該把所有 terminal 畫面都硬轉成 chat bubbles。它應該為每一種 event 選擇資訊損失最少的呈現方式。

建議呈現：

- agent messages：chat bubbles
- tool calls：可展開卡片
- diffs：diff cards
- file references：可點擊連結 / reader / editor
- slash command summaries：結構化卡片
- permission prompts：native action controls
- terminal output：可展開 raw output 的 monospaced block
- unknown TUI state：raw terminal preview

使用者永遠要能回到 raw terminal。

## Chatspace

Chatspace 是多 agent 會議層。它和 workspace 不同。

workspace 是工作發生的地方。workspace 裡的 panels 可以保持獨立。

chatspace 是需要跨 panel 或跨 agent 協調時才建立的空間。使用者可以把既有 panels 召喚進同一個討論，做出決策、分配後續工作，再讓 agents 回到各自 workspace。

Chatspace state 應該包含：

- 被加入的 panels / agents
- 目前任務
- 可見 context
- 隱藏的 context 邊界
- 決策
- action items
- 責任歸屬
- 交接狀態
- 未解問題

Chatspace 需要語意 Terminal，因為它不該靠抓 terminal 畫面運作。它需要結構化 agent events、context 邊界、明確記錄的決策。

## 安全與 Context 邊界

語意 Terminal 會讓更多動作變得可見，因此需要更明確的邊界。

擴大 agent 自主性之前，需要先回答：

- 哪個 panel 可以讀哪些檔案？
- 哪個 agent 可以看到另一個 agent 的 transcript？
- 哪些 chatspace 訊息會寫回 workspace？
- 哪些 action 需要使用者確認？
- agent 能不能對另一個 panel 送 input？
- 哪些內容算決策，哪些只是暫時討論？

預設策略應該保守：

- 使用者決定哪些 panels 進 chatspace。
- agents 不會自動看到其他 panel 的完整 context。
- raw terminal output 保留，但不自動注入所有地方。
- permission prompts 需要明確且有範圍。

## 第一批可驗證切片

### 1. Slash Command Cards

繼續把常用 CLI slash command 輸出轉成 Remote 結構化卡片。

目前方向：

- Codex `/status`
- Claude `/context`

下一批 command 應該根據實際使用頻率選，不要一次追求全覆蓋。

### 2. Permission and Option Prompts

Remote 應該理解 CLI 正在等待的常見輸入：

- approval
- escape
- arrow selection
- tab / completion
- yes / no
- numbered choices

如果 prompt 能從 structured logs、known CLI output 或窄範圍 terminal observation 偵測到，就不需要先重寫整個 terminal。

### 3. Terminal Output Blocks

對 raw terminal 工作，Remote 應該把輸出整理成可閱讀的 blocks，而不是只做完整 terminal clone。

每個 block 可以包含：

- title
- command / origin when known
- recent output
- copy action
- expand raw output
- send follow-up input

### 4. Semantic Event Log Prototype

在 Bridge 或 Tidey Mac 裡新增一層內部 event log，先記錄既有來源能提供的 semantic events。

第一版可以很窄，而且 append-only：

- chat submit request
- agent user echo
- agent assistant message
- slash command summary
- permission / option prompt candidate
- terminal output block

目標是驗證 Remote UI 能不能從 semantic events render，同時保留 raw fallback。

### 5. Chatspace Prototype

先做手動建立 chatspace：

- 選兩個既有 panels。
- 顯示它們最近的 semantic summaries。
- 使用者寫一則訊息送給兩邊。
- 手動記錄 decision / action item。

第一版先不要做自動 agent-to-agent 控制。產品價值在協調，不在讓 agents 不受控互聊。

## 目前不做

- 不把重寫 terminal emulator 當第一步。
- 不依賴未公開 app-server 行為。
- 不寫一個通用 parser 去解析所有 TUI。
- 不把所有 workspace context 自動分享進 chatspace。
- 不讓 agents 在沒有使用者可見邊界的情況下互相操作。

## 待釐清問題

- semantic event log 應該放在 Bridge、Tidey Mac，或兩邊都放？
- semantic events 要保存多久？
- 哪些 events 只留本機，哪些同步給 Remote？
- Remote 如何針對單一 event 要求 raw fallback？
- Tidey 如何標記一個 event 是否安全，可注入另一個 agent？
- chatspace decisions 要存在哪裡？
- cross-panel interaction 的最小 permission model 是什麼？
- 哪些 slash commands 夠穩定，可以做 template？
- terminal observation 做到哪裡會變成脆弱的畫面抓取？

## 目前結論

> Semantic Terminal is the model. Chaterminal is the interface.

Tidey 不需要先放棄 iTerm2 才能探索這個方向。實際下一步是保留既有 terminal 與 agent integrations，從已經有結構化來源的地方建立 semantic events。
