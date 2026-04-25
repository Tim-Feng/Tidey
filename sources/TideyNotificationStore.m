#import "TideyNotificationStore.h"

#import <UserNotifications/UserNotifications.h>

#import "DebugLogging.h"

NSNotificationName const TideyNotificationStoreDidChangeNotification = @"TideyNotificationStoreDidChangeNotification";
NSNotificationName const TideyStatusStoreDidChangeNotification = @"TideyStatusStoreDidChangeNotification";
static NSString *const kTideyBroadcastWorkspaceIdentifier = @"*";
static NSString *const kTideySystemNotificationCategoryIdentifier = @"TIDEY_WORKSPACE_NOTIFICATION";

#pragma mark - TideyNotificationItem

@interface TideyNotificationItem ()
@property(nonatomic, copy, readwrite) NSString *notificationID;
@property(nonatomic, copy, readwrite) NSString *workspaceID;
@property(nonatomic, copy, readwrite) NSString *title;
@property(nonatomic, copy, readwrite, nullable) NSString *subtitle;
@property(nonatomic, copy, readwrite) NSString *body;
@property(nonatomic, strong, readwrite) NSDate *createdAt;
@property(nonatomic, readwrite, getter=isRead) BOOL read;
@property(nonatomic, strong) NSMutableSet<NSString *> *readWorkspaceIDs;
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
        _readWorkspaceIDs = [[NSMutableSet alloc] init];
    }
    return self;
}

@end

#pragma mark - TideyNotificationStore

@interface TideyNotificationStore ()
@property(nonatomic, strong) NSMutableArray<TideyNotificationItem *> *notifications;
@end

@implementation TideyNotificationStore

- (BOOL)tideyNotificationItemIsBroadcast:(TideyNotificationItem *)item {
    return [item.workspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier];
}

- (BOOL)tideyNotificationItem:(TideyNotificationItem *)item matchesWorkspaceID:(NSString *)workspaceID {
    return [item.workspaceID isEqualToString:workspaceID] ||
           [item.workspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier];
}

- (BOOL)tideyNotificationItem:(TideyNotificationItem *)item isReadForWorkspaceID:(NSString *)workspaceID {
    if (item.isRead) {
        return YES;
    }
    if ([self tideyNotificationItemIsBroadcast:item] && workspaceID.length > 0) {
        return [item.readWorkspaceIDs containsObject:workspaceID];
    }
    return NO;
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
        if (![self tideyNotificationItem:item isReadForWorkspaceID:workspaceID] &&
            [self tideyNotificationItem:item matchesWorkspaceID:workspaceID]) {
            count++;
        }
    }
    return count;
}

