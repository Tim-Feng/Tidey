## Code Best Practices

- Avoid writing javascript, html, or CSS that's more than one line long in Swift. Create a new file and use the existing template mechanism to load it.
- After creating a new file, `git add` it immediately
- To add a file to the Xcode project, use `tools/add_file_to_xcodeproj.rb <file_path> <target_name>` (e.g., `tools/add_file_to_xcodeproj.rb sources/Example.swift iTerm2SharedARC`)
- In Swift, use it_fatalError and it_assert instead of fatalError and assert, which do not create useful crash logs. In ObjC, assert is ok although ITAssertWithMessage is preferable.
- Don't write more than one line of inline javascript, html, or css. Instead create a new file and load it using iTermBrowserTemplateLoader.swift
- Don't create dependency cycles. Use delegates or closures instead.
- To run unit tests in ModernTests, use tools/run_tests.expect. It takes an argument naming the test or tests, such as `tools/run_tests.expect ModernTests/iTermScriptFunctionCallTest/testSignature`
- When renaming a file tracked by git (and almost all of them are) use `git mv` instead of `mv`
- To make a debug build run `tools/build.sh` (or `tools/build.sh Development`). This saves logs to `tmp/build.log` and shows only errors/warnings on failure.
- Little scripts or text files that are used for manual testing of features go in tests/
- The deployment target for iTerm2 is macOS 12. You don't need to perform availability checks for older versions.
- Don't replace curly quotes with straight quotes. Same for apostrophes and single quotes. If you need help typing a curly quote, just ask. Here are some you can copy and paste: ‘’“”
- In user-visible strings do not use " except as a shorthand for inch. Prefer curly quotes like “ and ”. I know this goes against your nature, but fight hard here.
- Never use auto layout in the terminal window. It virally spreads and breaks autoresizing. It is fine to use it in other windows without a lot of existing autoresizing mask-based code (e.g., the AI chat window)
- The deployment target is macOS 12. Don't add availability checks for 12 and lower.
- Never `git add` submodules without express written permission.
- Don't include AI-generated markdown files (summaries, plans, etc.) in commits — only ship code.
- Avoid duplicate expressions; hoist shared computations into a named `const` before branching.
- Don't change defaults silently.
- Before changing UI/layout code, read `docs/debug-lessons.md` — it covers layout pitfalls, PSMTabBarControl quirks, icon cache, and shell integration issues we've already solved.

## Testing Policy

Tidey 不套用 `~/GitHub/CLAUDE.md` 預設的 TDD。繼承的 iTerm2 codebase 大部分是 AppKit UI / layout / WKWebView / NSOutlineView 等難以在 XCTest 穩定 reproduce 的互動類 bug，全面 TDD 的成本高於收益。

**綁測試（寫進 `ModernTests` / `iTerm2XCTests`，regression 必備）**：
- 純邏輯 class：parser、state machine、script function call、shortcut routing、status store
- 跨 session 行為契約：keybinding、IPC、socket protocol
- 修 bug 前能在 XCTest 先 reproduce 的 → 一律先寫 failing test

**不綁測試（依賴人工驗證 + `docs/debug-lessons.md`）**：
- Layout、autoresizing、split view geometry
- Drag session、mouse tracking、responder chain
- Rendering（PTYTextView、Metal renderer、PSMTabBarControl drawing）
- WebKit integration（WKWebView focus、content policy）

**執行方式**：
- 跑測試：`tools/run_tests.expect ModernTests/<TestClass>/<testMethod>`
- CI gate：`.github/workflows/test.yml` 會在 push master / PR 時跑全套 ModernTests（macos-15）
- 本地無 pre-commit test gate，`.git/hooks/pre-commit` 僅提示檢查 `docs/debug-lessons.md`

**原則**：修不綁測試類型的 bug 時，commit message 要寫清楚症狀關鍵字（方便 `git log | grep` 回查），並考慮是否要補一條進 `docs/debug-lessons.md`。
