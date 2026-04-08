#import "TideySocketServer.h"

#import "DebugLogging.h"
#import "PseudoTerminal.h"
#import "TideyNotificationStore.h"
#import "TideySocketCommandDecoder.h"
#import "TideySocketConnection.h"
#import "iTermController.h"
#import "iTermSocket.h"
#import "iTermSocketAddress.h"

#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

static NSString *gTideyActiveSocketPath = nil;

static NSString *TideyDefaultSocketPath(void) {
    return [[TideySocketServer socketDirectory] stringByAppendingPathComponent:@"tidey.sock"];
}

static NSString *TideyAlternateSocketPath(void) {
    return [[TideySocketServer socketDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"tidey-%d.sock", getpid()]];
}

static BOOL TideySocketPathHasLiveListener(NSString *path) {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return NO;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    NSData *pathData = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (pathData.length == 0 || pathData.length >= sizeof(addr.sun_path)) {
        close(fd);
        return NO;
    }
    memcpy(addr.sun_path, pathData.bytes, pathData.length);
    addr.sun_path[pathData.length] = '\0';

    const socklen_t len = (socklen_t)sizeof(addr);
    const BOOL connected =
        (connect(fd, (const struct sockaddr *)&addr, len) == 0);
    close(fd);
    return connected;
}

static NSString *TideySocketStringParam(NSDictionary *params, NSString *key) {
    id value = params[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSInteger TideySocketIntegerParam(NSDictionary *params, NSString *key, NSInteger defaultValue) {
    id value = params[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value integerValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [value integerValue];
    }
    return defaultValue;
}

@interface TideySocketServer ()
@property(nonatomic, strong) iTermSocket *socket;
@property(nonatomic, strong) NSMutableSet<TideySocketConnection *> *connections;
@property(nonatomic) BOOL started;
@end

@implementation TideySocketServer

+ (instancetype)sharedServer {
    static TideySocketServer *server;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        server = [[self alloc] init];
    });
    return server;
}

+ (NSString *)socketDirectory {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] stringByAppendingPathComponent:@"Tidey"];
}

+ (NSString *)socketPath {
    return gTideyActiveSocketPath ?: TideyDefaultSocketPath();
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _connections = [[NSMutableSet alloc] init];
    }
    return self;
}

- (BOOL)start {
    if (self.started) {
        return YES;
    }
    NSString *directory = [TideySocketServer socketDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:@{ NSFilePosixPermissions: @(0700) }
                                                    error:nil];
    [self cleanupStaleSockets:directory];

    NSString *defaultPath = TideyDefaultSocketPath();
    NSString *chosenPath = defaultPath;
    if (TideySocketPathHasLiveListener(defaultPath)) {
        chosenPath = TideyAlternateSocketPath();
    } else {
        unlink(defaultPath.UTF8String);
    }

    if (![chosenPath isEqualToString:defaultPath]) {
        unlink(chosenPath.UTF8String);
    }
    gTideyActiveSocketPath = [chosenPath copy];

    self.socket = [iTermSocket unixDomainSocket];
    if (!self.socket) {
        XLog(@"Failed to create Tidey unix socket");
        gTideyActiveSocketPath = nil;
        return NO;
    }

    iTermSocketAddress *address = [iTermSocketAddress socketAddressWithPath:TideySocketServer.socketPath];
    if (![self.socket bindToAddress:address]) {
        XLog(@"Failed to bind Tidey unix socket");
        self.socket = nil;
        gTideyActiveSocketPath = nil;
        return NO;
    }
    chmod(TideySocketServer.socketPath.UTF8String, (S_IRUSR | S_IWUSR));

    __weak __typeof(self) weakSelf = self;
    BOOL ok = [self.socket listenWithBacklog:5 accept:^(int fd, iTermSocketAddress *clientAddress, NSNumber *euid) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf acceptFileDescriptor:fd];
    }];
    if (!ok) {
        XLog(@"Failed to listen on Tidey unix socket");
        [self.socket close];
        self.socket = nil;
        unlink(TideySocketServer.socketPath.UTF8String);
        gTideyActiveSocketPath = nil;
        return NO;
    }

    self.started = YES;
    return YES;
}

- (void)cleanupStaleSockets:(NSString *)directory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *entry in entries) {
        if (![entry hasSuffix:@".sock"]) {
            continue;
        }
        NSString *path = [directory stringByAppendingPathComponent:entry];
        if (!TideySocketPathHasLiveListener(path)) {
            DLog(@"Removing stale socket: %@", entry);
            unlink(path.UTF8String);
        }
    }
}

