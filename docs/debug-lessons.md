# Tidey Debug Checklist

改 UI、layout、shell integration、terminal interaction 前，先掃這份。

## 審閱 marker

**Last reviewed**: `c4f3a50b5` · 2026-04-17

**下次審閱要做的事**：
1. `git log c4f3a50b5..HEAD` 列出所有新 commits
2. 掃 `~/.claude/projects/-Users-timfeng/*.jsonl`（cc sessions）跟 `~/.codex/sessions/**/rollout-*.jsonl` 在 marker 日期之後的記錄
3. 從 commit message + session 對話中找「原本沒想到 / 踩第二次 / 花超過 1 小時才解的」歸納成 bullet
4. 把 lesson 補進對應章節（owner／UI／shell integration 等），iOS 側去 `~/GitHub/Tidey-Remote/docs/debug-lessons.md`
5. 把 marker 的 commit hash 更新成掃完當下的 HEAD，日期同步

## 先判斷 owner

- `iTermRootTerminalView`
  - sidebar、editor/browser panel、file tree、right-panel tab strip、toggle/drag handles、layout glue
- `PseudoTerminal`
  - workspace / panel model、window-level selector routing、menu actions
- `PSMTabBarControl`
  - terminal tab bar、overflow button `>>`、add-tab button、tab cell drawing
- `PTYSession`
  - env injection、cwd/title/status、terminal session lifecycle
- `PTYTextView` / `PTYMouseHandler`
  - terminal mouse hit testing、selection anchor、drag selection、URL hover/click
- `NSOutlineView` / `NSTableView` / `NSScrollView`
  - file tree、sidebar row、disclosure triangle、scroll behavior
- `iTermSemanticHistoryController` / `iTermURLActionHelper`
  - `cmd+click` 開檔案 / URL
- `TideySocketServer` / `TideyStatusStore`
  - IPC、workspace status、notification read state

## 每次下刀前先做

- **profile 顏色永遠要考慮 (Dark)/(Light) variant**
  - iTerm2 runtime 在 dark mode 讀的是 `Background Color (Dark)`，不是 `Background Color`
  - 寫入時要 fan out 到 base + `(Dark)` + `(Light)` 三份
  - 測試 iTerm2 匯入時，source profile 的 variant key 也要一起改，只改 base key 畫面不會變
  - 這個坑已經踩三次：bootstrap color fan-out、Settings Appearance 寫入、iTerm2 importer 測試
- 找最後一個 writer
  - AppKit / PSM / shell startup 常常在後面把剛設好的值蓋掉
- 先做 local patch
  - 先修單一 subview 的 frame / hidden / event routing，不要第一刀就換整條 layout path
- 一次只改一個假設
  - 同一輪不要同時換 owner、座標系、view hierarchy
- 要加 debug 時優先寫 `/tmp/`
  - Tidey `NSLog` 不會進 macOS unified log stream：`log stream --predicate 'process == "Tidey"'` 抓不到任何東西
  - 原因：macOS 對第三方 app log 預設標為 private，被系統 redact 掉
  - 用 `fopen("/tmp/tidey-xxx.log", "a")` + `fprintf` 最穩，log 看完就刪

## UI / Layout

- 不要直接切 `layoutSubviewsWithVisibleTabBarForWindow:` / `layoutSubviewsWithHiddenTabBarForWindow:`
  - 這會連 tab bar、status bar、division view 一起動
- `PSMTabBarControl` 會在 layout 後重設 overflow button
  - `>>` 是 PSM overflow button，不是 Tidey toggle
- `autoresizingMask` 會製造中間態
  - 先分清楚最終 frame 錯，還是中間一拍錯
- `NSOutlineView` / `NSTableView` / `NSScrollView` 的行為先查 API
  - selection、indentation、disclosure、horizontal scroll 多半是 control 自己算的
