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

static NSString *TideyDevelopmentSocketPath(void) {
    return [[TideySocketServer socketDirectory] stringByAppendingPathComponent:@"tidey-dev.sock"];
}

static NSString *TideyAlternateSocketPath(void) {
    return [[TideySocketServer socketDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"tidey-%d.sock", getpid()]];
}

static BOOL TideyBundleIdentifierPrefersDevelopmentSocket(void) {
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return [bundleIdentifier hasSuffix:@".dev"];
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

static BOOL TideySocketBoolParam(NSDictionary *params, NSString *key, BOOL defaultValue) {
    id value = params[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)value lowercaseString];
        if ([string isEqualToString:@"1"] ||
            [string isEqualToString:@"true"] ||
            [string isEqualToString:@"yes"]) {
            return YES;
        }
        if ([string isEqualToString:@"0"] ||
            [string isEqualToString:@"false"] ||
            [string isEqualToString:@"no"]) {
            return NO;
        }
    }
    return defaultValue;
}

static NSString *TideySubmitLogSuffix(NSString *input) {
    if (input.length == 0) {
        return @"";
    }
    NSUInteger start = input.length > 3 ? input.length - 3 : 0;
    NSString *suffix = [input substringFromIndex:start];
    suffix = [suffix stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    suffix = [suffix stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return suffix;
}

typedef BOOL (^TideySocketSendInputHandler)(NSString *workspaceID, NSString *input);
typedef NSString * _Nullable (^TideySocketRecentOutputProvider)(NSString *workspaceID);

@interface TideySocketServer ()
@property(nonatomic, strong) iTermSocket *socket;
@property(nonatomic, strong) NSMutableSet<TideySocketConnection *> *connections;
@property(nonatomic, strong) NSMapTable<TideySocketConnection *, NSString *> *workspaceEventSubscriptions;
@property(nonatomic) long long nextWorkspaceEventSequence;
@property(nonatomic) BOOL started;
@end

@interface TideySocketServer (Testing)
+ (nullable NSDictionary *)tideyResponseForRequestMessage:(NSDictionary *)message
                                       workspaceSummaries:(NSArray<NSDictionary *> *)workspaceSummaries
                                         sendInputHandler:(nullable TideySocketSendInputHandler)sendInputHandler
                                     recentOutputProvider:(nullable TideySocketRecentOutputProvider)recentOutputProvider;
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
        _workspaceEventSubscriptions = [NSMapTable strongToStrongObjectsMapTable];
        _nextWorkspaceEventSequence = 1;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleWorkspaceEventNotification:)
                                                     name:PseudoTerminalTideyWorkspaceEventNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    NSString *chosenPath = nil;
    if (TideyBundleIdentifierPrefersDevelopmentSocket()) {
        NSString *developmentPath = TideyDevelopmentSocketPath();
        if (TideySocketPathHasLiveListener(developmentPath)) {
            chosenPath = TideyAlternateSocketPath();
        } else {
            unlink(developmentPath.UTF8String);
            chosenPath = developmentPath;
        }
    } else {
        chosenPath = defaultPath;
        if (TideySocketPathHasLiveListener(defaultPath)) {
            chosenPath = TideyAlternateSocketPath();
        } else {
            unlink(defaultPath.UTF8String);
        }
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
                                                     [strongSelf removeWorkspaceEventSubscriptionForConnection:closingConnection];
                                                     [strongSelf.connections removeObject:closingConnection];
                                                 }];
    [self.connections addObject:connection];
}

- (PseudoTerminal *)tideyTerminalForWorkspaceIdentifier:(NSString *)workspaceIdentifier {
    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        if ([term tideySocketWorkspaceSummaryForWorkspaceIdentifier:workspaceIdentifier]) {
            return term;
        }
    }
    return nil;
}

- (PseudoTerminal *)tideyTerminalForPanelIdentifier:(NSString *)panelIdentifier {
    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        if ([term tideySocketPanelSummaryForPanelIdentifier:panelIdentifier]) {
            return term;
        }
    }
    return nil;
}

- (PseudoTerminal *)tideyTerminalForWindowGUID:(NSString *)windowGUID {
    if (windowGUID.length == 0) {
        return [iTermController sharedInstance].currentTerminal ?: [[[iTermController sharedInstance] terminals] firstObject];
    }
    return [[iTermController sharedInstance] terminalWithGuid:windowGUID];
}

