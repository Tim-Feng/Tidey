# AppKit Quick Reference for Tidey

Tidey 專案常用 AppKit UI 元件的關鍵 API、行為特性、常見坑整理。

---

## 1. NSTableView

> Apple 文件: [NSTableView](https://developer.apple.com/documentation/appkit/nstableview)

### Style (macOS 11+)

| Style | 說明 |
|---|---|
| `.automatic` | 預設值。根據 context 自動選擇：sidebar 內 → sourceList；bordered scroll view 內 → fullWidth；其他 → inset |
| `.inset` | 額外水平 padding、較高預設 row height、wider spacing |
| `.fullWidth` | selection 從邊到邊（與 Catalina 以前相同） |
| `.sourceList` | sidebar source list 外觀，帶圓角 selection highlight |

```objc
tableView.style = NSTableViewStyleSourceList;
// 讀取實際解析結果
NSTableViewStyle resolved = tableView.effectiveStyle;
```

### selectionHighlightStyle（已部分 deprecated）

- `NSTableViewSelectionHighlightStyleRegular` — 標準藍色/灰色 highlight
- `NSTableViewSelectionHighlightStyleSourceList` — **deprecated（macOS 11+）**，改用 `style = .sourceList`
- `NSTableViewSelectionHighlightStyleNone` — 不繪製 selection

設定 sourceList highlight style 會自動改變 `draggingDestinationFeedbackStyle` 為 sourceList。

### 關鍵 Method

| Method | 說明 |
|---|---|
| `makeViewWithIdentifier:owner:` | 從 reuse queue 或 nib 建立/取得 cell view |
| `rowViewAtRow:makeIfNecessary:` | 取得指定 row 的 NSTableRowView |
| `reloadData` / `reloadDataForRowIndexes:columnIndexes:` | 重新載入資料 |
| `selectRowIndexes:byExtendingSelection:` | 程式化選取 |

### 常見坑

- **Source list style 的 selection 由系統用 NSVisualEffectView 繪製**（macOS 11+）。系統會在 row view 內部插入一個 `NSVisualEffectView`（material 為 "Generic Match Appearance"）來畫 selection highlight，而不一定呼叫 row view 的 `drawSelection(in:)`。
- 如果 table view 嵌套在 `NSVisualEffectView` 內並設了透明背景，Big Sur 上 selection 可能變透明（Catalina 不會）。
- `.automatic` style 在 SDK 升級後行為可能改變——建議明確指定 style。
- View-based table view 只有可見區域的 view 存在，scroll 時會 recycle（reuse queue 機制）。

---

## 2. NSTableRowView

> Apple 文件: [NSTableRowView](https://developer.apple.com/documentation/appkit/nstablerowview)

### 關鍵 Property

| Property | 型別 | 說明 |
|---|---|---|
| `isSelected` | `BOOL` | row 是否被選取 |
| `isEmphasized` | `BOOL` | table 是否為 first responder。YES → 使用 accent color（藍色等）；NO → 使用灰色 |
| `selectionHighlightStyle` | enum | 繼承自 table view 的 selection highlight style |
| `interiorBackgroundStyle` | `NSBackgroundStyle` | **唯讀、動態計算**。告訴 cell view 應使用淺色或深色文字。`.dark` → 用淺色文字；`.normal`/`.light` → 用深色文字 |
| `isGroupRowStyle` | `BOOL` | 是否為 group row |
| `isFloating` | `BOOL` | group row 是否浮動在內容上方 |
| `backgroundColor` | `NSColor` | 自訂 row 背景色 |

### 繪製 Method（可 override）

| Method | 說明 |
|---|---|
| `drawSelection(in:)` / `drawSelectionInRect:` | 繪製 selection highlight。override 此方法可自訂 selection 顏色/形狀 |
| `drawBackground(in:)` / `drawBackgroundInRect:` | 繪製 row 背景 |
| `drawSeparator(in:)` / `drawSeparatorInRect:` | 繪製 row 底部分隔線 |
| `drawDraggingDestinationFeedback(in:)` | 繪製拖放目標反饋 |

### View 層級

```
NSTableRowView
  ├── NSTableCellView (column 0)
  ├── NSTableCellView (column 1)
  └── ...（每個 column 一個 subview）
```

Row view 的 cell view 是透過 `addSubview:` 加入的普通 subview。可以是任何 NSView 子類，不限於 NSTableCellView。

### 常見坑

- **Source list style (macOS 11+)**: 系統不一定呼叫 `drawSelection(in:)`，而是插入一個內部 `NSVisualEffectView` 來繪製 selection。要自訂 source list selection，需要攔截 subview 的加入（override `addSubview:` 或 `didAddSubview:`），移除或隱藏系統插入的 NSVisualEffectView，再用自己的 view 繪製。
- **isEmphasized 與顏色選擇**: override `drawSelection(in:)` 時應檢查 `self.isEmphasized`：
  - `YES` → 使用 `selectedContentBackgroundColor`（accent color）
  - `NO` → 使用 `unemphasizedSelectedContentBackgroundColor`（灰色）
- `interiorBackgroundStyle` 是動態計算的，會自動傳播給 cell view 的 `backgroundStyle`。不要手動設定 cell view 的 backgroundStyle。
- Row view 的 frame 由 table view 控制，不需要手動指定。

---

## 3. NSTableCellView

> Apple 文件: [NSTableCellView](https://developer.apple.com/documentation/appkit/nstablecellview)

### 關鍵 Property

| Property | 型別 | 說明 |
|---|---|---|
| `textField` | `NSTextField?` | IBOutlet — 主文字欄位。自動用於 VoiceOver accessibility |
| `imageView` | `NSImageView?` | IBOutlet — 主圖示 |
| `objectValue` | `id` | 由 table view 自動設定（binding 或 dataSource method 的回傳值）。支援 KVO |
| `backgroundStyle` | `NSBackgroundStyle` | 由 row view 的 `interiorBackgroundStyle` 自動設定。`.dark` 時應用淺色文字 |
| `rowSizeStyle` | `NSTableViewRowSizeStyle` | row 的尺寸風格 |
| `draggingImageComponents` | `[NSDraggingImageComponent]` | 自動提供拖拽圖片（icon + label） |

### 基本用法

```objc
- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)column
                   row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
    cell.textField.stringValue = myData[row];
    cell.imageView.image = myIcon;
    return cell;
}
```

### 常見坑

- `textField` 和 `imageView` 是 IBOutlet，需要在 IB 中連線。如果用純 code 建立，必須手動 addSubview 並設定 outlet。
- 要增加額外控制項，需 subclass NSTableCellView 並新增 outlet property。
- 有 `drawsBackground` 屬性的 cell 應設為 NO，否則會覆蓋 table view 的 highlight 繪製。
- `objectValue` 支援 KVO，cell 的 subview 可以 bind 到 `cellView.objectValue.someProperty`。

---

## 4. NSColor — Semantic Colors

> Apple 文件: [NSColor](https://developer.apple.com/documentation/appkit/nscolor)

### Selection 相關

| Color | 說明 |
|---|---|
| `selectedContentBackgroundColor` | 選取內容的背景色（跟隨 accent color）。用於 table view emphasized selection |
| `unemphasizedSelectedContentBackgroundColor` | 非 emphasized 狀態的選取背景（灰色）。window 不是 key 或 view 不是 first responder 時使用 |
| `alternateSelectedControlColor` | **deprecated** — 改用 `selectedContentBackgroundColor` |
| `secondarySelectedControlColor` | **deprecated** — 改用 `unemphasizedSelectedContentBackgroundColor` |

### Accent / Control 相關

| Color | 說明 |
|---|---|
| `controlAccentColor` | 使用者目前的 accent color 偏好設定。用於自訂控制項要跟隨系統 accent |
| `controlBackgroundColor` | 控制項背景（如 text field 背景） |
| `controlColor` | 控制項表面 |
| `selectedControlColor` | 被選取的控制項顏色 |

### 內容 / 文字相關

| Color | 說明 |
|---|---|
| `labelColor` | 主要 label 文字色 |
| `secondaryLabelColor` | 次要 label 文字色 |
| `tertiaryLabelColor` | 第三層 label 文字色 |
| `quaternaryLabelColor` | 第四層 label 文字色 |
| `textColor` | 一般文字色 |
| `textBackgroundColor` | 文字背景色 |
| `selectedTextColor` | 選取文字的前景色 |
| `selectedTextBackgroundColor` | 選取文字的背景色（跟隨系統 highlight color） |

### 背景相關

| Color | 說明 |
|---|---|
| `windowBackgroundColor` | 視窗背景 |
| `underPageBackgroundColor` | 翻頁底下的背景 |
| `alternatingContentBackgroundColors` | 交替 row 背景色陣列（2 色） |

### 關鍵行為

- **Dynamic resolution at draw time**: NSColor 的 semantic colors 在繪製時才解析為實際 RGBA 值，會根據當時的 effective appearance 自動切換 dark/light。
- 不要在 `init` 中將 semantic color 轉為 CGColor 賦給 layer——appearance 改變時不會更新。
- Desktop tint（桌布色調）是非同步由 Window Server 渲染的，讀取 RGB 值不會包含 tint 效果。

### 常見坑

- 手動建立的 `NSAttributedString` 如果沒指定 `foregroundColor`，預設是黑色（即使在 dark mode）。務必使用 semantic color 或透過 NSTextField/NSTextView 自動處理。
- `controlAccentColor` 跟隨系統 accent 設定，不要和 `systemBlueColor` 混用——後者永遠是藍色。

---

## 5. NSAppearance

> Apple 文件: [NSAppearance](https://developer.apple.com/documentation/appkit/nsappearance)

### 關鍵 Property

| Property | 說明 |
|---|---|
| `NSApp.effectiveAppearance` | App 層級的當前外觀 |
| `view.effectiveAppearance` | 考慮繼承鏈後的實際外觀（唯讀） |
| `view.appearance` | 可設定。設為特定 appearance 會鎖定該 view 及其 subview。設為 `nil` 恢復繼承 |
| `NSAppearance.currentDrawing()` / `.current` | 繪製時的 thread-local 當前外觀 |

### Dark/Light Mode 偵測

```objc
NSAppearanceName bestMatch = [self.effectiveAppearance
    bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
BOOL isDark = [bestMatch isEqualToString:NSAppearanceNameDarkAqua];
```

使用 `bestMatchFromAppearancesWithNames:` 而非直接比對 name 字串——這樣能正確處理 high contrast 等變體。

### Per-View Appearance

```objc
// 鎖定某個 view 為 dark mode
view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

// 恢復跟隨系統
view.appearance = nil;
```

Appearance 沿 view hierarchy 向下繼承。Window 的 appearance 傳播到所有 subview。

### 回應 Appearance 變化

1. **NSView override**: `viewDidChangeEffectiveAppearance` — appearance 變化後立即呼叫。不需要在此觸發 view invalidation（AppKit 自動處理）。
2. **KVO**: 觀察 `view.effectiveAppearance` 或 `NSApp.effectiveAppearance`。
3. **自訂 Notification**: 在 KVO callback 中 post 自訂 notification 到 NotificationCenter，讓非 view 元件也能收到。

### 安全的 Appearance 查詢時機

只在以下 NSView method 中查詢/解析 appearance 相關的值（此時 `NSAppearance.current` 正確）：

- `updateConstraints`
- `layout`
- `draw(_:)` / `drawRect:`
- `updateLayer`

在其他時機查詢可能取得 stale 結果。

### 常見坑

- **IB 意外鎖定**: Interface Builder 可能意外設定了 appearance 為 aqua，導致 dark mode 失效。檢查 IB 中是否設為 "Inherited"。
- **Sublayer 不繼承 appearance**: 自訂的 CALayer sublayer 不會自動適應 appearance 變化。需要在 `viewDidChangeEffectiveAppearance` 中手動更新，或改用 subview。
- **Vibrant appearance 誤用**: 在 dark mode 下手動設定 `vibrantLight` 外觀會導致文字/圖片不可讀。
- Child window 可以使用 `appearanceSource` 屬性從特定 view 繼承 appearance（而非手動同步）。

---

## 6. NSNotificationCenter (NotificationCenter)

> Apple 文件: [NotificationCenter](https://developer.apple.com/documentation/foundation/notificationcenter)

### 基本 Observer Pattern

```objc
// 添加 observer（selector 方式）
[[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(handleThemeChange:)
           name:@"TideyThemeDidChangeNotification"
         object:nil];

// 添加 observer（block 方式，推薦）
id token = [[NSNotificationCenter defaultCenter]
    addObserverForName:@"TideyThemeDidChangeNotification"
                object:nil
                 queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
    // 處理 theme 變化
}];

// 發送 notification
[[NSNotificationCenter defaultCenter]
    postNotificationName:@"TideyThemeDidChangeNotification"
                  object:self
                userInfo:@{@"isDark": @(isDark)}];
```

### 移除 Observer

```objc
// selector 方式
[[NSNotificationCenter defaultCenter] removeObserver:self];

// block 方式（用 token）
[[NSNotificationCenter defaultCenter] removeObserver:token];
```

### Theme Change 偵測相關 Notification

| Notification | 說明 |
|---|---|
| `NSSystemColorsDidChangeNotification` | 系統顏色改變時發送（包含 accent color 變更） |
| `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification` | Accessibility 顯示設定變更（如 high contrast） |
| 自訂 notification | 透過 KVO 觀察 `effectiveAppearance`，在 callback 中 post 自訂 notification |

### 建議的 Theme Change 通知架構

AppKit 沒有內建的 "appearance did change" notification。建議作法：

1. 在 app 啟動時 KVO 觀察 `NSApp.effectiveAppearance`
2. 變化時 post 自訂 `TideyThemeDidChangeNotification`
3. 各元件 observe 此 notification 更新 UI

### 常見坑

- Block-based observer 回傳的 token 必須保存並在適當時機 removeObserver，否則會 leak。
- macOS 下 notification 預設在 posting thread 上 deliver。指定 `queue:` 可確保在主執行緒處理 UI 更新。
- KVO 觀察 `effectiveAppearance` 要求 view 在 view hierarchy 中且可見，獨立 view 不會收到更新。

---

## 7. NSPopUpButton

> Apple 文件: [NSPopUpButton](https://developer.apple.com/documentation/appkit/nspopupbutton)

### 關鍵 Property

| Property | 說明 |
|---|---|
| `pullsDown` | `YES` → pull-down menu 模式；`NO` → pop-up list 模式（預設） |
| `selectedItem` | 目前選取的 NSMenuItem |
| `indexOfSelectedItem` | 目前選取項目的 index（-1 = 無選取） |
| `selectedTag` | 目前選取項目的 tag |
| `itemArray` | 所有 menu items |
| `numberOfItems` | item 數量 |
| `isBordered` | 設為 NO 可移除邊框 |

### 關鍵 Method

| Method | 說明 |
|---|---|
| `addItemWithTitle:` | 新增一個 item |
| `addItemsWithTitles:` | 批次新增 items |
| `removeAllItems` | 移除所有 items |
| `removeItemAtIndex:` | 移除指定 index 的 item |
| `selectItemWithTitle:` | 依 title 選取 |
| `selectItemWithTag:` | 依 tag 選取 |
| `selectItemAtIndex:` | 依 index 選取 |
| `itemWithTitle:` | 依 title 取得 NSMenuItem |
| `indexOfItemWithTitle:` | 依 title 取得 index（-1 = 不存在） |

### Action Handling

```objc
[popup setTarget:self];
[popup setAction:@selector(popupChanged:)];

- (void)popupChanged:(NSPopUpButton *)sender {
    NSInteger selectedIndex = sender.indexOfSelectedItem;
    NSString *selectedTitle = sender.titleOfSelectedItem;
}
```

### 常見坑

- 用 `addItemsWithTitles:` 建立的 item，其 action/target 需要**個別設定**（不會自動設定）。
- Pull-down 模式下，第一個 item 顯示為按鈕標題，不是選取項目。
- NSPopUpButton 繼承自 NSButton，底層使用 NSPopUpButtonCell 和 NSMenu。

---

## 8. NSPanel

> Apple 文件: [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)

### 概述

NSPanel 是 NSWindow 的子類，適合用於輔助/工具視窗。與普通 window 的差異：

- 不出現在 Window menu
- App 非 active 時自動隱藏
- 可以在 responder chain 中排在 main window 之前
- ESC 鍵可以關閉

### 關鍵 Property

| Property | 說明 |
|---|---|
| `becomesKeyOnlyIfNeeded` | `YES` → 只在需要時（如點擊 text field）才成為 key window |
| `isFloatingPanel` | `YES` → 浮動在其他 window 上方 |
| `worksWhenModal` | `YES` → modal session 期間仍可操作 |

### StyleMask 選項

| StyleMask | 說明 |
|---|---|
| `NSWindowStyleMaskTitled` | 有標題列 |
| `NSWindowStyleMaskClosable` | 有關閉按鈕 |
| `NSWindowStyleMaskMiniaturizable` | 有最小化按鈕 |
| `NSWindowStyleMaskResizable` | 可調整大小 |
| `NSWindowStyleMaskUtilityWindow` | Utility window 外觀（窄標題列、小字標題） |
| `NSWindowStyleMaskNonactivatingPanel` | 不會 activate owning app（浮動工具列/palette 用） |
| `NSWindowStyleMaskHUDWindow` | HUD 半透明面板風格 |

### Settings Window 典型設定

```objc
NSPanel *panel = [[NSPanel alloc]
    initWithContentRect:rect
              styleMask:NSWindowStyleMaskTitled |
                        NSWindowStyleMaskClosable |
                        NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered
                  defer:YES];
panel.title = @"Settings";

// 如果是 inspector 風格（不搶 key window）
panel.becomesKeyOnlyIfNeeded = YES;
panel.styleMask |= NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel;
```

### 常見坑

- `NSWindowStyleMaskNonactivatingPanel` 單獨設定不夠——通常需要搭配 `becomesKeyOnlyIfNeeded = YES` 和 `panel.level = NSFloatingWindowLevel`。
- Panel 預設在 app deactivate 時隱藏。若要保持可見，需設定 `hidesOnDeactivate = NO`。
- 使用 `NSWindowStyleMaskUtilityWindow` 會讓標題列變窄、字變小——適合 inspector/palette 但不適合主要 settings window。

---

## 9. NSUserDefaults (UserDefaults)

> Apple 文件: [NSUserDefaults](https://developer.apple.com/documentation/foundation/nsuserdefaults)

### 基本讀寫

```objc
NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

// 寫入
[defaults setObject:@"dark" forKey:@"TideyTheme"];
[defaults setBool:YES forKey:@"TideyShowSidebar"];
[defaults setInteger:14 forKey:@"TideyFontSize"];

// 讀取
NSString *theme = [defaults stringForKey:@"TideyTheme"];
BOOL showSidebar = [defaults boolForKey:@"TideyShowSidebar"];
NSInteger fontSize = [defaults integerForKey:@"TideyFontSize"];
```

### registerDefaults — 設定預設值

```objc
[[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"TideyTheme": @"auto",
    @"TideyShowSidebar": @YES,
    @"TideyFontSize": @(14)
}];
```

- 可以多次呼叫，dictionary 會合併
- 只是 fallback——使用者一旦設定就會覆蓋
- 不會寫入磁碟
- 建議將 registerDefaults 放在靠近使用該設定的程式碼旁邊

### KVO 觀察

```objc
// 觀察特定 key
[defaults addObserver:self
           forKeyPath:@"TideyTheme"
              options:NSKeyValueObservingOptionNew
              context:NULL];

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"TideyTheme"]) {
        [self applyTheme];
    }
}
```

### NSUserDefaultsDidChangeNotification

```objc
[[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(defaultsChanged:)
           name:NSUserDefaultsDidChangeNotification
         object:nil];
```

- 任何 key 變化都會觸發（不分辨哪個 key）
- **只**在同一 process 內的變更會觸發
- 外部 process 或 ubiquitous defaults 的變更**不會**觸發
- 需要追蹤特定 key 的變更，用 KVO 更精確

### 常見坑

- **`synchronize` 已 deprecated（macOS 10.12+）**。不再需要呼叫。系統自動在適當時機同步。
- `registerDefaults:` 的值不會出現在 `dictionaryRepresentation` 中——只有使用者實際設定的值才會。
- NSUserDefaults 是 thread-safe 的，可以從任何 thread 讀寫。
- 不要存放大量資料或敏感資料在 UserDefaults（用 Keychain 存密碼/token）。
- `boolForKey:` 在 key 不存在時回傳 `NO`——如果預設值是 `YES`，務必用 `registerDefaults:` 設定。

---

## 10. NSVisualEffectView

> Apple 文件: [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)

### 概述

提供半透明毛玻璃效果的 view。用於 sidebar 背景、titlebar、popover 等。

### 關鍵 Property

| Property | 說明 |
|---|---|
| `material` | 毛玻璃材質（見下表） |
| `blendingMode` | `.behindWindow`（預設）→ 模糊窗口後方內容；`.withinWindow` → 模糊窗口內的內容 |
| `state` | `.followsWindowActiveState`（預設）→ 跟隨 window active/inactive；`.active` → 永遠 active；`.inactive` → 永遠 inactive |
| `maskImage` | 用 alpha channel 遮罩材質形狀 |
| `isEmphasized` | 是否使用 emphasized 外觀 |

### Semantic Materials（推薦使用）

| Material | 說明 |
|---|---|
| `.sidebar` | Sidebar 背景 |
| `.headerView` | Header 區域 |
| `.contentBackground` | 內容區域背景 |
| `.windowBackground` | 視窗背景 |
| `.underPageBackground` | 翻頁底下區域 |
| `.menu` | Menu 背景 |
| `.popover` | Popover 背景 |
| `.titlebar` | 標題列 |

### Non-Semantic Materials（避免使用）

`.light`, `.dark`, `.mediumLight`, `.ultraDark` 等 — **deprecated**。不會自動適應 dark/light mode。

### Sidebar 用法

```objc
NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:frame];
effectView.material = NSVisualEffectMaterialSidebar;
effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
effectView.state = NSVisualEffectViewStateFollowsWindowActiveState;
```

### Desktop Tinting（macOS 10.14+）

Mojave 起，某些 material 會從桌布取色做 tint。此效果由 Window Server 非同步渲染：

- 讀取 color 的 RGB 值**不會包含** desktop tint
- 無法直接用 Quartz drawing 繪製含 tint 的顏色
- 要做自訂形狀的 tinted 材質，使用 `maskImage`（只用 alpha channel）

### 常見坑

- NSVisualEffectView 放在 NSTableView 底層時，table view 的 scroll view 和 clip view 需要設為透明背景（`drawsBackground = NO`），table view 的 `backgroundColor` 設為 `clearColor`。
- macOS 11 上，上述透明設定可能導致 source list selection 也變透明（系統用 NSVisualEffectView 畫 selection，被透明背景影響）。
- `state` 預設跟隨 window active state——window inactive 時材質自動變淡。如果要保持 active 外觀，明確設為 `.active`。
- 不要在 NSVisualEffectView 上再疊另一個不透明 view 覆蓋整個區域——會讓毛玻璃效果失去意義且浪費效能。
- `maskImage` 只使用 alpha channel，RGB 被忽略。可以用 `NSImage(size:flipped:drawingHandler:)` 動態產生。

---

## 附錄：相關 WWDC Sessions

| Session | 主題 |
|---|---|
| [WWDC 2011 Session 120](https://asciiwwdc.com/2011/sessions/120) | View Based NSTableView Basic to Advanced |
| [WWDC 2018 Session 210](https://asciiwwdc.com/2018/sessions/210) | Introducing Dark Mode |
| [WWDC 2018 Session 218](https://asciiwwdc.com/2018/sessions/218) | Advanced Dark Mode |
| [WWDC 2020 Session 10104](https://developer.apple.com/videos/play/wwdc2020/10104/) | Adopt the New Look of macOS |

## 附錄：快速查找 Apple 文件連結

- [NSTableView](https://developer.apple.com/documentation/appkit/nstableview)
- [NSTableRowView](https://developer.apple.com/documentation/appkit/nstablerowview)
- [NSTableCellView](https://developer.apple.com/documentation/appkit/nstablecellview)
- [NSColor](https://developer.apple.com/documentation/appkit/nscolor)
- [NSAppearance](https://developer.apple.com/documentation/appkit/nsappearance)
- [NotificationCenter](https://developer.apple.com/documentation/foundation/notificationcenter)
- [NSPopUpButton](https://developer.apple.com/documentation/appkit/nspopupbutton)
- [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [NSUserDefaults](https://developer.apple.com/documentation/foundation/nsuserdefaults)
- [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