- `NSOutlineView` 會自動把自己的 frame 撐寬到容納最寬的 row
  - 預設 `columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle` + `autoresizesOutlineColumn = YES`
  - 就算手動設 column width / view frame，NSOutlineView 還是會在 layout pass 把 outline view 的 frame 撐到最寬 cell 的寬度
  - 症狀：file tree 長檔名的 `...` 截斷在初次 render 顯示、捲動後消失，因為 outline frame (267pt) 已經比 scroll document visible width (199pt) 寬，cell 有空間完整畫出來
  - 用 `fopen("/tmp/...")` log `outlineView.frame.size.width` vs `scrollView.documentVisibleRect.size.width` 就能抓到
  - 解法：`columnAutoresizingStyle = NSTableViewNoColumnAutoresizing` + `autoresizesOutlineColumn = NO`，讓自己的 layout code 成為 column width 的唯一 authority

## Sidebar / File Tree

- Source-list row 裡的 close glyph 可以畫，不代表能點
  - hover / click 往往要在 table-level hit testing 做
- file tree root 和 reveal 分開處理
  - 同檔案已開著時，不要讓 reveal 被 root 切換短路
- file tree 寬度不要第一刀就改 column geometry
  - 很容易把 indentation 和 disclosure triangle 一起打壞

## Browser / Editor Panel

- `WKWebView` 不是普通 sibling view
  - 它有自己的 compositing layer，`NSView` sibling 的 z-order 和 `layer.zPosition` 不足以保證蓋在它上面
  - 需要真正的 panel-level overlay，或更高層的 overlay 容器
- 不要靠 `osascript` quit 驗證 UI 改動
  - Tidey 有 `cmd+q` 雙重確認
  - `osascript` / menu quit 會被 quit guard 攔住，看起來像 app 沒關、還在跑舊 UI
  - 要用使用者手動 `cmd+q` 再 `cmd+q` 真正關掉
- browser/editor mixed tab strip 先改 render policy，再改 model
  - collapsed group 最安全的做法是不 layout tabs，不是 remove/re-add model
- `NSTextFieldRoundedBezel` 的文字基線偏上
  - browser URL bar 要自然置中時，`SquareBezel` 比較對稱
- 不要用 custom `NSTextFieldCell` 去改 `titleRectForBounds:` / `editingRectForBounds:`
  - 很容易把 click / editing hit testing 弄壞
- `closeTideyRightPanelTabAtIndex:` 的 `count == 0` early return 路徑
  - 容易漏掉 `tideyUpdateBrowserContentVisibility` / `layoutTideyEditorContents` / `updateTideyChromeToggleButtons`
  - 關掉最後一個 browser tab 後 file tree 不恢復就是這個原因
- `updateTideyChromeToggleButtons` 要考慮 browser mode
  - file tree toggle button 在 browser 顯示時要 hidden，切回 editor 時要恢復
- `NSButton` 會吃掉 tab drag 的 `mouseDragged`
  - `mouseDown` 進 `NSCell trackMouse:` 後，local monitor 收不到後續 drag/up
  - tab title 不能用會攔事件的 `NSButton`
  - 要在 item view 自己用 `mouseDown` + `nextEventMatchingMask:` 做 click vs drag
- split 後 browser host 只能用 pane-local bounds
  - browser container / webview 不能 fallback 回 whole-panel bounds
  - primary pane 如果直接用 `_tideyEditorPanelView.bounds`，左 pane 開 web 會橫跨兩欄

## Terminal Selection / Mouse

- 文字選取起點先看 `PTYMouseHandler -> mouseHandlerCoordForPointInView:`
  - selection anchor 主要走這條，不是 `coordForPoint:`
- URL hover / `cmd+click` 和文字選取不是同一路
  - URL hit testing 可以走 biased coord；文字選取不要跟著吃 bias
- **`clickCoord` 和 `selectionCoord` 走不同座標系**
  - `clickCoord` 走 `coordForPoint:`（document 座標，含 scrollback）
  - `selectionCoord` 走 `mouseHandlerCoordForPointInView:`（screen-relative，已扣 `numberOfScrollbackLines`）
  - `beginSelectionAtAbsCoord` 要用 `selectionY + overflow + numberOfScrollbackLines` 才正確
  - 只加 `overflow` 會少 `numberOfScrollbackLines` 行，selection 起點偏上
  - tmux detach 後特別容易觸發：primary buffer 恢復 scrollback，`numberOfScrollbackLines` 不再是 0