- (BOOL)hasAnyUnreadNotifications {
    for (TideyNotificationItem *item in self.notifications) {
        if (!item.isRead) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasUnreadNotificationsForKnownWorkspaceIDs:(NSSet<NSString *> *)workspaceIDs {
    if (workspaceIDs.count == 0) {
        return [self hasAnyUnreadNotifications];
    }

    for (TideyNotificationItem *item in self.notifications) {
        if ([self tideyNotificationItemIsBroadcast:item]) {
            for (NSString *workspaceID in workspaceIDs) {
                if (![self tideyNotificationItem:item isReadForWorkspaceID:workspaceID]) {
                    return YES;
                }
            }
            continue;
        }

        if (!item.isRead && [workspaceIDs containsObject:item.workspaceID]) {
            return YES;
        }
    }
    return NO;
}

- (TideyNotificationItem *)addNotificationForWorkspaceID:(NSString *)workspaceID
                                                   title:(NSString *)title
                                                subtitle:(NSString *)subtitle
                                                    body:(NSString *)body {
    NSString *effectiveWorkspaceID = workspaceID.length > 0 ? workspaceID : kTideyBroadcastWorkspaceIdentifier;
    // Replace existing notifications for the same workspace (broadcast notifications are exempt).
    if (![effectiveWorkspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier]) {
        NSIndexSet *existing =
            [self.notifications indexesOfObjectsPassingTest:^BOOL(TideyNotificationItem *item, NSUInteger idx, BOOL *stop) {
                return [item.workspaceID isEqualToString:effectiveWorkspaceID];
            }];
        [self.notifications removeObjectsAtIndexes:existing];
    }
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
        if ([self tideyNotificationItem:item matchesWorkspaceID:workspaceID] &&
            ![self tideyNotificationItem:item isReadForWorkspaceID:workspaceID]) {
            if ([self tideyNotificationItemIsBroadcast:item] &&
                workspaceID.length > 0 &&
                ![workspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier]) {
                [item.readWorkspaceIDs addObject:workspaceID];
            } else {
                item.read = YES;
            }
            changed = YES;
        }
    }
    if (changed) {
        [self removeDeliveredSystemNotificationsForWorkspaceID:workspaceID];
        [self postDidChangeWithNotification:nil];
    }
}

- (void)markUnreadForWorkspaceID:(NSString *)workspaceID {
    BOOL changed = NO;
    for (TideyNotificationItem *item in self.notifications) {
        if ([self tideyNotificationItem:item matchesWorkspaceID:workspaceID] &&
            [self tideyNotificationItem:item isReadForWorkspaceID:workspaceID]) {
            if ([self tideyNotificationItemIsBroadcast:item] &&
                workspaceID.length > 0 &&
                ![workspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier]) {
                [item.readWorkspaceIDs removeObject:workspaceID];
            } else {
                item.read = NO;
            }
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

- (BOOL)hasReadNotificationsForWorkspaceID:(NSString *)workspaceID {
    for (TideyNotificationItem *item in self.notifications) {
        if ([self tideyNotificationItem:item isReadForWorkspaceID:workspaceID] &&
            [self tideyNotificationItem:item matchesWorkspaceID:workspaceID]) {
            return YES;
        }
    }
    return NO;
}

- (TideyNotificationItem *)latestUnreadForWorkspaceID:(NSString *)workspaceID {
    for (TideyNotificationItem *item in self.notifications) {
        if (![self tideyNotificationItem:item isReadForWorkspaceID:workspaceID] &&
            [self tideyNotificationItem:item matchesWorkspaceID:workspaceID]) {
            return item;
        }
    }
    return nil;
}

- (TideyNotificationItem *)latestNotificationForWorkspaceID:(NSString *)workspaceID {
    for (TideyNotificationItem *item in self.notifications) {
        if ([self tideyNotificationItem:item matchesWorkspaceID:workspaceID]) {
            return item;
        }
    }
    return nil;
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

#pragma mark - System Notifications (UNUserNotificationCenter)

- (void)requestNotificationAuthorization {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            DLog(@"Tidey notification authorization error: %@", error);
        } else {
            DLog(@"Tidey notification authorization granted: %@", granted ? @"YES" : @"NO");
        }
    }];
    // Register a category so we can identify our notifications.
    UNNotificationCategory *category =
        [UNNotificationCategory categoryWithIdentifier:kTideySystemNotificationCategoryIdentifier
                                               actions:@[]
                                     intentIdentifiers:@[]
                                               options:UNNotificationCategoryOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:category]];
}

- (void)postSystemNotificationForItem:(TideyNotificationItem *)item {
    if (!item) {
        return;
    }

    // The UNUserNotificationCenterDelegate (in iTermApplicationDelegate) handles
    // fine-grained suppression (e.g. suppressing when the workspace is focused).
    // Here we just create and submit the notification request.
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = item.title ?: @"";
    content.body = item.body ?: @"";
    content.categoryIdentifier = kTideySystemNotificationCategoryIdentifier;
    content.userInfo = @{ @"workspaceID": item.workspaceID ?: @"",
                          @"notificationID": item.notificationID ?: @"" };
    content.sound = [UNNotificationSound defaultSound];

    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:item.notificationID
                                             content:content
                                             trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError *error) {
        if (error) {
            DLog(@"Failed to deliver Tidey system notification: %@", error);
        }
    }];
}

