import CryptoKit
import Foundation

struct InteractivePromptOption: Equatable, Sendable {
    let index: Int
    let label: String
    let inputSequence: String

    var jsonValue: JSONValue {
        .object([
            "index": .number(Double(index)),
            "label": .string(label),
            "input_sequence": .string(inputSequence),
        ])
    }
}

struct InteractivePrompt: Equatable, Sendable {
    let promptID: String
    let vendor: String
    let source: String
    let title: String
    let body: String
    let options: [InteractivePromptOption]
    let selectedIndex: Int

    var selectedInputSequence: String {
        inputSequence(targetIndex: selectedIndex)
    }

    func inputSequence(targetIndex: Int) -> String {
        let delta = targetIndex - selectedIndex
        if delta == 0 {
            return "\r"
        }
        let step = delta > 0 ? "\u{1b}[B" : "\u{1b}[A"
        return String(repeating: step, count: abs(delta)) + "\r"
    }

    var jsonValue: JSONValue {
        .object([
            "prompt_id": .string(promptID),
            "vendor": .string(vendor),
            "source": .string(source),
            "title": .string(title),
            "body": .string(body),
            "options": .array(options.map(\.jsonValue)),
            "selected_index": .number(Double(selectedIndex)),
            "input_sequence": .string(selectedInputSequence),
        ])
    }
}

enum WorkflowConfirmPromptDetection: Equatable, Sendable {
    case present(InteractivePrompt)
    case uncertain
    case absent
}

private enum WorkflowConfirmPromptCandidateDetection {
    case present(InteractivePrompt)
    case uncertain
    case answeredResidue
}

struct WorkflowConfirmPromptDetector {
    private static let title = "Run a dynamic workflow?"
    private static let expectedOptionLabels = ["Yes, run it", "View raw script", "No"]

    func detect(ansiOutput: String,
                workspaceID: String,
                panelID: String,
                sessionID: String,
                vendor: String = "claude") -> WorkflowConfirmPromptDetection {
        let plainOutput = Self.stripANSI(ansiOutput)
        let lines = Self.lines(from: plainOutput)
        let titleIndices = lines.indices.filter { Self.trim(lines[$0]) == Self.title }
        var sawUncertainCandidate = false
        var sawAnsweredResidue = false

        for titleIndex in titleIndices.reversed() {
            let endIndex = titleIndices.first(where: { $0 > titleIndex }) ?? lines.endIndex
            switch Self.detectCandidate(lines: lines,
                                        titleIndex: titleIndex,
                                        endIndex: endIndex,
                                        workspaceID: workspaceID,
                                        panelID: panelID,
                                        sessionID: sessionID,
                                        vendor: vendor) {
            case .present(let prompt):
                return .present(prompt)
            case .uncertain:
                sawUncertainCandidate = true
            case .answeredResidue:
                sawAnsweredResidue = true
            }
        }

        if sawUncertainCandidate {
            return .uncertain
        }
        if sawAnsweredResidue {
            return .absent
        }
        if !titleIndices.isEmpty || Self.containsWorkflowConfirmFragment(lines) {
            return .uncertain
        }
        return .absent
    }

    func parse(ansiOutput: String,
               workspaceID: String,
               panelID: String,
               sessionID: String,
               vendor: String = "claude") -> InteractivePrompt? {
        if case .present(let prompt) = detect(ansiOutput: ansiOutput,
                                              workspaceID: workspaceID,
                                              panelID: panelID,
                                              sessionID: sessionID,
                                              vendor: vendor) {
            return prompt
        }
        return nil
    }

