# Tidey Debug Checklist

改 UI、layout、shell integration、terminal interaction 前，先掃這份。

## 本機 deployment phase 驗證（2026-09-07）

- 部署 helper 必須驗相鄰 phase 的輸入／輸出契約。服務重啟後要採用新 PID；dry-run 證據不可占用 real 的輸出位置；real preflight 即使所有檢查成功，也要確認最終 shell exit status。只測各 helper 的獨立 happy path，無法證明整個部署能連續執行。
- Tidey GUI 重新 attach 既有 iTermServer 時，不會呼叫 `serverPathCopyingIfNeeded`；support binary 的複製發生在 `launchNewDaemonWithState`。初次 GUI 替換與 checkpointed daemon restart 必須使用各自的 hash／PID 預期，不能在舊 daemon 保留階段就要求新 support hash。
- 長時間部署的 process 身分不可只用 PID。這次 baseline 的 Claude／暫時 sleep PID 被新 process 重用，造成 retirement 誤擋；只有出生時間嚴格晚於 inventory 完成後的 checkpoint `captured_at` 才可排除。同秒、更早、無法解析或查詢失敗仍阻擋；不可依名稱不同就殺掉重用 PID 的 process。
- archive wrapper 的 FD 255 會跟著被移動的 inode；先精確結束舊 writer 並證明子樹消失，最後要求所有 retained archive 的 argv、cwd、executable、mapped／open-file holder 為零。過渡中的預期 wrapper 與 pending dialog 的 tccd 必須分開記錄；不能先 unregister 就宣稱修好，也不能用 TCC probe／reset 排除問題。失效 socket 要先確認原 inode、server 與 shell 已消失、socket 無 server 回應，才移除該精確節點。
- matching DONE 只代表某個協作工作結束。部署驗收仍需由 controller 獨立重查實際 listener／服務 PID、workspace／panel／durable 一對一、SavedState、archive holder 與完整 LaunchServices dump，並保留 checkpoint。跨版本新增的 API 欄位（例如 pinned）需對照原本的持久化資料，不可把舊版未輸出欄位誤認為使用者狀態改變。

## 審閱 marker

**Last reviewed**: `4842b41e1` · 2026-04-25

**下次審閱要做的事**：
1. `git log 4842b41e1..HEAD` 列出所有新 commits
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
- 跨 process / tmux / launchd 問題第二輪還沒收斂就先加 runtime log
  - workspace ghost 和 tmux cleanup 這次都先盲修了不只一輪，直到補 `/tmp/tidey-bridge-codex.log` 和 `[TideyTmuxCleanup]` 才看到真正斷點
  - 先記 command、PATH、socket path、workspace/panel id、exit status、stderr，再決定要改哪條流程
- hot path debug log 不能靠換 macro 當 production 降噪
  - 2026-08 native restoration 實機驗證中，Deployment build 的 `DLog` 與 `NSLog` 都進了 macOS unified log；把三個 `NSLog` 改成 `DLog` 後，啟動仍產生約 19,000 筆 `ensure_workspaces` 記錄
  - workspace／panel summary、layout、render 與 polling 這類高頻路徑，debug 完成後要直接移除 log，或做明確 opt-in gate／rate limit；不能假設 build configuration 會替你消音
  - 驗收要以實際 production app 的 log 數量、CPU sample 與啟動後穩態為準，不能只看 source macro 或測試 build
  - 短期跨 process 診斷仍可優先寫 `/tmp/`，例如用 `fopen("/tmp/tidey-xxx.log", "a")` + `fprintf`；結案時一樣要移除或關閉

## UI / Layout

- terminal window 的 table cell 要沿用 frame-based layout
  - `NSTableView` 可能先向 delegate 取 zero-size cell，再套用 60／82pt 的實際 row frame；只在 configure 階段算一次 subview frame，cell reuse 或高度切換後會留在舊位置
  - 在 cell subclass 的 `-layout` 依最新 bounds 重算位置；不要為了固定右上角，把 `NSLayoutConstraint` 引進 terminal window
- 不要直接切 `layoutSubviewsWithVisibleTabBarForWindow:` / `layoutSubviewsWithHiddenTabBarForWindow:`
  - 這會連 tab bar、status bar、division view 一起動
- `PSMTabBarControl` 會在 layout 後重設 overflow button
  - `>>` 是 PSM overflow button，不是 Tidey toggle
- paper tab 與 workspace separator 的銜接取決於目前選中的 tab
  - 第一個 tab 被選取時，左側 focus outline 才能延續到 workspace separator；選中後續 tab 時，workspace separator 要恢復普通分隔線，該 tab 的左右垂直邊則各自漸層接回 tab strip baseline
  - tab selection callback 要在 PSM cell state 更新後重新計算 join 狀態；render regression 必須同時覆蓋第一個與後續 tab 被選取的畫面
  - 共用 `TideyPaperTabPolicy` 不代表兩個 host 都已接上 renderer；terminal PSM 與 editor custom tab 必須各自把 selected tab 的 leading／trailing leg 交給 overlay，host regression 要釘住 overlay frame 與首位 tab 的例外
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

- 新的 `WKWebView` owner 不會繼承舊 Browser manager 的 delegate 行為
  - `TideyBrowserEngine` 與 `iTermBrowserManager` 即使用同一種 `WKWebView`，各自仍是獨立的 `WKNavigationDelegate`；只接 `didCommit`，不代表 attachment／ZIP response 會自動進既有下載流程
  - 症狀是 automation `click`／`navigate` 都回成功、頁面仍停在原處，但 Downloads 沒有檔案；這只證明操作已送進 WebKit，沒有證明 response 已被任何 download owner 接手
  - 新增 browser engine 時要逐項 audit navigation action policy、navigation response policy、兩種 `didBecome WKDownload` callback、下載物件 retention 與完成後 quarantine；response 判斷要抽成新舊 engine 共用 policy，避免兩邊 MIME 清單 drift
  - 補證：Blender Studio `wing_it-caches.zip` 實機驗收（2026-08-21）
- `diskutil info` 的查詢目標必須是 volume／device，不是 archive 子目錄
  - 外接碟本身可讀寫、UUID 也正確時，若 scoped transfer 仍在第一個 byte 前回 `destination unsafe or unavailable`，先檢查是否把 nested archive root 直接交給 `diskutil info -plist`
  - 用 `URLResourceKey.volumeURLKey` 先解析 containing volume，再把該 volume URL 交給 disk inspector；archive root realpath 與 root-relative destination 的驗證仍保留原路徑
  - regression 要直接斷言 disk inspector 收到 containing volume，live acceptance 另用真正的 nested external archive root 驗第一個 byte，不能只在 volume root 或 internal temp directory 測
  - 補證：`6aeb88552` `75886d266` 與 Blender Studio `wing_it-caches.zip` external first-byte probe（2026-08-21）
- 跨 socket session 的下載交接要由 Tidey 以實體目的地做 linearization
  - 舊 connection 的 close callback 和新 connection 的 start callback 都可能非同步排進 main queue；只在 `cleanupSession` pause 舊 transfer、或讓新 owner 查自己的 status，不能阻止新 callback 先打開同一個 partial file
  - manager 要在目的地完成 root／volume／symlink 驗證並打開後，回到 MainActor 以 validated canonical destination 原子 recheck lease；舊 handle 還沒 synchronize＋close、或 quiescence 失敗時，新 handle 只能關閉且不得啟動 payload
  - lease key 不能只用 `destination_relative_path`，否則不同 archive root／volume 上的同名 partial 會互相阻塞；相反地，同一 canonical file 換 owner 或 callback 反序都必須共用同一個 fence
  - regression 要走 manager 的真 `cleanupSession`，並覆蓋 replacement-before-cleanup、close failure、不同目的地併行，以及 conflict handle 零寫入；直接對 transfer 呼叫第二次 `pause()` 不能證明 socket handoff
  - 補證：`1c76dbe0e`
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
- 需要跨切換保留的 state，要綁在 item，不要綁在共享 container
  - 只要一切換就要 detach / reattach 的 view，如果 state 掛在 pane 這種共享容器，切 item 時就會被迫 reload 或重建
  - browser tab 之前把 `WKWebView` 綁在 pane，共用一個 webview；切 tab 直接 `loadURL`，scroll position、form state、SPA state 全丟
  - 解法不是補 cache，而是把 browser engine 綁回 tab；pane 只 attach 目前選中的 webview
  - 補證：`89a44bb5f` `604c9eac2`
- 動態重排之後，不要再用位置或 subview 順序當 lookup
  - 只要 view hierarchy 會因 reattach / insert / reorder 改變，`subviews.firstObject` 這類 positional lookup 遲早會指錯
  - browser panel 這次把 webview 改成可重 attach 之後，toolbar 不再穩定是 `browserContainerView.subviews.firstObject`，網址列整段直接消失
  - 解法是顯式持有 reference，例如 `pane.browserToolbarView`
  - 補證：`007585964`

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

- Tidey App Icon 的 authority 是 SVG，不要從 repo 裡的舊 PNG 或 Icon Composer bundle 猜目前圖示
  - 唯一來源是 `images/AppIcon/TideyAppIcon.svg`；執行 `tools/generate-app-icon.sh` 產生 `AppIcon.png`、完整 `AppIcon.iconset`、`AppIcon.icns`、Nightly 相容資產、文件首頁圖示與選單列圖示
  - 主 app 實際由 `plists/iTerm2.plist` 的 `CFBundleIconFile = AppIcon.icns` 指向 `images/AppIcon.icns`；`iTerm2 App Icon for Beta/Release.icon` 是上游 build configuration 資產，不能拿來判斷 Tidey 目前 logo
  - 驗收要跑 `tools/build.sh Development`，再以 `cmp`／雜湊確認 build product 的 `Contents/Resources/AppIcon.icns` 與 source output 相同；只看 Xcode build setting 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 會被未進 Resources phase 的舊 `.icon` reference 誤導
- **Selection Color 的 alpha 被渲染層覆寫為 1.0**
  - profile `Selection Color` 的 alpha 完全不生效
  - AppKit 路徑：`iTermTextDrawingHelper.m:755` 用 `[color colorWithAlphaComponent:alpha]` 覆寫，`alpha` 來自 `_transparencyAlpha` 或硬寫 1.0
  - Metal 路徑：`iTermMetalPerFrameState.m:1822` 用 `color.w = alpha` 覆寫，同樣來自 `_transparencyAlpha`
  - 所以改 selection color 只能改 RGB，alpha 無效
  - 要讓 selection 半透明需要改渲染管線，讓 selected path 保留 color 自身的 alpha
- 非 live resize 不要切回 legacy renderer
  - sidebar toggle / panel switch flicker 很常是多切了一次 fallback renderer
- Remote terminal 顏色的 authority 在 native grid，不在手機 palette
  - `screen_char_t` 的 foreground/background、bold、faint 等屬性若先被 `get_recent_output` 壓成 `NSString`，client 端換 xterm palette 也不可能重建已丟失的 SGR
  - 保留既有純文字欄位供舊 client 使用，彩色畫面另以版本化、完整 active-grid capture 傳送；只要欄位缺漏、row/cursor geometry 不符或 plain output 被 line/char limit 裁切，就整組省略並 fail closed 回純文字
  - producer 應重用 terminal 自己的 SGR projector，不另寫顏色對照表；client theme 只決定 default foreground/background，明確 ANSI 色碼仍由 capture 決定
- Remote snapshot 必須讀取本機 renderer 當下實際呈現的 terminal frame
  - synchronized output 啟用時，terminal 會把尚未完成的 backing grid 藏在 temporary double buffer 後面；若 Remote 直接讀 `currentGrid`，會把本機從未顯示的半成品 picker 與 tmux status row 傳到手機
  - snapshot producer 在同步更新期間要投影 saved visible grid 與對應 cursor visibility，frame boundary 結束後才改讀 current grid；不能讓輪詢路徑繞過 renderer 的防閃爍邊界
- `MTKView.paused` 不會阻止外部明確送進來的 CALayer invalidation
  - `paused` 只控制 MTKView 自己的 draw loop；`setNeedsDisplay:YES` 仍會把 Metal view 與 scroll view 標成需要重畫，所以縮小視窗後仍可能持續消耗 CPU
  - 高頻 `requestRedraw` 在視窗縮小期間要保留 screen model 與 legacy-view 更新，只把 Metal／scroll-view invalidation 合併成 session-view 自己的一個 pending bit；視窗恢復可見後補畫一次
  - window lifecycle notification 若以 `object:nil` 全域訂閱，handler 必須先用 notification object 與 owning window controller 的 pointer identity 過濾；flush 時還要重查 `isMiniaturized`，確認可見後才能清掉 pending state
  - `iTermMTKView` 另有每 0.5 秒執行一次的 keep-warm timer，會直接設定自己的 `needsDisplay`，不經過 `SessionView.requestRedraw`；它的可見性判斷也必須排除 miniaturized window
  - keep-warm tick 不代表內容變更，不需要 pending bit 或恢復時補畫；視窗恢復後讓下一次 timer tick 自然重新啟用即可
