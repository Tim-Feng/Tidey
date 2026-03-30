# Tidey Design Language

靜水深流 — Calm Water, Deep Current.

介面退到背景，工作佔前景。

## Scope

DESIGN.md 管所有 Tidey 自繪的 UI surface（chrome、content panel、overlay、browser chrome、chat）和 Tidey 預設 terminal/editor theme。系統原生 AppKit surface（標準 NSMenu、system dialog）維持系統預設，除非明確列在這裡。

## Precedence

Palette token 是 source of truth。Chrome 直接引用 token。Terminal 和 editor 透過 Tidey 預設 iTerm profile + Monaco theme 對齊同一組 palette。

Icon tint 預設繼承 text role（text-primary / text-secondary / text-tertiary），不另建 icon palette。

---

## Principles

### 1. Content speaks, chrome whispers

Chrome（邊框、工具列、狀態列）盡量看不見。Terminal 輸出、editor 程式碼、file tree 結構佔據視覺主體。

### 2. Color is a privilege

預設單色。Teal accent 只用在 active 狀態、focus indicator、通知。不需要被注意的元素不給顏色。

### 3. Natural materials

Neutral 帶海洋色調偏移——偏冷的深藍綠 tinted neutrals，讓畫面有材質感。

### 4. Discover, don't display

功能在需要時才浮現。cmd 長按顯示快捷鍵，cmd+click 觸發 file tree reveal。預設藏起來，用到才出現。

### 5. Breathe

間距寬鬆。導航區域用 proportional type。狀態轉場不急。

---

## Palette

### Background

| Token | Hex | 用途 |
|-------|-----|------|
| `bg-base` | `#0c1117` | Terminal、editor canvas、browser content、chat transcript |
| `bg-surface` | `#131a21` | Sidebar、file tree container、tab bar、status bar |
| `bg-control` | `#1a232d` | URL bar、chat input、code block container、inline pill |
| `bg-hover` | `#ffffff0f` | Sidebar row hover、editor tab hover、file tree row hover |
| `bg-active-subtle` | `#ffffff12` | Active/selected row tint（sidebar、file tree、list）搭配 accent rail + text weight |
| `bg-popover` | `#212b37` | Tooltip、dropdown、popover |
| `bg-overlay` | `#212b37e6` | Cmd overlay、Open Quickly、sheet、toast（90% opacity） |

### Border & Line

| Token | Hex | 用途 |
|-------|-----|------|
| `border-default` | `#1e2830` | Panel 之間分隔（sidebar ↔ terminal ↔ editor） |
| `border-strong` | `#2a3540` | URL bar border、tooltip border、code block border、sheet border |
| `line-hairline` | `#ffffff19` | 1px divider（editor tab separator） |
| `line-active` | `#30D5C8` | 2px active indicator（sidebar active rail、editor active tab top line） |

### Text

| Token | Hex | 用途 |
|-------|-----|------|
| `text-primary` | `#e1e7ef` | 主文字、active workspace title、active tab label、file tree item |
| `text-secondary` | `#8891a0` | Inactive workspace title、inactive tab label、subtitle、notification body |
| `text-tertiary` | `#4d5666` | Status bar、最弱文字 |
| `text-on-accent` | `#ffffff` | Badge 白字、filled accent chip 上的文字 |
| `text-link` | `#30D5C8` | Browser/chat link |

### Accent

| Token | Hex | 用途 |
|-------|-----|------|
| `accent-primary` | `#30D5C8` | Active rail、focus ring、unread dot、active tab line、cursor、URL underline |
| `accent-muted` | `#1a7a6e` | Scrollbar thumb、subtle active ornament |

### Reserved

尚未接上 UI，先定義備用。

| Token | Hex | 用途 |
|-------|-----|------|
| `state-success` | `#34d399` | 成功操作 |
| `state-warning` | `#fbbf24` | 警告 |
| `state-error` | `#f87171` | 錯誤 |
| `text-disabled` | `#333d4a` | 停用狀態 |

---

## Typography

UI 用 proportional font，讓 sidebar 和 file tree 跟一般 terminal app 的 monospace 拉開距離。

### UI / Navigation

**iA Writer Quattro**

Proportional，帶 monospace 基因，字距寬鬆。用在 sidebar、file tree、dialog、status indicator。

- Fallback: iA Writer Duo → SF Pro Text → system sans-serif
- 下載：https://github.com/iaolo/iA-Fonts

### Code / Terminal

**Geist Mono**