    private static func detectCandidate(lines: [String],
                                        titleIndex: Int,
                                        endIndex: Int,
                                        workspaceID: String,
                                        panelID: String,
                                        sessionID: String,
                                        vendor: String) -> WorkflowConfirmPromptCandidateDetection {
        guard let selectedLineIndex = lines.indices.first(where: { index in
            guard index > titleIndex,
                  index < endIndex,
                  let parsed = Self.parseOption(lines[index]) else {
                return false
            }
            return parsed.selected
        }) else {
            return .uncertain
        }

        var optionStartIndex = selectedLineIndex
        while optionStartIndex > titleIndex + 1,
              let previous = Self.parseOption(lines[optionStartIndex - 1]),
              !previous.selected {
            optionStartIndex -= 1
        }
        var optionEndIndex = selectedLineIndex
        while optionEndIndex + 1 < endIndex,
              Self.parseOption(lines[optionEndIndex + 1]) != nil {
            optionEndIndex += 1
        }

        var parsedOptions = [(lineIndex: Int, selected: Bool, optionIndex: Int, label: String)]()
        for lineIndex in optionStartIndex...optionEndIndex {
            guard let parsed = Self.parseOption(lines[lineIndex]) else {
                return .uncertain
            }
            parsedOptions.append((lineIndex, parsed.selected, parsed.optionIndex, parsed.label))
        }

        guard parsedOptions.count == Self.expectedOptionLabels.count else {
            return .uncertain
        }
        guard parsedOptions.map(\.label) == Self.expectedOptionLabels else {
            return .uncertain
        }
        guard let selectedOption = parsedOptions.first(where: \.selected) else {
            return .uncertain
        }

        if Self.hasAnsweredEvidence(lines: lines, after: optionEndIndex, before: endIndex) {
            return .answeredResidue
        }

        let firstOptionLineIndex = parsedOptions[0].lineIndex
        let body = Self.trimBody(Array(lines[(titleIndex + 1)..<firstOptionLineIndex]))
        let selectedIndex = max(0, selectedOption.optionIndex - 1)
        let options = parsedOptions.enumerated().map { offset, parsed in
            InteractivePromptOption(index: offset,
                                    label: parsed.label,
                                    inputSequence: Self.inputSequence(selectedIndex: selectedIndex, targetIndex: offset))
        }
        let prompt = InteractivePrompt(promptID: Self.promptID(workspaceID: workspaceID,
                                                               panelID: panelID,
                                                               sessionID: sessionID,
                                                               title: Self.title,
                                                               labels: parsedOptions.map(\.label)),
                                       vendor: vendor,
                                       source: "workflow_confirm",
                                       title: Self.title,
                                       body: body,
                                       options: options,
                                       selectedIndex: selectedIndex)
        return .present(prompt)
    }

    private static func hasAnsweredEvidence(lines: [String], after optionEndIndex: Int, before endIndex: Int) -> Bool {
        guard optionEndIndex + 1 < endIndex else {
            return false
        }
        return lines[(optionEndIndex + 1)..<endIndex].contains { line in
            let trimmed = trim(line)
            guard !trimmed.isEmpty else {
                return false
            }
            guard !Self.isLivePromptFooter(trimmed),
                  !Self.isTransientPromptStatus(trimmed) else {
                return false
            }
            return Self.isWorkflowExecutionOutput(trimmed)
        }
    }

    private static func isLivePromptFooter(_ trimmed: String) -> Bool {
        (trimmed.contains("Esc to cancel") && trimmed.contains("Tab to amend"))
            || trimmed.contains("ctrl+g to edit script")
    }

    private static func isTransientPromptStatus(_ trimmed: String) -> Bool {
        let lowercased = trimmed.lowercased()
        return lowercased == "esc to interrupt"
            || lowercased.contains("press up to edit queued messages")
            || lowercased.contains("jitterbugging")
    }

    private static func isWorkflowExecutionOutput(_ trimmed: String) -> Bool {
        let lowercased = trimmed.lowercased()
        return lowercased.hasPrefix("starting dynamic workflow")
            || lowercased.hasPrefix("phase ")
            || lowercased.contains("workflow(")
            || lowercased.contains("dynamic workflow completed")
            || lowercased.contains("dynamic workflow \"")
            || trimmed.hasPrefix("⏺")
            || trimmed.hasPrefix("●")
            || trimmed.hasPrefix("✔")
    }

