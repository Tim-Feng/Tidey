# Tidey Agent Guide

Tidey 用 Claude Code + Codex 協作開發。

## Roles
- Codex
  - 實作、小範圍修改、按既定計畫逐步落地
- Claude Code
  - audit / review、build / test、repo-wide 掃描、多檔案協調
- 不用 agent 的外部貢獻者也照同樣分工：
  - 一個角色做實作
  - 一個角色做 review / build / regression check

## Read First
- `CLAUDE.md`
  - 專案級規則
- `docs/debug-lessons.md`
  - Tidey 已知坑與 debug checklist
- `docs/theme-token-map.md`
  - 改色、theme token 替換前先看
- `docs/appkit-reference.md`
  - 查 AppKit 行為時先看

## Core Rules
- 先找 owner，再改
  - `iTermRootTerminalView`: sidebar、editor/browser panel、file tree、right-panel tab strip
  - `PseudoTerminal`: window/menu action routing
  - `PSMTabBarControl`: terminal tab bar
  - `PTYSession` / `PTYTextView` / `PTYMouseHandler`: terminal lifecycle、selection、mouse
- 行為改動先找 test seam，不要直接 patch owner
- 沒有 seam 時，先做 structural change，再做 behavioral change
- 一次只改一個元素或一個假設，不要一輪混 layout、state、shortcut
- UI/AppKit 題先做最小 patch，不要第一刀就重寫整條 layout path
- 改 XIB 後至少做 XML 檢查；build 驗證由使用者或外部流程跑 `tools/build.sh`
- 回報時要明講做了哪些靜態檢查，以及 `tools/build.sh` 沒跑

## TDD / Tidy First
- 預設流程是 TDD + Tidy First，不是手動修 bug
- UI/AppKit 題也要先抽可測 seam：
  - helper method
  - class method
  - state object
  - selector routing decision
- `iTermRootTerminalView` 不要直接在 test host init；純邏輯先抽 helper 再測
- 沒有可行測試時要明講是例外，不能默默跳過

## High-Risk Areas
- SourceList selection、WKWebView layering、menu shortcut conflict、CALayer refresh
- file tree / browser interaction、right-panel mixed tabs、theme token 替換
- 細節不要寫在這裡，先查 `docs/debug-lessons.md`

## Regression Updates
- 每次遇到以下情況，當輪結束前都要更新文件：
  - 同一種錯又犯一次
  - 花超過一輪才找到根因
  - 修法和原本直覺完全不同
- 更新規則：
  - `AGENTS.md` 只補核心規則或文件入口
  - `docs/debug-lessons.md` 補具體 lesson
- 沒回填文件，不算真正結束這輪工作