- (void)acceptFileDescriptor:(int)fd {
    __weak __typeof(self) weakSelf = self;
    TideySocketConnection *connection =
        [[TideySocketConnection alloc] initWithFileDescriptor:fd
                                               messageHandler:^(TideySocketConnection *connection, NSDictionary *message) {
                                                   __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                   [strongSelf handleMessage:message onConnection:connection];
                                               }
                                                 closeHandler:^(TideySocketConnection *closingConnection) {
                                                     __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                     [strongSelf.connections removeObject:closingConnection];
                                                 }];
    [self.connections addObject:connection];
}

- (void)handleMessage:(NSDictionary *)message onConnection:(TideySocketConnection *)connection {
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;
    NSString *requestID = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : nil;
    if (requestID.length > 0) {
        [self handleRequestMessage:message onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"set_status"]) {
        [self handleSetStatus:message];
        return;
    }
    if ([action isEqualToString:@"clear_status"]) {
        [self handleClearStatus:message];
        return;
    }
    if ([action isEqualToString:@"report_shell_state"]) {
        [self handleReportShellState:message];
        return;
    }
    if ([action isEqualToString:@"set_title"]) {
        [self handleSetTitle:message];
        return;
    }

    if (![action isEqualToString:@"notification.create"] &&
        ![action isEqualToString:@"notification.create_for_workspace"]) {
        DLog(@"Ignoring unsupported Tidey socket action: %@", action);
        return;
    }

    TideySocketCommand *command = [TideySocketCommandDecoder notificationCommandFromMessage:message];
    if (!command) {
        DLog(@"Ignoring malformed Tidey notification payload: %@", message);
        return;
    }

    TideyNotificationItem *item =
        [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:command.workspaceID
                                                                      title:command.title
                                                                   subtitle:command.subtitle
                                                                       body:command.body];
    [[TideyNotificationStore sharedStore] postSystemNotificationForItem:item];
}

- (void)handleRequestMessage:(NSDictionary *)message onConnection:(TideySocketConnection *)connection {
    NSString *requestID = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : nil;
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;
    if (requestID.length == 0 || action.length == 0) {
        [self sendErrorResponseForRequestID:requestID
                                       code:@"invalid_request"
                                    message:@"Missing request id or action."
                               onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"ping"]) {
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"pong": @YES }
                                  onConnection:connection];
        return;
    }
    if ([action isEqualToString:@"list_workspaces"]) {
        [self handleListWorkspacesRequestWithID:requestID onConnection:connection];
        return;
    }
    if ([action isEqualToString:@"send_input"]) {
        [self handleSendInputRequest:message requestID:requestID onConnection:connection];
        return;
    }
    if ([action isEqualToString:@"get_recent_output"]) {
        [self handleGetRecentOutputRequest:message requestID:requestID onConnection:connection];
        return;
    }

    [self sendErrorResponseForRequestID:requestID
                                   code:@"unsupported_action"
                                message:[NSString stringWithFormat:@"Unsupported request action: %@", action]
                           onConnection:connection];
}

- (void)handleListWorkspacesRequestWithID:(NSString *)requestID
                             onConnection:(TideySocketConnection *)connection {
    NSMutableArray<NSDictionary *> *workspaces = [NSMutableArray array];
    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        [workspaces addObjectsFromArray:[term tideySocketWorkspaceSummaries]];
    }
    [self sendSuccessResponseForRequestID:requestID
                                   result:@{ @"workspaces": workspaces }
                              onConnection:connection];
}

- (void)handleSendInputRequest:(NSDictionary *)message
                     requestID:(NSString *)requestID
                  onConnection:(TideySocketConnection *)connection {
    NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : nil;
    NSString *workspaceID = TideySocketStringParam(params ?: message, @"workspace_id");
    NSString *input = TideySocketStringParam(params ?: message, @"input");
    if (workspaceID.length == 0 || input.length == 0) {
        [self sendErrorResponseForRequestID:requestID
                                       code:@"invalid_params"
                                    message:@"send_input requires workspace_id and input."
                               onConnection:connection];
        return;
    }

    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        if ([term tideySendInput:input toWorkspaceWithIdentifier:workspaceID]) {
            [self sendSuccessResponseForRequestID:requestID
                                           result:@{ @"sent": @YES }
                                      onConnection:connection];
            return;
        }
    }

    [self sendErrorResponseForRequestID:requestID
                                   code:@"workspace_not_found"
                                message:@"No terminal workspace accepted the input."
                           onConnection:connection];
}