    private static func containsWorkflowConfirmFragment(_ lines: [String]) -> Bool {
        let normalized = lines.map(trim).joined(separator: "\n")
        if normalized.contains(Self.title) {
            return true
        }
        return Self.expectedOptionLabels.contains { normalized.contains($0) }
    }

    private static func lines(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func inputSequence(selectedIndex: Int, targetIndex: Int) -> String {
        let delta = targetIndex - selectedIndex
        if delta == 0 {
            return "\r"
        }
        let step = delta > 0 ? "\u{1b}[B" : "\u{1b}[A"
        return String(repeating: step, count: abs(delta)) + "\r"
    }

    private static func parseOption(_ line: String) -> (selected: Bool, optionIndex: Int, label: String)? {
        var trimmed = trim(line)
        let selected: Bool
        if trimmed.hasPrefix("❯") {
            selected = true
            trimmed.removeFirst()
            trimmed = trim(trimmed)
        } else {
            selected = false
        }

        guard let dotIndex = trimmed.firstIndex(of: ".") else {
            return nil
        }
        let numberText = trim(String(trimmed[..<dotIndex]))
        guard let optionIndex = Int(numberText), optionIndex > 0 else {
            return nil
        }
        let labelStart = trimmed.index(after: dotIndex)
        let label = trim(String(trimmed[labelStart...]))
        guard !label.isEmpty else {
            return nil
        }
        return (selected, optionIndex, label)
    }

    private static func promptID(workspaceID: String,
                                 panelID: String,
                                 sessionID: String,
                                 title: String,
                                 labels: [String]) -> String {
        let seed = [workspaceID, panelID, sessionID, title, labels.joined(separator: "|")].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(seed.utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "workflow-confirm:\(prefix)"
    }

    private static func trimBody(_ lines: [String]) -> String {
        var bodyLines = lines.map(trimTrailingWhitespace)
        while bodyLines.first.map({ trim($0).isEmpty }) == true {
            bodyLines.removeFirst()
        }
        while bodyLines.last.map({ trim($0).isEmpty }) == true {
            bodyLines.removeLast()
        }
        return bodyLines.joined(separator: "\n")
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        var endIndex = text.endIndex
        while endIndex > text.startIndex {
            let previous = text.index(before: endIndex)
            let scalarView = String(text[previous]).unicodeScalars
            guard scalarView.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                break
            }
            endIndex = previous
        }
        return String(text[..<endIndex])
    }

    private static func stripANSI(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var index = text.unicodeScalars.startIndex
        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            guard scalar == "\u{1b}" else {
                result.append(scalar)
                index = text.unicodeScalars.index(after: index)
                continue
            }

            index = text.unicodeScalars.index(after: index)
            guard index < text.unicodeScalars.endIndex else {
                break
            }
            let introducer = text.unicodeScalars[index]
            if introducer == "[" {
                index = text.unicodeScalars.index(after: index)
                while index < text.unicodeScalars.endIndex {
                    let code = text.unicodeScalars[index].value
                    index = text.unicodeScalars.index(after: index)
                    if code >= 0x40 && code <= 0x7e {
                        break
                    }
                }
                continue
            }
            if introducer == "]" {
                index = text.unicodeScalars.index(after: index)
                while index < text.unicodeScalars.endIndex {
                    let current = text.unicodeScalars[index]
                    if current == "\u{7}" {
                        index = text.unicodeScalars.index(after: index)
                        break
                    }
                    if current == "\u{1b}" {
                        let nextIndex = text.unicodeScalars.index(after: index)
                        if nextIndex < text.unicodeScalars.endIndex,
                           text.unicodeScalars[nextIndex] == "\\" {
                            index = text.unicodeScalars.index(after: nextIndex)
                            break
                        }
                    }
                    index = text.unicodeScalars.index(after: index)
                }
                continue
            }
        }
        return String(result)
    }
}