- (void)removeDeliveredSystemNotificationsForWorkspaceID:(NSString *)workspaceID {
    if (workspaceID.length == 0) {
        return;
    }
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSMutableArray<NSString *> *identifiersToRemove = [NSMutableArray array];
        for (UNNotification *notification in notifications) {
            NSString *nWorkspaceID = notification.request.content.userInfo[@"workspaceID"];
            if ([nWorkspaceID isEqualToString:workspaceID] ||
                [workspaceID isEqualToString:kTideyBroadcastWorkspaceIdentifier]) {
                [identifiersToRemove addObject:notification.request.identifier];
            }
        }
        if (identifiersToRemove.count > 0) {
            [center removeDeliveredNotificationsWithIdentifiers:identifiersToRemove];
        }
    }];
}

@end

#pragma mark - TideyStatusEntry

@interface TideyStatusEntry ()
@property(nonatomic, copy, readwrite) NSString *key;
@property(nonatomic, copy, readwrite) NSString *value;
@property(nonatomic, copy, readwrite, nullable) NSString *icon;
@property(nonatomic, copy, readwrite, nullable) NSString *colorHex;
@end

@implementation TideyStatusEntry

- (instancetype)initWithKey:(NSString *)key
                      value:(NSString *)value
                       icon:(nullable NSString *)icon
                   colorHex:(nullable NSString *)colorHex {
    self = [super init];
    if (self) {
        _key = [key copy];
        _value = [value copy];
        _icon = [icon copy];
        _colorHex = [colorHex copy];
    }
    return self;
}

@end

#pragma mark - TideyStatusStore

@interface TideyStatusStore ()
// workspaceID -> (key -> TideyStatusEntry)
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, TideyStatusEntry *> *> *statusMap;
@end

@implementation TideyStatusStore

+ (instancetype)sharedStore {
    static TideyStatusStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[self alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusMap = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)setStatusForWorkspaceID:(NSString *)workspaceID
                            key:(NSString *)key
                          value:(NSString *)value
                           icon:(nullable NSString *)icon
                       colorHex:(nullable NSString *)colorHex {
    if (workspaceID.length == 0 || key.length == 0) {
        return;
    }
    NSMutableDictionary<NSString *, TideyStatusEntry *> *entries = self.statusMap[workspaceID];
    if (!entries) {
        entries = [[NSMutableDictionary alloc] init];
        self.statusMap[workspaceID] = entries;
    }
    entries[key] = [[TideyStatusEntry alloc] initWithKey:key value:value icon:icon colorHex:colorHex];
    [self postDidChange];
}

- (void)clearStatusForWorkspaceID:(NSString *)workspaceID key:(NSString *)key {
    if (workspaceID.length == 0 || key.length == 0) {
        return;
    }
    NSMutableDictionary<NSString *, TideyStatusEntry *> *entries = self.statusMap[workspaceID];
    if (!entries || !entries[key]) {
        return;
    }
    [entries removeObjectForKey:key];
    if (entries.count == 0) {
        [self.statusMap removeObjectForKey:workspaceID];
    }
    [self postDidChange];
}

- (NSArray<TideyStatusEntry *> *)statusEntriesForWorkspaceID:(NSString *)workspaceID {
    if (workspaceID.length == 0) {
        return @[];
    }
    // Merge workspace-specific entries with broadcast ("*") entries.
    NSMutableDictionary<NSString *, TideyStatusEntry *> *merged = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, TideyStatusEntry *> *broadcastEntries = self.statusMap[@"*"];
    if (broadcastEntries) {
        [merged addEntriesFromDictionary:broadcastEntries];
    }
    NSDictionary<NSString *, TideyStatusEntry *> *entries = self.statusMap[workspaceID];
    if (entries) {
        [merged addEntriesFromDictionary:entries];  // workspace-specific overrides broadcast
    }
    if (merged.count == 0) {
        return @[];
    }
    return [[merged allValues] sortedArrayUsingComparator:^NSComparisonResult(TideyStatusEntry *a, TideyStatusEntry *b) {
        return [a.key compare:b.key];
    }];
}

- (BOOL)hasStatusForWorkspaceID:(NSString *)workspaceID {
    if (workspaceID.length == 0) {
        return NO;
    }
    return self.statusMap[workspaceID].count > 0 || self.statusMap[@"*"].count > 0;
}

- (NSArray<NSString *> *)allWorkspaceIDs {
    return [self.statusMap allKeys];
}

- (void)postDidChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:TideyStatusStoreDidChangeNotification
                                                        object:self
                                                      userInfo:nil];
}

@end
