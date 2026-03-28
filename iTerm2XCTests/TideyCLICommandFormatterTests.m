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
        @"report_shell_state prompt --workspace_id=workspace-1"
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

- (void)testMessagesForClaudeHookEventWithoutWorkspaceReturnsNoMessages {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:@"notification"
                                                 workspaceID:@""
                                                   stdinJSON:nil
                                           transcriptContent:nil];

    XCTAssertEqual(messages.count, 0);
}

@end
