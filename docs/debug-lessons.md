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

## Socket / Notification / Claude Hook

- `workspace_id` 缺失的 state update 要 fail closed
  - `report_shell_state` / `set_status` 不能默默落到 broadcast
- broadcast notification 的 unread state 不能用單一共享 bit
  - read/unread 要按 workspace 分開算
- Claude hook 不要靠 terminal output 猜狀態
  - 用明確事件：`session-start`、`prompt-submit`、`notification`、`stop`、`session-end`
- hook command 只要含空白路徑就要先 escape

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
