#import <XCTest/XCTest.h>
#import "iTerm2SharedARC-Swift.h"
#import "TideySocketCommandDecoder.h"
#import "TideyNotificationStore.h"

// Formatter -> (socket line parse) -> decoder -> status store: the full Mac
// pipeline for Claude hook signals, per-session ownership included. The
// socket line parse mirrors TideySocketConnection's two accepted forms
// (JSON object line, or "<action> <state> --key=value ..." plaintext).
@interface TideyClaudeStatusPipelineTests : XCTestCase
@end

@implementation TideyClaudeStatusPipelineTests

- (NSDictionary *)parseSocketLine:(NSString *)line {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]]) {
        return json;
    }
    NSArray<NSString *> *parts = [[line componentsSeparatedByString:@" "]
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *s, NSDictionary *bindings) {
            return s.length > 0;
        }]];
    if (parts.count < 2) {
        return nil;
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"action"] = parts[0];
    dict[@"state"] = parts[1];
    for (NSUInteger i = 2; i < parts.count; i++) {
        NSString *part = parts[i];
        if ([part hasPrefix:@"--"] && part.length > 2) {
            NSString *kv = [part substringFromIndex:2];
            NSRange eq = [kv rangeOfString:@"="];
            if (eq.location != NSNotFound) {
                dict[[kv substringToIndex:eq.location]] = [kv substringFromIndex:eq.location + 1];
            }
        }
    }
    return dict;
}

- (void)applyMessage:(NSString *)line toStore:(TideyStatusStore *)store {
    NSDictionary *dict = [self parseSocketLine:line];
    XCTAssertNotNil(dict, @"unparseable socket line: %@", line);
    NSString *action = dict[@"action"];
    TideySocketCommand *command = nil;
    if ([action isEqualToString:@"report_shell_state"]) {
        command = [TideySocketCommandDecoder reportShellStateCommandFromMessage:dict];
    } else if ([action isEqualToString:@"set_status"]) {
        command = [TideySocketCommandDecoder setStatusCommandFromMessage:dict];
    } else if ([action isEqualToString:@"clear_status"]) {
        command = [TideySocketCommandDecoder clearStatusCommandFromMessage:dict];
    } else {
        return;  // notification.create / set_title: not status pipeline
    }
    XCTAssertNotNil(command, @"decoder rejected: %@", line);
    if (command.kind == TideySocketCommandKindClearStatus) {
        [store clearStatusForWorkspaceID:command.workspaceID
                                     key:command.key
                                 ownerID:command.statusOwnerID];
    } else {
        [store setStatusForWorkspaceID:command.workspaceID
                                   key:command.key
                                 value:command.value
                                  icon:command.icon
                              colorHex:command.colorHex
                               ownerID:command.statusOwnerID];
    }
}

- (void)applyClaudeHookEvent:(NSString *)event
                   stdinJSON:(NSString *)stdinJSON
                     toStore:(TideyStatusStore *)store {
    NSArray<NSString *> *messages =
        [TideyCLICommandFormatter messagesForClaudeHookEvent:event
                                                 workspaceID:@"workspace-1"
                                                     panelID:@"panel-1"
                                                   stdinJSON:stdinJSON
                                           transcriptContent:nil];
    for (NSString *message in messages) {
        [self applyMessage:message toStore:store];
    }
}

- (NSString *)shellStateOf:(TideyStatusStore *)store {
    for (TideyStatusEntry *entry in [store statusEntriesForWorkspaceID:@"workspace-1"]) {
        if ([entry.key isEqualToString:@"shell_state"]) {
            return entry.value;
        }
    }
    return nil;
}

- (void)testTwoSessionsAggregateAndPermissionLifecycle {
    TideyStatusStore *store = [[[TideyStatusStore alloc] init] autorelease];
    NSString *sessionA = @"{\"session_id\":\"session-a\"}";
    NSString *sessionB = @"{\"session_id\":\"session-b\"}";

    // Session A running; session B idle at prompt.
    [self applyClaudeHookEvent:@"prompt-submit" stdinJSON:sessionA toStore:store];
    [self applyClaudeHookEvent:@"notification-idle" stdinJSON:sessionB toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Running",
                          @"another session going idle must not overwrite the running one");

    // PermissionRequest alone changes nothing; the actual prompt does.
    [self applyClaudeHookEvent:@"permission-request" stdinJSON:sessionA toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Running");
    [self applyClaudeHookEvent:@"notification-permission" stdinJSON:sessionA toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Needs input");

    // Stop while a stop hook drives continuation: NOT a terminal.
    [self applyClaudeHookEvent:@"stop"
                     stdinJSON:@"{\"session_id\":\"session-a\",\"stop_hook_active\":true}"
                       toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Needs input");

    // Genuine stop for session A: its cell goes Idle; aggregate follows.
    [self applyClaudeHookEvent:@"stop" stdinJSON:sessionA toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Idle");

    // Session B starts working again; A's session-end clears only A's cell.
    [self applyClaudeHookEvent:@"prompt-submit" stdinJSON:sessionB toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Running");
    [self applyClaudeHookEvent:@"session-end" stdinJSON:sessionA toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Running");
}

- (void)testPostToolUseResolvesPermissionBackToRunning {
    TideyStatusStore *store = [[[TideyStatusStore alloc] init] autorelease];
    NSString *session = @"{\"session_id\":\"session-a\"}";

    [self applyClaudeHookEvent:@"prompt-submit" stdinJSON:session toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Running");

    [self applyClaudeHookEvent:@"notification-permission" stdinJSON:session toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Needs input");

    // Mac has no PostToolUse-equivalent tool_result signal today — this
    // hook is the resolution transport: the tool actually running proves
    // the permission was decided.
    [self applyClaudeHookEvent:@"post-tool-use" stdinJSON:session toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Running",
                          @"PostToolUse must resolve the permission prompt back to Running");

    [self applyClaudeHookEvent:@"stop" stdinJSON:session toStore:store];
    XCTAssertEqualObjects([self shellStateOf:store], @"Idle");
}

@end