- `locationInTextViewFromEvent` 的 `ceil(y)` 會在行邊界把 click 推到下一行
  - 這題要看 click / drag 實際吃的是哪條 path，再決定 rounding
- `textView.frame.origin.y` 和 `topBottomMargins` 都會影響視覺起點
  - 先確認 point 所在座標系，再決定要不要扣 offset
- `WKWebView` 的 responder chain 不能拿來判斷 editor focus
  - `firstResponder` 常是 WebKit 內部 view，不是穩定 contract
  - `isDescendantOfView:` 和 class-name heuristic 都會飄
  - editor/browser 快捷鍵 routing 要改用 click-based region tracking

## Rendering

- **Selection Color 的 alpha 被渲染層覆寫為 1.0**
  - profile `Selection Color` 的 alpha 完全不生效
  - AppKit 路徑：`iTermTextDrawingHelper.m:755` 用 `[color colorWithAlphaComponent:alpha]` 覆寫，`alpha` 來自 `_transparencyAlpha` 或硬寫 1.0
  - Metal 路徑：`iTermMetalPerFrameState.m:1822` 用 `color.w = alpha` 覆寫，同樣來自 `_transparencyAlpha`
  - 所以改 selection color 只能改 RGB，alpha 無效
  - 要讓 selection 半透明需要改渲染管線，讓 selected path 保留 color 自身的 alpha
- 非 live resize 不要切回 legacy renderer
  - sidebar toggle / panel switch flicker 很常是多切了一次 fallback renderer
- `it_imageWithTintColor:` 會把多層 SF Symbol 壓成單色
  - 要保層次用 hierarchical symbol configuration

## Shell Integration / tmux

- PATH 問題先看 shell startup 全部跑完之後的最終值
  - `.zshenv` 先注入不夠，`.zshrc` 很可能再蓋一次
- tmux 不是同一條 startup path
  - 直接 shell、tmux 新 session、attach 到既有 tmux server 要分開看
- `TERM_PROGRAM` 在 tmux 裡不可靠
  - tmux 內通常會變成 `tmux`
- 不要在 shell integration 裡用 `tmux set-option`
  - 會污染所有連到同一個 tmux session 的 terminal，不只 Tidey
- shell integration 裡的 PROMPT override 會被 oh-my-zsh 覆蓋
  - 要用 `precmd` hook 在 `.zshrc` 跑完後才設定，不能直接賦值
  - 不要用 one-shot hook（`add-zsh-hook -d`），oh-my-zsh 每次 precmd 都會重設 PROMPT
- `LC_TERMINAL` 在 tmux 裡是空的
  - tmux 不自動轉發 `LC_TERMINAL`
  - 用 `tmux show-environment LC_TERMINAL` 查 tmux server 的環境變數作為 fallback
- tmux server 的 env 會跨 Tidey 重啟殘留
  - tmux server 第一次起來時抓一份 env snapshot，之後所有新 session / new-window 都繼承
  - Tidey 重啟後 `TIDEY_SOCKET_PATH` / `TIDEY_WORKSPACE_ID` 可能指向已失效的 socket / UUID
  - Claude wrapper 做法（`4c3e3ebd9`）：hook command 執行時從 `tmux show-environment` 即時讀，不用 shell startup 繼承值
  - 症狀：wrapper 檢查 socket 不存在就 bypass，整條 pipeline 默默失效
  - 特別慘的場景：從 Tidey Dev 切回 prod，socket path 是 `tidey-dev.sock`
  - Codex wrapper 目前還沒這層 fallback（已知債，見 TODO）
- prod / dev socket path 要硬分離，不要靠 fallback 猜
  - 同機同時有 Tidey prod / dev 時，如果兩邊共用同一個 socket path，wrapper / hook / sidebar 會誤打到另一個 instance
  - socket naming policy 要在啟動時就決定，不能等 wrapper 檢查失敗再臨時 fallback
  - 補證：`aa75413df`
