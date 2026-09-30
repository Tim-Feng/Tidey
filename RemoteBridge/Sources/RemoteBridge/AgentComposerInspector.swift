import Foundation

// Reads an agent TUI's input box ("composer") from a `capture-pane -p -e`
// screen, to decide whether a chat_submit Enter was swallowed. Every rule
// fails closed: anything that is not clearly the agent's own composer is
// `.unknown`, and anything that looks like a choice list is `.dialog` — the
// caller only ever acts on `.containsMessage`.
enum AgentComposerState: String, Equatable, Sendable {
    /// The composer is empty (or shows only its dimmed placeholder).
    case empty
    /// The composer still ends with the submitted message.
    case containsMessage
    /// The composer holds something else (e.g. text typed on the Mac).
    case other
    /// A choice list / approval dialog owns the input.
    case dialog
    /// No composer recognised on screen.
    case unknown
}

enum AgentComposerInspector {
    static func classify(screen: String, vendorID: String, message: String) -> AgentComposerState {
        let lines = AgentComposerScreenLine.parse(screen)
        switch vendorID {
        case "claude":
            return classifyClaude(lines: lines, message: message)
        case "codex":
            return classifyCodex(lines: lines, message: message)
        default:
            return .unknown
        }
    }

    // MARK: - Claude Code (2.1.x)
    //
    //   ─────────────────────────   (full-width rule)
    //   ❯ first line
    //     continuation lines
    //   ─────────────────────────
    //     ⏵⏵ auto mode on …       (footer)
    //
    // The box is the region between the LAST two rules on screen.

    private static func classifyClaude(lines: [AgentComposerScreenLine], message: String) -> AgentComposerState {
        let ruleIndices = lines.indices.filter { isClaudeRule(lines[$0].plain) }
        guard ruleIndices.count >= 2 else {
            return .unknown
        }
        let top = ruleIndices[ruleIndices.count - 2]
        let bottom = ruleIndices[ruleIndices.count - 1]
        let box = Array(lines[(top + 1)..<bottom])
        guard let first = box.first, first.plain.hasPrefix("❯") else {
            return .unknown
        }
        if box.contains(where: { isChoiceLine($0.plain, promptGlyph: "❯") || $0.plain.contains("Do you want to") }) {
            return .dialog
        }
        let composer = box.enumerated().map { index, line in
            index == 0 ? String(line.content.drop { $0 == "❯" }) : line.content
        }.joined()
        return classifyComposerText(composer,
                                    message: message,
                                    collapsedPasteMarker: "[Pasted text #")
    }

    private static func isClaudeRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 20 && trimmed.allSatisfy { $0 == "─" }
    }

    // MARK: - Codex TUI
    //
    //   › first line               (shaded block; placeholder is dimmed)
    //     continuation lines
    //                              (blank)
    //     model · cwd · title      (footer = last non-empty line)
    //
    // The composer is the `›` block directly above the footer. A choice
    // list uses the same glyph (`› 1. Resume goal`) and ends with a hint
    // footer such as `enter select · esc back`.

    private static let codexMaxComposerLines = 12

    private static func classifyCodex(lines: [AgentComposerScreenLine], message: String) -> AgentComposerState {
        guard let footer = lines.lastIndex(where: { !$0.plain.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .unknown
        }
        if lines[footer].plain.contains("enter select") || lines[footer].plain.contains("esc back") {
            return .dialog
        }
        var end = footer - 1
        while end >= 0, lines[end].plain.trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        guard end >= 0 else {
            return .unknown
        }
        var start = end
        while start >= 0, !lines[start].plain.hasPrefix("›") {
            guard end - start < codexMaxComposerLines,
                  lines[start].plain.hasPrefix("  ") else {
                return .unknown
            }
            start -= 1
        }
        guard start >= 0 else {
            return .unknown
        }
        let block = Array(lines[start...end])
        if block.contains(where: { isChoiceLine($0.plain, promptGlyph: "›") }) {
            return .dialog
        }
        let composer = block.enumerated().map { index, line in
            index == 0 ? String(line.content.drop { $0 == "›" }) : line.content
        }.joined()
        return classifyComposerText(composer,
                                    message: message,
                                    collapsedPasteMarker: "[Pasted Content")
    }

    // MARK: - Shared

    /// `❯ 1. Yes` / `› 1. Resume goal` / an indented `  2. No` option row.
    private static func isChoiceLine(_ line: String, promptGlyph: Character) -> Bool {
        var rest = Substring(line)
        if rest.first == promptGlyph {
            rest = rest.dropFirst()
        }
        rest = rest.drop { $0 == " " || $0 == "\u{a0}" }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.count > digits.count else {
            return false
        }
        let afterDigits = rest.dropFirst(digits.count)
        return afterDigits.hasPrefix(". ")
    }

    private static func classifyComposerText(_ composer: String,
                                             message: String,
                                             collapsedPasteMarker: String) -> AgentComposerState {
        let box = removingWhitespace(composer)
        guard !box.isEmpty else {
            return .empty
        }
        if composer.contains(collapsedPasteMarker) {
            return .containsMessage
        }
        let lastLine = message
            .split(whereSeparator: \.isNewline)
            .map(removingWhitespace)
            .last { !$0.isEmpty } ?? ""
        guard !lastLine.isEmpty else {
            return .other
        }
        return box.hasSuffix(lastLine) ? .containsMessage : .other
    }

    /// TUIs wrap long lines at unpredictable columns, so comparisons ignore
    /// all whitespace.
    private static func removingWhitespace<S: StringProtocol>(_ text: S) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
}

/// One captured screen row: `plain` is every visible character, `content`
/// drops characters drawn dim (SGR 2 — the TUIs' placeholder text).
struct AgentComposerScreenLine: Equatable {
    let plain: String
    let content: String

    static func parse(_ screen: String) -> [AgentComposerScreenLine] {
        var dim = false
        return screen.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            var plain = ""
            var content = ""
            var iterator = Array(rawLine.unicodeScalars).makeIterator()
            while let scalar = iterator.next() {
                if scalar == "\u{1b}" {
                    guard let next = iterator.next() else { break }
                    guard next == "[" else { continue }  // non-CSI escape: skip its introducer
                    var parameters = ""
                    while let byte = iterator.next() {
                        if (0x40...0x7e).contains(byte.value) {
                            if byte == "m" {
                                dim = applySGR(parameters, dim: dim)
                            }
                            break
                        }
                        parameters.unicodeScalars.append(byte)
                    }
                    continue
                }
                if scalar == "\r" {
                    continue
                }
                plain.unicodeScalars.append(scalar)
                if !dim {
                    content.unicodeScalars.append(scalar)
                }
            }
            return AgentComposerScreenLine(plain: plain.replacingTrailingWhitespace(),
                                           content: content)
        }
    }

    private static func applySGR(_ parameters: String, dim: Bool) -> Bool {
        var dim = dim
        let codes = parameters.isEmpty ? ["0"] : parameters.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < codes.count {
            switch codes[index] {
            case "", "0", "22":
                dim = false
            case "2":
                dim = true
            case "38", "48", "58":
                // Extended colour: skip `5;n` or `2;r;g;b` so a colour value of
                // 2 or 22 is never read as a dim toggle.
                if index + 1 < codes.count {
                    index += codes[index + 1] == "5" ? 2 : (codes[index + 1] == "2" ? 4 : 1)
                }
            default:
                break
            }
            index += 1
        }
        return dim
    }
}

private extension String {
    func replacingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }
}
