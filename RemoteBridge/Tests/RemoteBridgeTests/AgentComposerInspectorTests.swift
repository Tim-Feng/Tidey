import XCTest
@testable import RemoteBridge

// Composer classification against REAL screens captured read-only from the
// production tmux panes (no input was sent to any pane), plus screens
// CONSTRUCTED from those real frames where no live pane showed the state
// (text left in the composer, an approval dialog). The constructed ones must
// be re-checked against a real capture during acceptance.
final class AgentComposerInspectorTests: XCTestCase {
    private func classify(_ screen: String, _ vendor: String, _ message: String) -> AgentComposerState {
        AgentComposerInspector.classify(screen: screen, vendorID: vendor, message: message)
    }

    // MARK: - Real captures

    func testRealClaudeWorkingScreensHaveAnEmptyComposer() {
        XCTAssertEqual(classify(RealComposerScreens.claudeWorkingMV, "claude", "歌詞是日文嗎"), .empty)
        XCTAssertEqual(classify(RealComposerScreens.claudeWorkingTideyCC, "claude", "hello"), .empty)
    }

    func testRealCodexIdleScreenTreatsTheDimPlaceholderAsEmpty() {
        XCTAssertEqual(classify(RealComposerScreens.codexIdle, "codex", "hello"), .empty)
        // Even a message equal to the placeholder text is not "still there".
        XCTAssertEqual(classify(RealComposerScreens.codexIdle, "codex", "Ask Codex to do anything"), .empty)
    }

    func testRealCodexChoiceListIsADialog() {
        XCTAssertEqual(classify(RealComposerScreens.codexGoalDialog, "codex", "Resume goal"), .dialog)
    }

    // MARK: - Claude (constructed from the real frame)

    func testClaudeSingleLineMessageStillInTheComposer() {
        let screen = ComposerScreenBuilder.claude(box: ["❯\u{a0}用 yt-dlp 下載就好"])
        XCTAssertEqual(classify(screen, "claude", "用 yt-dlp 下載就好"), .containsMessage)
    }

    func testClaudeMultilineAndWrappedMessageMatchesOnItsLastLine() {
        let screen = ComposerScreenBuilder.claude(box: [
            "❯\u{a0}這是測試訊息第一行",
            "  這是測試訊息第二行",
            "  這是測試訊息第三行，這一行很長很長很長會被 Claude Code 在畫面上折",
            "  成兩行",
        ])
        XCTAssertEqual(classify(screen, "claude", "這是測試訊息第一行\n這是測試訊息第二行\n這是測試訊息第三行，這一行很長很長很長會被 Claude Code 在畫面上折成兩行\n"),
                       .containsMessage)
    }

    func testClaudeCollapsedPasteCountsAsTheMessage() {
        let screen = ComposerScreenBuilder.claude(box: ["❯\u{a0}[Pasted text #1 +12 lines]"])
        XCTAssertEqual(classify(screen, "claude", String(repeating: "line\n", count: 13)), .containsMessage)
    }

    func testClaudeShortMessageIsASuffixNotASubstringMatch() {
        let screen = ComposerScreenBuilder.claude(box: ["❯\u{a0}好了我再看"])
        XCTAssertEqual(classify(screen, "claude", "好"), .other)
    }

    func testClaudeApprovalOptionsInTheBoxAreADialog() {
        let screen = ComposerScreenBuilder.claude(box: [
            "❯\u{a0}1. Yes",
            "  2. Yes, and don’t ask again for this command",
            "  3. No, and tell Claude what to do differently (esc)",
        ])
        XCTAssertEqual(classify(screen, "claude", "Yes"), .dialog)
        let question = ComposerScreenBuilder.claude(box: ["❯\u{a0}Do you want to proceed?"])
        XCTAssertEqual(classify(question, "claude", "proceed?"), .dialog)
    }

    func testClaudeConversationTextAboveTheBoxDoesNotCount() {
        let screen = ComposerScreenBuilder.claude(history: ["⏺ Do you want to deploy? 用 yt-dlp 下載就好"],
                                                  box: ["❯\u{a0}"])
        XCTAssertEqual(classify(screen, "claude", "用 yt-dlp 下載就好"), .empty)
        let withMessage = ComposerScreenBuilder.claude(history: ["⏺ Do you want to deploy?"],
                                                       box: ["❯\u{a0}好"])
        XCTAssertEqual(classify(withMessage, "claude", "好"), .containsMessage,
                       "a question in the conversation must not disable the check")
    }

    func testClaudeScreenWithoutTheRulePairIsUnknown() {
        XCTAssertEqual(classify("❯\u{a0}hello\nsome output", "claude", "hello"), .unknown)
        XCTAssertEqual(classify("", "claude", "hello"), .unknown)
    }

    // MARK: - Codex (constructed from the real frame)

