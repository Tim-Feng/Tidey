#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TideySocketCommandKind) {
    TideySocketCommandKindNotification = 1,
    TideySocketCommandKindSetStatus = 2,
    TideySocketCommandKindClearStatus = 3,
    TideySocketCommandKindSetTitle = 4,
};

@interface TideySocketCommand : NSObject

@property(nonatomic, readonly) TideySocketCommandKind kind;
@property(nonatomic, copy, readonly, nullable) NSString *workspaceID;
@property(nonatomic, copy, readonly, nullable) NSString *title;
@property(nonatomic, copy, readonly, nullable) NSString *subtitle;
@property(nonatomic, copy, readonly, nullable) NSString *body;
@property(nonatomic, copy, readonly, nullable) NSString *key;
@property(nonatomic, copy, readonly, nullable) NSString *value;
@property(nonatomic, copy, readonly, nullable) NSString *icon;
@property(nonatomic, copy, readonly, nullable) NSString *colorHex;
// Session/panel ownership for shell-state entries: the status store keeps
// one cell per owner and aggregates, never a workspace-level last-writer.
@property(nonatomic, copy, readonly, nullable) NSString *panelID;
@property(nonatomic, copy, readonly, nullable) NSString *sessionID;

// sessionID ?: panelID ?: nil — the status store owner cell for this command.
@property(nonatomic, copy, readonly, nullable) NSString *statusOwnerID;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface TideySocketCommandDecoder : NSObject

+ (nullable TideySocketCommand *)notificationCommandFromMessage:(NSDictionary *)message;
+ (nullable TideySocketCommand *)reportShellStateCommandFromMessage:(NSDictionary *)message;
+ (nullable TideySocketCommand *)setStatusCommandFromMessage:(NSDictionary *)message;
+ (nullable TideySocketCommand *)clearStatusCommandFromMessage:(NSDictionary *)message;
+ (nullable TideySocketCommand *)setTitleCommandFromMessage:(NSDictionary *)message;

@end

NS_ASSUME_NONNULL_END
