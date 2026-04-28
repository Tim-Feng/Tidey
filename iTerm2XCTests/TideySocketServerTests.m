#import <XCTest/XCTest.h>

#import "TideySocketServer.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

@interface TideySocketServer (Testing)
+ (NSDictionary *)tideyResponseForRequestMessage:(NSDictionary *)message
                              workspaceSummaries:(NSArray<NSDictionary *> *)workspaceSummaries
                                sendInputHandler:(BOOL (^)(NSString *workspaceID, NSString *input))sendInputHandler
                            recentOutputProvider:(NSString * _Nullable (^)(NSString *workspaceID))recentOutputProvider;
- (void)acceptFileDescriptor:(int)fd;
- (void)cleanupStaleSockets:(NSString *)directory;
- (NSUInteger)tideyTestingConnectionCount;
@end

@interface TideySocketServerTests : XCTestCase
@end

@implementation TideySocketServerTests

- (void)testPingRequestReturnsPong {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-1",
        @"action": @"ping",
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"id"], @"req-1");
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"pong"], @YES);
}

- (void)testListWorkspacesReturnsWorkspacesArray {
    NSArray *workspaces = @[
        @{ @"workspace_id": @"ws-1", @"title": @"Claude", @"state": @"running" },
        @{ @"workspace_id": @"ws-2", @"title": @"Codex", @"state": @"idle" },
    ];
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-2",
        @"action": @"list_workspaces",
    }
                                                                  workspaceSummaries:workspaces
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"workspaces"], workspaces);
}

- (void)testSendInputRequiresParams {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-3",
        @"action": @"send_input",
        @"params": @{ @"workspace_id": @"ws-1" },
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:^BOOL(NSString *workspaceID, NSString *input) {
                                                                        return YES;
                                                                    }
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects(response[@"error"][@"code"], @"invalid_params");
}

- (void)testGetRecentOutputRequiresWorkspaceID {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-4",
        @"action": @"get_recent_output",
        @"params": @{ @"max_lines": @10 },
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:^NSString *(NSString *workspaceID) {
                                                                    return @"ignored";
                                                                }];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects(response[@"error"][@"code"], @"invalid_params");
}

- (void)testUnsupportedActionReturnsError {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-5",
        @"action": @"bogus",
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects(response[@"error"][@"code"], @"unsupported_action");
}

- (void)testCleanupStaleSocketsRemovesDeadSocketFile {
    NSString *directory = [self temporarySocketDirectory];
    NSString *socketPath = [directory stringByAppendingPathComponent:@"dead.sock"];
    int fd = [self createBoundUnixSocketAtPath:socketPath listen:NO];
    XCTAssertGreaterThanOrEqual(fd, 0);
    close(fd);

    TideySocketServer *server = [[TideySocketServer alloc] init];
    [server cleanupStaleSockets:directory];

    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:socketPath]);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testCleanupStaleSocketsKeepsLiveSocketFile {
    NSString *directory = [self temporarySocketDirectory];
    NSString *socketPath = [directory stringByAppendingPathComponent:@"live.sock"];
    int fd = [self createBoundUnixSocketAtPath:socketPath listen:YES];
    XCTAssertGreaterThanOrEqual(fd, 0);

    TideySocketServer *server = [[TideySocketServer alloc] init];
    [server cleanupStaleSockets:directory];

    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:socketPath]);

    close(fd);
    unlink(socketPath.UTF8String);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testConnectionSetSurvivesRapidAcceptAndClose {
    TideySocketServer *server = [[TideySocketServer alloc] init];
    dispatch_queue_t closeQueue = dispatch_queue_create("com.tidey.tests.socket-close", DISPATCH_QUEUE_CONCURRENT);

    for (NSUInteger i = 0; i < 200; i++) {
        int fds[2] = { -1, -1 };
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
        [server acceptFileDescriptor:fds[0]];
        int writeFD = fds[1];
        dispatch_async(closeQueue, ^{
            close(writeFD);
        });
    }

    XCTAssertTrue([self waitForServer:server connectionCount:0 timeout:3]);
}

- (BOOL)waitForServer:(TideySocketServer *)server connectionCount:(NSUInteger)expected timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        if ([server tideyTestingConnectionCount] == expected) {
            return YES;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return [server tideyTestingConnectionCount] == expected;
}

- (NSString *)temporarySocketDirectory {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tidey-socket-tests.XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    char *result = mkdtemp(buffer);
    NSString *directory = result ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:result
                                                                                                 length:strlen(result)] : nil;
    free(buffer);
    XCTAssertNotNil(directory);
    return directory;
}

- (int)createBoundUnixSocketAtPath:(NSString *)path listen:(BOOL)shouldListen {
    unlink(path.UTF8String);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return fd;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    NSData *pathData = [path dataUsingEncoding:NSUTF8StringEncoding];
    memcpy(addr.sun_path, pathData.bytes, pathData.length);
    addr.sun_path[pathData.length] = '\0';
    if (bind(fd, (const struct sockaddr *)&addr, (socklen_t)sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    if (shouldListen && listen(fd, 1) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

@end
