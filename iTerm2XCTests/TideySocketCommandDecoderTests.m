#import <XCTest/XCTest.h>
#import "TideySocketCommandDecoder.h"

@interface TideySocketCommandDecoderTests : XCTestCase
@end

@implementation TideySocketCommandDecoderTests

- (void)testNotificationCommandAllowsBroadcastNotification {
    TideySocketCommand *command =
        [TideySocketCommandDecoder notificationCommandFromMessage:@{
            @"action": @"notification.create",
            @"title": @"Claude Code",
            @"subtitle": @"Repo",
            @"body": @"Done"
        }];

    XCTAssertNotNil(command);
    XCTAssertEqual(command.kind, TideySocketCommandKindNotification);
    XCTAssertNil(command.workspaceID);
    XCTAssertEqualObjects(command.title, @"Claude Code");
    XCTAssertEqualObjects(command.subtitle, @"Repo");
    XCTAssertEqualObjects(command.body, @"Done");
}

- (void)testNotificationCommandRequiresWorkspaceForWorkspaceScopedNotification {
    TideySocketCommand *command =
        [TideySocketCommandDecoder notificationCommandFromMessage:@{
            @"action": @"notification.create_for_workspace",
            @"title": @"Claude Code"
        }];

    XCTAssertNil(command);
}

- (void)testSetStatusCommandRequiresWorkspaceKeyAndValue {
    TideySocketCommand *command =
        [TideySocketCommandDecoder setStatusCommandFromMessage:@{
            @"workspace_id": @"ws-1",
            @"key": @"shell_state",
            @"value": @"Running",
            @"icon": @"bolt.fill",
            @"color": @"#007AFF"
        }];

    XCTAssertNotNil(command);
    XCTAssertEqual(command.kind, TideySocketCommandKindSetStatus);
    XCTAssertEqualObjects(command.workspaceID, @"ws-1");
    XCTAssertEqualObjects(command.key, @"shell_state");
    XCTAssertEqualObjects(command.value, @"Running");
    XCTAssertEqualObjects(command.icon, @"bolt.fill");
    XCTAssertEqualObjects(command.colorHex, @"#007AFF");

    TideySocketCommand *invalidCommand =
        [TideySocketCommandDecoder setStatusCommandFromMessage:@{
        @"key": @"shell_state",
        @"value": @"Running"
    }];
    XCTAssertNil(invalidCommand);
}

- (void)testClearStatusCommandRequiresWorkspaceAndKey {
    TideySocketCommand *command =
        [TideySocketCommandDecoder clearStatusCommandFromMessage:@{
            @"workspace_id": @"ws-1",
            @"key": @"shell_state"
        }];

    XCTAssertNotNil(command);
    XCTAssertEqual(command.kind, TideySocketCommandKindClearStatus);
    XCTAssertEqualObjects(command.workspaceID, @"ws-1");
    XCTAssertEqualObjects(command.key, @"shell_state");

    TideySocketCommand *invalidCommand =
        [TideySocketCommandDecoder clearStatusCommandFromMessage:@{
        @"workspace_id": @"ws-1"
    }];
    XCTAssertNil(invalidCommand);
}

- (void)testReportShellStateCommandNormalizesRunningToBroadcastStatus {
    TideySocketCommand *command =
        [TideySocketCommandDecoder reportShellStateCommandFromMessage:@{
            @"state": @"running"
        }];

    XCTAssertNotNil(command);
    XCTAssertEqual(command.kind, TideySocketCommandKindSetStatus);
    XCTAssertEqualObjects(command.workspaceID, @"*");
    XCTAssertEqualObjects(command.key, @"shell_state");
    XCTAssertEqualObjects(command.value, @"Running");
    XCTAssertEqualObjects(command.icon, @"bolt.fill");
    XCTAssertEqualObjects(command.colorHex, @"#007AFF");
}

- (void)testReportShellStateCommandNormalizesClearToClearStatus {
    TideySocketCommand *command =
        [TideySocketCommandDecoder reportShellStateCommandFromMessage:@{
            @"state": @"clear",
            @"workspace_id": @"ws-2"
        }];

    XCTAssertNotNil(command);
    XCTAssertEqual(command.kind, TideySocketCommandKindClearStatus);
    XCTAssertEqualObjects(command.workspaceID, @"ws-2");
    XCTAssertEqualObjects(command.key, @"shell_state");
}

- (void)testReportShellStateCommandRejectsUnknownState {
    TideySocketCommand *command =
        [TideySocketCommandDecoder reportShellStateCommandFromMessage:@{
            @"state": @"bogus"
        }];

    XCTAssertNil(command);
}

- (void)testSetTitleCommandRequiresWorkspaceAndNormalizesMissingTitleToEmptyString {
    TideySocketCommand *command =
        [TideySocketCommandDecoder setTitleCommandFromMessage:@{
            @"workspace_id": @"ws-3"
        }];

    XCTAssertNotNil(command);
    XCTAssertEqual(command.kind, TideySocketCommandKindSetTitle);
    XCTAssertEqualObjects(command.workspaceID, @"ws-3");
    XCTAssertEqualObjects(command.title, @"");

    TideySocketCommand *invalidCommand =
        [TideySocketCommandDecoder setTitleCommandFromMessage:@{
        @"title": @"Claude Code"
    }];
    XCTAssertNil(invalidCommand);
}

@end