- `it_imageWithTintColor:` 會把多層 SF Symbol 壓成單色
  - 要保層次用 hierarchical symbol configuration

## Shell Integration / tmux

- tmux paste 指令成功，不代表 TUI 已經處理並顯示貼上的文字
  - 固定等待一段時間再送 Enter，仍可能讓 Enter 落到剛開啟的 picker，直接修改使用者設定
  - slash command 的 Enter 必須等同一個精確 pane 的 active screen 游標列顯示完整 command；舊 scrollback 裡的相同文字不能算
  - 在期限內沒有取得游標列證據時，保留已輸入的 command 並停止，不送 Enter
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
- tmux server 的 responsible app 跟著第一次 spawn 它的 parent process，不會被後續 env cleanup 改寫
  - `__CFBundleIdentifier` cleanup 只能防止舊 terminal 身分繼續污染新 session，不能把已經活著的 tmux server 從 `cmux` 改回 Tidey
  - 真正驗證要先 `tmux kill-server`，再讓 Tidey 重開新的 server；這時 TCC attribution 才會回到 Tidey
  - 補證：`b97fadf61` `e75c1b6c3` `394a293d1`
- TCC prompt 顯示的 responsible app 名稱不能只靠整理 LaunchServices 修正
  - accessing process、responsible audit token 與 LaunchServices 顯示名稱是不同層：長存 tmux server 會把第一次建立時的 responsible process ancestry 傳給後續 Claude／Codex；LaunchServices 再用已註冊的相同 bundle identifier 選擇顯示路徑與名稱
  - unregister 舊 bundle 或清掉 `__CFBundleIdentifier` 不會改寫已存活程序的 audit token；要先讓 production Tidey 建立隔離 tmux server，再以 durable resume ID 搬移 agent，最後才終止舊 server
  - deployment backup 在移動前必須先 unregister，並保存成名稱不含 `.app` 的 `.bundle-archive`；只把已註冊 bundle 改副檔名，LaunchServices database 仍可能保留舊路徑
  - production 替換固定使用 `tools/archive_production_app.sh`，不得再建立 `Tidey.app-*` 或另一個 `.app` 備份
  - 補證：2026-08-21 Claude Code PID 67356 的 TCC log、舊 tmux server PID 779，以及 app-owned tmux server PID 92364 的實機切換
- prod / dev socket path 要硬分離，不要靠 fallback 猜
  - 同機同時有 Tidey prod / dev 時，如果兩邊共用同一個 socket path，wrapper / hook / sidebar 會誤打到另一個 instance
  - socket naming policy 要在啟動時就決定，不能等 wrapper 檢查失敗再臨時 fallback
  - 補證：`aa75413df`
- 寫進 Tidey Unix socket 成功前的狀態不能視為已交付
  - `TideyStatusStore` 是 App process 內記憶體；Bridge 若比 Tidey 早啟動，bootstrap 算出的 Idle 即使正確，也可能因 socket 尚未出現而整批丟失，之後 direct hook 的 Running 就會長留在 sidebar
  - Bridge 要保存 session lifecycle 的權威狀態，依 workspace／panel／session owner 回報；socket 從 unavailable 變成可用或 device／inode identity 改變時，先清掉 workspace 的 legacy unowned `shell_state` cell，再重播所有 active owners，同一 generation 內則去重，send 失敗不可標成 delivered
  - 實機補證：2026-08-21 Tidey 啟動比 Remote Bridge 晚約 16 秒，Bridge log 的 bootstrap prompt 全部是 `socketUnavailable`，造成多個 Idle workspace 顯示 Running
- Tidey socket listener 的 backlog 壓力會讓正確的狀態重播偶發失敗
  - `TideySocketLocator.resolveLiveSocketPath()` 會先建立一次 probe connection，`TideySocketClient.send` 再建立真正的 command connection；Bridge 在啟動或 registry 重播時同時送出多筆命令，可能填滿 Tidey listener 的 backlog，讓仍正常運作的 socket 回 `ECONNREFUSED` 或被 locator 判成 `socketUnavailable`
  - 共用的 `TideySocketClient` 要序列化完整 transport transaction，並只對 `ECONNREFUSED` 做短暫、有上限的重試；其他 POSIX 錯誤維持立即失敗，sidebar syncer 也必須保留未送達項目供下一輪重播
  - 驗證要同時覆蓋 client 內並行命令、拒絕連線後成功、重試耗盡、非暫時錯誤不重試，以及第一次 sidebar reset 失敗後下一輪收斂
  - 實機補證：2026-08-26 同一個 production socket 的循序 ping 全部成功，但 20 筆同時 direct ping 有 3 筆 `ECONNREFUSED`，20 筆 probe-then-ping 有 10 筆 `ECONNREFUSED`；`備課/共讀` 兩個 panel 的 lifecycle 都是 Idle，sidebar 仍停在 Running
- GUI app 背景 `NSTask` 不會繼承互動 shell 裡的 Homebrew PATH
  - Tidey 從 LaunchServices 啟動時只有 `/usr/bin:/bin:/usr/sbin:/sbin`；`/bin/sh -c "tmux ..."` 這類 cleanup job 直接跑會 `command not found`
  - shell pane 內最後看到的 PATH 常常是 `.zshrc` 補出來的，不能拿來假設 GUI app 的背景 task 也找得到同一支 binary
  - 解法（`a11942fee` `394a293d1`）：先 resolve tmux 絕對路徑，再把完整路徑寫進 cleanup command
- 清 tmux server global env 不要看新 job env 裡有沒有那個 key
  - `__CFBundleIdentifier` 可能已經在 Tidey 的 new-job env 被 scrub 掉，但 tmux server global env 仍然是髒的
  - cleanup command 的目標是 server state，不是反映新 job env；`tmux set-environment -gu __CFBundleIdentifier` 要固定送
  - 解法（`b97fadf61` `20a2d3168`）：helper 固定帶 unset，別再從 input env 推導 keysToUnset
- tmux workspace / panel identity 不要再讀 server global env
  - `tmux show-environment TIDEY_WORKSPACE_ID` 只代表 server/global state，多 pane、多 workspace 並存時很快 stale
  - Tidey 端把 `@tidey_workspace_id`、`@tidey_panel_id` 寫到 pane user options，wrapper 再用 `tmux show-options -p -v -t "$TMUX_PANE"` 讀
  - 補證：`3c0e4f4ad` `d5478d5a4` `4e796c19f`
- 從 tmux pane 啟動 GUI 時，LaunchServices 會把 pane identity 帶進 GUI 與後續 native terminal
  - 症狀：native Codex 的 controlling TTY 和 `tmux display-message -t "$TMUX_PANE" '#{pane_tty}'` 不同，但 registry 仍宣稱屬於該 tmux pane；Remote submit 隨後被較新的錯誤 app-server record 攔走
  - wrapper 在讀 pane option 前必須比對兩個 TTY；明確不相符時清除 `TMUX`／`TMUX_PANE`，保留 native panel 原有的 `TIDEY_WORKSPACE_ID`／`TIDEY_PANEL_ID`
  - Bridge 還要以 fresh workspace graph 與唯一 process ancestry 校正 Codex app-server，不能因 stale pane 剛好吻合 cache 就略過
  - production 替換後一律用 `tools/open-production-clean-env.sh` 啟動 GUI
- 共享長壽 service 繼承到的 early env，會污染所有後續 client
  - 只要 service 生命週期比 client 長，而且會保存 global env，第一個 client 帶進去的值就可能污染後面所有 attach / new session
  - 這次是從 prod shell 開 `tmux new -s tidey-cc`，prod 的 `TIDEY_*` 被繼承進 tmux server global env；之後 Dev shell attach 到同一個 default socket，wrapper fallback 讀到的還是 prod UUID / socket path
  - 症狀是：Dev 的 Claude hook 送 prod `workspace_id`，sidebar 永遠 no-match，紅點 / status 一起失效
  - 先驗：`tmux show-environment -g | grep TIDEY_`
  - 臨時解：`tmux set-environment -gu TIDEY_WORKSPACE_ID TIDEY_PANEL_ID TIDEY_SOCKET_PATH TIDEY_BIN_DIR`
  - 長期解：不要把 tmux server global env 當 identity source；pane option 才是 Tidey 自己寫入、可相信的來源
- zsh 會 cache command 的絕對路徑
  - Tidey shell integration 把 `TIDEY_BIN_DIR` prepend 到 PATH，但長 live 的 shell 已經把 `codex` / `claude` hash 成舊路徑
  - 新裝 Tidey 後沒有新開 shell 就測不到新 wrapper
  - 解法（`6f1b3459e`）：shell integration 裡 PATH 注入後跑 `rehash 2>/dev/null || true`，強制失效 command hash
- CODEX_HOME overlay 小心 nesting
  - wrapper 用 `CODEX_HOME` 覆蓋到 `/tmp/tidey-codex-home.XXX` 並塞 hooks.json + config.toml
  - 如果 wrapper 被 exec 兩次（例如使用者在 codex TUI 裡再開 codex），第二次的 real-home 會指向第一次的 overlay，產生 overlay-of-overlay
  - 解法（`cb0d4bb8e`）：`resolve_real_codex_home` 偵測 `tidey-codex-home.*` pattern，找回原始 `~/.codex`
- Codex app-server 必須自己取得 Tidey Browser MCP 設定
  - `codex mcp list` 經 wrapper 的 plain CLI 路徑顯示 `tidey_browser` enabled，不代表互動 session 的 app-server 已載入同一份 profile
  - `codex --profile <name> app-server` 會被真實 CLI 拒絕，因為 named profile 只適用於 runtime commands；app-server 必須用自己的 `-c mcp_servers...` 參數取得同一份 Tidey MCP 設定
  - `--remote` TUI 仍是 runtime command，要帶 session-scoped profile 取得剛產生的 hook trust；app-server 則不能帶 profile，只能在自己的 argv 取得 MCP overrides
  - Codex CLI 的 `-c` dotted path 不支援 quoted key segment；`hooks.state."<dynamic-key>".trusted_hash=...` 會被接受卻寫到錯誤節點。動態 hook keys 必須包成單一 `hooks.state={...}` TOML inline table value
  - wrapper regression test 要讓 fake CLI 同樣拒絕 app-server profile，並分別檢查 app-server 的完整 MCP overrides 與 remote TUI 的 profile
  - argv 仍只是中間證據，驗收必須由全新 Codex session 實際看到並呼叫 `tidey_browser` tools

## Socket / Notification / Agent Integration

- 本機圖片預覽要用 WebSocket frame 大小設計，不能只看原始檔大小
  - PNG decode / re-encode 後可能比 source 更大，base64 還會再膨脹約三分之一；1672×941、約 2.3 MB 的一般 PNG 曾產生約 3.3 MB 的單一 JSON frame，在高延遲連線上反覆撞到 iOS 20 秒 timeout
  - Bridge 應限制 encoded preview bytes，無 alpha 的高熵 PNG 可改送 JPEG；有 alpha 的 PNG 必須縮小後維持 PNG，不能為了省流量丟掉透明度
  - expensive decode 與透過 Tidey Unix socket 執行的 panel-root lookup 都必須放進同一個 bounded admission；只讓 decode 排隊，短時間連點仍會在前置 root lookup 互撞並回 `socket_unavailable`
  - bounded admission 應維持單一 in-flight，並提供有上限、有 timeout 的小型等待佇列；立即回 `resource_busy` 會讓正常的多圖點擊互相失敗
  - conditional read 必須在 admission 內、source size policy 之後、bounded content read 與 decode 之前判斷；revision identity 不能只有 mtime＋size，同尺寸且保留 mtime 的檔案替換還要靠 device／inode／ctime 分辨
  - 補證：`c581edf6d` `1af812ce2` `6af69e35e` `ac1cfe7cb` `0dea40ece` `547d91ded` `4e6f99fa7`
- `workspace_id` 缺失的 state update 要 fail closed
  - `report_shell_state` / `set_status` 不能默默落到 broadcast
