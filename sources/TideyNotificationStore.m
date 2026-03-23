#import "TideyNotificationStore.h"

NSNotificationName const TideyNotificationStoreDidChangeNotification = @"TideyNotificationStoreDidChangeNotification";
static NSString *const kTideyBroadcastWorkspaceIdentifier = @"*";

@interface TideyNotificationItem ()
@property(nonatomic, copy, readwrite) NSString *notificationID;
@property(nonatomic, copy, readwrite) NSString *workspaceID;
@property(nonatomic, copy, readwrite) NSString *title;
@property(nonatomic, copy, readwrite, nullable) NSString *subtitle;
@property(nonatomic, copy, readwrite) NSString *body;
@property(nonatomic, strong, readwrite) NSDate *createdAt;
@property(nonatomic, readwrite, getter=isRead) BOOL read;
@end

@implementation TideyNotificationItem

- (instancetype)initWithNotificationID:(NSString *)notificationID
                           workspaceID:(NSString *)workspaceID
                                 title:(NSString *)title
                              subtitle:(NSString *)subtitle
                                  body:(NSString *)body
                             createdAt:(NSDate *)createdAt {
    self = [super init];
    if (self) {
        _notificationID = [notificationID copy];
        _workspaceID = [workspaceID copy];
        _title = [title copy];
        _subtitle = [subtitle copy];
        _body = [body copy];
        _createdAt = createdAt;
        _read = NO;
    }
    return self;
}

@end

@interface TideyNotificationStore ()
@property(nonatomic, strong) NSMutableArray<TideyNotificationItem *> *notifications;
@end

@implementation TideyNotificationStore

- (BOOL)tideyNotificationItem:(TideyNotificationItem *)item matchesWorkspaceID:(NSString *)workspaceID {
    return [item.workspaceID isEqualToString:workspaceID] ||
           [item.workspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier];
}

+ (instancetype)sharedStore {
    static TideyNotificationStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[self alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _notifications = [[NSMutableArray alloc] init];
    }
    return self;
}

- (NSArray<TideyNotificationItem *> *)allNotifications {
    return [self.notifications copy];
}

- (NSArray<TideyNotificationItem *> *)notificationsForWorkspaceID:(NSString *)workspaceID {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(TideyNotificationItem *item, NSDictionary *bindings) {
        return [self tideyNotificationItem:item matchesWorkspaceID:workspaceID];
    }];
    return [self.notifications filteredArrayUsingPredicate:predicate];
}

- (NSInteger)unreadCountForWorkspaceID:(NSString *)workspaceID {
    NSInteger count = 0;
    for (TideyNotificationItem *item in self.notifications) {
        if (!item.isRead && [self tideyNotificationItem:item matchesWorkspaceID:workspaceID]) {
            count++;
        }
    }
    return count;
}

- (TideyNotificationItem *)addNotificationForWorkspaceID:(NSString *)workspaceID
                                                   title:(NSString *)title
                                                subtitle:(NSString *)subtitle
                                                    body:(NSString *)body {
    NSString *effectiveWorkspaceID = workspaceID.length > 0 ? workspaceID : kTideyBroadcastWorkspaceIdentifier;
    TideyNotificationItem *item =
        [[TideyNotificationItem alloc] initWithNotificationID:NSUUID.UUID.UUIDString
                                                  workspaceID:effectiveWorkspaceID
                                                        title:title
                                                     subtitle:subtitle
                                                         body:body
                                                    createdAt:[NSDate date]];
    [self.notifications insertObject:item atIndex:0];
    [self postDidChangeWithNotification:item];
    return item;
}

- (void)markReadForWorkspaceID:(NSString *)workspaceID {
    BOOL changed = NO;
    for (TideyNotificationItem *item in self.notifications) {
        if (!item.isRead && [self tideyNotificationItem:item matchesWorkspaceID:workspaceID]) {
            item.read = YES;
            changed = YES;
        }
    }
    if (changed) {
        [self postDidChangeWithNotification:nil];
    }
}

- (void)markAllRead {
    BOOL changed = NO;
    for (TideyNotificationItem *item in self.notifications) {
        if (!item.isRead) {
            item.read = YES;
            changed = YES;
        }
    }
    if (changed) {
        [self postDidChangeWithNotification:nil];
    }
}

- (void)removeNotificationWithID:(NSString *)notificationID {
    NSIndexSet *indexes =
        [self.notifications indexesOfObjectsPassingTest:^BOOL(TideyNotificationItem *item, NSUInteger idx, BOOL *stop) {
            return [item.notificationID isEqualToString:notificationID];
        }];
    if (indexes.count == 0) {
        return;
    }
    [self.notifications removeObjectsAtIndexes:indexes];
    [self postDidChangeWithNotification:nil];
}

- (void)clearAllNotifications {
    if (self.notifications.count == 0) {
        return;
    }
    [self.notifications removeAllObjects];
    [self postDidChangeWithNotification:nil];
}

- (void)postDidChangeWithNotification:(TideyNotificationItem *)item {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (item.workspaceID.length > 0) {
        userInfo[@"workspaceID"] = item.workspaceID;
    }
    if (item.notificationID.length > 0) {
        userInfo[@"notificationID"] = item.notificationID;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:TideyNotificationStoreDidChangeNotification
                                                        object:self
                                                      userInfo:userInfo.count ? userInfo : nil];
}

@end
