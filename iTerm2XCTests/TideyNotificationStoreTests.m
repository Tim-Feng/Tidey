//
//  TideyNotificationStoreTests.m
//  iTerm2XCTests
//

#import <XCTest/XCTest.h>

#import "TideyNotificationStore.h"

@interface TestableTideyNotificationStore : TideyNotificationStore
@end

@implementation TestableTideyNotificationStore

- (void)removeDeliveredSystemNotificationsForWorkspaceID:(NSString *)workspaceID {
}

@end

@interface TideyNotificationStoreTests : XCTestCase
@end

@implementation TideyNotificationStoreTests {
    NSMutableArray *_changeUserInfos;
}

- (void)setUp {
    [super setUp];
    _changeUserInfos = [[NSMutableArray alloc] init];
}

- (void)tearDown {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_changeUserInfos release];
    [super tearDown];
}

- (TestableTideyNotificationStore *)freshStore {
    TestableTideyNotificationStore *store = [[[TestableTideyNotificationStore alloc] init] autorelease];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(notificationStoreDidChange:)
                                                 name:TideyNotificationStoreDidChangeNotification
                                               object:store];
    return store;
}

- (void)notificationStoreDidChange:(NSNotification *)notification {
    [_changeUserInfos addObject:notification.userInfo ?: (id)NSNull.null];
}

- (void)testAddNotificationPostsCreatedNotificationMetadata {
    TestableTideyNotificationStore *store = [self freshStore];

    TideyNotificationItem *item = [store addNotificationForWorkspaceID:@"workspace-1"
                                                                 title:@"Build finished"
                                                              subtitle:@"main"
                                                                  body:@"Done"];

    XCTAssertEqual(_changeUserInfos.count, 1);

    NSDictionary *userInfo = [_changeUserInfos lastObject];
    XCTAssertEqualObjects(userInfo[@"workspaceID"], @"workspace-1");
    XCTAssertEqualObjects(userInfo[@"notificationID"], item.notificationID);
}

- (void)testWorkspaceNotificationReplacesPreviousItemButKeepsBroadcast {
    TestableTideyNotificationStore *store = [self freshStore];

    [store addNotificationForWorkspaceID:@"workspace-1"
                                   title:@"Old"
                                subtitle:nil
                                    body:@"First"];
    [store addNotificationForWorkspaceID:nil
                                   title:@"Broadcast"
                                subtitle:nil
                                    body:@"Shared"];
    [store addNotificationForWorkspaceID:@"workspace-1"
                                   title:@"New"
                                subtitle:nil
                                    body:@"Second"];

    NSArray *allNotifications = [[store allNotifications] autorelease];
    XCTAssertEqual(allNotifications.count, 2);
    XCTAssertEqualObjects([allNotifications valueForKey:@"title"], (@[ @"New", @"Broadcast" ]));

    NSArray *workspaceNotifications = [store notificationsForWorkspaceID:@"workspace-1"];
    XCTAssertEqual(workspaceNotifications.count, 2);
    XCTAssertEqualObjects([workspaceNotifications valueForKey:@"title"], (@[ @"New", @"Broadcast" ]));

    TideyNotificationItem *latestWorkspaceItem = [store latestNotificationForWorkspaceID:@"workspace-1"];
    TideyNotificationItem *latestOtherWorkspaceItem = [store latestNotificationForWorkspaceID:@"workspace-2"];
    XCTAssertEqualObjects(latestWorkspaceItem.title, @"New");
    XCTAssertEqualObjects(latestOtherWorkspaceItem.title, @"Broadcast");
}

- (void)testMarkReadForWorkspaceOnlyConsumesBroadcastForThatWorkspace {
    TestableTideyNotificationStore *store = [self freshStore];

    TideyNotificationItem *broadcast = [store addNotificationForWorkspaceID:nil
                                                                      title:@"Broadcast"
                                                                   subtitle:nil
                                                                       body:@"Shared"];
    [store addNotificationForWorkspaceID:@"workspace-1"
                                   title:@"Workspace"
                                subtitle:nil
                                    body:@"Scoped"];

    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-1"], 2);
    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-2"], 1);

    [store markReadForWorkspaceID:@"workspace-1"];

    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-1"], 0);
    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-2"], 1);
    XCTAssertTrue([store hasReadNotificationsForWorkspaceID:@"workspace-1"]);
    XCTAssertNil([store latestUnreadForWorkspaceID:@"workspace-1"]);
    XCTAssertEqualObjects([store latestUnreadForWorkspaceID:@"workspace-2"].notificationID, broadcast.notificationID);

    id lastUserInfo = [_changeUserInfos lastObject];
    XCTAssertEqualObjects(lastUserInfo, (id)NSNull.null);
}

- (void)testMarkUnreadRestoresBroadcastAndWorkspaceNotificationsForWorkspace {
    TestableTideyNotificationStore *store = [self freshStore];

    [store addNotificationForWorkspaceID:nil
                                   title:@"Broadcast"
                                subtitle:nil
                                    body:@"Shared"];
    [store addNotificationForWorkspaceID:@"workspace-1"
                                   title:@"Workspace"
                                subtitle:nil
                                    body:@"Scoped"];

    [store markReadForWorkspaceID:@"workspace-1"];
    [store markUnreadForWorkspaceID:@"workspace-1"];

    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-1"], 2);
    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-2"], 1);
    XCTAssertFalse([store hasReadNotificationsForWorkspaceID:@"workspace-1"]);
    XCTAssertEqualObjects([store latestUnreadForWorkspaceID:@"workspace-1"].title, @"Workspace");
}

- (void)testRemoveNotificationAndClearAllNotifications {
    TestableTideyNotificationStore *store = [self freshStore];

    TideyNotificationItem *first = [store addNotificationForWorkspaceID:@"workspace-1"
                                                                  title:@"One"
                                                               subtitle:nil
                                                                   body:@"1"];
    [store addNotificationForWorkspaceID:@"workspace-2"
                                   title:@"Two"
                                subtitle:nil
                                    body:@"2"];

    [store removeNotificationWithID:first.notificationID];

    NSArray *remaining = [[store allNotifications] autorelease];
    XCTAssertEqual(remaining.count, 1);
    XCTAssertEqualObjects(((TideyNotificationItem *)remaining.firstObject).title, @"Two");

    [store clearAllNotifications];

    NSArray *empty = [[store allNotifications] autorelease];
    XCTAssertEqual(empty.count, 0);
    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-1"], 0);
    XCTAssertEqual([store unreadCountForWorkspaceID:@"workspace-2"], 0);
}

@end
