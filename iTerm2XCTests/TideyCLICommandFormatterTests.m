#import <XCTest/XCTest.h>
#import "iTerm2SharedARC-Swift.h"

@interface TideyCLICommandFormatterTests : XCTestCase
@end

@implementation TideyCLICommandFormatterTests

- (void)testLastAssistantTextInTranscriptContentUsesLastNonEmptyAssistantMessage {
    NSString *transcript =
        @"{\"message\":{\"role\":\"user\",\"content\":\"ignore me\"}}\n"
         "{\"message\":{\"role\":\"assistant\",\"content\":\"  first answer  \"}}\n"
         "{\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\" second\"},{\"type\":\"tool_use\",\"text\":\"ignored\"},{\"type\":\"text\",\"text\":\"answer \"}]}}\n"
         "{\"message\":{\"role\":\"assistant\",\"content\":\"   \"}}\n";

    NSString *text = [TideyCLICommandFormatter lastAssistantTextInTranscriptContent:transcript];

    XCTAssertEqualObjects(text, @"second answer");
}

- (void)testSingleLineTruncatedStringCollapsesWhitespaceAndTruncates {
    NSString *input = @"line one\n\n line\t two   three";

    NSString *output = [TideyCLICommandFormatter singleLineTruncatedString:input
                                                                 maxLength:12];

    XCTAssertEqualObjects(output, @"line one lin");
}

- (void)testMessagesForClaudeHookEventSessionStart {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"session-start"
                                                 workspaceID:@"ws-1"
                                                   stdinJSON:nil
                                           transcriptContent:nil];

    NSArray<NSString *> *expected = @[
        @"report_shell_state prompt --workspace_id=ws-1",
        @"{\"action\":\"set_title\",\"workspace_id\":\"ws-1\",\"title\":\"Claude Code\"}"
    ];
    XCTAssertEqualObjects(messages, expected);
}

- (void)testMessagesForClaudeHookEventStopUsesTranscriptSummary {
    NSString *stdinJSON = @"{\"transcriptPath\":\"~/ignored.jsonl\"}";
    NSString *transcript =
        @"{\"message\":{\"role\":\"assistant\",\"content\":\"Earlier\"}}\n"
         "{\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Need \\\"quotes\\\"\"},{\"type\":\"text\",\"text\":\"and\\nnewlines\"}]}}\n";

    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"stop"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:stdinJSON
                                           transcriptContent:transcript];

    NSArray<NSString *> *expected = @[
        @"{\"action\":\"notification.create\",\"workspace_id\":\"workspace-1\",\"title\":\"Claude Code\",\"body\":\"Need \\\"quotes\\\" and newlines\"}",
        // Session identity derived from the transcript filename becomes the
        // status owner cell.
        @"report_shell_state prompt --workspace_id=workspace-1 --session_id=ignored"
    ];
    XCTAssertEqualObjects(messages, expected);
}

- (void)testMessagesForClaudeHookEventStopFallsBackToDefaultBody {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"stop"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:@"not json"
                                           transcriptContent:nil];

    NSArray<NSString *> *expected = @[
        @"{\"action\":\"notification.create\",\"workspace_id\":\"workspace-1\",\"title\":\"Claude Code\",\"body\":\"Task completed\"}",
        @"report_shell_state prompt --workspace_id=workspace-1"
    ];
    XCTAssertEqualObjects(messages, expected);
}

- (void)testTypedPermissionNotificationMapsToNeedsInput {
    NSArray<NSString *> *permission =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification-permission"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:nil
                                           transcriptContent:nil];
    XCTAssertEqual(permission.count, 1);
    XCTAssertTrue([permission.firstObject containsString:@"Needs input"]);

    // PermissionRequest is PREPARATION only: another hook may auto-allow it,
    // so it must not report Needs input (same semantics as the Bridge path).
    NSArray<NSString *> *request =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"permission-request"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:nil
                                           transcriptContent:nil];
    XCTAssertEqual(request.count, 0);
}

- (void)testPostToolUseReportsRunning {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"post-tool-use"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:nil
                                           transcriptContent:nil];
    XCTAssertEqualObjects(messages, @[ @"report_shell_state running --workspace_id=workspace-1" ]);
}

- (void)testStopWithActiveStopHookIsNotTerminal {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"stop"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:@"{\"stop_hook_active\":true}"
                                           transcriptContent:nil];
    XCTAssertEqual(messages.count, 0,
                   @"a Stop while a stop hook drives continuation must not report Idle");
}

- (void)testIdlePromptNotificationMapsToIdleNotNeedsInput {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification-idle"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:nil
                                           transcriptContent:nil];
    XCTAssertEqualObjects(messages, @[ @"report_shell_state prompt --workspace_id=workspace-1" ]);
}

- (void)testUntypedNotificationChangesNoState {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification"
                                                 workspaceID:@"workspace-1"
                                                   stdinJSON:nil
                                           transcriptContent:nil];
    XCTAssertEqual(messages.count, 0);
}

- (void)testMessagesForClaudeHookEventWithoutWorkspaceReturnsNoMessages {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification"
                                                 workspaceID:@""
                                                   stdinJSON:nil
                                           transcriptContent:nil];

    XCTAssertEqual(messages.count, 0);
}


- (void)testClaudeHookMessagesCarrySessionPanelOwnerIdentity {
    NSString *stdinJSON = @"{\"session_id\":\"session-42\"}";
    NSArray<NSString *> *permission =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification-permission"
                                                 workspaceID:@"workspace-1"
                                                     panelID:@"panel-7"
                                                   stdinJSON:stdinJSON
                                           transcriptContent:nil];
    XCTAssertEqual(permission.count, 1);
    XCTAssertTrue([permission.firstObject containsString:@"\"panel_id\":\"panel-7\""]);
    XCTAssertTrue([permission.firstObject containsString:@"\"session_id\":\"session-42\""]);

    NSArray<NSString *> *idle =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification-idle"
                                                 workspaceID:@"workspace-1"
                                                     panelID:@"panel-7"
                                                   stdinJSON:stdinJSON
                                           transcriptContent:nil];
    XCTAssertEqualObjects(idle, @[ @"report_shell_state prompt --workspace_id=workspace-1 --panel_id=panel-7 --session_id=session-42" ]);

    // session-end clears ONLY this session's owner cell.
    NSArray<NSString *> *sessionEnd =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"session-end"
                                                 workspaceID:@"workspace-1"
                                                     panelID:@"panel-7"
                                                   stdinJSON:stdinJSON
                                           transcriptContent:nil];
    XCTAssertEqual(sessionEnd.count, 2);
    XCTAssertTrue([sessionEnd.firstObject containsString:@"clear_status"]);
    XCTAssertTrue([sessionEnd.firstObject containsString:@"\"panel_id\":\"panel-7\""]);
}

@end