- ordinary tmux 的對外 panel ID 不一定有 `ordinary-tmux:` prefix
  - 單一 window carrier 會保留穩定的 `native-session:` panel ID，同時以 `logical_kind = ordinary_tmux_window` 啟用 tmux stream 與 history；字串 prefix 只描述可重建的 logical ID，不能取代 registry authorization
  - Bridge handler 要把 `(workspace_id, panel_id)` 交給共用 route resolver 做精確授權，並核對 resolver 回傳的 workspace／panel 身分；未知 native ID 與錯誤 workspace 必須回 `not_found`
  - regression 必須用實際 `native-session:` outward ID 走過 projector → registry → resolver → handler，不能只用測試方便的 `ordinary-tmux:` fixture
- broadcast notification 的 unread state 不能用單一共享 bit
  - read/unread 要按 workspace 分開算
- stream / subscription protocol 要有 completion signal
  - `subscribe_agent_events` 如果只回放 replay event、但不告訴 client replay 何時結束，client 只能寫死 timeout 猜「應該送完了」
  - 這種 timeout 很快會變成產品體感延遲的最大頭，甚至比實際 RTT 還大
  - 解法是在 protocol 裡明確帶 completion 訊號，例如 `replay_count` 或 `replay_end`，不要把「何時可以 reveal UI」交給 client 猜
- tmux PTY stream 的 logical subscription 與 physical `pipe-pane` 必須分開建模
  - WebSocket request receipt、每個 panel 的實體 pipe 置換、每條 connection 的訂閱表是三個不同 linearization boundary；只在 handler dictionary 加 lock，無法防止跨 connection 的晚到 subscribe 復活舊 owner
  - Bridge-wide receipt sequence 先建立全域順序，per-panel serial lane 負責 invalidate→stop→build，event-loop-local state 再以 exact token commit connection ownership；三層都要保留原始 request identity
  - delta 要在昂貴 cursor query／enqueue 前與 event-loop write 前各檢查 delivery gate；只檢查一次，invalidate 後已排隊的 chunk 仍會漏到新 owner
- logical admission 必須在 physical lane teardown 之前完成三階段交接
  - event-loop 的 owner state 測試全綠，仍可能掩蓋 lane 已經先停掉有效 B、之後才拒絕 A 的 phantom owner；每條 WebSocket connection 要先以同一把 lock `reserve`，lane 在任何 invalidate／stop／build 前原子 `claim`，event loop 安裝前再 `finalize`
  - lane 即使 claim 失敗也要先墊高自己的 sequence high-water，阻止更舊的跨 connection physical work 復活；reserve 失敗則完全不能進 lane
  - cleanup 只能取消 sequence 比自己舊的 exact reservation，不能清空整張 pending 表或只看 coarse watermark；identified subscription ID 是 connection-global、永久 one-shot authority，附帶的 panel 只能是相容性 hint
  - cleanup 發生在 claim 前時必須是零 physical side effect；claim 後才 cleanup 則 physical replacement 已合法 linearize，只 veto 最後 install 並清掉 candidate，不嘗試復活已停止的舊 pipe
- best-effort unsubscribe 仍要保留可重試的實體 teardown ownership
  - `tmux pipe-pane` stop 失敗時可以讓 unsubscribe 對 client 完成，但 lane 不能把 active lease 清掉；否則下一次 `pipe-pane -o` 可能成功返回卻沿用 orphan pipe，形成「subscribe 成功但永遠沒有 delta」
  - stop outcome 要穿過 subscription／lease boundary；失敗的 invalidated lease 留在 lane，後續 subscribe 必須先重試 `stopForReplacement()`，重試成功前禁止 build 新 tailer
- session identity 不能沿用舊 panel / workspace UUID，整條鏈都要改寫成 tmux-resolved current binding
  - tmux pane matching 只能解出「現在這個 pane 對應哪個 current workspace / panel」，之後 replay / fetch / apply / buffered migrate 都要跟著改寫
  - 只在入口做一次 old→new 映射不夠，任何還拿舊 UUID 讀 panel summary、抓 transcript、套 event 的路徑都會繼續錯綁
  - 這類 bug 常在 Tidey 重啟、pane close / reopen、workspace reload 後才出現，因為舊 ID 還在 event / buffer / registry 裡殘留
  - 補證：`b3d624e3f` `362c04ba2` `3756f4601` `b3d43c1ea` `f48295708` `d941cddf5` `dff5b16ed` `27a62089f` `9ed5ae92c` `552f40a42` `070796160` `85f255bfb` `8e26ad3e6`
- wrapper 擁有的 session registry 不能由 Bridge 把舊快照寫回
  - Bridge 讀檔後解析 tmux identity 的同時，wrapper 可能已把 runtime 從 `codex_app_server_starting` 推進成 `codex_app_server`，或在 agent 結束時刪除 registry；此時回寫先前 decode 的 record 會降級新狀態，甚至把已刪檔案復活
  - pane / workspace identity correction 應只套用到 Bridge 的 in-memory active record 與 runtime sync，不得跨 process 改寫 wrapper-owned lifecycle file
  - race 測試要同時覆蓋「讀取後檔案被更新」與「讀取後檔案被刪除」；只測最後 mapping 正確，抓不到 stale overwrite
  - ordinary-tmux carrier 的 raw `effective_shell_pid` 是外層 `tmux attach` client，不是 pane shell；要先走共享 projector 取得 inner pane PID / pane ID / socket，再做唯一 process-ancestry 配對，不能直接比較兩棵互不相干的 process tree
- 同一個 identity 如果分散在不同生命週期的 storage，遲早會 drift
  - UI model、restore snapshot、shell env 只要不是同一個 source of truth，就不能假設它們會自己同步
  - 這次是 `Workspace.identifier` 每次 relaunch 都新生，但 `SESSION_ARRANGEMENT_ENVIRONMENT` 會把舊 shell env 原封 restore 回來；結果 sidebar 查新 UUID，hook 送舊 UUID，notification/status 永遠 no-match
  - 看到「store 裡明明有寫進去，但 UI 永遠查不到」時，先檢查是不是兩邊拿的其實不是同一個 identity
  - 解法（Fix A）是把 workspace UUID 持久化到 tab arrangement，workspace 重建時 reuse；舊 arrangement 沒欄位時才 fallback 新生
  - 補證：`7a8c479f4` `17b5c94a3` `4842b41e1`
- 大 transcript / reconnect 不是單點修補，要一起做 paging、bootstrap limit、catch-up 和 no-replay aware parsing
  - transcript 一大，initial load、resume、reconnect 會同時撞到 bootstrap 成本、重播延遲、catch-up 遺漏與 UI reveal 時機
  - 只加 bootstrap line limit 會留下 reconnect 落後；只補 catch-up 又會被 replay / no-replay 混合路徑打回來
  - 這題要當成一條完整資料流處理：paged history fetch、bootstrap 上限、reconnect catch-up、stream completion / replay_count、以及不重播時的 parser 邏輯一起收
  - 補證：`208595cae` `c48599a47` `f14a0959e` `aea886f8f` `7627e99bf`
- transcript 的 raw byte 進度不等於 client 看得見的 event coverage
  - 一條 JSONL record 可能產生零個、多個或只產生 silent consumer event；只看「讀過幾行」或 Hub oldest seq，eventless 區段會讓分頁提早停、同一行的 ordinal 會漏掉
  - source cursor 要保存精確 `(lineOffset, ordinal)`，raw scan frontier 與已完成索引 frontier要分開；`before_seq` 的 anchor line也必須能重讀，包括 byte offset 0
  - `has_more` / BOF 只能由該次 source-owned raw frontier 決定，不能由 Hub 目前裝得下多少 visible event 猜；500 筆 raw record 只產出 86 筆 visible event 時，`visibleCount < limit` 完全不代表已到檔案開頭
  - blank-only byte range 即使 `didRead == false` 仍是有效 raw progress；要沿 `minimumRawOffset` 在同一個 request 內繼續，不能回 `has_more=true` 配原 cursor，否則 client 永遠重送同一頁
  - synthetic `session_started(seq: 0)` 不是 raw cursor：非終頁必須排除它並保證 `0 < oldest_seq < requested_before_seq`，只有 source-proven BOF 頁才可讓 seq 0 成為 bound
  - missing/invalid/stalled raw authority 要回明確 unavailable，不能沿用 visible cache 回 `has_more=false`；即使 cursor 在 offset 0，也要先 source fence，避免同路徑 replacement 的舊 cursor誤報 BOF
  - raw frontier 本身仍不夠：replay 必須保持 semantic trust、完成 post-replay source fence，且 `.more` / `.end` 要綁定產生它的 Hub epoch；flow refetch 前後 epoch 都一致，才可對 client 宣告 continuation / BOF
  - source reset 對 Hub 可見的資料撤銷與 epoch 前進必須共用一個 atomic linearization point；先清 history、下一次 call 才 bump epoch，會讓並行 fetch 接受「舊 epoch＋空 history」並誤報 BOF
  - positive seq 若不在 exact raw map，仍可作保守的 virtual cursor：必須保留 `(lineOffset, ordinal)` 並重讀 anchor line，再以 public seq 投影；只有 exact raw `(0, 0)` 能直接證明 BOF，否則 offset-zero synthetic 會讓第一筆 raw 靜默消失
  - paging 測試要像正式 client 一樣只用 wire `oldest_seq` / `has_more` 前進與停止，不能從 payload 自己找最小正 seq，否則會把錯誤 bounds 藏掉
  - 相鄰 producer twin 的 identity 不能隨 raw 分頁邊界改變：若 legacy before replay 從 `response_item` 半邊開始，第一頁先發布 response identity、下一頁才改成 predecessor `event_msg` identity，即使 shared cache 已 reconcile，client 累積的兩頁仍會留下重複
  - 每次 replay rolling window 前可往前讀一筆 pure-evidence context，再從 owned window 開始產生 products；context 不得進入 bounded window、不得發布、不得影響 semantic trust 或該頁的 continuation / BOF authority。owned page 已證明 BOF 時不能再讀不存在的 predecessor
  - context read 遇到 source replacement 要撤銷舊 epoch 並重新附著；一般 I/O 失敗則保留 epoch、回 unavailable 讓同一游標重試。malformed / invalid UTF-8 context 只代表沒有配對證據，等它進入 owned page 才能使整頁 fail closed
  - 補證：`8bc228295` `43c8266a6` `2ec452f29` `2bc9efc28` `70c0bf01c` `2a6683494` `a4c4c2abd` `ea21da0ff` `4e793551f` `619064a43` `50ba1c32b` `128a54451` `da9863369` `c7b78c5c7` `f1d04fab4` `3e4469dd5` `487be0d9c` `08fab6ccf` `d4c9640c3` `fd32d6be5` `900423313` `92394009f` `d50249d2f`
- 跨頁關聯事件要用 source-wide closure evidence，再做 anchor-owned atomic projection
  - Ask opener / terminal與 `/context` command / summary可能隔很多頁；單頁內配對會把已結束的舊 opener誤顯示成待輸入
  - 先增量建立全 source closure index，再一次替換該 anchor擁有的 historical window；最後套完 workspace排序、limit與byte budget後，還要重驗 terminal仍在實際 slice，否則 fail closed隱藏 opener
  - live tailer與history index可能反序看到同一 suffix，closure identity與 lifecycle blocker都要用每次 lifecycle的 exact token，不能只用可重複的 tool ID
  - 補證：`5d2e53eb5` `637c3e634` `2ff375d71` `8022a3352` `1886326ae`
- append-only history index仍要把 source mutation與不完整輸入當正式狀態
  - 固定 EOF snapshot後只掃 append suffix；每輪驗 inode / path / boundary，保留跨 append partial UTF-8，但 partial要有硬上限
  - scanned frontier與indexed frontier不可混用：只有完整 newline record才可推進 indexed frontier；invalid UTF-8、malformed JSON、超限 partial或source identity改變都要撤回舊頁並把 closure coverage標成 unknown
  - unknown不是「目前沒看到 terminal」；若繼續顯示已cache opener就是 fail open
  - 補證：`0d48cfc65` `b8bc20c19` `6ec7dffa4` `f19628650` `5487592c4` `d25a8908b`