- (void)handleGetRecentOutputRequest:(NSDictionary *)message
                           requestID:(NSString *)requestID
                        onConnection:(TideySocketConnection *)connection {
    NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : nil;
    NSString *workspaceID = TideySocketStringParam(params ?: message, @"workspace_id");
    if (workspaceID.length == 0) {
        [self sendErrorResponseForRequestID:requestID
                                       code:@"invalid_params"
                                    message:@"get_recent_output requires workspace_id."
                               onConnection:connection];
        return;
    }

    NSInteger maxLines = TideySocketIntegerParam(params ?: message, @"max_lines", 200);
    NSInteger maxChars = TideySocketIntegerParam(params ?: message, @"max_chars", 12000);
    if (maxLines < 0) {
        maxLines = 0;
    }
    if (maxChars < 0) {
        maxChars = 0;
    }

    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        NSString *output = [term tideyRecentOutputForWorkspaceIdentifier:workspaceID];
        if (!output) {
            continue;
        }
        NSString *trimmed = [self trimmedRecentOutput:output maxLines:maxLines maxChars:maxChars];
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"output": trimmed ?: @"",
                                                 @"workspace_id": workspaceID }
                                  onConnection:connection];
        return;
    }

    [self sendErrorResponseForRequestID:requestID
                                   code:@"workspace_not_found"
                                message:@"No terminal workspace produced recent output."
                           onConnection:connection];
}

- (NSString *)trimmedRecentOutput:(NSString *)output maxLines:(NSInteger)maxLines maxChars:(NSInteger)maxChars {
    NSString *trimmed = output ?: @"";
    if (maxLines > 0) {
        NSArray<NSString *> *lines = [trimmed componentsSeparatedByString:@"\n"];
        if ((NSInteger)lines.count > maxLines) {
            lines = [lines subarrayWithRange:NSMakeRange(lines.count - maxLines, maxLines)];
            trimmed = [lines componentsJoinedByString:@"\n"];
        }
    }
    if (maxChars > 0 && (NSInteger)trimmed.length > maxChars) {
        trimmed = [trimmed substringFromIndex:trimmed.length - maxChars];
    }
    return trimmed;
}

- (void)sendSuccessResponseForRequestID:(NSString *)requestID
                                 result:(NSDictionary *)result
                            onConnection:(TideySocketConnection *)connection {
    if (requestID.length == 0) {
        return;
    }
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id": requestID,
        @"ok": @YES,
    }];
    response[@"result"] = result ?: @{};
    [connection sendJSONObject:response];
}

- (void)sendErrorResponseForRequestID:(NSString *)requestID
                                 code:(NSString *)code
                              message:(NSString *)message
                         onConnection:(TideySocketConnection *)connection {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @NO,
        @"error": @{
            @"code": code ?: @"unknown_error",
            @"message": message ?: @"Unknown error",
        },
    }];
    if (requestID.length > 0) {
        response[@"id"] = requestID;
    }
    [connection sendJSONObject:response];
}

- (void)handleReportShellState:(NSDictionary *)message {
    TideySocketCommand *command = [TideySocketCommandDecoder reportShellStateCommandFromMessage:message];
    if (!command) {
        DLog(@"Ignoring malformed report_shell_state payload: %@", message);
        return;
    }

    TideyStatusStore *store = [TideyStatusStore sharedStore];
    if (command.kind == TideySocketCommandKindClearStatus) {
        [store clearStatusForWorkspaceID:command.workspaceID key:command.key];
    } else {
        [store setStatusForWorkspaceID:command.workspaceID
                                   key:command.key
                                 value:command.value
                                  icon:command.icon
                              colorHex:command.colorHex];
    }
}

- (void)handleSetStatus:(NSDictionary *)message {
    TideySocketCommand *command = [TideySocketCommandDecoder setStatusCommandFromMessage:message];
    if (!command) {
        DLog(@"Ignoring malformed set_status payload: %@", message);
        return;
    }

    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:command.workspaceID
                                                        key:command.key
                                                      value:command.value
                                                       icon:command.icon
                                                   colorHex:command.colorHex];
}

- (void)handleClearStatus:(NSDictionary *)message {
    TideySocketCommand *command = [TideySocketCommandDecoder clearStatusCommandFromMessage:message];
    if (!command) {
        DLog(@"Ignoring malformed clear_status payload: %@", message);
        return;
    }

    [[TideyStatusStore sharedStore] clearStatusForWorkspaceID:command.workspaceID key:command.key];
}

- (void)handleSetTitle:(NSDictionary *)message {
    TideySocketCommand *command = [TideySocketCommandDecoder setTitleCommandFromMessage:message];
    if (!command) {
        DLog(@"Ignoring malformed set_title payload: %@", message);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
            if (command.title.length == 0) {
                [term tideyClearWorkspaceTitleForWorkspaceID:command.workspaceID];
            } else {
                [term tideySetWorkspaceTitle:command.title forWorkspaceID:command.workspaceID];
            }
        }
    });
}

- (void)stop {
    if (!self.started) {
        return;
    }
    for (TideySocketConnection *connection in self.connections.allObjects) {
        [connection close];
    }
    [self.connections removeAllObjects];
    [self.socket close];
    self.socket = nil;
    unlink(TideySocketServer.socketPath.UTF8String);
    gTideyActiveSocketPath = nil;
    self.started = NO;
}

@end
