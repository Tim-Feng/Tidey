# Theme Token Map

將 Tidey UI 元件的硬編碼色碼對應到語意 token，作為 theme system 替換的依據。

## 版面區域總覽

```
┌─────────────────────────────────────────────────────────┐
│ Title Bar                                    timfeng@.. │
├────────┬────────────────┬───────────────┬───────────────┤
│        │ Terminal Tab   │ Editor Tab    │               │
│        │ ══focus bar══  │ (start-cl.. ×)│               │
│        ├────────────────┤───────────────┤               │
│Sidebar │                │               │               │
│        │  Terminal      │  Editor       │  File Tree    │
│ work-  │  Panel         │  Panel        │  (右側)       │
│ spaces │                │               │               │
│ + idle │                │  (code view)  │  Applications │
│ status │                │               │  Desktop      │
│        │                │               │  ...          │
└────────┴────────────────┴───────────────┴───────────────┘
         ↑                ↑               ↑
     tab bar 背景     editor tab 欄    file tree 容器
     (bgSurface)      (bgBase)         (bgSurface)
```

### 背景色的角色說明

- **bgBase** — 主內容區底色（最暗）。用於 terminal content、editor content、tab 欄
- **bgSurface** — 次級面板底色。用於 sidebar、file tree、terminal tab bar
- **bgControl** — 可互動控制元件底色。用於 browser toolbar、URL 欄、shortcut hints
- **bgHover** — 疊加在任何背景上的 hover 態（半透明白/黑）

### 同色碼 / 近似色碼的區分

以下三列看起來接近，但角色不同：

| 色碼 | 角色 | 何時設定 |
|------|------|---------|
| :1454 `#171A21` | Editor tab 欄背景 | `initWithFrame:` 初始化時 |
| :3741 `#1A1C22` | Editor tab 欄背景 | `tideyLayoutActiveEditorGroups` layout 時重設 |
| :4863 `#171A21` | Terminal tab bar gap 補色 | `layoutSubviewsWithVisibleTopTabBarForWindow:` 填補間隙 |

三個都是 bgBase 角色，只是在不同時機設定。替換時統一用同一個 token 即可。

## iTermRootTerminalView.m

### 背景色

| UI 區域 | 行號 | 目前色碼 | 對應 token | 狀態 | 備註 |
|---------|------|---------|-----------|------|------|
| Sidebar 背景 | 1381 | `SRGB(0.11, 0.12, 0.15)` #1C1F26 | bgSurface | 待替換 | 左側面板 |
| Editor 面板背景 | 1444 | `SRGB(0.10, 0.11, 0.14)` #191D24 | bgBase | 待替換 | 程式碼編輯區 |
| Editor tab 欄背景 (init) | 1454 | `SRGB(0.09, 0.10, 0.13)` #171A21 | bgBase | 待替換 | 初始化時設定 |
| File tree 容器背景 | 1479 | `SRGB(0.12, 0.13, 0.17)` #1E212C | bgSurface | 待替換 | 右側檔案樹 |
| Tab bar gap 補色 | 4863 | `SRGB(0.09, 0.10, 0.13)` #171A21 | bgBase | 待替換 | 填補頂部間隙 |
| Editor tab 欄背景 (layout) | 3741 | `SRGB(0.102, 0.108, 0.135)` #1A1C22 | bgBase | 待替換 | layout 時重設 |
| 瀏覽器工具欄背景 | 2969 | `White(0.15)` #262626 | bgControl | 待替換 | browser toolbar |
| 瀏覽器 URL 欄背景 | 3006 | `White(0.22)` #383838 | bgControl | 待替換 | URL input field |
| 快捷鍵提示容器背景 | 968 | `SRGB(0.075, 0.102, 0.129)` #132120 | bgControl | 待替換 | shortcut hint |
| 面板快捷鍵提示背景 | 987 | `SRGB(0.075, 0.102, 0.129)` #132120 | bgControl | 待替換 | panel hint |

### 文字色

| UI 區域 | 行號 | 目前色碼 | 對應 token | 備註 |
|---------|------|---------|-----------|------|
| Editor tab 文字 | 1466 | `White(0.92)` #EBEBEB | textPrimary | tab 標題 |
| 檔案樹標題文字 | 5214 | `White(0.92)` #EBEBEB | textPrimary | file tree cell |
| 快捷鍵提示文字 | 956 | `White(1.0, a:0.9)` | textPrimary | shortcut label |
| 面板提示文字 | 995 | `White(1.0, a:0.9)` | textPrimary | panel hint label |
| 副標題文字 | 5551 | `White(0.72)` #B8B8B8 | textSecondary | sidebar subtitle |
| 檔案樹圖示 | 5195 | `White(0.78)` #C7C7C7 | textSecondary | file icon tint |
| 釘子圖示 | 5528 | `White(0.90)` #E5E5E5 | textPrimary | pin icon |
| 選中行文字 | 5697 | `White(1.0, a:0.8)` | textPrimary | selected row |
| 選中副標題 | 5704 | `White(1.0, a:0.8)` | textPrimary | selected subtitle |
| 未選中副標題 | 5725 | `White(0.72)` #B8B8B8 | textSecondary | unselected subtitle |
| 狀態文字(選中) | 5760 | `White(1.0, a:0.8)` | textPrimary | status text |