- `security` / `codesign` / `notarytool` 的 keychain 狀態不要用 sandbox 內結果下結論
  - 這條特別是 Codex 這邊的 agent sandbox 問題；同一台機器的互動 shell 與 Claude Code session 不一定會重現
  - 這類命令在 Codex agent sandbox 裡可能出現假陰性：`security find-identity` 回 `0 valid identities found`、`codesign` 回參數錯、`notarytool` 回 keychain access error，但同一台機器的互動 shell 實際是正常的
  - release / notarization 調查時，先用 unsandboxed interactive shell 驗證 signing identity、notary profile、Apple agreement 狀態，再決定是 cert / private key / profile / 法務同意書哪一層出問題
  - 補證：2026-04-18 release 調查最後在沙盒外確認 `Developer ID Application` identity 正常，真正阻塞是 Apple Developer `403 required agreement is missing or has expired`
- Claude hook 不要靠 terminal output 猜狀態
  - 用明確事件：`session-start`、`prompt-submit`、`notification`、`stop`、`session-end`
- pipeline debug 先在 seam 插 mock，把 producer / consumer 兩半切開
  - 一條鏈太長時，不要一開始就往 app 內加 log；先找最窄的 seam，換成可控制的假端點，先判斷問題在寫出端還是接收端
  - 這次把 `TIDEY_SOCKET_PATH` 暫時指到 `/tmp/tidey-hook-probe.sock`，起一個最小的 Unix socket listener，就能直接看到 wrapper / hook / CLI 寫出的完整事件序列和 `workspace_id`
  - 先驗 fake socket（Claude → wrapper → CLI → socket write），再驗真 socket（Tidey app → store → sidebar），比直接在 Tidey binary 裡亂塞 probe 快很多
  - 這個方法在 hook、socket、notification、IPC 都適用，不只 Tidey
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
- Bridge 重啟會重新驗證 Codex bootstrap，新的合法 lifecycle record 可能只在此時讓舊訊息分頁失效
  - 症狀是最近訊息仍持續出現，但往前載入回 `agent_history_unavailable`；先驗證 registry 指向的 rollout 還在、每行 JSON 都合法，再統計 bootstrap 內未支援的 top-level／payload type，不要先判定訊息檔損毀
  - Codex 0.147 的 `event_msg.item_completed` 是 `response_item` 旁的 lifecycle wrapper；由後者繼續當聊天內容權威，前者列為精確的 known-ignored event，避免同一則訊息發布兩次
  - 只能加入已由真實 rollout 證明為合法且 eventless 的精確 type；任意未知 type 仍須撤銷 semantic trust，避免把不完整解析誤報成完整歷史
- Bridge 改 code 要重 build、重 deploy、重啟 launchd
  - `tools/build.sh` 只 build Tidey Mac app，不動 Bridge
  - Bridge 獨立：`RemoteBridge/tools/deploy-bridge.sh` 會 build release binary + install + sign + `launchctl kickstart`
  - Tidey prod 的 wrapper 路徑 `/Applications/Tidey.app/Contents/Resources/bin/codex` 是手動 cp，build.sh 也不會自動同步
- 新增 `Resources/bin/*` script 時，要同步加進 Xcode CopyFiles phase
  - 只把檔案加進 repo 不夠，app bundle 沒有這支 script，wrapper 在 bundle 內 `source` / exec 會直接 `No such file or directory`
  - 這次漏掉 `tidey-tmux-pane-identity`、`codex-hook-dispatch`，build 照樣過，runtime 才炸
  - 解法（`4e796c19f` `d7bd6c1bb`）：新 script 一律和 `claude` / `codex` 一起檢查 CopyFiles phase 和 bundle 實體檔
- wrapper function 定義了就要接到 main flow，特別是 registry / monitor 這類生命週期函式
  - `Resources/bin/codex` 的 `monitor_rollout_and_registry()` 有定義、沒 call site 時，registry `rollout_path` 會永遠是空字串
  - 後果不是立刻 crash，而是 Bridge 退回 `lsof` race 找 rollout 檔，任務太快就永遠抓不到 `task_complete`
  - 解法（`ea33c8671` `c23502f26`）：在初始 registry 寫完後、`exec "$REAL_CODEX"` 前明確啟動 monitor
- 單一 launchd Bridge 搭配全域 socket locator，prod/dev 同開時一定會搶錯 instance
  - `TideySocketLocator.resolveLiveSocketPath()` 先找 `tidey.sock` 再找 `tidey-dev.sock`，只要 prod 活著，Codex Bridge 就會把 sidebar / notification 更新送到 prod
  - 症狀：Bridge log 顯示 `notification.create` 正常送出，但 Dev 的 sidebar 和 Dock 完全沒反應；關掉 prod 後 Dev 立刻正常
  - 這題現在的 workaround 是測 Codex 時先關 prod；真要根治，session registry 就要帶 per-session socket path

### Codex app-server approval / event stream（2026-07 permission-approval 加固，round 1–6）

- `no rollout` 要撤銷 subscription discovery 的舊 root，但不能連 submit authority 一起清掉
  - `codex resume <id>` 找不到 rollout 時，TUI 仍可能讓使用者從 chooser 選到另一個 thread；wrapper registry 會繼續保留原本的 resume ID
  - Bridge 若每輪 loaded-list 無法對上 registry root 就 fallback 回同一個舊 ID，會每兩秒重送 `thread/resume`，永遠看不到 app-server 已載入的真實 thread
  - app-server 明確回 `no rollout found` 後，把該 registry root 標成「subscription 已拒絕」；下一輪只可採用唯一、非 child、非 paginated 的 loaded root，遇到多個候選仍 fail closed
  - Remote 主動送訊息的 submit lookup 仍保留 registry root，因為同一個 thread 的 rollout 可能只是稍晚出現；subscription 與 submit 必須分開保存這兩種權威狀態
- seq 取號要用 reservation，不能用 peek
  - 「看 buffer 最大值 +1」的 peek 在同一批多個 event 先建立、後發布時會全部拿到同一個 seq
  - 取號當下就要墊高 high-water（reservation），批次 terminal、close 一次收多個 prompt 都靠這個
- 每個 session 只能有一個 seq authority，且 unique 不等於 cursor monotonic
  - synthetic reservation 與 native producer（transcript session）各自宣稱 seq，遲早撞號；`after_seq` cursor 會永久漏掉其中一筆
  - 只防「相同 seq」不夠：晚到的 unseen 較小 seq（先發 100 再來 50）對已推進到 100 的 cursor 一樣永久不可見；批次 reservation 反序 publish 同理
  - hub `publish` 以 stored high-water 為準：unseen event 的 seq 不高於 high-water 就 rebase 到 `max(highWater, reservation)+1`（保留 eventID identity）；high-water 不隨 buffer trim 消失，eviction 不會復活舊 cursor
  - monotonic 規則只適用 live/forward publish：transcript 的 historical backfill（載入比現存更舊的頁）必須用明確命名的 storage policy 保留原始 cursor 位置——照 rebase 會把舊歷史搬到最新 cursor 後面，`before_seq` 取不到、`after_seq` 誤當新 live event。不要拿 `deliverToSubscribers == false` 隱含判斷 backfill，policy 要進 API 契約並 audit 所有 caller
  - lifecycle token 也要進所有下游判斷：reducer 的 suppression key、hub 的 active/latest-resolved query、submit 的 hub fallback 只按 promptID 判斷時，晚到又被 rebase 的舊 terminal 會 suppress 新 delivery、或把舊 terminal 當新 submit 的答案
- snapshot / 補發要重用已發布 event 的 identity，動態欄位用 overlay，bounds 停在 retained page
  - pending snapshot 若配新 seq，就會注入 hub 沒發過的 cursor 位置，跟下一筆真 event 撞
  - 正解：同 eventID + 原 seq + 原 timestamp，只 overlay submit_state / client_request_id 這類動態 metadata；空 page 注入舊 snapshot 時 newest_seq 要 clamp 在 requested after_seq 之上，否則 poll cursor 反覆倒退
- capability token 必須保護 request、completion、terminal、recovery 四個方向
  - 只在 submit request 帶 token 擋不住其餘三路：晚到的舊 attempt completion（error / already_resolved）會蓋掉新 attempt、舊 lifecycle 的 live terminal 會清掉新卡片、recovery snapshot 會把舊 client_request_id 沿用到新 lifecycle
  - completion 要帶 expected clientRequestID 只改 exact attempt；terminal event 要攜帶被終結 delivery 的 token、consumer 只清 token 相符的卡片；recovery 比對 displayed token 與 local attempt token，不同就整個清掉（fresh lifecycle、fresh identity）
- wire 協定的 RequestId 和 UI 生命週期是兩種 identity，各要各的 guard
  - JSON-RPC RequestId 是 wire collision domain：response 已 enqueue/flush 後同 id 換內容 = protocol violation，要 poison 該 id、不再寫任何 bytes、abort transport；poison scope 是單一 connection
  - wire taint 是 connection-level history，不是 attempt state：identical redelivery 可以 re-arm 卡片，但不能把「已有 response 上 wire」的 taint 降回 false，否則之後的 changed request 繞過 violation
  - collision domain 涵蓋所有 server-initiated frame：malformed / unsupported request 的 error response 也要先 claim 同一個 ledger，反向（先寫過 error 再變成 valid approval）同樣算 violation
  - abort 要真的停掉 runtime generation：websocket 關 channel、stdio 要 terminate owned process（transport close 對 stdio 是 no-op 的話 violation 只是形式上的）
  - UI 卡片要另發 server-issued lifecycle capability token（本案用 published event 的 eventID），submit 必須原樣 echo、`beginSubmit` 原子驗證；changed payload 換 token，舊卡片打新 lifecycle 只會拿到 conflict、零 response bytes
  - 只靠 prompt_id + target_index 擋不住「舊卡片批准新內容」——prompt_id 對 changed payload 是同一個
- close() 先 retire store、收 terminal，再跑任何外部 callback
  - 反過來做，一個阻塞的 pending-response handler 就開出「closed connection 還能 admit server request / terminal→pending 復活」的窗口
  - 所有 admission / terminal publication 走同一把 publication lock；測試要用 latch 證明競爭者真的抵達 lock（純 barrier 可能只是循序排程僥倖通過）
- generation 換代要做成 transaction，不是 check-then-act
  - stale session 先移 generation 再 stop() 會把 stop 同步發出的 expired terminal 丟掉：先標 retiring（只放行 terminal cleanup）、stop 完才移除
  - attach 失敗要能回滾：attach 期間 callback 先 staging，成功才按序 commit，失敗 discard——否則 handler 同步 flush 的 event 已洩漏到 hub / sidebar
  - staging 的 commit 本身也有 arrival race：先把 mode 翻成 committed 再 drain，post-commit callback 會直接執行、插到還沒 drain 的 staged work 前面。要用 committing 狀態 + 單一 drain executor：drain 完成前新 callback 一律排隊尾，FIFO 才成立
  - generation 檢查與 side-effect commit 要在同一把 lock 裡重驗；排進 queue 的工作要攜帶 generation，執行當下再驗
  - 整個 sync/attach pass 要在元件內部序列化（不能依賴呼叫端剛好用 serial queue）：兩個 sync 交錯會讓 entry 與 current generation 分裂（entry 是舊代、current 是新代，submit 與 callback 各路由一邊）
  - 換代造成的「entry 空窗」（舊 entry 已移除、新 attach 未 commit）不是 authoritative 的「沒有 runtime」：submit 撞到空窗要等 transition commit（bounded wait，用 DispatchGroup 之類的 signal，不是 sleep 輪詢）再 reconcile
- subscribe 的 replay / live race 要用 eventID 合併
  - 先裝 live subscriber、後取 snapshot 之間發布的 event 會同時進 live buffer 和 replay；gate open 時要 suppress 已 replay 的 eventID，保留 snapshot（帶最新 submit metadata）那份
- flush ≠ 結案：transport 寫出成功只代表 bytes 出去了
  - 結案只能由 authoritative 訊號（serverRequest/resolved、turn completed、expiry）驅動；把 flush 當 resolved 會讓 server 沒收到時 UI 假成功

## Theme System

- `NSTableViewStyleSourceList` 的 selection 顏色無法可靠自訂
  - macOS 15 的真實 Tidey Dev 視窗不會為 Source List 選取列呼叫 `drawSelectionInRect:`，仍由系統畫原生藍色；在 row 上疊自訂 selection view 的實驗也沒有蓋過實際系統層級
  - 需要精確自訂焦點色時，Warm 使用 `NSTableViewStylePlain`＋`NSTableViewSelectionHighlightStyleRegular`，讓 `TideySidebarRowView` 畫選取卡；Classic 保留 Source List
  - Plain／Source List 的切換必須另外凍結 row height、欄位 frame、字級、最小寬度、背景與 close hit area，並以真實 Development 視窗驗收；不能只靠 hosted bitmap 或假設 table style 不影響排版

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

## Native workspace restoration