    func testCodexMessageStillInTheComposer() {
        let screen = ComposerScreenBuilder.codex(composer: ["\u{1b}[1m›\u{1b}[0m 可以根據你對我跟小孩的了解"])
        XCTAssertEqual(classify(screen, "codex", "可以根據你對我跟小孩的了解"), .containsMessage)
    }

    func testCodexMultilineAndCollapsedPaste() {
        let multiline = ComposerScreenBuilder.codex(composer: ["› 第一行", "  第二行"])
        XCTAssertEqual(classify(multiline, "codex", "第一行\n第二行"), .containsMessage)
        let pasted = ComposerScreenBuilder.codex(composer: ["› [Pasted Content 2048 chars]"])
        XCTAssertEqual(classify(pasted, "codex", String(repeating: "x", count: 2048)), .containsMessage)
    }

    func testCodexOtherTextAndApprovalOptions() {
        XCTAssertEqual(classify(ComposerScreenBuilder.codex(composer: ["› 好了我再看"]), "codex", "好"), .other)
        let approval = ComposerScreenBuilder.codex(composer: ["› 1. Yes, proceed (y)", "  2. No, and tell Codex what to do differently (esc)"])
        XCTAssertEqual(classify(approval, "codex", "Yes"), .dialog)
    }

    func testCodexScreenWithoutAComposerAboveTheFooterIsUnknown() {
        XCTAssertEqual(classify("some output\n\n  model · ~", "codex", "hello"), .unknown)
        XCTAssertEqual(classify(RealComposerScreens.claudeWorkingMV, "codex", "hello"), .unknown)
    }

    func testUnsupportedVendorIsUnknown() {
        XCTAssertEqual(classify(RealComposerScreens.codexIdle, "gemini", "hello"), .unknown)
    }
}

enum ComposerScreenBuilder {
    /// The real mv-cc frame with the composer rows replaced.
    static func claude(history: [String] = [], box: [String]) -> String {
        let rows = RealComposerScreens.claudeWorkingMV.components(separatedBy: "\n")
        let ruleRows = rows.indices.filter { AgentComposerScreenLine.parse(rows[$0])[0].plain.hasPrefix("────") }
        let top = ruleRows[ruleRows.count - 2]
        let bottom = ruleRows[ruleRows.count - 1]
        return (history + Array(rows[..<top]) + [rows[top]] + box + Array(rows[bottom...])).joined(separator: "\n")
    }

    /// The real tidey-codex frame with the `›` row replaced.
    static func codex(composer: [String]) -> String {
        var rows = RealComposerScreens.codexIdle.components(separatedBy: "\n")
        let composerRow = rows.lastIndex { AgentComposerScreenLine.parse($0)[0].plain.hasPrefix("›") }!
        rows.replaceSubrange(composerRow...composerRow, with: composer)
        return rows.joined(separator: "\n")
    }
}