### 邊框 / 分隔線

| UI 區域 | 行號 | 目前色碼 | 對應 token | 備註 |
|---------|------|---------|-----------|------|
| 列表行分隔線 | 608 | `White(0.25)` #404040 | borderDefault | table row separator |
| 快捷鍵提示邊框 | 969 | `White(1.0, a:0.25)` | borderDefault | hint border |
| 面板提示邊框 | 988 | `White(1.0, a:0.25)` | borderDefault | panel hint border |
| 視窗邊框 | 1654 | `White(0.5, a:0.75)` | borderStrong | window border |

### Hover / 互動狀態

| UI 區域 | 行號 | 目前色碼 | 對應 token | 備註 |
|---------|------|---------|-----------|------|
| 列表行 hover 背景 | 596 | `White(1, a:0.06)` | bgHover | table row hover |
| 按鈕文字(未懸停) | 940 | `White(0.50, a:0.25)` | textTertiary | toggle button |
| 按鈕懸停文字 | 1327 | `White(0.92)` #EBEBEB | textPrimary | button hover |
| 按鈕離開文字 | 1339 | `White(0.50, a:0.25)` | textTertiary | button exit |
| 編輯器按鈕背景 | 3782 | `White(1, a:0.08)` | bgHover | editor group btn |
| 徽章背景(未選中) | 5634 | `White(1, a:0.25)` | bgHover | badge bg |
| 快捷鍵提示背景 | 5598 | `White(1.0, a:0.12)` | bgHover | shortcut hint bg |

### Tab 分隔線 (依 appearance)

| UI 區域 | 行號 | 目前色碼 | 對應 token | 備註 |
|---------|------|---------|-----------|------|
| Light, Key | 2569 | `HSB(1,0,0.70)` | lineHairline | tab division |
| Light, Non-Key | 2570 | `HSB(1,0,0.86)` | lineHairline | tab division |
| Dark, Key | 2576 | `HSB(1,0,0.10)` | lineHairline | tab division |
| Dark, Non-Key | 2577 | `HSB(1,0,0.07)` | lineHairline | tab division |

## PSMMinimalTabStyle.m

| UI 區域 | 行號 | 目前色碼 | 對應 token | 狀態 | 備註 |
|---------|------|---------|-----------|------|------|
| Tab bar 背景 | 14 | `SRGB(0.102, 0.108, 0.135)` #1A1C22 | bgSurface | ✅ 已替換 | |
| Focus indicator | 216 | → `currentTheme.accentIndicator` | accentIndicator | ✅ 已替換 | |
| 未選中 tab 背景 | 178 | `SRGB(0.14, 0.15, 0.19)` #242630 | bgControl | 待替換 | inactive tab |
| 分隔線 | 152 | `White(0.25)` #404040 | borderDefault | 待替換 | tab separator |
| 配件填充色 | 200 | `White(0.27)` #454545 | textTertiary | 待替換 | accessory fill |
| 配件邊框色 | 204 | `White(0.12)` #1F1F1F | borderDefault | 待替換 | accessory stroke |

## 尚未收錄的 UI 元件

以下元件已知存在但未列入上方表格，需要補充路徑：

- **Terminal tab 未讀藍點** — 不在 PSMMinimalTabStyle.m，可能在 PSMTabBarCell 或 PTYTab 的 icon path
- **Sidebar workspace 選中態背景** — 可能在 TideyTableRowView 或 NSTableView selection
- **Editor panel "Loading Editor..." 文字** — iTermRootTerminalView.m 的 `_tideyEditorPanelLabel`

## Accent 語意說明

| Token | 角色 | 靜水深流 | 櫻花爛漫 |
|-------|------|---------|---------|
| accentPrimary | 主要互動色（badge、連結、小型 UI） | 水浅葱 #70C5BA | 今様 #D05A6E |
| accentMuted | 低調版 accent（次要互動） | 錆浅葱 #5C9291 | 撫子 #DC9FB4 |
| accentIndicator | **高對比指示線**（focus bar 等 2px 線條） | 千草 #3A8FB7 | 一斤染 #F4A7B9 |
| lineActive | 活躍分隔線 | 水浅葱 #70C5BA | 今様 #D05A6E |

### 問題：櫻花爛漫的 accentIndicator 對比不足

目前 accentIndicator 用一斤染 `#F4A7B9`（淺粉），但 tab bar 背景在 light theme 是白練 `#FCFAF2`（近白）。
兩者亮度差太小，2px 線條看不清楚。