- MRC mutable collection 取出的舊值若要跨過 collection mutation 使用，必須先取得 ownership
  - `objectForKey:`／subscript 只回傳 borrowed reference；若 dictionary 是該值的唯一 owner，替換同一個 key 會立即 release 舊值，後續 diff、enumeration 或 event publication 都可能讀到已釋放物件
  - 保留「先更新 cache、再發布 event」的 reentrancy 順序時，先 retain 舊值，完成 diff 後再 release；不能靠區域變數延長 MRC lifetime
  - 只用 array literal 直接測 pure diff 會讓呼叫端持續持有舊值，無法覆蓋 ownership transition；regression 要讓 cache 成為唯一 owner，並用 deallocation probe 驗證舊值在 diff 執行時仍存活、helper 回傳後已釋放
  - restoration、key-window 切換與 session-count callback 都可能觸發這條路徑；部署驗收除了正常啟動，也要包含 AppKit reopen／restoration 期間的 topology refresh
- 還原 panel、cwd 與 scrollback，不代表原本的 agent runtime 已經還原
  - non-tmux Claude／Codex 在正常結束後只會剩下重新啟動的 shell；驗收時要另外確認 durable session ID 與 agent process
  - Bridge 的 runtime descriptor 必須把沒有 tmux carrier 的 agent 表達成第一級 `direct_resume`，不能因為共用 tmux schema 就直接略過
- 使用者原本沒有使用 tmux 時，不要為了還原而建立 synthetic tmux topology
  - `direct_resume` 在同一個 restored panel 內執行 bundled、allowlisted 的 `claude --resume <id>` 或 `codex resume <id>`
  - descriptor 要如實保留 target／topology 不存在的狀態，並依 policy 驗證欄位組合；optional field 不代表任意組合都可接受
- `direct_resume` 仍要保留一般 terminal 的 shell lifecycle
  - login shell 可以先載入使用者 PATH，再把 agent 當成子程序執行；agent 結束後應 `exec` 一個新的 login shell，讓同一個 panel 回到可輸入狀態
  - 若外層直接 `exec` agent，正常 `/exit` 也會結束整個 PTY，留下無法操作的 `Session Ended`
- process 啟動所需的 Tidey identity 必須在 native graph hydration 前傳入
  - `PTYSession` 可能早於 workspace graph 完成啟動，事後才設定 workspace／panel ID 已經太晚
  - 從 saved arrangement 先解析 workspace ID，panel GUID 經 collision 檢查後只計算一次，並把同一個實際 GUID 同時交給 session environment 與最後的 tab graph
  - arrangement 與最後存回的 session environment 正確，不代表 child process 實際繼承正確；`startProgram` 仍會在更晚的階段用 terminal lookup 覆寫 identity
  - restored tab 必須在 recursive session launch 前先安裝 workspace ID 與 collision-safe panel GUID；啟動期 workspace lookup 依序採 graph、tab 自己的 saved identity、selected workspace，而且 tab fallback 要直接讀 property，不能再透過尚未完成的 workspace graph 查一次
- App bundle 與常駐 Bridge 是兩個獨立的 deployment boundary
  - 只替換 Tidey app 不會更新或重啟 Application Support 內由 launchd 執行的 Bridge；驗收 descriptor 新功能時要同時核對 bundled binary、installed binary 與實際 running process
- runtime descriptor 只能當成受限的重新啟動指令
  - executable 必須從 app bundle 解析並通過 allowlist，argv 形狀與 vendor／durable ID 要完全一致，shell 參數需安全 quoting
  - relaunch 沿用 `(panelID, descriptorRevision)` state machine 與 completion fencing，避免重複 callback 再啟動第二次 agent
- native server 找到紀錄，不代表 child process 仍可使用
  - multiserver 的 `Attached` 只表示找到 server-side process record；`Attached` 但沒有 `Registered` 可能是已終止的 child
  - 一般 iTerm 還原仍可沿用 attached-only 語意，但 Tidey-managed descriptor 必須要求 `Attached + Registered`，否則要進 durable rehydration
- 非同步 PTY lifecycle callback 必須帶來源 task identity，並在實際執行 side effect 時驗證
  - callback 排進 main queue 後才替換 `_shell` 時，事後清掉舊 delegate 已經無法取消 queued block
  - broken-pipe callback 要保留 originating `PTYTask`，到 main queue 執行時再和目前 `_shell` 比對；舊 task 不得關閉新的 panel runtime
  - 這類跨 process 還原在第一輪修正後仍失敗時，要凍結 saved graph、server process record 與 callback 時序；只看最終 workspace 數量會把兩個 lifecycle 缺口誤判成一個
- one-shot workspace sidecar 必須由實際 consumer 清除，不能把後續空 decode 當成撤銷
  - AppKit 可能對同一批 restoration data 走不只一次 decode；後來的 nil／GUID-only arrangement 不代表先前已解出的 Tidey workspace graph 無效
  - pending graph 尚未被 `didFinishRestoringWindow` 消費前，空 decode 應保留現值；只有新的有效 graph 才能取代它並重設相關 panel-ID remap
- driver restore 完成不等於 workspace graph 已完成 hydration
  - `dispatch_group_notify(..., main_queue, ...)` 保留了必要的 AppKit 非同步邊界，但 callback 會在 driver completion 之後才執行；此時若先把 controller 標成 ready，下一個 save 就可能把 provisional 單一 workspace graph 寫回資料庫
  - 另設 hydration group：每個 restored record 在排入 deferred callback 前 enter，callback 完成後 leave；先釋放原本的 restoration group，再等 hydration group 歸零，避免兩個 group 互等造成 deadlock
  - 不要為了縮短時序而把 `didFinishRestoringWindow` 改成同步；AppKit restoration 的 reentrancy 風險仍要由原本的 async boundary 隔離
- 所有 durable save 入口都必須共用 hydration readiness gate
  - 定期儲存、`needsSave` flush 與 termination synchronous save 都要等 driver restoration、controller readiness、workspace hydration 三者完成；只封鎖 scheduler 仍會從其他入口寫入 provisional graph
  - scheduler 被拒絕後會依自己的 dirty/retry 狀態重試，這和 `_driver.needsSave` 是兩條機制；不能假設 periodic refusal 會自動設定 `needsSave`
- Remote 顯示用的 logical panel identity 不能直接當 durable restore identity
  - 同一個 native carrier panel 可以投影成多個 tmux window／agent panel；若每個 logical panel 各發布 descriptor，native binding gate 會拒絕 logical panel ID，或讓同一 carrier 最後只留下其中一個 agent
  - 保存前要依 `(workspace, native carrier panel, tmux socket, session ID)` 聚合成一份 descriptor，並把每個 Claude／Codex resume command 放到實際 pane 的 topology launch；active pane 可以是沒有 launch 的 monitor
- runtime descriptor publisher 必須讀取已由 live process／pane 證據校正的 in-memory binding
  - registry JSON 是 wrapper 啟動時的歷史觀測，workspace／panel 可能已經 rename、move 或重新投影；重新讀磁碟會把正確的 live binding 降回 stale binding
  - 校正結果只作為當前發布權威，不要反向改寫 wrapper-owned registry；遇到 pane、carrier 或 durable ID 衝突時 fail closed，不發布部分 topology
- runtime descriptor inventory 必須能原樣送回 update gate
  - `restore_policy=create` 的更新 gate 要求 live `tmux_pane_id`；inventory 若只回 workspace／panel binding，controller 即使只改 socket 也必然得到 `stale_binding`
  - restored descriptor 本身不保存 live pane identity；Bridge 以相同 descriptor 內容重新發布 runtime evidence 時，gate 仍要更新 binding metadata，不能因 canonical content 未變就直接略過
  - regression 要覆蓋 restore→同內容 live republish→list→只改 target→update 的完整流程；分別用手工完整 update payload 測 gate、用 inventory 測 removal，抓不到兩個 wire contract 之間的欄位 drift
- controlled runtime handoff 的未來 target 不能和 ordinary live evidence 共用同一種 update ownership
  - 2026-08-23 實機中，controller 把 candidate socket 寫成 revision 36 後，仍存活的 Bridge publisher 在下一個 5 秒 cadence 用舊 server 證據覆寫成 revision 37；單次 accepted response 不是穩定 handoff gate
  - 明確的 staged update 要建立 in-memory pending lease：內容不同的 ordinary evidence 只能 accepted/no-change，內容相同才完成 hydration 並清除 lease；App restart 則把 staged 降為 restored pending，保留正常 drift reconciliation
  - inventory 必須暴露 `awaiting_runtime_evidence` 與 `staged`；controller 要跨過至少一個 publisher cadence 再確認 revision 與 target 都不漂移，之後才可 checkpoint、結束舊 runtime 並重啟 App
- tmux restore target 必須保存 server 回報的完整 canonical session name
  - 使用者啟動時可用 `tmux attach -t s` 這類 prefix，但 prefix 不是 durable identity；冷重開後 exact attach 到 `=s` 不會等同 `storage`
  - topology capture 要以穩定的 session ID 查詢 `list-panes -s`，再保存輸出中的 `session_name`、真實 `window_index` 與 `pane_index`
- 正常 ⌘Q／重開不能當成 cold-reboot agent restoration 驗收
  - tmux server 還活著時只是在 reattach，會遮蔽 descriptor 遺漏；部署前要比對 live agent ID 集合與 saved descriptor pane-launch ID 集合，要求每個 ID 恰好一次
  - production-shaped fixture 與實際快照都要檢查 native carrier 數、完整 agent 數、multi-window carrier 的 monitor 空 launch，以及 canonical session target；allowlist 以外的 monitor process 只恢復 window／cwd，不宣稱自動重啟
- serial restoration queue 上的 subprocess 必須有 timeout 與完整結果紀錄
  - 一個沒有 timeout 的 `tmux has-session` 就能擋住後續所有 carrier；每個 probe／mutation 都要限制執行時間，timeout 後先 terminate、再於短暫 grace 後強制結束
  - stdout 與 stderr 必須同時持續 drain 並限制保留大小，否則大量輸出也可能造成 pipe deadlock；每次結果至少記錄 phase、descriptor revision、session、launch 狀態、timeout、termination reason、status 與截短後的 stderr
  - `tmux has-session` 只有正常 exit 0 可視為 existing、正常 exit 1 可視為 missing；timeout、signal、launch error 與其他 status 都要是 failed，不能誤觸 create
- 透過 `Foundation.Process` 傳給 tmux `-F` 的格式字串要使用可列印分隔符號
  - argv 裡的實際 TAB 控制字元可能被 tmux 正規化成 `_`；互動 shell 傳入反斜線加 `t` 的測試會由 tmux 自己展開，無法代表 GUI app 的 argv 路徑
  - command format 與 parser 要由同一個 codec 管理，並以 isolated tmux socket 跑實際 `Process` round-trip；`list-panes` exit 0 只代表命令成功，不代表 stdout 符合 parser contract
- managed descriptor 的 native reattach `.notAttempted` 不能在占用 exactly-once key 後直接 return
  - cold boot 可能先還原 native panel，卻沒有可重接的 native server；此時 `.notAttempted` 要走和 native reattach failed 相同的 probe／durable resume 流程
  - launch policy 與 runtime state machine 必須共用同一個啟動 owner；valid descriptor 的 `.notAttempted` 要延後 saved program，由 state machine 依 `(panelID, descriptorRevision)` exactly-once gate 啟動
- cold-boot descriptor 不能在 runtime evidence 尚未重現時被 Bridge 撤銷
  - Bridge 啟動後的完整空 registry 只代表當下沒有 live record；若直接當成 authoritative absence，兩次輪詢後就會刪掉仍在排隊重建的 descriptor，再由自動儲存永久覆寫
  - native restore 要先為 exact `(panelID, revision, canonical content)` 建立等待 runtime evidence 的 lease；只有接受同 binding 的有效 Bridge publication 後才允許 absence removal，pending removal 必須回可重試錯誤
- Finder／login 啟動的 Tidey 必須自行建立 canonical runtime task environment
  - 不能假設 app parent 已有正確 `TIDEY_SOCKET_PATH`／`TIDEY_BIN_DIR`；先移除 ambient `TIDEY_*` 與 controller identity，再注入當前 Tidey socket 與 app bundle `Resources/bin`
  - workspace／panel identity 仍由 attach 後的 pane options 提供，不可放入 tmux server global environment