- zsh 會 cache command 的絕對路徑
  - Tidey shell integration 把 `TIDEY_BIN_DIR` prepend 到 PATH，但長 live 的 shell 已經把 `codex` / `claude` hash 成舊路徑
  - 新裝 Tidey 後沒有新開 shell 就測不到新 wrapper
  - 解法（`6f1b3459e`）：shell integration 裡 PATH 注入後跑 `rehash 2>/dev/null || true`，強制失效 command hash
- CODEX_HOME overlay 小心 nesting
  - wrapper 用 `CODEX_HOME` 覆蓋到 `/tmp/tidey-codex-home.XXX` 並塞 hooks.json + config.toml
  - 如果 wrapper 被 exec 兩次（例如使用者在 codex TUI 裡再開 codex），第二次的 real-home 會指向第一次的 overlay，產生 overlay-of-overlay
  - 解法（`cb0d4bb8e`）：`resolve_real_codex_home` 偵測 `tidey-codex-home.*` pattern，找回原始 `~/.codex`

## Socket / Notification / Agent Integration

- `workspace_id` 缺失的 state update 要 fail closed
  - `report_shell_state` / `set_status` 不能默默落到 broadcast
- broadcast notification 的 unread state 不能用單一共享 bit
  - read/unread 要按 workspace 分開算
- stream / subscription protocol 要有 completion signal
  - `subscribe_agent_events` 如果只回放 replay event、但不告訴 client replay 何時結束，client 只能寫死 timeout 猜「應該送完了」
  - 這種 timeout 很快會變成產品體感延遲的最大頭，甚至比實際 RTT 還大
  - 解法是在 protocol 裡明確帶 completion 訊號，例如 `replay_count` 或 `replay_end`，不要把「何時可以 reveal UI」交給 client 猜
- session identity 不能沿用舊 panel / workspace UUID，整條鏈都要改寫成 tmux-resolved current binding
  - tmux pane matching 只能解出「現在這個 pane 對應哪個 current workspace / panel」，之後 replay / fetch / apply / buffered migrate 都要跟著改寫
  - 只在入口做一次 old→new 映射不夠，任何還拿舊 UUID 讀 panel summary、抓 transcript、套 event 的路徑都會繼續錯綁
  - 這類 bug 常在 Tidey 重啟、pane close / reopen、workspace reload 後才出現，因為舊 ID 還在 event / buffer / registry 裡殘留
  - 補證：`b3d624e3f` `362c04ba2` `3756f4601` `b3d43c1ea` `f48295708` `d941cddf5` `dff5b16ed` `27a62089f` `9ed5ae92c` `552f40a42` `070796160` `85f255bfb` `8e26ad3e6`
- 大 transcript / reconnect 不是單點修補，要一起做 paging、bootstrap limit、catch-up 和 no-replay aware parsing
  - transcript 一大，initial load、resume、reconnect 會同時撞到 bootstrap 成本、重播延遲、catch-up 遺漏與 UI reveal 時機
  - 只加 bootstrap line limit 會留下 reconnect 落後；只補 catch-up 又會被 replay / no-replay 混合路徑打回來
  - 這題要當成一條完整資料流處理：paged history fetch、bootstrap 上限、reconnect catch-up、stream completion / replay_count、以及不重播時的 parser 邏輯一起收
  - 補證：`208595cae` `c48599a47` `f14a0959e` `aea886f8f` `7627e99bf`
- `security` / `codesign` / `notarytool` 的 keychain 狀態不要用 sandbox 內結果下結論
  - 這類命令在 agent sandbox 裡可能出現假陰性：`security find-identity` 回 `0 valid identities found`、`codesign` 回參數錯、`notarytool` 回 keychain access error，但同一台機器的互動 shell 實際是正常的
  - release / notarization 調查時，先用 unsandboxed interactive shell 驗證 signing identity、notary profile、Apple agreement 狀態，再決定是 cert / private key / profile / 法務同意書哪一層出問題
  - 補證：2026-04-18 release 調查最後在沙盒外確認 `Developer ID Application` identity 正常，真正阻塞是 Apple Developer `403 required agreement is missing or has expired`
