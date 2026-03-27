# Tidey Debug Lessons

從開發過程中踩過的坑整理出的規則。改 UI 之前先讀這份。

## Layout

### 不要改 layout path 選擇
`layoutSubviews` 根據 `tabBarShouldBeVisible` 選擇 `layoutSubviewsWithVisibleTabBarForWindow:` 或 `WithHiddenTabBarForWindow:`。切換這個路徑會影響整條 layout chain，導致不可預測的 regression（如第二個 panel 出現黑條）。

**正確做法**：layout 照常跑完，最後在 `layoutSubviews` 結尾修改 view 的 hidden/frame。

### PSMTabBarControl 會覆蓋你的設定
PSMTabBarControl 在自己的 layout 裡會重設 `overflowPopUpButton.hidden`（PSMTabBarControl.m:1492）。直接設 hidden 會被蓋回去。

**正確做法**：在 PSM layout 跑完之後（`layoutSubviews` 結尾）再設 hidden。

### tabBarAlwaysVisible = YES 是刻意的
為了防止 sidebar toggle 時 24px 高度跳動。不要改回條件式。

### autoresizingMask 會造成中間態
設 view frame 時，autoresizingMask 可能在 `layoutSubviews` 之前先跑一次，產生錯誤的中間態。Terminal reflow flicker 就是這個原因。

## Rendering

### SF Symbol 的 it_imageWithTintColor: 會破壞多層 symbol
`it_imageWithTintColor:` 用 `NSCompositingOperationSourceIn` 把所有 pixel 塗成同色，多層 symbol（如 `pause.circle.fill`）的內部細節會消失。

**正確做法**：用 `NSImageSymbolConfiguration configurationWithHierarchicalColor:` 保留層次。

### icon 快取很頑固
改了 app icon 後 macOS 不會立即更新。需要：
1. 刪掉 bundle 裡的舊 icns
2. `touch` app bundle
3. `lsregister -f` 重新註冊
4. `killall Dock`

### .icon bundles 會覆蓋 plist
Xcode 的 Icon Composer `.icon` bundles 在 build 時自動覆蓋 `CFBundleIconFile`/`CFBundleIconName`。要用自己的 icns，必須從 build phase 移除 `.icon` bundles。

## Debug 方法

### 先 instrument 再動手
遇到 UI bug 時，不要猜哪個 view 有問題。先用 debug 方法確認：
- 背景色標記（每個 view 不同顏色）
- 寫 layout frame 到 /tmp 檔案
- `NSLog` 不一定能在 Console.app 看到，改用寫檔

### terminal reflow flicker 的 instrument
在 `layoutSubviews` 開頭寫 tabView frame + call stack 到 `/tmp/tidey-layout.log`，確認是否有多次 layout pass。

### NSOutlineView horizontal scroll
NSOutlineView 的 document view 會自動撐大。設 `hasHorizontalScroller = NO` 和 `horizontalScrollElasticity = NSScrollElasticityNone` 不夠。需要：
1. 用 `NSScrollView` subclass override `scrollWheel:` 把水平 delta 歸零
2. 在 layout 時同步 column width 到 `contentSize.width`
3. 設 `columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle`

## Shell Integration

### .zshrc 會重建 PATH
Shell integration 在 `.zshenv` 時載入，`.zshrc` 之後重建 PATH 會覆蓋注入的 `TIDEY_BIN_DIR`。

**正確做法**：用 one-shot `precmd` hook，在所有 startup 完成後 remove-then-prepend。

### tmux 裡 shell integration 不自動載入
iTerm2 的 ZDOTDIR 注入只對直接啟動的 shell 有效。tmux 裡的 shell 由 tmux 啟動，不會被注入。

**正確做法**：首次啟動時自動安裝 source 行到 `.zshrc` + 設 `LC_TERMINAL=Tidey` + `ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX=Yes`。

### TERM_PROGRAM 在 tmux 裡變成 "tmux"
Shell integration 的 guard 檢查 `TERM_PROGRAM == "iTerm.app"`，在 tmux 裡失敗。

**正確做法**：加 `LC_TERMINAL == "Tidey"` 作為備用條件。
