#import "TideySocketServer.h"

#import "DebugLogging.h"
#import "PseudoTerminal.h"
#import "TideyNotificationStore.h"
#import "TideySocketCommandDecoder.h"
#import "TideySocketConnection.h"
#import "iTermController.h"
#import "iTermSocket.h"
#import "iTermSocketAddress.h"
#import "iTerm2SharedARC-Swift.h"

#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

static NSString *gTideyActiveSocketPath = nil;

static dispatch_queue_t TideyRuntimeTmuxServerPreparationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.tidey.runtime-tmux-server-preparation",
            DISPATCH_QUEUE_SERIAL
        );
    });
    return queue;
}

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

static NSDictionary<NSString *, NSString *> *TideySocketStringDictionaryParam(NSDictionary *params, NSString *key) {
    id value = params[key];
    if (![value isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id dictKey, id dictValue, BOOL *stop) {
        if (![dictKey isKindOfClass:[NSString class]] || ![dictValue isKindOfClass:[NSString class]]) {
            [result removeAllObjects];
            *stop = YES;
            return;
        }
        result[dictKey] = dictValue;
    }];
    if (result.count == 0 && [(NSDictionary *)value count] > 0) {
        return nil;
    }
    return result;
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
typedef NSDictionary * _Nullable (^TideySocketNativeTerminalSizeHandler)(
    NSString *action,
    NSString *panelID,
    NSString * _Nullable token,
    NSInteger columns,
    NSInteger rows);
typedef void (^TideySocketBrowserAutomationHandler)(
    NSString *workspaceID,
    NSString *operation,
    NSDictionary *parameters,
    NSString *sessionID,
    void (^completion)(NSDictionary * _Nullable result, NSDictionary * _Nullable error));
typedef NSDictionary * _Nullable (^TideySocketRuntimeTmuxServerPreparationHandler)(
    NSString *serverIdentifier);
typedef NSDictionary * _Nullable (^TideySocketTerminalHistoryPageHandler)(
    NSString * _Nullable panelID,
    NSString * _Nullable workspaceID,
    NSNumber * _Nullable beforeAbsoluteLine,
    NSInteger pageLines,
    NSNumber *routeGeneration);

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
+ (NSDictionary *)tideyNativeTerminalSizeResponseForRequestID:(NSString *)requestID
                                                        action:(NSString *)action
                                                        source:(NSDictionary *)source
                                                       handler:(TideySocketNativeTerminalSizeHandler)handler;
+ (void)tideyBrowserAutomationResponseForRequestMessage:(NSDictionary *)message
                                               sessionID:(NSString *)sessionID
                                                 handler:(TideySocketBrowserAutomationHandler)handler
                                              completion:(void (^)(NSDictionary *response))completion;
+ (NSDictionary *)tideyRuntimeTmuxServerPreparationResponseForRequestID:(NSString *)requestID
                                                                  source:(NSDictionary *)source
                                                                 handler:(TideySocketRuntimeTmuxServerPreparationHandler)handler;
+ (NSDictionary *)tideyTerminalHistoryPageResponseForRequestID:(NSString *)requestID
                                                          source:(NSDictionary *)source
                                                         handler:(TideySocketTerminalHistoryPageHandler)handler;
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
                                                      [strongSelf connectionDidClose:closingConnection];
                                                 }];
    [self registerAcceptedConnection:connection];
}

- (void)registerAcceptedConnection:(TideySocketConnection *)connection {
    if (!connection) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self registerAcceptedConnection:connection];
        });
        return;
    }
    [self.connections addObject:connection];
    [connection startReading];
}

- (void)connectionDidClose:(TideySocketConnection *)connection {
    if (!connection) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectionDidClose:connection];
        });
        return;
    }
    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        [term tideyCleanupBrowserAutomationSession:connection.automationSessionID];
    }
    [self.workspaceEventSubscriptions removeObjectForKey:connection];
    [self.connections removeObject:connection];
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