- Claude hook 不要靠 terminal output 猜狀態
  - 用明確事件：`session-start`、`prompt-submit`、`notification`、`stop`、`session-end`
- hook command 只要含空白路徑就要先 escape
- `ChatBroker.publish()` 要在 `append()` 前先 init cache
  - `ChatListModel.append()` 的 early-return 路徑（`.append`、`.commit` 等）用 `createIfNeeded: false`
  - 如果 cache 尚未 init，sidebar `snippet(forChatID:)` 會 fallback 到 DB，讀到舊資料
  - 解法：在 `publish()` 呼叫 `messages(forChat:createIfNeeded: true)` 確保 cache 存在
- 第三方 agent 的 hook 系統不一定 fire
  - Codex 0.121.0 的 `codex_hooks` feature 標記 **under development**，即使 config.toml 設 true、hooks.json schema 寫對、dispatch script 可執行——runtime 也不會叫 hook command
  - 驗證方法：`codex features list | grep <feature>` 看 status（`under development` 不能信）
  - 別指望 binary 有 `HookEventNameWire` enum 或 `user_prompt_submit.rs` 字串就等於 runtime 會 fire
  - 改走該 agent 自己穩定會寫的 transcript / rollout 檔
  - 補證：`79521530a` `1ee8dac72` `5cd214aed`
- rollout / transcript 檔是比 hook 更穩的狀態來源
  - Codex rollout 格式：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，每行 JSON
  - 外層 `type: event_msg`，有用資訊在 `payload.type`：`task_started` / `task_complete` / `turn_aborted`
  - Codex `resume` 會 append 到舊 rollout 檔（不是另開新檔），檔名仍帶原 thread UUID
  - Bridge 端 tail 檔、只看 append 部分：新 prompt 一進來、Codex 一 append event，watcher 就翻成 socket 命令
  - 補證：`039cbd47e` `25020e105` `a7177e357` `a4c4eacb1`
- watcher 放 Bridge，不要放 wrapper daemon
  - wrapper 養 tail daemon 生命週期難管（resume、force-kill、pane 關掉都留殘骸）
  - Bridge 本來就是 long-running、有 session registry、有 JSONLFileTailer 基礎設施，加 watcher 是擴充現有模組不是新 process
- Codex wrapper 必須寫 registry 檔
  - Claude 有 `handleClaudeRegistryLifecycle`，Codex 也要對應寫 `~/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex/codex-<id>.json`
  - 沒這檔，Bridge `AgentSessionRegistryMonitor` 不知道 Codex 存在，CodexTranscriptSession 從不 spawn，rollout watcher 一次都不跑（症狀：sidebar 從頭到尾沒反應）
  - 補證：`f580a876f` `87989ffbb` `fe1710bdb` `a942b153e`
- rollout 檔路徑解析用 lsof process tree
  - wrapper 寫 registry 時只知道自己的 PID，不知道 Codex 會寫哪個 rollout（檔名用 Codex 內部產的 thread UUID）
  - 解法：Bridge 端 BFS 走 wrapper PID + 子孫，對每個 PID 跑 `lsof -Fn -p <pid>`，找 `/.codex/sessions/.../rollout-*.jsonl` 被開啟的檔
  - 多個同時開時取 sorted last（用字典序排序通常對應最新的）
- `resume` 模式下 rollout 檔可能非常巨大
  - 實測 252MB（8 天累積）
  - bootstrap 一定要有 line limit（目前是 500），別一開始就 full-scan
  - `isBootstrappingSidebarState` 旗標：bootstrap 期間吃 event 但不發 socket，避免回放歷史事件重送通知
- Bridge 改 code 要重 build、重 deploy、重啟 launchd
  - `tools/build.sh` 只 build Tidey Mac app，不動 Bridge
  - Bridge 獨立：`RemoteBridge/tools/deploy-bridge.sh` 會 build release binary + install + sign + `launchctl kickstart`
  - Tidey prod 的 wrapper 路徑 `/Applications/Tidey.app/Contents/Resources/bin/codex` 是手動 cp，build.sh 也不會自動同步

