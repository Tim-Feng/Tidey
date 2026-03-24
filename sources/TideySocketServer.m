#import "TideySocketServer.h"

#import "DebugLogging.h"
#import "TideyNotificationStore.h"
#import "TideySocketConnection.h"
#import "iTermSocket.h"
#import "iTermSocketAddress.h"

#include <sys/stat.h>
#include <sys/types.h>

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
    return [[self socketDirectory] stringByAppendingPathComponent:@"tidey.sock"];
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
    unlink(TideySocketServer.socketPath.UTF8String);

    self.socket = [iTermSocket unixDomainSocket];
    if (!self.socket) {
        XLog(@"Failed to create Tidey unix socket");
        return NO;
    }

    iTermSocketAddress *address = [iTermSocketAddress socketAddressWithPath:TideySocketServer.socketPath];
    if (![self.socket bindToAddress:address]) {
        XLog(@"Failed to bind Tidey unix socket");
        self.socket = nil;
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
        return NO;
    }

    self.started = YES;
    return YES;
}

- (void)acceptFileDescriptor:(int)fd {
    __weak __typeof(self) weakSelf = self;
    TideySocketConnection *connection =
        [[TideySocketConnection alloc] initWithFileDescriptor:fd
                                               messageHandler:^(NSDictionary *message) {
                                                   __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                   [strongSelf handleMessage:message];
                                               }
                                                 closeHandler:^(TideySocketConnection *closingConnection) {
                                                     __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                     [strongSelf.connections removeObject:closingConnection];
                                                 }];
    [self.connections addObject:connection];
}

- (void)handleMessage:(NSDictionary *)message {
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;

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

    if (![action isEqualToString:@"notification.create"] &&
        ![action isEqualToString:@"notification.create_for_workspace"]) {
        DLog(@"Ignoring unsupported Tidey socket action: %@", action);
        return;
    }

    NSString *workspaceID = [message[@"workspace_id"] isKindOfClass:[NSString class]] ? message[@"workspace_id"] : nil;
    NSString *title = [message[@"title"] isKindOfClass:[NSString class]] ? message[@"title"] : @"";
    NSString *subtitle = [message[@"subtitle"] isKindOfClass:[NSString class]] ? message[@"subtitle"] : nil;
    NSString *body = [message[@"body"] isKindOfClass:[NSString class]] ? message[@"body"] : @"";
    if ([action isEqualToString:@"notification.create_for_workspace"] && workspaceID.length == 0) {
        DLog(@"Ignoring malformed Tidey workspace notification payload: %@", message);
        return;
    }
    if (title.length == 0) {
        DLog(@"Ignoring malformed Tidey notification payload: %@", message);
        return;
    }

    TideyNotificationItem *item =
        [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:workspaceID
                                                                      title:title
                                                                   subtitle:subtitle
                                                                       body:body];
    [[TideyNotificationStore sharedStore] postSystemNotificationForItem:item];
}

- (void)handleReportShellState:(NSDictionary *)message {
    NSString *state = [message[@"state"] isKindOfClass:[NSString class]] ? message[@"state"] : nil;
    if (state.length == 0) {
        DLog(@"Ignoring report_shell_state with empty state: %@", message);
        return;
    }

    // workspace_id is optional. When absent, broadcast to all known workspaces
    // (same pattern as notification.create).
    NSString *workspaceID = [message[@"workspace_id"] isKindOfClass:[NSString class]] ? message[@"workspace_id"] : nil;

    NSString *value = nil;
    NSString *icon = nil;
    NSString *colorHex = nil;
    BOOL shouldClear = NO;

    if ([state isEqualToString:@"running"] ||
        [state isEqualToString:@"busy"] ||
        [state isEqualToString:@"command"]) {
        value = @"Running";
        icon = @"bolt.fill";
        colorHex = @"#007AFF";
    } else if ([state isEqualToString:@"prompt"] ||
               [state isEqualToString:@"idle"]) {
        value = @"Idle";
        icon = @"circle.fill";
        colorHex = @"#8E8E93";
    } else if ([state isEqualToString:@"unknown"] ||
               [state isEqualToString:@"clear"]) {
        shouldClear = YES;
    } else {
        DLog(@"Ignoring report_shell_state with unknown state '%@': %@", state, message);
        return;
    }

    NSString *const key = @"shell_state";
    TideyStatusStore *store = [TideyStatusStore sharedStore];

    if (workspaceID.length > 0) {
        if (shouldClear) {
            [store clearStatusForWorkspaceID:workspaceID key:key];
        } else {
            [store setStatusForWorkspaceID:workspaceID key:key value:value icon:icon colorHex:colorHex];
        }
    } else {
        // No workspace_id: use broadcast identifier so all workspaces show status.
        NSString *broadcastID = @"*";
        if (shouldClear) {
            [store clearStatusForWorkspaceID:broadcastID key:key];
        } else {
            [store setStatusForWorkspaceID:broadcastID key:key value:value icon:icon colorHex:colorHex];
        }
    }
}

- (void)handleSetStatus:(NSDictionary *)message {
    NSString *workspaceID = [message[@"workspace_id"] isKindOfClass:[NSString class]] ? message[@"workspace_id"] : nil;
    NSString *key = [message[@"key"] isKindOfClass:[NSString class]] ? message[@"key"] : nil;
    NSString *value = [message[@"value"] isKindOfClass:[NSString class]] ? message[@"value"] : nil;
    NSString *icon = [message[@"icon"] isKindOfClass:[NSString class]] ? message[@"icon"] : nil;
    NSString *color = [message[@"color"] isKindOfClass:[NSString class]] ? message[@"color"] : nil;

    if (key.length == 0 || value.length == 0) {
        DLog(@"Ignoring malformed set_status: missing key or value: %@", message);
        return;
    }
    if (workspaceID.length == 0) {
        // Broadcast: set status for all known workspaces is not well-defined.
        // For broadcast, the caller should specify workspace_id.
        DLog(@"Ignoring set_status with empty workspace_id: %@", message);
        return;
    }

    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:workspaceID
                                                        key:key
                                                      value:value
                                                       icon:icon
                                                   colorHex:color];
}

- (void)handleClearStatus:(NSDictionary *)message {
    NSString *workspaceID = [message[@"workspace_id"] isKindOfClass:[NSString class]] ? message[@"workspace_id"] : nil;
    NSString *key = [message[@"key"] isKindOfClass:[NSString class]] ? message[@"key"] : nil;

    if (workspaceID.length == 0 || key.length == 0) {
        DLog(@"Ignoring malformed clear_status: missing workspace_id or key: %@", message);
        return;
    }

    [[TideyStatusStore sharedStore] clearStatusForWorkspaceID:workspaceID key:key];
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
    self.started = NO;
}

@end