- (PseudoTerminal *)tideyTerminalForWorkspaceListSource:(NSDictionary *)source sourceWasSpecified:(BOOL *)sourceWasSpecified {
    NSString *windowGUID = TideySocketStringParam(source, @"source_window_guid");
    NSString *panelID = TideySocketStringParam(source, @"source_panel_id");
    NSString *workspaceID = TideySocketStringParam(source, @"source_workspace_id");

    const BOOL hasSource = windowGUID.length > 0 || panelID.length > 0 || workspaceID.length > 0;
    if (sourceWasSpecified) {
        *sourceWasSpecified = hasSource;
    }
    if (!hasSource) {
        return nil;
    }
    if (windowGUID.length > 0) {
        return [self tideyTerminalForWindowGUID:windowGUID];
    }
    if (panelID.length > 0) {
        return [self tideyTerminalForPanelIdentifier:panelID];
    }
    return [self tideyTerminalForWorkspaceIdentifier:workspaceID];
}

- (void)setWorkspaceEventSubscriptionForConnection:(TideySocketConnection *)connection
                                       workspaceID:(NSString *)workspaceID {
    if (!connection) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setWorkspaceEventSubscriptionForConnection:connection workspaceID:workspaceID];
        });
        return;
    }
    [self.workspaceEventSubscriptions setObject:(workspaceID ?: @"") forKey:connection];
}

