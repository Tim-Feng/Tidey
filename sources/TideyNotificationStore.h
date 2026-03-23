#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const TideyNotificationStoreDidChangeNotification;

@interface TideyNotificationItem : NSObject

@property(nonatomic, copy, readonly) NSString *notificationID;
@property(nonatomic, copy, readonly) NSString *workspaceID;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly, nullable) NSString *subtitle;
@property(nonatomic, copy, readonly) NSString *body;
@property(nonatomic, strong, readonly) NSDate *createdAt;
@property(nonatomic, readonly, getter=isRead) BOOL read;

- (instancetype)initWithNotificationID:(NSString *)notificationID
                           workspaceID:(NSString *)workspaceID
                                 title:(NSString *)title
                              subtitle:(nullable NSString *)subtitle
                                  body:(NSString *)body
                             createdAt:(NSDate *)createdAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface TideyNotificationStore : NSObject

+ (instancetype)sharedStore;

- (NSArray<TideyNotificationItem *> *)allNotifications;
- (NSArray<TideyNotificationItem *> *)notificationsForWorkspaceID:(NSString *)workspaceID;
- (NSInteger)unreadCountForWorkspaceID:(NSString *)workspaceID;

- (TideyNotificationItem *)addNotificationForWorkspaceID:(NSString *)workspaceID
                                                   title:(NSString *)title
                                                subtitle:(nullable NSString *)subtitle
                                                    body:(NSString *)body;
- (void)markReadForWorkspaceID:(NSString *)workspaceID;
- (void)markUnreadForWorkspaceID:(NSString *)workspaceID;
- (void)markAllRead;
- (void)removeNotificationWithID:(NSString *)notificationID;
- (void)clearAllNotifications;

- (BOOL)hasReadNotificationsForWorkspaceID:(NSString *)workspaceID;
- (nullable TideyNotificationItem *)latestUnreadForWorkspaceID:(NSString *)workspaceID;
- (nullable TideyNotificationItem *)latestNotificationForWorkspaceID:(NSString *)workspaceID;

@end

NS_ASSUME_NONNULL_END
