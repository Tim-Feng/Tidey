# Tidey Debug 手冊

Tidey 從 iTerm2 fork 出來之後所有踩過的坑，涵蓋 UI layout、sidebar / workspace、file tree、shell integration、tmux、socket API、branding、Claude hook。

下次碰到問題先讀這份。猜錯過 owner、加過 instrumentation、或反覆試超過一次的問題，修完回來補。

## Debug 流程

### 1. 先搞清楚 owner

先判斷 bug 屬於哪一層：

| 層 | 管什麼 |
|---|---|
| `iTermRootTerminalView` | sidebar、editor panel、file tree、Monaco host、toggle/drag handles、layout glue |
| `PseudoTerminal` | window-level orchestration、workspace/panel model、menu actions、selector routing |
| `PSMTabBarControl` | terminal tab bar、overflow button (`>>`)、add-tab button、tab cell drawing |
| `NSOutlineView` / `NSTableView` | file tree、sidebar row、disclosure triangle、scroll behavior |
| `PTYSession` | cwd、title/subtitle、env injection、shell integration |
| `iTermSemanticHistoryController` | `cmd+click` 開檔案/URL |
| Tidey sidebar / workspace model | workspace 切換、sidebar row、drag preview、badge、reorder |
| Tidey file tree | outline view、truncation、scroll、reveal |
| Tidey socket API | IPC、shell state report、workspace_id |
| Tidey Claude hook | hook command escaping、notification routing |

### 2. 先 instrument

candidate view 各染一個 debug 顏色。frame / hidden / selected state 寫 log（Console 看不到就寫 `/tmp/`）。`rg` 搜 owner class，找到最後寫入 state 的程式碼。

### 3. 找最後一個 writer

設好的值常常被後面的 code 蓋掉：

- PSM layout 會重設 overflow button
- AppKit control 在 layout / reload / expand 後重新算 frame
- `.zshrc` / tmux startup 再蓋一次環境變數

### 4. Local patch 優先

改一個 subview 的 hidden / frame、一條 event routing、一個 selector 分支。Layout path 選擇或整條 window orchestration 不要第一刀就動，除非已經確認 bug 在那裡。

### 5. 一次只改一個假設

同一輪同時換 layout path、view hierarchy、owner，之後就不知道哪刀有效、哪刀造成 regression。

---

## 踩過的坑

### Layout

**不要直接切 layout path。** `layoutSubviewsWithVisibleTabBarForWindow:` 和 `layoutSubviewsWithHiddenTabBarForWindow:` 會影響整條 layout chain（tab bar frame、title-in-place、status bar、division view）。讓原本的 path 跑完，在 `layoutSubviews` 結尾或 local helper 裡 patch hidden / frame。→ `sources/iTermRootTerminalView.m`

**PSM 會覆蓋剛設好的值。** 設 `overflowPopUpButton.hidden = YES`，下一個 layout pass PSM 又打回來——`PSMTabBarControl.m` layout 過程中直接 `setHidden:` overflow button。要 patch 就在 PSM layout 跑完之後補。→ `ThirdParty/PSMTabBarControl/source/PSMTabBarControl.m`

**`>>` 是 PSM overflow button，不是 Tidey toggle。** Terminal 收合後 sidebar 右上角冒出 `>>`，看起來像 Tidey 的 toggle。四個 toggle button 各染 debug 顏色後 `>>` 沒吃到任何顏色，搜 PSM source 才找到是 overflow button。

**autoresizingMask 會製造中間態。** Frame 在某個瞬間是錯的（terminal reflow / flicker），最終值沒問題——`autoresizingMask` 在自訂 layout 之前先跑了一次。`layoutSubviews` 開頭記 frame + call stack 可以分辨最終值錯還是中間態。

### AppKit controls

`NSOutlineView` / `NSTableView` / `NSScrollView` 出問題（selection 顏色、disclosure triangle 疊到文字、indentation 消失、horizontal scroll），多半是 control 自己的行為。`NSButton` 在 source-list cell 裡可能完全不 render；row hover / click 需要 table-level hit-test；`NSOutlineView` 的 document view / column sizing 會自己撐大。查 table / outline / scroll view 的 API 再決定要不要 custom。→ `sources/iTermRootTerminalView.m` sidebar table view / file tree outline view

### Rendering