- 復原工具建立長存 tmux server 前要隔離控制端 agent 的環境
  - Codex tool runtime 會注入 `NO_COLOR`、`CODEX_CI`、thread ID 與 sandbox metadata；若第一個 `tmux new-session` 原樣繼承，server 與所有後續 agent 都會帶著這些變數，`NO_COLOR` 會讓全部 TUI 失去 ANSI 顏色
  - 建立 tmux client process 時先移除精確的 controller denylist；agent shell 啟動前再 `unset` 同一組 keys，因為乾淨的 client environment 無法刪除既有 server 已保存的 global environment
  - native runtime tmux CLI 要移除 ambient `TMUX`／`TMUX_PANE`，並以 descriptor 的 canonical socket arguments 定位；不要用 global `tmux set-environment -gu` 改動使用者其他 session
- 事故 artifact 要標明時間與資料來源，不能把較早的 SavedState 當成最後 reboot input
  - 2026-08-07 的較早 native graph 是 2 個 create + 9 個 attach-only descriptor，但最後重開前已發布 11 個 v2 create carrier／21 launches；復原時前者只提供 workspace graph，descriptor inventory 由最後 rollout 的 canonical manifest 取代
  - 保存 unified log、native DB、collapsed DB、canonical manifest 與雜湊；若舊版未記 command status／stderr，文件必須明說這段證據不存在，不能用後來的推論補成既成事實
- Codex app-server 的 generic `thread/read failed during TUI session lookup` warning 不能當成自動切換 runtime 的依據
  - Codex 0.147 對所有 `thread_read` request error 都輸出同一段 warning，外層 trace 看不出 writer、權限、認證、transport 或特定大型 thread 不相容；rollout 大小也沒有上游保證的門檻
  - 只有人工確認過的 exact durable ID ＋ exact Codex 版本，才可由 Tidey-owned、owner/mode/schema 驗證通過的相容性檔改走 tracked plain；缺檔、壞檔、錯 ID、錯版本或不安全權限一律維持 app-server
  - wrapper 不得依 warning、exit status、等待時間或 rollout 大小自行新增相容性紀錄；版本升級後 exact-version 不再命中，驗證新版本可用後再由 operator 刪除舊紀錄
  - tracked plain 仍可提供 history、一般輸入與 `/status`，但 structured prompt、approval 與完整 lifecycle/busy 狀態屬於 app-server 能力，驗收文件要明講差異
- app-server cleanup 不得保留已由 `wait` 回收的 Remote TUI PID
  - `wait` 取得 status 後立刻清空 PID；否則後續 cleanup 可能對已重用的 PID 發 signal
  - 手動 cleanup／fallback 前先解除 `EXIT`、`HUP`、`INT`、`TERM` traps；cleanup 函式本身也先解除 traps 再執行，避免 `exit` 重新觸發 EXIT trap 而清理兩次
  - 測試直接攔截 signal 嘗試與 socket-directory cleanup 次數，不要靠作業系統真的重用 PID，也不要只驗最後程序已死亡
- Tidey-managed Codex profile 的使用者選擇不會自然跨 relaunch 保留
  - wrapper 每次啟動都會完整重建 per-carrier profile；Codex TUI 寫回同一檔案的 `resume_cwd` 會在下一次啟動被覆寫，不能把一次人工選擇當成持久修復
  - unattended durable resume 應由 profile generator 明確設定 `tui.resume_cwd = "session"`，讓 Codex 使用自己保存的 session cwd；明確 `--cd`／`-C` 仍保留逐次覆寫權
  - tmux pane／wrapper registry 的 cwd 是 carrier 啟動位置，與 Codex 恢復後的 logical cwd 是不同資料；修互動提示時不要順便擴成 rollout parser 或 registry cwd 重構
- Codex runtime instance ID 不能當成 durable resume ID 發布
  - tracked-plain wrapper 會先用每次啟動的隨機 instance ID 建立 registry；rollout 尚未出現前，這筆資料仍可供 active-session 與 pane matching 使用，但不能更新 runtime-resume descriptor
  - tracked plain 只有在 rollout 檔名可解析出合法 UUID，且該 UUID 精確等於 registry session ID 時才算 durable；completed app-server 則必須已有非空的 `thread_id` 或 `resume_thread_id`
  - provisional／starting record 要讓整份 runtime-resume snapshot 保持 incomplete，凍結 publisher 的 update、list 與 remove；若直接把它當成不存在，兩輪 absence observation 反而可能撤銷原本正確的 descriptor
- tmux 的游標欄位等於 pane 寬度是合法的延遲換行狀態，不是越界資料
  - active `cursor_x == columns` 在 DECAWM 開或關時都可能存在；下一個 printable 才依當下 wrap mode 換行或覆寫末格，不能用 `wrap_flag` 決定是否接受這個 sentinel
  - alternate saved cursor 也可等於 `columns`；tmux 離開 alternate screen 時會自行把 restored cursor 夾回末格，因此 wire contract 應接受原值，renderer 不需另造 saved-cursor pending flag
  - strict Bridge 與 client validator 都要接受 `0...columns`、拒絕 `> columns`；只修一端仍會落回 legacy renderer，表面症狀可能只是 ANSI 顏色消失
  - ANSI CUP 會把 active cursor 夾到 `columns - 1`；bootstrap 全部 feed 完後，renderer 才用 terminal buffer 的公開 seam 恢復 `x == columns`，保留下一字的真正 wrap／overwrite 行為
- Codex app-server 的 attach／resume 也必須有明確的初始載入上限
  - `thread/resume` 預設帶回完整 turns 時，大型 thread 會在 iOS 真正取 transcript 前先讓 Bridge 載入整段歷史；不能把這種延遲誤判成網路或 iOS renderer 問題
  - 訂閱只請求最新一筆 descending summary turn：`excludeTurns=true` 加 `initialTurnsPage(limit: 1, sortDirection: desc, itemsView: summary)`；這一筆仍足以找出既有 `inProgress` turn ID，保留 steer 能力
  - response parser 要先讀 bounded `initialTurnsPage.data`，並保留舊 `thread.turns` shape 的 compatibility fallback；測試同時固定 request shape 與 active-turn seed，避免為了省載入而破壞 busy session
- 無縫 agent handoff 的 durable commit 應使用既有 tmux pane identity，不要再造 manifest
  - B 先以 staging panel identity 啟動；prepare 期間 stable panel 只會解析 A。Codex 要等第一個 prompt 才建立 fresh durable thread，不能把 thread ID 當成 pre-submit readiness
  - commit 順序固定 B := stable、A := rollback；雙 stable 的窄視窗由 `created_at` 決定性選較新的 B，Bridge 重啟也能從 pane options 重建同一結果
  - rollback 順序固定 B := rollback、A := stable；雖有短暫 unbound 視窗，但兩步皆冪等，helper 重跑即可修復。不可反轉順序，也不可改寫 wrapper-owned registry JSON
  - chat／TUI submit 在多步 delivery 前後都要重查 stable panel 的 route token；handoff 中抓到 A 的舊 request 不得在 B 接手後再送 Enter 或送進 app-server A
  - 「同步重掃」不等於「讀到 live pane option」：`TmuxStateResolver` production 有 pane-identity TTL；submit-time route capture／validation 必須先失效該 cache，測試也要保留非零 TTL，否則 `ttl: 0` 會把真實的 stale-A 空窗藏掉
  - fresh tmux session 可能繼承 controller shell 的舊 `TIDEY_*` 值，也可能拿不到 pane-scoped socket/bin；啟動 B 前要把 staging workspace/panel 與 A 的 runtime values 明確注入 agent command，並同步投影到 B 的 pane options，不能賭 wrapper 與後設 option 的啟動 race
  - fresh Codex app-server record 起初沒有 durable thread ID，而且 Codex 0.150 不會持續開著 rollout FD；用 `lsof` 掃 replacement process tree 可能完全找不到 B，也可能誤抓同時存活的其他 rollout。pre-submit gate 只驗 wrapper／socket／app-server／remote TUI；prompt submit 後才進 durable gate
  - helper 把 UUID token 以一次性 launch value 交給 replacement wrapper，wrapper 立即從 child environment 移除；prompt 建立 thread 後，wrapper 只查該 staging panel 的 SQLite `threads.first_user_message`，以 exact token 取得 thread／rollout，再原子更新同一筆 registry。這條查詢不載入 turns、不讀完整 rollout，也不掃全域 sessions
  - 無人值守的 replacement 不能停在 Codex startup update chooser；remote TUI 啟動時要明確關閉 startup update check，並由測試固定 argv contract
  - B 在 prepare 階段不能執行全域 stale-registry cleanup，否則它可能刪掉仍存活的 A record，讓 tmux rollback 看似成功、Remote routing 卻已失去 A。replacement 要帶窄的一次性環境旗標，wrapper 入口立即把它消耗成不 export 的內部 launch state，cleanup 函式本體依此跳過；不能只 gate app-server happy path，因為 startup fallback 到 tracked plain 也會呼叫同一個 cleanup
  - 一次性 handoff 旗標不能留在 B 的 agent／tool process 或 agent 結束後的 login shell；helper 只對 Codex executable 的單一 command assignment，wrapper 讀完即 unset。測試要同時驗證 child runtime 看不到旗標、post-agent shell 也看不到
  - background registry monitor 不能只用 `kill -0 owner_pid` 判斷 owner identity；SIGKILL 後 PID 重用可能讓 orphan monitor 復活 ghost registry。parent 先把 monitor 的真 PID 寫進私有 runtime dir，monitor 以 `ps` 驗證自己的 PPID 仍是原 wrapper；正常 cleanup 仍要 `kill`＋`wait`
  - wrapper 本身在 tmux pane 裡不代表它啟動的 background Remote TUI 仍有 terminal stdin；非 job-control shell 會把背景工作的 fd 0 變成非 TTY。wrapper 要在前景先解析 controlling／pane TTY，再把 Remote TUI 的 stdin 明確接回該裝置；測試也必須用真的 PTY，不能只靠 `TMUX_PANE` 環境字串假裝 terminal
  - `tmux paste-buffer` 完成不代表 Codex／Claude 的 multiline editor 已完成 ingest；大型 handoff prompt 後立刻送 Enter，Enter 可能只被 editor 吃掉而沒有 submit。paste payload 先去掉尾端換行，保留固定五秒 settle window，再送一次 Enter；transcript token 仍是唯一 commit gate
  - registry readiness record 是會繼續補欄位的 writer-owned lease，不是 immutable snapshot；Codex 先發布 runtime／socket／PID，收到第一個 prompt 後才補 fresh thread 與 `rollout_path`。transcript detector 等待期間要重讀同一個 exact registry path，以 vendor＋session ID fence，並同時驗 fresh thread、live runtime 與 transcript token；不能接受別的 writer
  - live wrapper registry 是 writer-owned lease，不是一次性 startup artifact；外部 observer 在 handoff 暫態誤刪 record 時，helper 不得複製 JSON，仍活著的 wrapper guardian 要用原 runtime identity 自動 republish。guardian 必須是 wrapper 的直屬 child，cleanup 先 kill＋wait guardian 再移除自己的 record，避免正常退出後復活 ghost registry
  - live canary 的 pre-commit failure 驗收不能只看 session 名稱、pane identity 與 process；還要核對 A 的 exact registry、durable ID、socket 與 runtime PID 都仍然有效
- iOS session 切換的 seamless 不等於跨 session 拼接 scrollback
  - context change 立即清掉舊 approval、pending submit 與 response model，讓舊卡片不可再提交；已渲染 rows 只作為唯讀視覺快照保留
  - B 的 bounded snapshot 先進唯一的 canonical `ChatTranscriptState`，不另建 history loader；訂閱回條的 `replay_count` 必須等 event consumer 實際處理完才一次 publish 新 rows
  - 不使用固定 reveal delay。若 session change 是 recovery refresh 才發現，成功 publish 還要恢復 composer connection，否則畫面雖換到 B，輸入仍會停在 disabled
- Claude transcript 的 turn 結束不能只依賴 `turn_duration` 或 hook
  - durable resume 後，最後一筆可能只有 assistant `message.stop_reason = end_turn`／`stop_sequence`，沒有後續 `turn_duration`、Stop hook 或 idle hook；bootstrap replay 與 live tail 都必須把這種 terminal assistant record 收束為 Idle
  - terminal record 仍要沿 `parentUuid` 找到 owning user turn，並以 expected turn ID fence；舊 turn 延遲寫入的 assistant record 不得結束較新的 active turn，`stop_reason = tool_use` 也必須維持 Working
