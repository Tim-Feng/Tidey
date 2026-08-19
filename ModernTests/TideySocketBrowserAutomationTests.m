#import <XCTest/XCTest.h>

#import "TideySocketConnection.h"
#import "TideySocketServer.h"

#include <sys/socket.h>
#include <unistd.h>

@interface TideySocketBrowserAutomationTests : XCTestCase
@end

typedef void (^TideySocketBrowserAutomationTestHandler)(
    NSString *workspaceID,
    NSString *operation,
    NSDictionary *parameters,
    NSString *sessionID,
    void (^completion)(NSDictionary * _Nullable result, NSDictionary * _Nullable error));

@interface TideySocketServer (BrowserAutomationTesting)
+ (void)tideyBrowserAutomationResponseForRequestMessage:(NSDictionary *)message
                                               sessionID:(NSString *)sessionID
                                                 handler:(TideySocketBrowserAutomationTestHandler)handler
                                              completion:(void (^)(NSDictionary *response))completion;
@end

@implementation TideySocketBrowserAutomationTests

- (void)testBrowserActionDispatchSeamUsesStablePerConnectionSessionIdentity {
    int firstPair[2] = { -1, -1 };
    int secondPair[2] = { -1, -1 };
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, firstPair), 0);
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, secondPair), 0);

    TideySocketConnection *first = [[TideySocketConnection alloc]
        initWithFileDescriptor:firstPair[0]
        messageHandler:^(TideySocketConnection *connection, NSDictionary *message) {}
        closeHandler:^(TideySocketConnection *connection) {}];
    TideySocketConnection *second = [[TideySocketConnection alloc]
        initWithFileDescriptor:secondPair[0]
        messageHandler:^(TideySocketConnection *connection, NSDictionary *message) {}
        closeHandler:^(TideySocketConnection *connection) {}];

    NSString *firstIdentity = first.automationSessionID;
    XCTAssertGreaterThan(firstIdentity.length, 0u);
    XCTAssertEqualObjects(first.automationSessionID, firstIdentity);
    XCTAssertNotEqualObjects(first.automationSessionID, second.automationSessionID);

    [first close];
    [second close];
    close(firstPair[1]);
    close(secondPair[1]);
}

- (void)testBrowserRequestBindsWorkspaceOperationAndConnectionSession {
    XCTestExpectation *expectation = [self expectationWithDescription:@"response"];
    [TideySocketServer tideyBrowserAutomationResponseForRequestMessage:@{
        @"id": @"request-1",
        @"action": @"browser_automation",
        @"params": @{
            @"workspace_id": @"workspace-1",
            @"operation": @"tabs",
            @"parameters": @{},
        },
    }
                                                            sessionID:@"session-1"
                                                              handler:^(NSString *workspaceID,
                                                                        NSString *operation,
                                                                        NSDictionary *parameters,
                                                                        NSString *sessionID,
                                                                        void (^completion)(NSDictionary *, NSDictionary *)) {
        XCTAssertEqualObjects(workspaceID, @"workspace-1");
        XCTAssertEqualObjects(operation, @"tabs");
        XCTAssertEqualObjects(parameters, @{});
        XCTAssertEqualObjects(sessionID, @"session-1");
        completion(@{ @"tabs": @[] }, nil);
    }
                                                           completion:^(NSDictionary *response) {
        XCTAssertEqualObjects(response[@"id"], @"request-1");
        XCTAssertEqualObjects(response[@"ok"], @YES);
        XCTAssertEqualObjects(response[@"result"][@"tabs"], @[]);
        [expectation fulfill];
    }];
    [self waitForExpectations:@[ expectation ] timeout:1];
}

- (void)testBrowserRequestRejectsMissingWorkspaceBeforeCallingHandler {
    __block BOOL called = NO;
    XCTestExpectation *expectation = [self expectationWithDescription:@"response"];
    [TideySocketServer tideyBrowserAutomationResponseForRequestMessage:@{
        @"id": @"request-2",
        @"action": @"browser_automation",
        @"params": @{ @"operation": @"tabs" },
    }
                                                            sessionID:@"session-1"
                                                              handler:^(NSString *workspaceID,
                                                                        NSString *operation,
                                                                        NSDictionary *parameters,
                                                                        NSString *sessionID,
                                                                        void (^completion)(NSDictionary *, NSDictionary *)) {
        called = YES;
    }
                                                           completion:^(NSDictionary *response) {
        XCTAssertEqualObjects(response[@"ok"], @NO);
        XCTAssertEqualObjects(response[@"error"][@"code"], @"invalid_request");
        [expectation fulfill];
    }];
    [self waitForExpectations:@[ expectation ] timeout:1];
    XCTAssertFalse(called);
}

@end