`it_imageWithTintColor:` 用 `NSCompositingOperationSourceIn` 會把多層 SF Symbol 全染成同色（`pause.circle.fill` 變扁平）。要保層次就用 `NSImageSymbolConfiguration` 的 hierarchical color。

**非 live resize 不要切回 legacy renderer。** sidebar toggle / panel 切換時 terminal flicker，不一定是 layout 多跑一次；如果 `SessionView` 的 frame 更新也走 `temporarilyDisableMetal -> async draw -> show metal`，畫面會在 frame 已經正確之後還閃一拍。這條 fallback 是拿來扛 live resize 的，不要套到一般 panel/sidebar layout。→ `sources/PTYSession.m:sessionViewNeedsMetalFrameUpdate`

### Branding

**Icon cache。** 改了 app icon 但 Finder / Dock 還是舊圖，多半是 macOS Launch Services cache。build 問題跟 cache 問題要分開排查。

**`.icon` bundle 會覆蓋 plist。** 手動改 `CFBundleIconFile` / `CFBundleIconName`，build 後被 Xcode 的 Icon Composer `.icon` bundle 蓋掉。純用 `.icon` 或純用 `.icns`，不要混。

### Shell Integration

**PATH 被蓋掉。** `TIDEY_BIN_DIR` 在 `.zshenv` 注入成功，但 interactive shell 起來後消失——`.zshrc` 又重建了 PATH。要看 shell startup 全部跑完之後的最終值。

**tmux 裡不是同一條 startup path。** 直接開 shell 有 integration，tmux 裡沒有——啟動路徑不同。三種要分開看：Tidey 直接啟動的 shell、tmux 啟動的 shell、attach 到既有 tmux server 的 shell。

**`TERM_PROGRAM` 在 tmux 裡不可靠。** 直接 shell 正常，tmux 裡 guard 失敗——`TERM_PROGRAM` 在 tmux 內會變成 `tmux`。Tidey 要有自己的備用識別條件。

### Sidebar / Workspace

**Workspace 和 panel 是兩層，不是 iTerm 的 tab 直接改名。** 一開始 sidebar 直接讀 `PseudoTerminal.tabs`，很快就撞到 `⌘N`、`⌘T`、`⌘W`、`⌘⇧[]` 全都打錯層。真正的模型是 `Workspace > Panel(PTYTab)`。generic tab path 只知道目前 tab view item，不知道 Tidey workspace，要在 `PseudoTerminal` 額外攔截。→ `sources/PseudoTerminal.m:ensureTideyWorkspacesInitialized / showWorkspaceAtIndex: / closeCurrentTab:`

**Sidebar drag preview 的位置不要自己算。** 這題前後試了 `setDraggingFrame`、screen 座標、window 座標、table 座標、`dragImageForRowsWithIndexes:`，結果都會偏，而且偏移量跟 row index 成比例。最後留下來的做法是讓 AppKit 保留原本的 dragging frame，只用 `imageComponentsProvider` 換掉 preview image。→ `sources/iTermRootTerminalView.m:tableView:draggingSession:willBeginAtPoint:forRowIndexes:`

**Source list row 裡的 close glyph 可以畫，不代表能點。** `NSButton`、`NSTextField`、自訂 close view 都可能 render 但吃不到事件，因為 source-list row 的 mouse event 被 table view 攔走。最後可用的做法是：cell 只負責畫 `✕`，hover 和 click 都在 table-level hit-testing 做。→ `sources/iTermRootTerminalView.m:TideySidebarTableView / tideyCloseRectForRow:`

### Editor / File Tree

**editor 跟 terminal 的 1pt seam，不要靠 web view frame 疊 offset。** 這塊前後試過 content 高度扣 22pt、panel 多加 1pt、tab strip 往上頂、root view 換色，最後還有一串 revert。比較穩的是先把 editor panel 維持簡單的 full-height layout，再去修 tab bar backing / strip 那條 seam；不要把對齊補丁一路堆進 Monaco frame。→ `sources/iTermRootTerminalView.m:layoutTideyEditorPanelWithOutputs: / setTabBarFrame:`