- restored tmux agent 的 wrapper 可能早於 pane identity projection 啟動
  - app-owned Runtime 復原時，Claude wrapper 可能先看到 `TMUX`，但 workspace、panel、socket pane options 尚未全部寫入；若此時直接 passthrough，Claude TUI 雖正常，Remote 仍因沒有 hooks 與 registry 而降級成 terminal
  - 互動式 wrapper 應在已知 Tidey Runtime socket 上有限等待完整且仍存活的 runtime context，再決定是否 passthrough；`mcp`／`config` 等非互動 subcommand 與外部 tmux 不應承擔等待

## Testing

- AppKit enum 不可用布林 truthiness 判斷有效狀態
  - `NSTableViewSelectionHighlightStyleRegular` 的值是 `0`；`if (!style)` 會把正常選取誤判成沒有選取，導致 plain table 的自訂選取背景完全不畫
  - 判斷關閉狀態要明確比較 `NSTableViewSelectionHighlightStyleNone`，並用 bitmap render 覆蓋實際 style 值，不只測 token 或 model
- UI token／單元測試通過不等於完整畫面驗收
  - 至少用一個真實 Development app 視窗同時呈現選取 workspace、最小側欄寬度、terminal 與右側 Browser／Editor；確認實際階層、裁切、間距與選取狀態
  - 真實畫面先由產品負責人驗收，再交 frozen code review；code review 不能代替視覺驗收，也不能只靠 mockup 宣稱實作完成
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

### CI hosted tests（2026-07 CI 假綠事故串：5897a021a、40a31f2cc、ae6510b88；runs 29197275492、29211477438、29212683099）

- Pipeline 必須保留 producer 的 exit status
  - `xcodebuild ... | tee` 沒有 `set -o pipefail` 時，`** TEST FAILED **` 照樣印 `Tests passed`——CI 假綠了數月
  - 綠燈本身不代表測試跑過：同時驗 xcresult 的 total test count > 0（5897a021a）
- isolated DerivedData 的 hosted tests 要先建立 app host
  - 先用同一個 `-derivedDataPath` build `iTerm2` scheme 的 Development configuration，並確認 `Tidey Dev.app/Contents/MacOS/Tidey Dev` 存在，再執行 `iTerm2Tests`
  - 直接對全新的 DerivedData 執行 hosted test，或沿用只完成部分 linkage 的舊快取，可能以缺少 test host binary 或第三方 undefined symbols 失敗；這是 infra red，不是產品行為 red
- Xcode `-quiet` 的文字紀錄不保證含有測試總數
  - Xcode 26 可能只留下 `Testing started`，即使測試已成功；用 `xcresulttool get test-results tests` 讀 `.xcresult`，確認 `Test Case` 數量大於零且沒有非 `Passed` 結果
- `.xctestplan` 是執行環境的一部分
  - test plan 的 environment entries 會覆蓋 shell env，外部 unset 蓋不掉
  - Malloc diagnostics（StackLogging/GuardEdges/PreScribble）留在預設 plan 會讓 test host 啟動在 CI 超時（40a31f2cc）；這類 config diff 要當程式碼審查
- Hosted unit test 的 app launch path 不可排程 modal、TCC prompt、installer 或 first-run UI
  - shell integration 安裝 modal 在啟動 1 秒後跳出，CI 上沒人按 → 誰 pump run loop 誰卡死、受害 test 每輪不同（「hang 會流動」）
  - guard 要放在「排程之前」，用既有 `isRunningUnitTests`（ae6510b88）
- Hang 先讀 xcresult diagnostics / spindump，再動手
  - 主執行緒 stack 一發定位（spindump 拍到 `runModalForWindow:`）；重跑與錯誤字串分類都給不出這個
  - 先開 `-test-timeouts-enabled` + execution time allowance，hang 幾分鐘內變 failure 並留 spindump，而不是吃滿 6 小時 job 上限
- Retry 必須先有非確定性證據
  - 相同 phase / 相同 signature 的 timeout 是 deterministic bug，直接失敗；`The test runner timed out while preparing to run tests` 不可進 retry allowlist
  - retry 條件要求「0 個 test 已執行 + 已知 asset compiler/ibtoold fingerprint」雙成立
- Release artifact 必須來自 tag 所指的同一 source tree
  - shipping code、版本或 build 設定在公證後有變動 → 重新 build、簽章、公證（v0.5.2 因 unit-test guard 進 shipping code 而整包重建）
  - 發布記錄 candidate SHA、DMG SHA256、notary submission ID
- Fresh runner 是環境契約
  - 測試只用 temp directory / repo root discovery（`#filePath` / `__FILE__`），不可寫死 home path
  - 外部工具缺席要有明確語意（無 tmux → cleanup command 為空是合法結果）
  - 就緒等待用 poll（連 port、等檔案出現），不可用固定 sleep——冷 runner 的 python3 首啟、wrapper monitor 都比本機慢數倍

## Versioning

- `version.txt` 是版號的唯一 source of truth，不是 `plists/iTerm2.plist`
  - Xcode build phase script 每次 build 都會讀 `version.txt`，用 PlistBuddy 覆寫 plist 的 `CFBundleShortVersionString`、`CFBundleVersion`、`CFBundleGetInfoString`
  - 直接改 plist 的版號無效，下次 build 就被蓋掉
  - Development config 會加 `-dev` suffix，Deployment 加日期 suffix（除非 version.txt 不含 `%(extra)s` placeholder）
  - 要改版號就改 `version.txt`，不要改 plist，也不要只看 Xcode General tab 的 Version / Build 顯示值（那些是 build 後才被覆寫的結果）
- appcast 的最低 macOS 版本要讀正式 build 的 `LSMinimumSystemVersion`
  - project deployment target 改過後，release script 裡的 hardcode 很容易留在舊版本，造成 Sparkle 允許不相容的系統下載更新

## Branding / Defaults

- 改 app icon 先分清楚是 build 問題還是 Launch Services cache
- `.icon` bundle 會覆蓋 plist icon 設定
  - `.icon` 和 `.icns` 不要混
- 改 `DefaultBookmark.plist` 後，如果 app 還在吃舊預設，要先清掉已寫入的 user defaults / cached profile
  - 不然 plist 改了，執行中的預設 profile 不一定會立刻跟著變
- hosted iTerm2Tests 的 linkage 快取跟著 scheme 走，不只跟著 app host 走
  - 一個只 build 過 `iTerm2` scheme 的 DerivedData，即使 `Tidey Dev.app` host 存在，跑 `iTerm2Tests` 仍可能以第三方 undefined symbols（CoreParse `_OBJC_CLASS_$_CP*`、railroad `_railroad_*`）在 test bundle 連結時失敗——這是 infra red
  - 解法：改用曾成功跑過 `iTerm2Tests` 的 DerivedData（例如 Xcode 預設樹），或在該樹完整重建 `iTerm2Tests` scheme；不要在產品 assertion 上除錯連結錯誤

## Remote 推播與測試時鐘（2026-09-07）

- WebSocket 上的本機通知只在 iOS 還能執行時有效；置頂 workspace 背景通知需要 Bridge 持久 outbox 與 APNs。UI history replay 不能推進通知 checkpoint；checkpoint、去重紀錄與待送項目必須同一筆交易提交。
- `replay:false` 不代表 producer 剛產生新訊息。bootstrap 與 Codex pending snapshot 也會走 live hub；用 durable occurrence、註冊／pin 時間及通知專用 cursor 判定。Claude permission hook 只更新 lifecycle blocker，不能假設會有對應 chat event。
- Relay HTTP/2 import 成功不等於環境真的支援 APNs。用本機 TLS HTTP/2 server 驗證 JWT 簽章、標頭與回應，再做外部設定後的實機驗收；不要用帳號憑證或權限彈窗作測試探針。
- iOS 的 APNs environment 與簽章 entitlement 要來自相同組態；不要以 `DEBUG` 猜測 token 的環境。重生 Xcode project 後須比對 source/resource membership 與橫向設定，避免把先前手工維護的設定覆蓋掉。
- XCTest case 可能在整套測試開始時就建立。時間基準放在 `setUp`，不要用 stored-property 初始化的 `Date()`；涉及非同步 enqueue／retry 的測試要跨過實際入列時間，否則單獨跑成功、整套跑卻因 stale clock 失敗。
- SQLite JSON 診斷必須限定外層欄位名稱。`SELECT (SELECT count(*) FROM json_each(value,'$.grants')) FROM push_state` 裡的 `value` 會被內層 `json_each.value` 遮蔽，實際有註冊也可能查成 0；使用 `FROM push_state s` 與 `json_each(s.value,'$.grants')`，並用非空固定資料驗證查詢。2026-09-08 曾因此把 1 台已註冊、實際能收推播的手機誤判為尚未註冊。
- 推播狀態的歷史錯誤與目前待送狀態要分開判讀。現有 Bridge 成功投遞會移除 pending，卻不清除 `lastError`；`Relay HTTP 429: unavailable` 可能在已恢復投遞、pending／dropped／sourceErrors 都為 0 時仍顯示。沒有保留 APNs reason 時，不能從這個字串反推當時的具體限流條件，也不能直接改資料庫把警告清掉當成修復。

## 置頂推播的回合完成判定（2026-09-09）

- 完整的 assistant 文字區塊不代表回合完成。Codex `commentary` 與 Claude `tool_use` 前的進度文字不能當作結果通知；Codex 用 `final_answer`／有回答的所屬 `task_complete`，Claude 用含文字的 `end_turn`／`stop_sequence`，或具有所屬回答證據的 `turn_duration`。thinking-only、工具結果與中斷都不能產生完成通知。
- 通知去重採 durable source 加 turn ID；沒有回合識別的舊／截斷來源，只能對明確 final 訊息使用既有 message／位置識別，不得靠等待幾秒推定完成。Claude 的 parentUuid lineage、待確認文字時間與 Codex turn ID 必須和通知 cursor 同筆交易保存，避免重啟後重複通知或把 A 的結束歸給已排隊的 B。
- Claude 結束紀錄可能沒有 timestamp，應使用已保存且屬於同一回合的文字時間；一般含 XML／HTML 的使用者文字仍能開啟新回合，只有實際的 metadata／local-command envelope 才排除。
- 升級前的 outbox message 沒有完成證據，不能直接當 final 送出。以 optional `completionVerified` 相容讀取舊資料；未分類項目保留原 TTL 並顯示 `unclassified_pending_message_count`，不阻擋新結果與正式提問。部署前應確認這個舊待送範圍為零，或另行核對來源；不能宣稱所有舊待送訊息都已自動分類。

## 推播部署前的簽章與設定保留（2026-09-09）

- App 的 `codesign --verify --deep --strict` 通過，仍不足以證明 Resources 內的 Bridge 是 Developer ID 簽章；這次 Bridge 只有 linker ad-hoc，卻被 App 當一般 resource 正常封存。維護中的 bundle helper 應在複製 Bridge 後、App 封存前，使用 Xcode 明確提供的 signing identity 簽章；分別驗證 App 與 Bridge。未簽章 build 不新增簽章動作，簽章失敗則 build 失敗，不能部署時臨時補簽。
- Bridge 開發安裝入口重新產生 plist 時，原本會遺失現用 `TIDEY_PUSH_RELAY_URL`。現在解析原 plist 並保留 operator EnvironmentVariables，再原子寫入套用正常 template 的結果；測試實際 installer 在兩份服務 plist 都保留既有環境值。這項修正尚不代表原生 App installer 的所有重寫路徑都已修改，也不代表 production 替換通過驗收。
- Runtime resume descriptor 清單必須與全部 live registry 及 native panel 聯集比對。本次 12 份 descriptor 都合法，仍有第 23 個 writer 在非 tmux 原生 panel，只有 durable thread，沒有自動恢復描述。重啟 iTermServer 前需明確決定該對話的退出與恢復方式；不能只以 tmux 上的 22 個 writer 全部可恢復就通過。
- Codex app-server wrapper 的 registry resume_thread_id 可能仍是啟動時 ID，TUI 已切到另一個 thread。這次 registry 指向 8/7 的 019fdad5…，原 pane 退出時 Reconnect 與實際最新對話則是 01a07f44…；以 TUI /status／退出資訊與 rollout 最後一輪交叉確認實際 thread，再做同 ID resume，不能只因 registry 的 PID／panel 正確就認定其 thread 仍正確。成功建立 tmux descriptor 也不等於 TUI idle；本次 /agents 顯示 Ready、/status 可回應，原畫面卻持續 Working，這項介面狀態問題尚未解決，不得略過部署 idle gate。
- Tidey 專用 Codex wrapper 會在 TUI /exit 後清除專用 app-server 與臨時 socket，因此 Codex 印出的 `--remote unix://… resume …` Reconnect 指令可能立即失效。舊程序已退出時，從原 tmux pane 用 `codex resume <完整 thread ID>` 重建 runtime；不要重建舊 socket 檔或複製歷史當成修復。tracked plain CLI 分支會另外要求 project trust，不能把這項授權與 remote 模式原本停用 project-local config 的行為混為一談。
- 01a07f44… 在 Tim 核准 project trust 後，透過現有 `TIDEY_CODEX_APP_SERVER_DISABLE=1` tracked plain 分支恢復，三次 capture 都不再顯示 Working，registry／原 panel／durable ID 保留。這只證明本機模式可避開當次問題，未證明 remote TUI 根因已修。環境覆寫沒有保存到 runtime descriptor，部署重啟不能忽略這個差異。CLI 將信任寫回 Tidey profile 時，還要注意 generator 會重建該檔；只有使用者已核准的 exact project trust 才能移到持久 base config，不能擴大到其他專案。
- 上述 plain 分支未驗證手機聊天、app-server 專用互動與推播，不能以 Working 消失代替原使用模式的修復驗收。Tim 後續要求恢復 managed app-server；等正在進行的封面回合 task_complete 後才正常退出、移除該次停用環境變數並恢復原 thread。Working 再現，應保留此未解事實，不再擅自以 plain 模式替代。
- tmux session 改名後，已 attach 的 client 可持續連在相同 session ID，但 client argv 仍保留舊 `attach-session -t =codex`。Tidey 的 ordinary_tmux 解析因此仍回報過期目標；本次 live session 已叫 Automation、pane %25 未變，卻缺少該 panel 的 runtime descriptor。核對 exact native client／tty／shell 後，正常 detach 該 client、在同一 stable panel 重新 attach 到 =Automation，即自動恢復正確 descriptor；Codex writer 不必退出或重建。改名後須分別驗證 live session、原生 panel 的 attach metadata 與 descriptor，不能只看 tmux list-sessions。