enum RealComposerScreens {
    // mv-cc %30, Claude Code 2.1.283, turn running, composer empty
    // (tmux capture-pane -p -e, 2026-09-30 08:5x, read-only; last 8 rows)
    static let claudeWorkingMV = [
        "     \u{1b}[38;5;246m(ctrl+b ctrl+b (twice) to run in background)\u{1b}[39m",
        "",
        "\u{1b}[38;5;174m✢\u{1b}[39m \u{1b}[38;5;174mSprouting… \u{1b}[38;5;246m(4m 33s · ↓\u{1b}[39m \u{1b}[38;5;246m9.9k tokens)\u{1b}[39m",
        "",
        "\u{1b}[38;5;244m──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "\u{1b}[38;5;246m❯\u{a0}\u{1b}[39m",
        "\u{1b}[38;5;244m──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "\u{1b}[39m  \u{1b}[38;5;220m⏵⏵\u{1b}[39m \u{1b}[38;5;220mauto\u{1b}[39m \u{1b}[38;5;220mmode\u{1b}[39m \u{1b}[38;5;220mon\u{1b}[38;5;246m (shift+tab\u{1b}[39m \u{1b}[38;5;246mto\u{1b}[39m \u{1b}[38;5;246mcycle)\u{1b}[39m \u{1b}[38;5;246m·\u{1b}[39m \u{1b}[38;5;246mesc\u{1b}[39m \u{1b}[38;5;246mto\u{1b}[39m \u{1b}[38;5;246minterrupt\u{1b}[39m \u{1b}[38;5;246m·\u{1b}[39m \u{1b}[38;5;246m←\u{1b}[39m \u{1b}[38;5;246mfor\u{1b}[39m \u{1b}[38;5;246magents\u{1b}[39m                  \u{1b}[38;5;114m✔\u{1b}[39m \u{1b}[38;5;114mUpdate\u{1b}[39m \u{1b}[38;5;114minstalled\u{1b}[39m \u{1b}[38;5;114m·\u{1b}[39m \u{1b}[38;5;114mRestart\u{1b}[39m \u{1b}[38;5;114mto\u{1b}[39m \u{1b}[38;5;114mupdate\u{1b}[39m",
    ].joined(separator: "\n")

    // tidey-cc %9, Claude Code 2.1.283, tool running, composer empty
    // (tmux capture-pane -p -e, 2026-09-30 08:5x, read-only; last 8 rows)
    static let claudeWorkingTideyCC = [
        "\u{1b}[38;5;246m  ⎿ \u{a0}Running…\u{1b}[39m",
        "",
        "\u{1b}[38;5;174m✢\u{1b}[39m \u{1b}[38;5;216mZesting…\u{1b}[38;5;174m \u{1b}[38;5;246m(10m 31s · ↓\u{1b}[39m \u{1b}[38;5;246m47.3k tokens)\u{1b}[39m",
        "",
        "\u{1b}[38;5;244m──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "\u{1b}[38;5;246m❯\u{a0}\u{1b}[39m",
        "\u{1b}[38;5;244m──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "\u{1b}[39m  \u{1b}[38;5;220m⏵⏵\u{1b}[39m \u{1b}[38;5;220mauto\u{1b}[39m \u{1b}[38;5;220mmode\u{1b}[39m \u{1b}[38;5;220mon\u{1b}[38;5;246m (shift+tab\u{1b}[39m \u{1b}[38;5;246mto\u{1b}[39m \u{1b}[38;5;246mcycle)\u{1b}[39m \u{1b}[38;5;246m·\u{1b}[39m \u{1b}[38;5;246mesc\u{1b}[39m \u{1b}[38;5;246mto\u{1b}[39m \u{1b}[38;5;246minterrupt\u{1b}[39m \u{1b}[38;5;246m·\u{1b}[39m \u{1b}[38;5;246m←\u{1b}[39m \u{1b}[38;5;246mfor\u{1b}[39m \u{1b}[38;5;246magents\u{1b}[39m                  \u{1b}[38;5;114m✔\u{1b}[39m \u{1b}[38;5;114mUpdate\u{1b}[39m \u{1b}[38;5;114minstalled\u{1b}[39m \u{1b}[38;5;114m·\u{1b}[39m \u{1b}[38;5;114mRestart\u{1b}[39m \u{1b}[38;5;114mto\u{1b}[39m \u{1b}[38;5;114mupdate\u{1b}[39m",
    ].joined(separator: "\n")

    // tidey-codex %24, Codex TUI idle, dimmed placeholder
    // (tmux capture-pane -p -e, 2026-09-30 08:5x, read-only; last 6 rows)
    static let codexIdle = [
        "\u{1b}[1m\u{1b}[38;5;3m⚠ Heads up, you have less than 5% of your weekly limit left. Run /status for a breakdown.\u{1b}[0m",
        "",
        "\u{1b}[48;2;49;46;47m",
        "\u{1b}[1m›\u{1b}[0m\u{1b}[48;2;49;46;47m \u{1b}[2mAsk Codex to do anything\u{1b}[0m\u{1b}[48;2;49;46;47m",
        "",
        "\u{1b}[49m  \u{1b}[38;2;246;226;183mGPT-6-Astra xhigh\u{1b}[38;2;151;145;148m · \u{1b}[38;2;171;223;167m~\u{1b}[38;2;151;145;148m · \u{1b}[38;2;166;227;161m幫我查一下我的 macbook pro 2015 要怎麼安裝 DHH 的\u{1b}[39m                             \u{1b}[38;2;151;145;148m⚠ \u{1b}[38;2;196;167;103m3 warnings\u{1b}[38;2;151;145;148m · \u{1b}[1m\u{1b}[38;2;238;231;234mf2\u{1b}[0m\u{1b}[38;2;151;145;148m to view\u{1b}[39m",
    ].joined(separator: "\n")

    // adbrewer-codex %2, Codex /goal choice list
    // (tmux capture-pane -p -e, 2026-09-30 08:5x, read-only; last 7 rows)
    static let codexGoalDialog = [
        "  \u{1b}[2m嚴格單工，直到達標或取得明確實驗結論。\u{1b}[0m\u{1b}[48;2;49;46;47m",
        "",
        "",
        "\u{1b}[1m\u{1b}[38;2;0;0;46m\u{1b}[48;2;99;168;248m› 1. Resume goal   \u{1b}[0m\u{1b}[38;2;0;0;46m\u{1b}[48;2;99;168;248mMark it active and continue when idle\u{1b}[1m",
        "\u{1b}[0m\u{1b}[48;2;49;46;47m  2. Leave paused  \u{1b}[2mKeep it paused; use /goal resume later\u{1b}[0m\u{1b}[48;2;49;46;47m",
        "",
        "\u{1b}[49m  \u{1b}[1m\u{1b}[38;2;238;231;234menter\u{1b}[0;2m select · \u{1b}[0;1m\u{1b}[38;2;238;231;234mesc\u{1b}[0;2m back",
    ].joined(separator: "\n")
}