- (void)removeWorkspaceEventSubscriptionForConnection:(TideySocketConnection *)connection {
    if (!connection) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeWorkspaceEventSubscriptionForConnection:connection];
        });
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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleWorkspaceEventNotification:notification];
        });
        return;
    }
    NSDictionary *event = [notification.userInfo isKindOfClass:[NSDictionary class]] ? notification.userInfo : nil;
    NSDictionary *envelope = [self workspaceEventEnvelopeForEvent:event];
    if (!envelope) {
        return;
    }
    NSString *workspaceID = [event[@"workspace_id"] isKindOfClass:[NSString class]] ? event[@"workspace_id"] : nil;
    NSArray<TideySocketConnection *> *connections = self.workspaceEventSubscriptions.keyEnumerator.allObjects;
    for (TideySocketConnection *connection in connections) {
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

    if ([action isEqualToString:@"browser_automation"]) {
        [[self class]
            tideyBrowserAutomationResponseForRequestMessage:message
            sessionID:connection.automationSessionID
            handler:^(NSString *workspaceID,
                      NSString *operation,
                      NSDictionary *parameters,
                      NSString *sessionID,
                      void (^completion)(NSDictionary *, NSDictionary *)) {
                PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
                if (!term) {
                    completion(nil, @{
                        @"code": @"workspace_not_found",
                        @"message": @"No workspace matched workspace_id.",
                    });
                    return;
                }
                [term tideyHandleBrowserAutomationOperation:operation
                                                  parameters:parameters
                                                 workspaceID:workspaceID
                                              ownerSessionID:sessionID
                                                  completion:completion];
            }
            completion:^(NSDictionary *response) {
                [connection sendJSONObject:response];
            }];
        return;
    }

    if ([action isEqualToString:@"list_workspaces"]) {
        [self handleListWorkspacesRequestWithID:requestID source:source onConnection:connection];
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

    if ([action isEqualToString:@"prepare_isolated_tmux_server"]) {
        NSString *supportDirectory = [[self class] socketDirectory];
        NSString *homeDirectory = NSHomeDirectory();
        NSString *binDirectory = [[[NSBundle mainBundle] resourcePath]
            stringByAppendingPathComponent:@"bin"] ?: @"";
        TideyRuntimeTaskEnvironmentBuilder *environmentBuilder =
            [[TideyRuntimeTaskEnvironmentBuilder alloc] init];
        NSDictionary<NSString *, NSString *> *environment =
            [environmentBuilder
                environmentWithParentEnvironment:
                    [NSProcessInfo processInfo].environment
                canonicalSocketPath:[[self class] socketPath] ?: @""
                canonicalBinDirectory:binDirectory];
        TideyRuntimeTmuxExecutableLocator *locator =
            [[TideyRuntimeTmuxExecutableLocator alloc] init];
        NSString *tmuxExecutable = [locator
            executablePathWithEnvironmentPath:environment[@"PATH"]
            fallbackPaths:@[
                @"/opt/homebrew/bin/tmux",
                @"/usr/local/bin/tmux",
                @"/usr/bin/tmux",
            ]] ?: @"";
        dispatch_async(TideyRuntimeTmuxServerPreparationQueue(), ^{
            NSDictionary *response = [[self class]
                tideyRuntimeTmuxServerPreparationResponseForRequestID:requestID
                source:source
                handler:^NSDictionary *(NSString *serverIdentifier) {
                    TideyRuntimeTmuxServerPreparer *preparer =
                        [[TideyRuntimeTmuxServerPreparer alloc] init];
                    TideyRuntimeTmuxServerPreparationResult *result =
                        [preparer
                            prepareWithServerIdentifier:serverIdentifier
                            supportDirectory:supportDirectory
                            homeDirectory:homeDirectory
                            tmuxExecutable:tmuxExecutable
                            environment:environment
                            timeout:10];
                    return [result responseDictionary];
                }];
            dispatch_async(dispatch_get_main_queue(), ^{
                [connection sendJSONObject:response];
            });
        });
        return;
    }

    if ([action isEqualToString:@"update_runtime_resume_descriptor"] ||
        [action isEqualToString:@"stage_runtime_resume_descriptor"]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleRequestMessage:message onConnection:connection];
            });
            return;
        }
        NSDictionary *binding =
            [source[@"binding"] isKindOfClass:[NSDictionary class]]
                ? source[@"binding"]
                : nil;
        NSString *panelID = TideySocketStringParam(binding, @"panel_id");
        NSString *workspaceID =
            TideySocketStringParam(binding, @"workspace_id");
        PseudoTerminal *term =
            [self tideyTerminalForPanelIdentifier:panelID] ?:
            [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        if (!term) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"stale_binding"
                                        message:@"Runtime descriptor binding is no longer current."
                                   onConnection:connection];
            return;
        }
        NSDictionary *result =
            [action isEqualToString:@"stage_runtime_resume_descriptor"]
                ? [term tideyStageRuntimeResumeDescriptorPayload:source]
                : [term tideyAcceptRuntimeResumeDescriptorUpdatePayload:source];
        if (![result[@"accepted"] boolValue]) {
            NSString *code =
                [result[@"error_code"] isKindOfClass:[NSString class]]
                    ? result[@"error_code"]
                    : @"invalid_descriptor";
            [self sendErrorResponseForRequestID:requestID
                                           code:code
                                        message:@"Runtime descriptor update was rejected."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:result
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"list_runtime_resume_descriptors"]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleRequestMessage:message onConnection:connection];
            });
            return;
        }
        NSMutableArray<NSDictionary *> *descriptors =
            [NSMutableArray array];
        for (PseudoTerminal *term in
                [[iTermController sharedInstance] terminals]) {
            [descriptors addObjectsFromArray:
                [term tideyRuntimeAgentDescriptorSnapshots]];
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"descriptors": descriptors }
                                  onConnection:connection];
        return;
    }

    if ([action isEqualToString:@"remove_runtime_resume_descriptor"]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleRequestMessage:message onConnection:connection];
            });
            return;
        }
        NSDictionary *binding =
            [source[@"binding"] isKindOfClass:[NSDictionary class]]
                ? source[@"binding"]
                : nil;
        NSString *panelID = TideySocketStringParam(binding, @"panel_id");
        NSString *workspaceID =
            TideySocketStringParam(binding, @"workspace_id");
        PseudoTerminal *term =
            [self tideyTerminalForPanelIdentifier:panelID] ?:
            [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        if (!term) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"stale_binding"
                                        message:@"Runtime descriptor binding is no longer current."
                                   onConnection:connection];
            return;
        }
        NSDictionary *result =
            [term tideyRemoveRuntimeResumeDescriptorPayload:source];
        if (![result[@"accepted"] boolValue]) {
            NSString *code =
                [result[@"error_code"] isKindOfClass:[NSString class]]
                    ? result[@"error_code"]
                    : @"invalid_descriptor";
            [self sendErrorResponseForRequestID:requestID
                                           code:code
                                        message:@"Runtime descriptor removal was rejected."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:result
                                  onConnection:connection];
        return;
    }

    if ([@[ @"native_terminal_size_acquire",
             @"native_terminal_size_update",
             @"native_terminal_size_heartbeat",
             @"native_terminal_size_release" ] containsObject:action]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleRequestMessage:message onConnection:connection];
            });
            return;
        }
        NSDictionary *response = [[self class]
            tideyNativeTerminalSizeResponseForRequestID:requestID
            action:action
            source:source
            handler:^NSDictionary *(NSString *operation,
                                     NSString *panelID,
                                     NSString *token,
                                     NSInteger columns,
                                     NSInteger rows) {
                PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
                if (!term) {
                    return @{ @"accepted": @NO, @"error_code": @"stale_binding" };
                }
                if ([operation isEqualToString:@"native_terminal_size_acquire"]) {
                    return [term tideyAcquireNativeTerminalSizeForPanelIdentifier:panelID
                                                                          columns:columns
                                                                             rows:rows];
                }
                if ([operation isEqualToString:@"native_terminal_size_update"]) {
                    return [term tideyUpdateNativeTerminalSizeForPanelIdentifier:panelID
                                                                           token:token
                                                                         columns:columns
                                                                            rows:rows];
                }
                if ([operation isEqualToString:@"native_terminal_size_heartbeat"]) {
                    return [term tideyHeartbeatNativeTerminalSizeForPanelIdentifier:panelID
                                                                              token:token];
                }
                return [term tideyReleaseNativeTerminalSizeForPanelIdentifier:panelID
                                                                         token:token];
            }];
        [connection sendJSONObject:response];
        return;
    }

    if ([action isEqualToString:@"get_terminal_history_page"]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleRequestMessage:message onConnection:connection];
            });
            return;
        }
        NSDictionary *response = [[self class]
            tideyTerminalHistoryPageResponseForRequestID:requestID
            source:source
            handler:^NSDictionary *(NSString *panelID,
                                     NSString *workspaceID,
                                     NSNumber *beforeAbsoluteLine,
                                     NSInteger pageLines,
                                     NSNumber *routeGeneration) {
                PseudoTerminal *term = panelID.length > 0
                    ? [self tideyTerminalForPanelIdentifier:panelID]
                    : [self tideyTerminalForWorkspaceIdentifier:workspaceID];
                if (!term) {
                    return nil;
                }
                NSDictionary *page = panelID.length > 0
                    ? [term tideyTerminalHistoryPageForPanelIdentifier:panelID
                                                    beforeAbsoluteLine:beforeAbsoluteLine
                                                             pageLines:pageLines]
                    : [term tideyTerminalHistoryPageForWorkspaceIdentifier:workspaceID
                                                        beforeAbsoluteLine:beforeAbsoluteLine
                                                                 pageLines:pageLines];
                if (!page) {
                    return nil;
                }
                NSMutableDictionary *identified = [page mutableCopy];
                if (panelID.length > 0) {
                    identified[@"panel_id"] = panelID;
                    NSDictionary *summary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
                    if ([summary[@"workspace_id"] isKindOfClass:[NSString class]]) {
                        identified[@"workspace_id"] = summary[@"workspace_id"];
                    }
                } else {
                    identified[@"workspace_id"] = workspaceID;
                }
                return identified;
            }];
        [connection sendJSONObject:response];
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

        NSLog(@"[TideyRemoteSubmit] receive action=send_input request_id=%@ workspace_id=%@ panel_id=%@ length=%lu hasCR=%@ hasLF=%@ tail=%@",
              requestID ?: @"-",
              workspaceID ?: @"-",
              panelID ?: @"-",
              (unsigned long)input.length,
              [input containsString:@"\r"] ? @"YES" : @"NO",
              [input containsString:@"\n"] ? @"YES" : @"NO",
              TideySubmitLogSuffix(input));

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

    if ([action isEqualToString:@"send_key"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        NSString *key = TideySocketStringParam(source, @"key");
        if (panelID.length == 0 || key.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"send_key requires panel_id and key."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
        NSDictionary *panelSummary = [term tideySocketPanelSummaryForPanelIdentifier:panelID];
        if (!panelSummary) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"panel_not_found"
                                        message:@"No panel matched panel_id."
                                   onConnection:connection];
            return;
        }
        if (![term tideySendKey:key toPanelWithIdentifier:panelID]) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"unsupported_key"
                                        message:@"The requested key is not supported for this panel."
                                   onConnection:connection];
            return;
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:@{ @"sent": @YES,
                                                 @"panel_id": panelID,
                                                 @"workspace_id": panelSummary[@"workspace_id"] ?: @"",
                                                 @"key": key }
                                  onConnection:connection];
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
            NSMutableDictionary *result = [@{ @"output": trimmed[@"output"] ?: @"",
                                               @"cursor_row": trimmed[@"cursor_row"] ?: @0,
                                               @"cursor_col": trimmed[@"cursor_col"] ?: @0,
                                               @"cursor_visible": trimmed[@"cursor_visible"] ?: @YES,
                                               @"panel_id": panelID,
                                               @"workspace_id": panelSummary[@"workspace_id"] ?: @"" } mutableCopy];
            for (NSString *key in @[ @"terminal_grid_version", @"ansi_active_capture_base64", @"ansi_scrollback_capture_base64", @"scrollback_rows", @"base_abs", @"cols", @"rows" ]) {
                if (trimmed[key]) {
                    result[key] = trimmed[key];
                }
            }
            [self sendSuccessResponseForRequestID:requestID
                                           result:result
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
        NSString *command = TideySocketStringParam(source, @"command");
        NSString *workingDirectory = TideySocketStringParam(source, @"working_directory");
        NSDictionary<NSString *, NSString *> *environment = TideySocketStringDictionaryParam(source, @"environment");
        (void)TideySocketBoolParam(source, @"make_selected", YES);
        if (source[@"environment"] && !environment) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"create_panel environment must be a string dictionary."
                                   onConnection:connection];
            return;
        }
        if (workspaceID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"create_panel requires workspace_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForWorkspaceIdentifier:workspaceID];
        NSDictionary *result = [term tideyCreatePanelInWorkspaceWithIdentifier:workspaceID
                                                                       command:command
                                                                   environment:environment
                                                              workingDirectory:workingDirectory];
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

    if ([action isEqualToString:@"restore_panel_focus"]) {
        NSString *panelID = TideySocketStringParam(source, @"panel_id");
        if (panelID.length == 0) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"invalid_params"
                                        message:@"restore_panel_focus requires panel_id."
                                   onConnection:connection];
            return;
        }
        PseudoTerminal *term = [self tideyTerminalForPanelIdentifier:panelID];
        if (![term tideyRestoreSelectedPanelWithIdentifier:panelID]) {
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
                                   source:(NSDictionary *)source
                             onConnection:(TideySocketConnection *)connection {
    NSMutableArray<NSDictionary *> *workspaces = [NSMutableArray array];
    BOOL sourceWasSpecified = NO;
    PseudoTerminal *sourceTerm = [self tideyTerminalForWorkspaceListSource:source sourceWasSpecified:&sourceWasSpecified];
    if (sourceWasSpecified) {
        if (!sourceTerm) {
            [self sendErrorResponseForRequestID:requestID
                                           code:@"source_not_found"
                                        message:@"No Tidey window matched the list_workspaces source."
                                   onConnection:connection];
            return;
        }
        [workspaces addObjectsFromArray:[sourceTerm tideySocketWorkspaceSummaries]];
    } else {
        for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
            [workspaces addObjectsFromArray:[term tideySocketWorkspaceSummaries]];
        }
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
        NSMutableDictionary *result = [@{ @"output": trimmed[@"output"] ?: @"",
                                           @"cursor_row": trimmed[@"cursor_row"] ?: @0,
                                           @"cursor_col": trimmed[@"cursor_col"] ?: @0,
                                           @"cursor_visible": trimmed[@"cursor_visible"] ?: @YES,
                                           @"workspace_id": workspaceID } mutableCopy];
        for (NSString *key in @[ @"terminal_grid_version", @"ansi_active_capture_base64", @"ansi_scrollback_capture_base64", @"scrollback_rows", @"base_abs", @"cols", @"rows" ]) {
            if (trimmed[key]) {
                result[key] = trimmed[key];
            }
        }
        [self sendSuccessResponseForRequestID:requestID
                                       result:result
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
    BOOL didTrim = NO;

    NSArray<NSString *> *lineArray = [output componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *lines = [lineArray mutableCopy];
    if (maxLines > 0 && (NSInteger)lines.count > maxLines) {
        NSInteger droppedLines = lines.count - maxLines;
        [lines removeObjectsInRange:NSMakeRange(0, droppedLines)];
        cursorRow = MAX(0, cursorRow - droppedLines);
        didTrim = YES;
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
        didTrim = YES;
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

    NSMutableDictionary *result = [@{
        @"output": trimmed ?: @"",
        @"cursor_row": @(derivedRow),
        @"cursor_col": @(derivedCol),
        @"cursor_visible": snapshot[@"cursor_visible"] ?: @YES,
    } mutableCopy];
    NSArray<NSString *> *gridKeys = @[ @"terminal_grid_version", @"ansi_active_capture_base64", @"cols", @"rows" ];
    NSArray<NSString *> *optionalGridKeys = @[ @"ansi_scrollback_capture_base64", @"scrollback_rows", @"base_abs" ];
    BOOL hasCompleteGrid = !didTrim;
    for (NSString *key in gridKeys) {
        hasCompleteGrid = hasCompleteGrid && snapshot[key] != nil;
    }
    if (hasCompleteGrid) {
        for (NSString *key in gridKeys) {
            result[key] = snapshot[key];
        }
        for (NSString *key in optionalGridKeys) {
            if (snapshot[key]) {
                result[key] = snapshot[key];
            }
        }
    }
    return result;
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

+ (NSDictionary *)tideyNativeTerminalSizeResponseForRequestID:(NSString *)requestID
                                                        action:(NSString *)action
                                                        source:(NSDictionary *)source
                                                       handler:(TideySocketNativeTerminalSizeHandler)handler {
    const BOOL isAcquire = [action isEqualToString:@"native_terminal_size_acquire"];
    const BOOL isUpdate = [action isEqualToString:@"native_terminal_size_update"];
    const BOOL isHeartbeat = [action isEqualToString:@"native_terminal_size_heartbeat"];
    const BOOL isRelease = [action isEqualToString:@"native_terminal_size_release"];
    NSString *panelID = TideySocketStringParam(source, @"panel_id");
    NSString *token = TideySocketStringParam(source, @"token");
    NSInteger columns = TideySocketIntegerParam(source, @"cols", 0);
    NSInteger rows = TideySocketIntegerParam(source, @"rows", 0);
    const BOOL hasExactNativeIdentity =
        [PseudoTerminal tideyNativeSessionPanelIdentityFromPanelIdentifier:panelID] != nil;
    const BOOL dimensionsAreValid =
        columns > 0 && columns <= 1000 && rows > 0 && rows <= 1000;
    const BOOL actionIsValid = isAcquire || isUpdate || isHeartbeat || isRelease;
    const BOOL tokenIsValid = isAcquire || token.length > 0;
    const BOOL sizeIsValid = (isAcquire || isUpdate) ? dimensionsAreValid : YES;
    if (!actionIsValid || !hasExactNativeIdentity || !tokenIsValid || !sizeIsValid) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"invalid_params"
                                            message:@"Native terminal sizing requires an exact native panel, valid dimensions, and a live lease token."];
    }
    NSDictionary *result = handler
        ? handler(action, panelID, token, columns, rows)
        : nil;
    if (![result[@"accepted"] boolValue]) {
        NSString *errorCode =
            [result[@"error_code"] isKindOfClass:[NSString class]]
                ? result[@"error_code"]
                : @"stale_binding";
        return [self tideyErrorResponseForRequestID:requestID
                                               code:errorCode
                                            message:@"Native terminal size lease request was rejected."];
    }
    return [self tideySuccessResponseForRequestID:requestID result:result];
}

+ (void)tideyBrowserAutomationResponseForRequestMessage:(NSDictionary *)message
                                               sessionID:(NSString *)sessionID
                                                 handler:(TideySocketBrowserAutomationHandler)handler
                                              completion:(void (^)(NSDictionary *response))completion {
    NSString *requestID = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : nil;
    NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : nil;
    NSDictionary *source = params ?: message;
    NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
    NSString *operation = TideySocketStringParam(source, @"operation");
    NSDictionary *parameters = [source[@"parameters"] isKindOfClass:[NSDictionary class]]
        ? source[@"parameters"]
        : @{};
    if (requestID.length == 0 || workspaceID.length == 0 || operation.length == 0 || sessionID.length == 0) {
        completion([self tideyErrorResponseForRequestID:requestID
                                                   code:@"invalid_request"
                                                message:@"Browser automation requires id, workspace_id, and operation."]);
        return;
    }
    if (!handler) {
        completion([self tideyErrorResponseForRequestID:requestID
                                                   code:@"internal_error"
                                                message:@"Browser automation handler is unavailable."]);
        return;
    }
    handler(workspaceID,
            operation,
            parameters,
            sessionID,
            ^(NSDictionary *result, NSDictionary *error) {
        if (error) {
            NSString *code = [error[@"code"] isKindOfClass:[NSString class]]
                ? error[@"code"]
                : @"internal_error";
            NSString *message = [error[@"message"] isKindOfClass:[NSString class]]
                ? error[@"message"]
                : @"Browser automation failed.";
            completion([self tideyErrorResponseForRequestID:requestID code:code message:message]);
        } else {
            completion([self tideySuccessResponseForRequestID:requestID result:result ?: @{}]);
        }
    });
}

+ (NSArray<NSDictionary *> *)tideyWorkspaceSummaries:(NSArray<NSDictionary *> *)workspaceSummaries
                 filteredToWindowForListWorkspacesSource:(NSDictionary *)source {
    NSString *windowGUID = TideySocketStringParam(source, @"source_window_guid");
    NSString *workspaceID = TideySocketStringParam(source, @"source_workspace_id");
    if (windowGUID.length == 0 && workspaceID.length > 0) {
        for (NSDictionary *summary in workspaceSummaries ?: @[]) {
            NSString *summaryWorkspaceID = [summary[@"workspace_id"] isKindOfClass:[NSString class]] ? summary[@"workspace_id"] : nil;
            if (![summaryWorkspaceID isEqualToString:workspaceID]) {
                continue;
            }
            NSString *summaryWindowGUID = [summary[@"window_guid"] isKindOfClass:[NSString class]] ? summary[@"window_guid"] : nil;
            windowGUID = summaryWindowGUID ?: @"";
            break;
        }
    }
    if (windowGUID.length == 0) {
        return workspaceSummaries ?: @[];
    }

    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSDictionary *summary in workspaceSummaries ?: @[]) {
        NSString *summaryWindowGUID = [summary[@"window_guid"] isKindOfClass:[NSString class]] ? summary[@"window_guid"] : nil;
        if ([summaryWindowGUID isEqualToString:windowGUID]) {
            [filtered addObject:summary];
        }
    }
    return filtered;
}

+ (NSDictionary *)tideyRuntimeTmuxServerPreparationResponseForRequestID:(NSString *)requestID
                                                                  source:(NSDictionary *)source
                                                                 handler:(TideySocketRuntimeTmuxServerPreparationHandler)handler {
    if (requestID.length == 0) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"invalid_request"
                                            message:@"Missing request id."];
    }
    NSString *serverIdentifier = TideySocketStringParam(source, @"server_id");
    if (serverIdentifier.length == 0) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"invalid_params"
                                            message:@"prepare_isolated_tmux_server requires server_id."];
    }
    NSDictionary *outcome = handler ? handler(serverIdentifier) : nil;
    if (![outcome[@"prepared"] boolValue]) {
        NSString *errorCode =
            [outcome[@"error_code"] isKindOfClass:[NSString class]]
                ? outcome[@"error_code"]
                : @"preparation_failed";
        return [self tideyErrorResponseForRequestID:requestID
                                               code:errorCode
                                            message:@"The isolated tmux server could not be prepared."];
    }
    return [self tideySuccessResponseForRequestID:requestID
                                           result:outcome];
}