- (void)setWorkspaceEventSubscriptionForConnection:(TideySocketConnection *)connection
                                       workspaceID:(NSString *)workspaceID {
    if (!connection) {
        return;
    }
    [self.workspaceEventSubscriptions setObject:(workspaceID ?: @"") forKey:connection];
}

- (void)removeWorkspaceEventSubscriptionForConnection:(TideySocketConnection *)connection {
    if (!connection) {
        return;
    }
    [self.workspaceEventSubscriptions removeObjectForKey:connection];
}

- (NSDictionary *)workspaceEventEnvelopeForEvent:(NSDictionary *)event {
    if (event.count == 0) {
        return nil;
    }
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:event];
    payload[@"event_id"] = [[NSUUID UUID] UUIDString];
    payload[@"seq"] = @(self.nextWorkspaceEventSequence++);
    payload[@"timestamp"] = [formatter stringFromDate:[NSDate date]];
    return @{
        @"type": @"workspace_event",
        @"v": @1,
        @"replay": @NO,
        @"event": payload,
    };
}

- (void)handleWorkspaceEventNotification:(NSNotification *)notification {
    NSDictionary *event = [notification.userInfo isKindOfClass:[NSDictionary class]] ? notification.userInfo : nil;
    NSDictionary *envelope = [self workspaceEventEnvelopeForEvent:event];
    if (!envelope) {
        return;
    }
    NSString *workspaceID = [event[@"workspace_id"] isKindOfClass:[NSString class]] ? event[@"workspace_id"] : nil;
    for (TideySocketConnection *connection in self.workspaceEventSubscriptions) {
        NSString *filterWorkspaceID = [self.workspaceEventSubscriptions objectForKey:connection];
        if (filterWorkspaceID.length > 0 &&
            ![filterWorkspaceID isEqualToString:workspaceID]) {
            continue;
        }
        [connection sendJSONObject:envelope];
    }
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
    NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : nil;
    NSDictionary *source = params ?: message;

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

    if ([action isEqualToString:@"subscribe_workspace_events"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        [self setWorkspaceEventSubscriptionForConnection:connection workspaceID:workspaceID];
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"subscribed"];
        if (workspaceID.length > 0) {
            result[@"workspace_id"] = workspaceID;
        }
        [self sendSuccessResponseForRequestID:requestID result:result onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"unsubscribe_workspace_events"]) {
        [self removeWorkspaceEventSubscriptionForConnection:connection];
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"subscribed": @NO }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"list_panels"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        if (workspaceID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"list_panels requires workspace_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        NSDictionary *result = [term tideySocketPanelListForWorkspaceIdentifier:workspaceID];
        if (!result) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"workspace_not_found"
                                        message:@"No workspace matched workspace_id."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID result:result onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"send_input"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        NSString *input = TideySocketStringParam(source, @"input");
        if (input.length == 0 || (panelID.length == 0 && workspaceID.length == 0)) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"send_input requires input and panel_id or workspace_id."
                                   onConnection:connection];
            return;
        }

        if (panelID.length > 0) {
            PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
            NSDictionary *panelSummary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
            if (!panelSummary) {
                [self sendErrorResponseForRequestID:requestID
                                               code:@"panel_not_found"
                                            message:@"No panel matched panel_id."
                                       onConnection:connection];
                return;
            }
            if (![term tideySendInput:input toPanelWithIdentifier:panelID]) {
                [self sendErrorResponseForRequestID:requestID
                                               code:@"panel_not_interactive"
                                            message:@"The panel does not accept terminal input."
                                       onConnection:connection];
                return;
            }
            [self sendSuccessResponseForRequestID:requestID
                                           result:@{ @"sent": @YES,
                                                     @"panel_id": panelID,
                                                     @"workspace_id": panelSummary[@"workspace_id"] ?: @"" }
                                      onConnection:connection];
            return;
        }

        [self handleSendInputRequest:message requestID:requestID onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"get_recent_output"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        NSInteger maxLines = TideySocketIntegerParam(source, @"max_lines", 200);
        NSInteger maxChars = TideySocketIntegerParam(source, @"max_chars", 12000);
        if (maxLines < 0) {
            maxLines = 0;
        }
        if (maxChars < 0) {
            maxChars = 0;
        }

        if (panelID.length > 0) {
            PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
            NSDictionary *panelSummary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
            if (!panelSummary) {
                [self sendErrorResponseForRequestID:requestID
                                               code:@"panel_not_found"
                                            message:@"No panel matched panel_id."
                                       onConnection:connection];
                return;
            }
            NSDictionary *snapshot = [term tideyRecentOutputSnapshotForPanelIdentifier:panelID];
            if (!snapshot) {
                [self sendErrorResponseForRequestID:requestID
                                               code:@"panel_not_interactive"
                                            message:@"The panel does not produce terminal output."
                                       onConnection:connection];
                return;
            }
            NSDictionary *trimmed = [self trimmedRecentOutputSnapshot:snapshot maxLines:maxLines maxChars:maxChars];
            [self sendSuccessResponseForRequestID:requestID
                                           result:@{ @"output": trimmed[@"output"] ?: @"",
                                                     @"cursor_row": trimmed[@"cursor_row"] ?: @0,
                                                     @"cursor_col": trimmed[@"cursor_col"] ?: @0,
                                                     @"panel_id": panelID,
                                                     @"workspace_id": panelSummary[@"workspace_id"] ?: @"" }
                                      onConnection:connection];
            return;
        }

        if (workspaceID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"get_recent_output requires panel_id or workspace_id."
                                   onConnection:connection];
            return;
        }
        [self handleGetRecentOutputRequest:message requestID:requestID onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"create_workspace"]) {
        NSString *windowGUID = TideySocketStringParam(source, @"window_guid");
        NSString *title = TideySocketStringParam(source, @"title");
        (void)TideySocketBoolParam(source, @"make_selected", YES);
        PseudoTerminal *term = [self tideyTerminalForWindowGUID:windowGUID];
        NSDictionary *result = [term tideyCreateWorkspaceWithCustomTitle:title];
        if (!result) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"window_not_found"
                                        message:@"Could not resolve a target terminal window."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID result:result onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"close_workspace"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        if (workspaceID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"close_workspace requires workspace_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        if (![term tideyCloseWorkspaceWithIdentifier:workspaceID]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"workspace_not_found"
                                        message:@"No workspace matched workspace_id."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"closed": @YES, @"workspace_id": workspaceID }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"rename_workspace"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        NSString *title = TideySocketStringParam(source, @"title");
        if (workspaceID.length == 0 || title == nil) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"rename_workspace requires workspace_id and title."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        if (![term tideyRenameWorkspaceWithIdentifier:workspaceID title:title]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"workspace_not_found"
                                        message:@"No workspace matched workspace_id."
                                   onConnection:connection];
            return;
        }
        NSDictionary *summary = [term tideySocketWorkspaceSummaryForWorkspaceIdentifier:workspaceID];
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"workspace": summary ?: @{} }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"rename_panel"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        NSString *title = TideySocketStringParam(source, @"title");
        if (panelID.length == 0 || title == nil) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"rename_panel requires panel_id and title."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
        if (![term tideyRenamePanelWithIdentifier:panelID title:title]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"panel_not_found"
                                        message:@"No panel matched panel_id."
                                   onConnection:connection];
            return;
        }
        NSDictionary *summary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"panel": summary ?: @{} }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"select_workspace"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        if (workspaceID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"select_workspace requires workspace_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        if (![term tideySelectWorkspaceWithIdentifier:workspaceID]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"workspace_not_found"
                                        message:@"No workspace matched workspace_id."
                                   onConnection:connection];
            return;
        }
        NSDictionary *summary = [term tideySocketWorkspaceSummaryForWorkspaceIdentifier:workspaceID];
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"selected": @YES,
                                                 @"workspace": summary ?: @{} }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"create_panel"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        (void)TideySocketBoolParam(source, @"make_selected", YES);
        if (workspaceID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"create_panel requires workspace_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        NSDictionary *result = [term tideyCreatePanelInWorkspaceWithIdentifier:workspaceID];
        if (!result) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"workspace_not_found"
                                        message:@"No workspace matched workspace_id."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID result:result onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"select_panel"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        if (panelID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"select_panel requires panel_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
        if (![term tideySelectPanelWithIdentifier:panelID]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"panel_not_found"
                                        message:@"No panel matched panel_id."
                                   onConnection:connection];
            return;
        }
        NSDictionary *panelSummary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
        NSString *workspaceID = [panelSummary[@"workspace_id"] isKindOfClass:[NSString class]] ? panelSummary[@"workspace_id"] : nil;
        NSDictionary *workspaceSummary = workspaceID.length > 0 ? [term tideySocketWorkspaceSummaryForWorkspaceIdentifier:workspaceID] : nil;
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"selected": @YES,
                                                 @"panel": panelSummary ?: @{},
                                                 @"workspace": workspaceSummary ?: @{} }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"close_panel"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        if (panelID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"close_panel requires panel_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
        NSDictionary *panelSummary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
        NSString *workspaceID = [panelSummary[@"workspace_id"] isKindOfClass:[NSString class]] ? panelSummary[@"workspace_id"] : @"";
        NSDictionary *workspaceSummary = workspaceID.length > 0 ? [term tideySocketWorkspaceSummaryForWorkspaceIdentifier:workspaceID] : nil;
        BOOL workspaceClosed = [workspaceSummary[@"panel_count"] integerValue] <= 1;
        if (![term tideyClosePanelWithIdentifier:panelID]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"panel_not_found"
                                        message:@"No panel matched panel_id."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"closed": @YES,
                                                 @"panel_id": panelID,
                                                 @"workspace_id": workspaceID ?: @"",
                                                 @"workspace_closed": @(workspaceClosed) }
                                  onConnection:connection];
        return;
    }

    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:message
                                                            workspaceSummaries:nil
                                                              sendInputHandler:nil
                                                          recentOutputProvider:nil];
    if (response) {
        [connection sendJSONObject:response];
    }
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
        NSDictionary *snapshot = [term tideyRecentOutputSnapshotForWorkspaceIdentifier:workspaceID];
        if (!snapshot) {
            continue;
        }
        NSDictionary *trimmed = [self trimmedRecentOutputSnapshot:snapshot maxLines:maxLines maxChars:maxChars];
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"output": trimmed[@"output"] ?: @"",
                                                 @"cursor_row": trimmed[@"cursor_row"] ?: @0,
                                                 @"cursor_col": trimmed[@"cursor_col"] ?: @0,
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

