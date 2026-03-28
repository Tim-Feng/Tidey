#import "TideySocketCommandDecoder.h"

NS_ASSUME_NONNULL_BEGIN

static NSString * _Nullable TideySocketStringValue(NSDictionary *message, NSString *key) {
    id value = message[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

@interface TideySocketCommand ()
@property(nonatomic, readwrite) TideySocketCommandKind kind;
@property(nonatomic, copy, readwrite, nullable) NSString *workspaceID;
@property(nonatomic, copy, readwrite, nullable) NSString *title;
@property(nonatomic, copy, readwrite, nullable) NSString *subtitle;
@property(nonatomic, copy, readwrite, nullable) NSString *body;
@property(nonatomic, copy, readwrite, nullable) NSString *key;
@property(nonatomic, copy, readwrite, nullable) NSString *value;
@property(nonatomic, copy, readwrite, nullable) NSString *icon;
@property(nonatomic, copy, readwrite, nullable) NSString *colorHex;
- (instancetype)initWithKind:(TideySocketCommandKind)kind;
@end

@implementation TideySocketCommand

- (instancetype)initWithKind:(TideySocketCommandKind)kind {
    self = [super init];
    if (self) {
        _kind = kind;
    }
    return self;
}

@end

@implementation TideySocketCommandDecoder

+ (nullable TideySocketCommand *)notificationCommandFromMessage:(NSDictionary *)message {
    NSString *action = TideySocketStringValue(message, @"action");
    NSString *workspaceID = TideySocketStringValue(message, @"workspace_id");
    NSString *title = TideySocketStringValue(message, @"title") ?: @"";
    if ([action isEqualToString:@"notification.create_for_workspace"] && workspaceID.length == 0) {
        return nil;
    }
    if (title.length == 0) {
        return nil;
    }

    TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindNotification];
    command.workspaceID = workspaceID;
    command.title = title;
    command.subtitle = TideySocketStringValue(message, @"subtitle");
    command.body = TideySocketStringValue(message, @"body") ?: @"";
    return command;
}

+ (nullable TideySocketCommand *)reportShellStateCommandFromMessage:(NSDictionary *)message {
    NSString *state = TideySocketStringValue(message, @"state");
    if (state.length == 0) {
        return nil;
    }

    NSString *workspaceID = TideySocketStringValue(message, @"workspace_id");
    NSString *targetWorkspaceID = workspaceID.length > 0 ? workspaceID : @"*";

    if ([state isEqualToString:@"running"] ||
        [state isEqualToString:@"busy"] ||
        [state isEqualToString:@"command"]) {
        TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindSetStatus];
        command.workspaceID = targetWorkspaceID;
        command.key = @"shell_state";
        command.value = @"Running";
        command.icon = @"bolt.fill";
        command.colorHex = @"#007AFF";
        return command;
    }

    if ([state isEqualToString:@"prompt"] ||
        [state isEqualToString:@"idle"]) {
        TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindSetStatus];
        command.workspaceID = targetWorkspaceID;
        command.key = @"shell_state";
        command.value = @"Idle";
        command.icon = @"pause.circle.fill";
        command.colorHex = @"#8E8E93";
        return command;
    }

    if ([state isEqualToString:@"unknown"] ||
        [state isEqualToString:@"clear"]) {
        TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindClearStatus];
        command.workspaceID = targetWorkspaceID;
        command.key = @"shell_state";
        return command;
    }

    return nil;
}

+ (nullable TideySocketCommand *)setStatusCommandFromMessage:(NSDictionary *)message {
    NSString *workspaceID = TideySocketStringValue(message, @"workspace_id");
    NSString *key = TideySocketStringValue(message, @"key");
    NSString *value = TideySocketStringValue(message, @"value");
    if (workspaceID.length == 0 || key.length == 0 || value.length == 0) {
        return nil;
    }

    TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindSetStatus];
    command.workspaceID = workspaceID;
    command.key = key;
    command.value = value;
    command.icon = TideySocketStringValue(message, @"icon");
    command.colorHex = TideySocketStringValue(message, @"color");
    return command;
}

+ (nullable TideySocketCommand *)clearStatusCommandFromMessage:(NSDictionary *)message {
    NSString *workspaceID = TideySocketStringValue(message, @"workspace_id");
    NSString *key = TideySocketStringValue(message, @"key");
    if (workspaceID.length == 0 || key.length == 0) {
        return nil;
    }

    TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindClearStatus];
    command.workspaceID = workspaceID;
    command.key = key;
    return command;
}

+ (nullable TideySocketCommand *)setTitleCommandFromMessage:(NSDictionary *)message {
    NSString *workspaceID = TideySocketStringValue(message, @"workspace_id");
    if (workspaceID.length == 0) {
        return nil;
    }

    TideySocketCommand *command = [[TideySocketCommand alloc] initWithKind:TideySocketCommandKindSetTitle];
    command.workspaceID = workspaceID;
    command.title = TideySocketStringValue(message, @"title") ?: @"";
    return command;
}

@end

NS_ASSUME_NONNULL_END