+ (NSDictionary *)tideyTerminalHistoryPageResponseForRequestID:(NSString *)requestID
                                                          source:(NSDictionary *)source
                                                         handler:(TideySocketTerminalHistoryPageHandler)handler {
    if (requestID.length == 0) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"invalid_request"
                                            message:@"Missing request id."];
    }
    NSString *historySource = TideySocketStringParam(source, @"source");
    NSString *panelID = TideySocketStringParam(source, @"panel_id");
    NSString *workspaceID = TideySocketStringParam(source, @"workspace_id");
    NSNumber *routeGeneration = [source[@"route_generation"] isKindOfClass:[NSNumber class]]
        ? source[@"route_generation"]
        : nil;
    NSDictionary *cursor = [source[@"cursor"] isKindOfClass:[NSDictionary class]]
        ? source[@"cursor"]
        : nil;
    NSNumber *beforeAbsoluteLine = [cursor[@"before_abs"] isKindOfClass:[NSNumber class]]
        ? cursor[@"before_abs"]
        : nil;
    const NSInteger requestedPageLines = TideySocketIntegerParam(source, @"page_lines", 200);
    if (![historySource isEqualToString:@"native"] ||
        (panelID.length == 0 && workspaceID.length == 0) ||
        routeGeneration == nil ||
        requestedPageLines <= 0 ||
        [routeGeneration longLongValue] < 0 ||
        (beforeAbsoluteLine && [beforeAbsoluteLine longLongValue] < 0)) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"invalid_params"
                                            message:@"Native terminal history paging requires valid identity, generation, cursor, and page size."];
    }
    if (!handler) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"internal_error"
                                            message:@"Native terminal history paging is unavailable."];
    }
    const NSInteger pageLines = MIN(requestedPageLines, 500);
    NSDictionary *page = handler(panelID,
                                 workspaceID,
                                 beforeAbsoluteLine,
                                 pageLines,
                                 routeGeneration);
    if (!page) {
        return [self tideyErrorResponseForRequestID:requestID
                                               code:@"stale_binding"
                                            message:@"Native terminal history binding is no longer current."];
    }
    NSMutableDictionary *result = [page mutableCopy];
    result[@"source"] = @"native";
    result[@"route_generation"] = routeGeneration;
    return [self tideySuccessResponseForRequestID:requestID result:result];
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
        NSDictionary *params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : nil;
        NSDictionary *source = params ?: message;
        NSArray<NSDictionary *> *scopedWorkspaceSummaries =
            [self tideyWorkspaceSummaries:workspaceSummaries filteredToWindowForListWorkspacesSource:source];
        return [self tideySuccessResponseForRequestID:requestID
                                               result:@{ @"workspaces": scopedWorkspaceSummaries ?: @[] }];
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
                                                   colorHex:command.colorHex
                                                    ownerID:command.statusOwnerID];
}

- (void)handleClearStatus:(NSDictionary *)message {
    TideySocketCommand *command = [TideySocketCommandDecoder clearStatusCommandFromMessage:message];
    if (!command) {
        DLog(@"Ignoring malformed clear_status payload: %@", message);
        return;
    }

    [[TideyStatusStore sharedStore] clearStatusForWorkspaceID:command.workspaceID
                                                           key:command.key
                                                       ownerID:command.statusOwnerID];
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
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self stop];
        });
        return;
    }
    if (!self.started) {
        return;
    }
    NSArray<TideySocketConnection *> *connections = self.connections.allObjects;
    [self.connections removeAllObjects];
    [self.workspaceEventSubscriptions removeAllObjects];
    for (TideySocketConnection *connection in connections) {
        [connection close];
    }
    [self.socket close];
    self.socket = nil;
    unlink(TideySocketServer.socketPath.UTF8String);
    gTideyActiveSocketPath = nil;
    self.started = NO;
}

- (NSUInteger)tideyTestingConnectionCount {
    if (![NSThread isMainThread]) {
        __block NSUInteger count = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{
            count = [self tideyTestingConnectionCount];
        });
        return count;
    }
    return self.connections.count;
}

@end