**file tree root 和 reveal 是兩件事。** `cmd+click` 開檔案時，如果「同一個檔案已經開著」就整條短路，file tree 會停在 home 或舊 root；如果 reveal 又順手重算 root，重複點同一條連結會在 home / 正確 root 之間交替。後來拆成兩步：root 只在真的要換 root 時改；同檔案重開仍然要跑 reveal。→ `sources/iTermRootTerminalView.m:openTideyEditorFileAtPath: / tideyEditorRevealFileAtPath:`

**file tree 的寬度修法很容易把 indentation 和 disclosure 一起打壞。** 這題先後出過「把 column 鎖死」和「直接改 outline 寬度」兩種修法，結果縮排消失、箭頭疊字，後來還得整包 revert。安全邊界比較小的做法是：保留 outline 自己的層級與 disclosure 行為，處理 label truncation 和 horizontal scroll，不要第一刀就改 column geometry。→ `sources/iTermRootTerminalView.m:newTideyEditorFileTreeCellView / layoutTideyEditorContents`

### Socket API / Notifications

**`workspace_id` 缺失時，state update 要 fail closed。** notification 可以選擇 broadcast，但 shell state / Claude 狀態如果在 `workspace_id` 空白時落到 broadcast，所有 workspace 都會被一起污染。這題後來明確切開：`notification.create` 可以 broadcast；`report_shell_state` / `set_status` 這類狀態更新沒有 workspace id 就直接丟掉。→ `sources/TideySocketServer.m`、`sources/TideyCLI/main.swift`

**broadcast notification 的 unread 狀態不是一個共享 bit。** 一開始把 broadcast item 存成單一 `*` notification，結果切到任一 workspace 就把所有 workspace 的 badge 一次清掉。後來改成 per-workspace read state，才有「每個 workspace 自己消自己的 badge」。→ `sources/TideyNotificationStore.m`

**active workspace 收到通知要立刻 mark read。** 如果只在「真的切 workspace」那一刻 markRead，當前 workspace 自己收到通知會冒出不該有的 badge，切回來也會晚一拍才消。這題最後變成兩條規則：active workspace 收到通知直接 read；workspace focus 改變時也補一次 markRead。→ `sources/PseudoTerminal.m`、`sources/iTermRootTerminalView.m`

### Claude Hook / Agent 狀態

**shell command string 只要有空白路徑就會炸。** Claude wrapper 把 hook command 直接串成 shell string，app bundle 或 `Resources/bin` 路徑只要有空白，hook 就整條失效。這題後來補的是 shell escaping，不是再擴大黑名單或靠使用者避開空白路徑。→ `Resources/bin/claude`

**Claude Code 這條路不要靠被動偵測 terminal output。** 後來穩定下來的是 Swift CLI + hooks：`session-start`、`prompt-submit`、`notification`、`stop`、`session-end` 都走明確事件，socket 收到什麼就更新什麼。這樣比去猜 process name、OSC、terminal output pattern 穩很多。→ `sources/TideyCLI/main.swift`、`sources/TideySocketServer.m`

### tmux / Agent 環境

**tmux 要活，不只是把 `TIDEY_SOCKET_PATH` 塞進 env。** 後來真正補齊的是整組：`TIDEY_SOCKET_PATH`、`TIDEY_WORKSPACE_ID`、`TIDEY_BIN_DIR`、`LC_TERMINAL`、`ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX`，再加 `tmux set-option -ga update-environment ...`。少一個都可能變成「直接 shell 正常，tmux 裡壞掉」。→ `sources/PTYSession.m`、`Resources/shell_integration/iterm2_shell_integration.zsh`

**PATH 注入要晚於 shell startup。** `.zshenv` 先注入不夠，因為 `.zshrc` 之後還會把 PATH 重建一遍；tmux 繼承外層 shell 時還會把舊值再帶進來。最後留得住的是 one-shot `precmd`：先 remove 再 prepend。→ `Resources/shell_integration/iterm2_shell_integration.zsh`

### Terminal Chrome

**terminal collapse 不要順手改整條 tab bar / title-in-place 路徑。** 這題後來直接留下了一個整包 revert：把 tab bar backing、title-in-place、top chrome 一起動，第二個 panel 立刻冒黑條，而且 gap 也沒真的修掉。terminal collapse 需要 local patch：overflow、toggle、可見性各修各的，不要再碰 window-level layout path。→ `10e59719b Revert tab bar collapse attempts`、`sources/PseudoTerminal.m`、`sources/iTermRootTerminalView.m`
