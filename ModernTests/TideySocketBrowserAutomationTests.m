#import <XCTest/XCTest.h>

#import "TideySocketConnection.h"

#include <sys/socket.h>
#include <unistd.h>

@interface TideySocketBrowserAutomationTests : XCTestCase
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

@end
