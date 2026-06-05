import XCTest
@testable import RemoteBridge

final class InteractivePromptDetectorTests: XCTestCase {
    func testParsesClaudeDynamicWorkflowConfirmPrompt() throws {
        let ansi = """
         \u{1b}[1mRun a dynamic workflow?\u{1b}[22m
          CC granular per-chunk craft-concept extraction for book 10 ...
          This dynamic workflow will spin up multiple subagents across the following phases:
            1. Extract - one agent per chunk - ...
          \u{1b}[38;5;220mDynamic workflows can use a lot of tokens quickly and counts against your usage limit.\u{1b}[0m

          \u{1b}[38;5;153m❯ 1. Yes, run it\u{1b}[0m
            \u{1b}[38;5;246m2.\u{1b}[0m View raw script
            \u{1b}[38;5;246m3.\u{1b}[0m No

          Esc to cancel - Tab to amend
        """

        let prompt = try XCTUnwrap(WorkflowConfirmPromptDetector().parse(ansiOutput: ansi,
                                                                          workspaceID: "workspace-1",
                                                                          panelID: "panel-1",
                                                                          sessionID: "claude-session",
                                                                          vendor: "claude"))

        XCTAssertEqual(prompt.title, "Run a dynamic workflow?")
        XCTAssertEqual(prompt.source, "workflow_confirm")
        XCTAssertEqual(prompt.vendor, "claude")
        XCTAssertTrue(prompt.body.contains("This dynamic workflow will spin up multiple subagents"))
        XCTAssertEqual(prompt.options.map(\.label), ["Yes, run it", "View raw script", "No"])
        XCTAssertEqual(prompt.selectedIndex, 0)
        XCTAssertEqual(prompt.options[0].inputSequence, "\r")
        XCTAssertEqual(prompt.options[1].inputSequence, "\u{1b}[B\r")
        XCTAssertEqual(prompt.options[2].inputSequence, "\u{1b}[B\u{1b}[B\r")
        XCTAssertTrue(prompt.promptID.hasPrefix("workflow-confirm:"))
    }

    func testParsesSelectedOptionBelowFirstOption() throws {
        let ansi = """
         Run a dynamic workflow?

           1. Yes, run it
         \u{1b}[38;5;153m❯ 2. View raw script\u{1b}[0m
           3. No

          Esc to cancel - Tab to amend
        """

        let prompt = try XCTUnwrap(WorkflowConfirmPromptDetector().parse(ansiOutput: ansi,
                                                                          workspaceID: "workspace-1",
                                                                          panelID: "panel-1",
                                                                          sessionID: "claude-session"))

        XCTAssertEqual(prompt.selectedIndex, 1)
        XCTAssertEqual(prompt.options[0].inputSequence, "\u{1b}[A\r")
        XCTAssertEqual(prompt.options[1].inputSequence, "\r")
        XCTAssertEqual(prompt.options[2].inputSequence, "\u{1b}[B\r")
    }

    func testDetectsUncertainWhenTitleExistsWithoutCompleteOptions() {
        let ansi = """
         Run a dynamic workflow?

           ❯ 1. Yes, run it
        """

        XCTAssertEqual(WorkflowConfirmPromptDetector().detect(ansiOutput: ansi,
                                                              workspaceID: "workspace-1",
                                                              panelID: "panel-1",
                                                              sessionID: "claude-session"),
                       .uncertain)
    }

    func testDetectsAbsentWhenNoWorkflowConfirmFragmentsExist() {
        let output = """
        Thinking...
        Jitterbugging...
        """

        XCTAssertEqual(WorkflowConfirmPromptDetector().detect(ansiOutput: output,
                                                              workspaceID: "workspace-1",
                                                              panelID: "panel-1",
                                                              sessionID: "claude-session"),
                       .absent)
    }

    func testDetectsLastCompletePromptWhenEarlierFrameIsIncomplete() throws {
        let output = """
         Run a dynamic workflow?

           ❯ 1. Yes, run it

         Some redraw noise

         Run a dynamic workflow?

           1. Yes, run it
           2. View raw script
         ❯ 3. No

          Esc to cancel - Tab to amend
        """

        guard case .present(let prompt) = WorkflowConfirmPromptDetector().detect(ansiOutput: output,
                                                                                 workspaceID: "workspace-1",
                                                                                 panelID: "panel-1",
                                                                                 sessionID: "claude-session") else {
            return XCTFail("expected present prompt")
        }
        XCTAssertEqual(prompt.selectedIndex, 2)
    }

    func testDetectsAnsweredWorkflowPromptResidueAsAbsentWhenFooterIsGoneAndOutputFollows() {
        let output = """
         Run a dynamic workflow?

           ❯ 1. Yes, run it
             2. View raw script
             3. No

        Starting dynamic workflow...
        Phase 1: Extract
        """

        XCTAssertEqual(WorkflowConfirmPromptDetector().detect(ansiOutput: output,
                                                              workspaceID: "workspace-1",
                                                              panelID: "panel-1",
                                                              sessionID: "claude-session"),
                       .absent)
    }

    func testDetectsCompletePromptWithoutFooterAtBottomAsUncertain() {
        let output = """
         Run a dynamic workflow?

           ❯ 1. Yes, run it
             2. View raw script
             3. No
        """

        XCTAssertEqual(WorkflowConfirmPromptDetector().detect(ansiOutput: output,
                                                              workspaceID: "workspace-1",
                                                              panelID: "panel-1",
                                                              sessionID: "claude-session"),
                       .uncertain)
    }

    func testRejectsNonWorkflowPromptTerminalOutput() {
        let output = """
        Thinking...
        1. Yes, run it
        2. View raw script
        3. No
        """

        XCTAssertNil(WorkflowConfirmPromptDetector().parse(ansiOutput: output,
                                                           workspaceID: "workspace-1",
                                                           panelID: "panel-1",
                                                           sessionID: "claude-session"))
    }
}