**建議**：accentIndicator 在 light theme 應該用更深、更飽和的色（具體色碼待 front-end design 決定），
讓對比度達到和靜水深流相同的水準（dark: 千草 #3A8FB7 對 #1C1F26 ≈ 高對比）。

## 視覺層級關係

### 靜水深流 (dark theme)

```
亮度由暗到亮：

背景層：
  bgBase    #171A21  (最暗，主內容區)
  bgSurface #1C1F26  (次暗，sidebar/file tree/tab bar)
  bgControl #262626  (控制元件，toolbar)
  bgHover   white@6-12%  (hover 疊加)

文字層：
  textTertiary  white@25%  (最淡，disabled/hint)
  textSecondary #B8B8B8    (次要文字)
  textPrimary   #EBEBEB    (主要文字)

邊框層：
  borderDefault #404040 / white@25%
  borderStrong  white@75%

Accent 層：
  accentIndicator  #3A8FB7  (高對比指示線)
  accentPrimary    #70C5BA  (互動色)
  accentMuted      #5C9291  (低調互動)
```

### 櫻花爛漫 (light theme) — 需維持同等相對對比

```
亮度由亮到暗（和 dark 反轉）：

背景層：
  bgBase    #FCFAF2  (最亮，主內容區)
  bgSurface #FEDFE1  (次亮，sidebar/tab bar)
  ⚠️ light theme 的 sidebar 和 tab bar 未必該同亮度，
     可能需要拆成 bgSurfaceSidebar / bgSurfaceTabBar
  bgControl #F2E8D0  (控制元件)
  bgHover   black@6-12%  (hover 疊加，和 dark 反轉)

文字層：
  textTertiary  #B19693  (最淡)
  textSecondary #9E7A7A  (次要文字)
  textPrimary   #563F2E  (主要文字)

邊框層：
  borderDefault  umenezumi@25%
  borderStrong   sakuranezumi@45%

Accent 層：（⚠️ 需要調整）
  accentIndicator  → 待 front-end design 決定（需高對比）
  accentPrimary    #D05A6E
  accentMuted      #DC9FB4
```

## 替換進度

### PSMMinimalTabStyle.m
- [x] focus indicator → accentIndicator
- [x] tab bar 背景 → bgSurface
- [ ] 未選中 tab 背景 → bgControl
- [ ] 分隔線 → borderDefault
- [ ] 配件填充色 → textTertiary
- [ ] 配件邊框色 → borderDefault

### iTermRootTerminalView.m
- [ ] Sidebar 背景 → bgSurface
- [ ] Editor 面板背景 → bgBase
- [ ] Editor tab 欄背景 (init) → bgBase
- [ ] Editor tab 欄背景 (layout) → bgBase
- [ ] File tree 容器背景 → bgSurface
- [ ] Tab bar gap 補色 → bgBase
- [ ] 瀏覽器工具欄背景 → bgControl
- [ ] 瀏覽器 URL 欄背景 → bgControl
- [ ] 快捷鍵提示容器背景 → bgControl
- [ ] 面板快捷鍵提示背景 → bgControl
- [ ] 所有文字色 → textPrimary / textSecondary / textTertiary
- [ ] 所有邊框 → borderDefault / borderStrong
- [ ] 所有 hover 態 → bgHover

### Terminal / Profile 色碼
- [ ] background（終端背景）→ background — iTermProfilePreferences.m:853, PTYSession.m:1365
- [ ] foreground（終端前景文字）→ foreground — iTermProfilePreferences.m:852, PTYSession.m:2179
- [ ] cursor（終端游標）→ cursor — iTermProfilePreferences.m:859, PTYSession.m:5077
- [ ] imeCursor（IME 游標）→ imeCursor — iTermProfilePreferences.m:861, PTYSession.m:5079
- [ ] selection（文字選取反白）→ selection — iTermProfilePreferences.m:857, PTYSession.m:5072

### ANSI 16 色
全部定義在 iTermProfilePreferences.m:862-877，映射在 iTermColorMap.m:542-557
- [ ] ansiBlack ~ ansiWhite（8 色）
- [ ] ansiBrightBlack ~ ansiBrightWhite（8 色）

### 狀態色
- [ ] stateSuccess → 成功 mark — iTermTextDrawingHelper.m:1184 `successMarkColor`
- [ ] stateWarning → 中性 mark — iTermTextDrawingHelper.m:1198 `otherMarkColor`
- [ ] stateError → 失敗 mark — iTermTextDrawingHelper.m:1191 `errorMarkColor`

### 其他分隔線
- [ ] lineHairline → tab division — iTermRootTerminalView.m:2569-2577
- [ ] lineHairline → pane divider — PTYSplitView.m:85 `dividerColor`

### 未收錄（待補路徑）
- [ ] Terminal tab 未讀藍點
- [ ] Sidebar workspace 選中態背景
- [ ] Editor "Loading Editor..." 文字