用在 terminal、editor、code snippet、shortcut hint label。

- Fallback: JetBrains Mono → SF Mono → system monospace
- 下載：https://github.com/vercel/geist-font

### Type Roles

| Role | 大小 | 字重 | 字體 |
|------|------|------|------|
| `type-nav-primary` | 13pt | Medium (500) | Quattro |
| `type-nav-secondary` | 11pt | Regular (400) | Quattro |
| `type-tab` | 12pt | Regular (400)；active: Semibold (600) | Quattro |
| `type-file-tree` | 12pt | Regular (400) | Quattro |
| `type-status` | 11pt | Regular (400) | Quattro |
| `type-shortcut` | 10pt | Semibold (600) | Geist Mono |
| `type-window-title` | 13pt | Medium (500) | Quattro |
| `type-code` | user-configurable | — | Geist Mono |

---

## Spacing

Base unit: 4px。所有間距是 4 的倍數。

| Token | Value | 用途 |
|-------|-------|------|
| `space-xs` | 4px | Icon 與 label 間距 |
| `space-sm` | 8px | Sidebar item vertical padding、緊湊元素內部 |
| `space-md` | 12px | Sidebar item horizontal padding、元素之間標準距離 |
| `space-lg` | 16px | Panel 內容 padding |
| `space-xl` | 24px | Section 之間 |
| `space-2xl` | 32px | 主要區塊分隔 |

---

## Shape & Size

| Token | Value | 用途 |
|-------|-------|------|
| `radius-sm` | 4px | Shortcut hint pill、small pill |
| `radius-md` | 6px | Badge、small control |
| `radius-lg` | 8px | Active row tint shape、tooltip、popover |
| `radius-xl` | 10px | Dialog、sheet |
| `size-badge` | 16px | Unread count badge 直徑 |
| `size-dot` | 6px | Unread dot、dirty indicator 直徑 |
| `size-drag-handle` | 4px | Panel 拖曳分隔條寬度 |
| `size-scrollbar` | 14px | Monaco scrollbar 寬度 |
| `size-active-rail` | 2px | Sidebar active rail、editor active tab line 寬度 |
| `shadow-popover` | 0 4px 8px rgba(0,0,0,0.5) | Tooltip、popover shadow |
| `shadow-overlay` | 0 8px 24px rgba(0,0,0,0.6) | Sheet、Open Quickly、modal shadow |

---

## Chrome

### 預設顯示

- Window traffic lights（標準 macOS）
- Sidebar（workspace 列表 + file tree）
- Tab bar（terminal tabs + editor tabs）
- Panel 分隔（`border-default` 或背景色差）

### 預設隱藏或最小化

- **Status bar**：minimal mode，只顯示 workspace name + cwd，`text-tertiary`
- **Scrollbar**：overlay style，滾動時出現（`accent-muted`），靜止後 fade out
- **Tooltip**：`bg-popover`、`border-strong`、微量陰影
- **File explorer buttons**：隱藏，用右鍵選單取代
- **Tab close button**：hover 時才顯示
- **Chrome toggle buttons**：預設低透明度，hover 時浮現

### 分隔策略

- Sidebar ↔ Terminal/Editor：`border-default` 或背景色差
- Terminal ↔ Editor：`border-default`
- Editor tab 之間：`line-hairline`
- Sidebar 內部 section：`space-xl` gap

---

## Motion

所有狀態轉換用 fade/slide，不瞬間切換。

| 動作 | Duration | Easing |
|------|----------|--------|
| Hover 背景 | 100ms | ease-out |
| State transition | 150ms | ease-out |
| Panel slide | 200ms | ease-in-out |
| Notification rise | 250ms | ease-out |
| Overlay fade | 150ms | ease-out |

不做：bounce、spring、overshoot、parallax、decorative animation。

---

## References

- [Obsidian Minimal](https://github.com/kepano/obsidian-minimal) — distraction-free theme by kepano
- [Flexoki](https://stephango.com/flexoki) — inky color scheme by Steph Ango
- [jameesy's Obsidian setup](https://x.com/jameesy/status/2036795753096421843) — Minimal + Flexoki + iA Writer Quattro + Geist Mono
- [Impeccable](https://github.com/pbakaus/impeccable) — AI design skill by Paul Bakaus
- [iA Writer Quattro](https://github.com/iaolo/iA-Fonts) — humanistic proportional font
- [Geist Mono](https://github.com/vercel/geist-font) — monospace font by Vercel
