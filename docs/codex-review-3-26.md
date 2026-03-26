# Codex Review: Claude Code commits 369f78516..HEAD

**日期**：2026-03-26
**範圍**：89 commits, 154 files, +2858/-1297 lines
**作者**：Claude Code (Claude Opus 4.6)
**審查重點**：正確性、安全性、MRC 記憶體管理、邊界條件

---

## 變更摘要

### 1. Notification System（Socket API）
**檔案**：`TideySocketServer.m`, `TideySocketConnection.m`, `TideyNotificationStore.m/.h`

- Unix domain socket at `~/Library/Application Support/Tidey/tidey.sock`
- JSON + plaintext protocol（newline-delimited, fire-and-forget）
- 命令：`notification.create`, `set_status`, `clear_status`, `report_shell_state`, `set_title`
- TideyNotificationStore（singleton）、TideyStatusStore（singleton, broadcast `*` support）
- System notification via UNUserNotificationCenter

**Review 重點**：socket lifecycle、thread safety（main queue dispatch）、singleton 記憶體

### 2. Claude Code Hook Integration
**檔案**：`Resources/bin/claude`（wrapper script）, `sources/TideyCLI/main.swift`（Swift CLI）

- claude wrapper 攔截 `claude` 指令，注入 `--settings` hooks
- Swift CLI binary `tidey` 處理 hook events（session-start, stop, notification, prompt-submit, session-end）
- Transcript JSONL 解析（stop hook 提取最後 assistant message）
- POSIX socket API（socket/connect/write/close）

**Review 重點**：wrapper 的 edge cases（`-r` flag、subcommands passthrough）、transcript 解析錯誤處理、socket 連線失敗靜默

### 3. Shell Integration
**檔案**：`iterm2_shell_integration.zsh`, `iterm2_shell_integration.bash`

- precmd/preexec hooks 報告 Running/Idle status
- `TIDEY_BIN_DIR` PATH injection（one-shot precmd, remove-then-prepend）
- tmux support: `LC_TERMINAL=Tidey`, `ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX`
- tmux `update-environment` propagation

**Review 重點**：PATH manipulation 安全性、tmux env propagation 完整性

### 4. Sidebar UI（iTermRootTerminalView.m）
**檔案**：`iTermRootTerminalView.m`（+595 lines）

- Workspace cell layout（expanded notification + normal）
- cmd-hold shortcut hints（overlay on toggle buttons）
- Badge rendering、status icon（SF Symbol with hierarchicalColor）
- Toggle button hints positioning（diagonal offset）
- App-activate dismiss for hints

**Review 重點**：frame 計算、flipped coords、記憶體（subview lifecycle）

### 5. PRODUCT_NAME Rename
**檔案**：`project.pbxproj`, `*.plist`, `iTerm2.xcscheme`, `Makefile`

- PRODUCT_NAME: iTerm2 → Tidey
- CFBundleExecutable/CFBundleName → Tidey
- Swift bridging header path: Tidey-Swift.h

**Review 重點**：是否有遺漏的硬編碼 "iTerm2" 路徑

### 6. Feature Trim + Branding
**檔案**：`iTermApplicationDelegate.m`（+777 lines）, `MainMenuMangler.swift`

- 隱藏 ~180 個選單項目
- Tidey Shortcuts panel（取代 Preferences）
- Shell integration 自動安裝（首次啟動 dialog）
- OSC 9 suppression when Claude is foreground

**Review 重點**：menu hiding 是否影響必要功能、auto-install 的 filesystem 操作

### 7. 其他
- `PseudoTerminal.m`：tabBarAlwaysVisible=YES、workspace title override（set_title）、performKeyEquivalent 攔截
- `PTYSession.m`：env var injection（TIDEY_SOCKET_PATH, TIDEY_WORKSPACE_ID, TIDEY_BIN_DIR, LC_TERMINAL）
- `iTermWindowImpl.m`：performKeyEquivalent for Tidey shortcuts
- `iTermComposerManager.m`：-379 lines（移除 MinimalComposerViewController）

---

## Top 10 最大變更檔案

| 檔案 | 變更 |
|------|------|
| iTermApplicationDelegate.m | +777 |
| iTermRootTerminalView.m | +595 |
| iTermComposerManager.m | -379 |
| MainMenuMangler.swift | -269 |
| TideyNotificationStore.m | +245 |
| TideyCLI/main.swift | +222 |
| PseudoTerminal.m | +184 |
| TideySocketServer.m | +138 |
| iTermAdvancedSettingsModel.m | ±92 |
| iTermTipData.m | ±88 |

---

## Review Findings（2026-03-26 Codex 審查結果）

### Finding 1 — HIGH: Shell state broadcast 污染
**狀態**：待修
**問題**：`TIDEY_WORKSPACE_ID` 缺失時，TideyCLI 送空的 `--workspace_id=`，server 的 `handleReportShellState:` 把空 workspace_id 視為 broadcast `*`。一個沒注入 workspace ID 的 Claude session 的 Running/Idle 會污染所有 sidebar row。
**檔案**：
- `sources/TideyCLI/main.swift:145,196` — workspaceID 可能為空字串
- `sources/TideySocketServer.m:157,194` — 空 workspace_id fallback 到 broadcast `*`
**修法**：CLI 在 workspaceID 為空時不送 `--workspace_id=` 參數，或 server 端拒絕空字串（不 fallback 到 broadcast）。

### Finding 2 — MEDIUM: Broadcast notification unread 全域共享
**狀態**：待修
**問題**：`notification.create` 不帶 workspace_id 時，store 只存一筆 `workspaceID == "*"` 的 item。`markReadForWorkspaceID:` 會把這筆 broadcast item 一起設成 read。切到任一 workspace 就清掉所有 workspace 的 badge。
**檔案**：
- `sources/TideyNotificationStore.m:55,123`
**修法**：broadcast notification 應 fan-out 成每個 workspace 各一筆，或 read 狀態改為 per-workspace tracking。

### Finding 3 — MEDIUM: Claude wrapper 路徑未 escape
**狀態**：待修
**問題**：`Resources/bin/claude` 把 `HOOK_DIR` 直接拼進 JSON hook command string，沒有 shell/JSON escape。App bundle 路徑含空白或特殊字元（如 `Tidey Beta.app`）時 hook 會壞掉。
**檔案**：
- `Resources/bin/claude:49`
**修法**：對 `HOOK_DIR` 做 shell quoting（用雙引號包裹）+ JSON string escape。

### Finding 4 — LOW: Socket unlink 單例問題
**狀態**：待修
**問題**：socket server 啟動時無條件 `unlink()` socket 路徑。第二個 Tidey 實例會搶走 socket，第一個實例的 shell 內 `TIDEY_SOCKET_PATH` 靜默失效。
**檔案**：
- `sources/TideySocketServer.m:51,56`
**修法**：啟動前先 `connect()` 測試 socket 是否已在用，若已有 listener 則跳過或用不同路徑。

---

## 已知問題（不需 review，已記錄）
- Terminal reflow flicker（Metal renderer 層級）
- tmux 內 pwd 顯示 "tmux"（iTerm2 看不到 tmux 內部 process）