## Theme System

- `NSTableViewStyleSourceList` 的 selection 顏色無法自訂
  - 沒有公開 API，`drawSelectionInRect:` 在 SourceList 模式下不會被呼叫
  - 解法：`selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone` + 自己加 overlay subview
  - overlay z-order：系統 selection → overlay → cell content（用 `NSWindowBelow relativeTo:cellView`）
  - 不要改 `NSTableViewStylePlain`，會破壞 SourceList 的排版（padding、行高、字體）

- `CALayer.backgroundColor` 改了但畫面不更新
  - notification handler 確認有被呼叫（用 NSLog 驗證），但 layer 改動沒反映到畫面
  - 可能需要 `setNeedsDisplay:YES`、`setNeedsLayout:YES`、或 `CATransaction.flush()`
  - 這個問題在 feature/theme-system 上沒有解決，需要繼續調查

- theme token 替換要一個元素一個元素來
  - 一次全換容易出錯且難以 debug
  - 每換一個就 build + 視覺確認 + commit
  - 先從最明顯的元素開始（focus bar → tab bar 背景 → sidebar 選中態）

- 櫻花爛漫（light theme）配色不能直接把 dark theme 的 token 對調
  - 主內容區用近白色（胡粉 #FFFFFB），粉色只點綴 sidebar
  - focus indicator 需要更深更飽和的色（今様 #D05A6E），不能用淺粉
  - 文字選取反白要夠深（今様 @55%），不然看不到
  - 先用 front-end mockup 規劃全局配色，再實作

- `pkill -9` 會破壞 saved state，導致 "session ended very soon" warning
  - 用 ⌘Q 正常關閉，不要 force kill
  - 清 UserDefaults 後第一次開正常，第二次才出 warning（因為第一次存了壞的 state）

- `docs/theme-token-map.md` 是 UI 元件 ↔ 色碼 ↔ token 的對照表
  - 改色之前先確認元件在畫面上的位置
  - 行號會隨改動偏移，用色碼值和上下文定位

## Testing

- 不要在 test host 直接初始化 `iTermRootTerminalView`
  - app bundle image/resource 常常缺，會在 init 途中炸掉
- 把 feature 抽成 standalone helper，或只測窄 seam
  - test subclass 只 override feature seam，不要依賴完整 view init
- split view 先抽 owner 再加第二 pane
  - 先做 `TideyRightPanelPane` / `TideyEditorDocumentStore`
  - 直接在單一 owner 上加 left/right 分支，後面會變成到處補 `if/else`
- `containerView` 不能直接指到 panel root view
  - `layoutTideyEditorContents` 只該管 panel 內部子 view
  - pane container 如果直接等於 `_tideyEditorPanelView`，一設 frame 就會把整個 panel 位置打亂

## Versioning

- `version.txt` 是版號的唯一 source of truth，不是 `plists/iTerm2.plist`
  - Xcode build phase script 每次 build 都會讀 `version.txt`，用 PlistBuddy 覆寫 plist 的 `CFBundleShortVersionString`、`CFBundleVersion`、`CFBundleGetInfoString`
  - 直接改 plist 的版號無效，下次 build 就被蓋掉
  - Development config 會加 `-dev` suffix，Deployment 加日期 suffix（除非 version.txt 不含 `%(extra)s` placeholder）
  - 要改版號就改 `version.txt`，不要改 plist，也不要只看 Xcode General tab 的 Version / Build 顯示值（那些是 build 後才被覆寫的結果）

## Branding / Defaults

- 改 app icon 先分清楚是 build 問題還是 Launch Services cache
- `.icon` bundle 會覆蓋 plist icon 設定
  - `.icon` 和 `.icns` 不要混
- 改 `DefaultBookmark.plist` 後，如果 app 還在吃舊預設，要先清掉已寫入的 user defaults / cached profile
  - 不然 plist 改了，執行中的預設 profile 不一定會立刻跟著變
