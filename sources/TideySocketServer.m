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
