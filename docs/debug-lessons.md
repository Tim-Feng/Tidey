# Tidey Debug Checklist

改 UI、layout、shell integration、terminal interaction 前，先掃這份。

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

- 找最後一個 writer
  - AppKit / PSM / shell startup 常常在後面把剛設好的值蓋掉
- 先做 local patch
  - 先修單一 subview 的 frame / hidden / event routing，不要第一刀就換整條 layout path
- 一次只改一個假設
  - 同一輪不要同時換 owner、座標系、view hierarchy
- 要加 debug 時優先寫 `/tmp/`
  - Console 常常看不到，log 看完就刪

## UI / Layout

- 不要直接切 `layoutSubviewsWithVisibleTabBarForWindow:` / `layoutSubviewsWithHiddenTabBarForWindow:`
  - 這會連 tab bar、status bar、division view 一起動
- `PSMTabBarControl` 會在 layout 後重設 overflow button
  - `>>` 是 PSM overflow button，不是 Tidey toggle
- `autoresizingMask` 會製造中間態
  - 先分清楚最終 frame 錯，還是中間一拍錯
- `NSOutlineView` / `NSTableView` / `NSScrollView` 的行為先查 API
  - selection、indentation、disclosure、horizontal scroll 多半是 control 自己算的

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

## Terminal Selection / Mouse

- 文字選取起點先看 `PTYMouseHandler -> mouseHandlerCoordForPointInView:`
  - selection anchor 主要走這條，不是 `coordForPoint:`
- URL hover / `cmd+click` 和文字選取不是同一路
  - URL hit testing 可以走 biased coord；文字選取不要跟著吃 bias
- `locationInTextViewFromEvent` 的 `ceil(y)` 會在行邊界把 click 推到下一行
  - 這題要看 click / drag 實際吃的是哪條 path，再決定 rounding
- `textView.frame.origin.y` 和 `topBottomMargins` 都會影響視覺起點
  - 先確認 point 所在座標系，再決定要不要扣 offset

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

## Socket / Notification / Claude Hook

- `workspace_id` 缺失的 state update 要 fail closed
  - `report_shell_state` / `set_status` 不能默默落到 broadcast
- broadcast notification 的 unread state 不能用單一共享 bit
  - read/unread 要按 workspace 分開算
- Claude hook 不要靠 terminal output 猜狀態
  - 用明確事件：`session-start`、`prompt-submit`、`notification`、`stop`、`session-end`
- hook command 只要含空白路徑就要先 escape

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

## Branding / Defaults

- 改 app icon 先分清楚是 build 問題還是 Launch Services cache
- `.icon` bundle 會覆蓋 plist icon 設定
  - `.icon` 和 `.icns` 不要混
- 改 `DefaultBookmark.plist` 後，如果 app 還在吃舊預設，要先清掉已寫入的 user defaults / cached profile
  - 不然 plist 改了，執行中的預設 profile 不一定會立刻跟著變