- (NSDictionary *)trimmedRecentOutputSnapshot:(NSDictionary *)snapshot
                                     maxLines:(NSInteger)maxLines
                                     maxChars:(NSInteger)maxChars {
    NSString *output = snapshot[@"output"] ?: @"";
    NSInteger cursorRow = [snapshot[@"cursor_row"] integerValue];
    NSInteger cursorCol = [snapshot[@"cursor_col"] integerValue];

    NSArray<NSString *> *lineArray = [output componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *lines = [lineArray mutableCopy];
    if (maxLines > 0 && (NSInteger)lines.count > maxLines) {
        NSInteger droppedLines = lines.count - maxLines;
        [lines removeObjectsInRange:NSMakeRange(0, droppedLines)];
        cursorRow = MAX(0, cursorRow - droppedLines);
    }

    cursorRow = MIN(cursorRow, MAX((NSInteger)lines.count - 1, 0));

    NSInteger cursorOffset = 0;
    for (NSInteger index = 0; index < cursorRow && index < (NSInteger)lines.count; index++) {
        cursorOffset += [lines[index] length] + 1;
    }
    if (cursorRow < (NSInteger)lines.count) {
        cursorOffset += MIN(cursorCol, [lines[cursorRow] length]);
    }

    NSString *trimmed = [lines componentsJoinedByString:@"\n"];
    if (maxChars > 0 && (NSInteger)trimmed.length > maxChars) {
        NSInteger droppedChars = trimmed.length - maxChars;
        trimmed = [trimmed substringFromIndex:droppedChars];
        cursorOffset = MAX(0, cursorOffset - droppedChars);
    }

    NSInteger derivedRow = 0;
    NSInteger derivedCol = 0;
    NSInteger boundedOffset = MIN(cursorOffset, trimmed.length);
    for (NSInteger index = 0; index < boundedOffset; index++) {
        if ([trimmed characterAtIndex:index] == '\n') {
            derivedRow++;
            derivedCol = 0;
        } else {
            derivedCol++;
        }
    }

    return @{
        @"output": trimmed ?: @"",
        @"cursor_row": @(derivedRow),
        @"cursor_col": @(derivedCol),
    };
}

+ (NSString *)tideyTrimmedRecentOutput:(NSString *)output maxLines:(NSInteger)maxLines maxChars:(NSInteger)maxChars {
    TideySocketServer *server = [[self alloc] init];
    return [server trimmedRecentOutput:output maxLines:maxLines maxChars:maxChars];
}

+ (NSDictionary *)tideySuccessResponseForRequestID:(NSString *)requestID result:(NSDictionary *)result {
    if (requestID.length == 0) {
        return nil;
    }
    return @{
        @"id": requestID,
        @"ok": @YES,
        @"result": result ?: @{},
    };
}

+ (NSDictionary *)tideyErrorResponseForRequestID:(NSString *)requestID code:(NSString *)code message:(NSString *)message {
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
    return response;
}

+ (NSDictionary *)tideyResponseForRequestMessage:(NSDictionary *)message
                               workspaceSummaries:(NSArray<NSDictionary *> *)workspaceSummaries
                                 sendInputHandler:(TideySocketSendInputHandler)sendInputHandler
                             recentOutputProvider:(TideySocketRecentOutputProvider)recentOutputProvider {
    NSString *requestID = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : nil;
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;
    if (requestID.length == 0 || action.length == 0) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"invalid_request"
                                            message:@"Missing request id or action."];
    }

    if ([action isEqualToString:@"ping"]) {
        return [self tideySuccessResponseForRequestID:requestID result:@{ @"pong": @YES }];
    }
    if ([action isEqualToString:@"list_workspaces"]) {
        return [self tideySuccessResponseForRequestID:requestID
                                               result:@{ @"workspaces": workspaceSummaries ?: @[] }];
    }

    NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : nil;
    NSDictionary *source = params ?: message;

    if ([action isEqualToString:@"subscribe_workspace_events"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"subscribed"];
        if (workspaceID.length > 0) {
            result[@"workspace_id"] = workspaceID;
        }
        return [self tideySuccessResponseForRequestID:requestID result:result];
    }

    if ([action isEqualToString:@"unsubscribe_workspace_events"]) {
        return [self tideySuccessResponseForRequestID:requestID result:@{ @"subscribed": @NO }];
    }

    if ([action isEqualToString:@"send_input"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        NSString *input = TideySocketStringParam(source, @"input");
        if (workspaceID.length == 0 || input.length == 0) {
            return [self tideyErrorResponseForRequestID:requestID
                                                   code:@"invalid_params"
                                                message:@"send_input requires workspace_id and input."];
        }
        if (sendInputHandler && sendInputHandler(workspaceID, input)) {
            return [self tideySuccessResponseForRequestID:requestID result:@{ @"sent": @YES }];
        }
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"workspace_not_found"
                                            message:@"No terminal workspace accepted the input."];
    }

    if ([action isEqualToString:@"get_recent_output"]) {
        NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
        if (workspaceID.length == 0) {
            return [self tideyErrorResponseForRequestID:requestID
                                                   code:@"invalid_params"
                                                message:@"get_recent_output requires workspace_id."];
        }
        NSInteger maxLines = TideySocketIntegerParam(source, @"max_lines", 200);
        NSInteger maxChars = TideySocketIntegerParam(source, @"max_chars", 12000);
        if (maxLines < 0) {
            maxLines = 0;
        }
        if (maxChars < 0) {
            maxChars = 0;
        }
        NSString *output = recentOutputProvider ? recentOutputProvider(workspaceID) : nil;
        if (!output) {
            return [self tideyErrorResponseForRequestID:requestID
                                                   code:@"workspace_not_found"
                                                message:@"No terminal workspace produced recent output."];
        }
        NSString *trimmed = [self tideyTrimmedRecentOutput:output maxLines:maxLines maxChars:maxChars];
        return [self tideySuccessResponseForRequestID:requestID
                                               result:@{ @"output": trimmed ?: @"",
                                                         @"workspace_id": workspaceID }];
    }

    return [self tideyErrorResponseForRequestID:requestID
                                           code:@"unsupported_action"
                                        message:[NSString stringWithFormat:@"Unsupported request action: %@", action]];
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
    [self.workspaceEventSubscriptions removeAllObjects];
    [self.socket close];
    self.socket = nil;
    unlink(TideySocketServer.socketPath.UTF8String);
    gTideyActiveSocketPath = nil;
    self.started = NO;
}

@end