### 2026-09-17：direct resume 的 logical panel 與保存 carrier 必須分開

- 已證原因：registry 的 panel_id 可是 native-session logical ID；原生 lookup 能找到 carrier，但 descriptor gate 以 carrier ID 驗證 binding，送 logical ID 會 stale_binding。同步 send throw 也會中止同輪後續 carrier。不能放寬 gate，也不能只修改 socket sender 後留下錯的 desired inventory slot。
- 修復：AgentSessionRegistryMonitor.runtimeResumeAgentRecord 只在 direct、唯一 live nativeSession 時投影其非空 carrierPanelID；保留 registry 與 chat routing 的 logical ID。缺 carrier／多筆衝突維持 incomplete；legacy direct 與 tmux 原路徑維持。
- 回歸：production-shaped logical≠carrier + 拒絕 logical binding 的 sender，修前 panel assertion／send 失敗，修後同輪後續 tmux carrier 送出；補 missing／empty carrier、same-carrier conflict、Codex current thread A→B、native 隔離保存讀回／hydration／重開 ack 與其他 descriptor 不變。
- 邊界：Claude current registry 唯一替換 A→B 可發布；舊、新 alias 並存會 fail closed。這只證明 fixture 行為，不足以判定 9/16 Genesis 根因。TideyCLI session-start 有寫 current registry 的路徑，不能只憑 hook payload mismatch 就說完全沒有 UUID 傳播。手動 API 補存、helper committed、source 修正，均不等於 production 自動保存已驗收。

### 2026-09-17：current UUID 交接由 SessionStart 擁有，monitor 不重建舊 UUID

- 隔離實證：實際 wrapper monitor 與編譯的 TideyCLI，僅注入暫存 registry root。SessionEnd(A) → monitor tick → SessionStart(B) 會使 A 重生並與 B 並存；B 先建立的正常順序原本可接手。缺 SessionEnd 而直接收到 SessionStart(B) 也會留下 A。這證明兩 writer 的缺陷，尚不能證明 9/16 Genesis 的歷史原因。
- 修復：wrapper 只在啟動時 bootstrap，monitor 之後只認領與清理，不重建、不補寫 metadata。TideyCLI SessionStart 同時寫 tmux 欄位與 transcript_path，成功後依 exact pid + workspace_id + panel_id 清除同 owner 的其他 UUID。沒有明確 current hook 的 monitor 遇多筆候選就等待；不依 created_at 猜新舊，不放寬 Bridge complete-inventory/binding gate。
- 不同 PID（包含 PID 前綴）、不同 workspace/panel、無法解析 ownership 的檔案均保留；清理會重查 owner，避免已轉給其他 process 的檔案被舊 monitor 刪除。CLI current 檔原子寫入；保留 current 時比較 session_id，不用可能具有不同 representation 的 URL 物件相等判斷（本單初次 green 測試抓到 current 自刪，已修）。
- 測試：tests/tidey_claude_registry_lifecycle_tests.py 控制實際函式 tick 與實際 CLI events，7 項含三種順序、歧義、scope/PID、metadata、cleanup；ClaudeRegistryUUIDPropagationTests 使用上述 writer 產生的檔案證 B 與其他 carrier 發布，不同存活 process 的真正衝突仍停止整輪。fixture 未改 HOME，未執行 live /clear。
- 邊界：explicit --resume/--session-id 的 hook journal 仍可能固定為 A，而 registry 已是 B；B lifecycle/epoch 連續性不在此次 registry 修復範圍，plan 保留待辦。source 修好不代表 production 已部署或保存全流程已驗收。


### 2026-09-19：重開前準備屬於產品；rollback 必須有明確 ownership 分類

- 實機唯讀 metadata probe 確認 32 個 live registry 中只有 27 個對應 current native graph；其餘 5 個為已有即時 pane-option 證據的 handoff rollback。舊 completeness 把它們當 unresolved，整輪 publisher 無法前進。這是 9/19 可重現的現行阻塞，不能外推成 9/16 唯一歷史根因。
- 不靠 session 名稱、timestamp 或 registry 自述跳過 record。只有同 socket 的 live tmux pane options 精確對上 workspace/panel、合法 rollback token，且同 workspace/socket 有保留的 stable panel 時才列入 non-restoring inventory；仍計入完整 source accounting，並在重開報告交給 owner 判斷。未知、無 stable carrier、真正 UUID/writer 衝突仍 fail closed。
- 重開前 CLI 使用 metadata-only registry scan：不載入巨大 history、不啟動 tailer/subscription、不清理或合成 registry。沿用 publisher 更新 descriptor；前後 runtime identity fence 與 native revision fence 必須一致。prepare 不以撤銷未觀測 carrier 補齊 inventory。
- awaiting_runtime_evidence 是 restore/staged lease；合法同內容 republish 已能清除它。前面的 incomplete inventory 或 direct logical→carrier 綁定錯誤會讓後續永遠沒機會 ack。不能把手動清旗標當修復。
- native checkpoint 共用 hydration readiness gate，同步 flush 後以唯讀 SQLite quick_check 和獨立 graph decode 比對 capture plan。save 的回傳值只表示受理，不能代替磁碟讀回證據。
- technical_ready 與 owner intent 分開。pending review、draft、approval、Monitor 邊界與人類輸入活性不由 Tidey 擅自判決。共用 controlled-reboot skill 只呼叫產品契約、重用 resource audit 並協調 owner，不累積人工修 descriptor 的清單。
- source／測試通過仍不等於 /Applications/Tidey.app 與 installed Bridge 已部署。新 wrapper monitor 也必須在後續受控 runtime 啟動才會載入。


### 2026-09-24：移植已覆核修正要逐 hunk；維護版工具要吃 native descriptor

- 隔離 candidate 由舊的 9/7 部署基線重建，同時帶有已撤回的推播 wiring。整檔複製 `ClaudeTranscriptSession.swift`、`main.swift` 或 `PseudoTerminal.m` 會把 `PushSourceReader`、`BridgePushService` 與 pin 推播 policy 帶回 main。移植時逐 hunk 分類，只取 restart 修正；每個保留的 hunk 必須沒有 push 符號，每個排除的 hunk 必須恰好是 push。反方向也成立：candidate 的圖片檔比 main 舊，不可覆蓋 9/20 原圖上傳。
- 維護版 `deploy_common.identity_sets` 與 `stage_descriptors` 對每個 descriptor 都取 `["target"]["tmux_session"]`。native `direct_resume` descriptor 沒有 target，遇到就 `KeyError: 'target'` 崩潰，而 production 已有 native carrier。改用 `split_descriptors` 分開 native 與 tmux，兩者都驗證、都不丟；staging 只搬 tmux socket，native 在開始前要等於 baseline、結束後不得改變。
- 放寬比較嚴格的判準前先檢查 fixture。舊 `test_stage` fixture 只有 `target`，沒有產品實際一定會發的 `kind`、`restore_policy`、`topology`；正確做法是把 fixture 補成 production 形狀，不是放寬 `split_descriptors`。
- 更新邊界：重開本來就會中斷每個 agent，所以「重開」與「更新」可能共用同一條流程，但目前只是提案。Mac 關機時無法安裝、登入後舊 Tidey／Bridge 可能自動啟動並重建 archive holder、只退出 GUI 不會結束 Runtime server 與 wrapper。現行 lineage handoff 仍是唯一可執行路徑。

### 2026-09-24：部署 helper 驗 native agent 要綁 iTermServer 世代

- native panel 由 iTermServer 承載，每次 checkpointed restart 都會 TERM daemon，native shell 與 agent 一起結束，再由產品 `direct_resume` 在原 carrier 接回。所以 native writer 只能比對「目前 daemon 世代」：attach 階段 PID 與 birth 都要等於 baseline；fresh 階段 birth 不得早於目前 daemon，而且 ancestry 要在 daemon 之下。`ps` birth 讀不到時是 typed 問題，不能當成不存在或新世代。
- native logical panel id `native-session:<carrier>:<session>` 內含 native session，fresh restart 後一定變。跨階段比對改用 workspace＋kind＋carrier＋位置，同時要求 logical id 可拆回自己的 carrier 與 session。
- registry 兩個 tmux 欄位都是 None 只代表沒有 tmux transport，不能直接當 native；Genesis 曾有缺 tmux 欄位的 record。要由 ancestry 找到恰好一個 native panel shell 才算 native。
- durable ID 舊寫法 `resume_thread_id or thread_id or session_id` 與產品相反：Codex app-server 換 thread 後會驗成舊對話，Claude 也不該看 thread 欄位。改照 `ClaudeTranscriptSession.restoreSessionID`，並與 descriptor 的 durable／launch 交叉比對。
- `phase2-pre` 舊預期 durable 只有 B，會把仍存活的 native 當多餘 writer；tmux 分流只數 tmux，durable 覆蓋另加全部 baseline native。

### 2026-09-25：Mac sidebar status 空白與假 Running

- 一次送出成功不等於 receiver 仍保有狀態。觀察到的事實：01:39:49 有第二個 `tidey-remote-bridge` process（PID 76223，argv 與啟動者未知），留下 sidebar owner 狀態與 workspace reset 的 `socketUnavailable` 失敗紀錄。依 source 推論：舊 `start()` 在 bind 之前就啟動 registry monitor，而 syncer 只有在該 workspace 的 reset 回報送出成功後才送 owner，所以部分 reset 當時回報成功；native store 是否實際套用沒有追到。正式 Bridge 的 delivered 快取不會察覺 receiver 端遺失，這是 source 與隔離重現都成立的缺口；7 個空白 workspace 與假 Running 的歷史觸發沒有逐一證實。修法：Bridge 必須 bind listener 成功後才啟動任何有狀態的工作；lifecycle sidebar syncer 在既有 sync 節奏上每 30 秒重新宣告目前 owner 狀態（值相同時 receiver 不動作），不做週期清空或逾時判 Idle。
- plaintext `report_shell_state` 以空白分隔參數，ordinary-tmux panel id 內含 `Application Support` 的空白，syncer 過去直接不送。owner 狀態改用 JSON。
- 無 owner 的 `""` cell 由同 workspace 所有 writer 共用，Running 又高於各 session 的 Idle，一個沒收到完成事件的 turn 就會讓整個 workspace 一直 Running。managed app-server Codex（Bridge app-server 路徑與 `TIDEY_CODEX_STATUS_OWNER=lifecycle` 的 hook）改由 session lifecycle 擁有狀態，只保留通知與標題。一般 shell、Claude hook、plain Codex 與 custom status 不變。
- 隔離重現沒有重現「每個指令一條連線造成順序錯亂」，但這不能證明不可能發生。
