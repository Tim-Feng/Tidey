//
//  TideyStatusStoreTests.m
//  iTerm2XCTests
//

#import <XCTest/XCTest.h>

#import "TideyNotificationStore.h"

@interface TideyStatusStoreTests : XCTestCase
@end

@implementation TideyStatusStoreTests {
    NSInteger _changeCount;
}

- (void)setUp {
    [super setUp];
    _changeCount = 0;
}

- (void)tearDown {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super tearDown];
}

- (TideyStatusStore *)freshStore {
    TideyStatusStore *store = [[[TideyStatusStore alloc] init] autorelease];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(statusStoreDidChange:)
                                                 name:TideyStatusStoreDidChangeNotification
                                               object:store];
    return store;
}

- (void)statusStoreDidChange:(NSNotification *)notification {
    _changeCount++;
}

- (void)testSetStatusPostsChangeNotificationAndStoresEntry {
    TideyStatusStore *store = [self freshStore];

    [store setStatusForWorkspaceID:@"workspace-1"
                               key:@"shell_state"
                             value:@"Running"
                              icon:@"bolt.fill"
                          colorHex:@"#007AFF"];

    XCTAssertEqual(_changeCount, 1);

    NSArray *entries = [store statusEntriesForWorkspaceID:@"workspace-1"];
    XCTAssertEqual(entries.count, 1);

    TideyStatusEntry *entry = entries.firstObject;
    XCTAssertEqualObjects(entry.key, @"shell_state");
    XCTAssertEqualObjects(entry.value, @"Running");
    XCTAssertEqualObjects(entry.icon, @"bolt.fill");
    XCTAssertEqualObjects(entry.colorHex, @"#007AFF");
}

- (void)testWorkspaceSpecificStatusOverridesBroadcastAndEntriesAreSorted {
    TideyStatusStore *store = [self freshStore];

    [store setStatusForWorkspaceID:@"*"
                               key:@"shell_state"
                             value:@"Idle"
                              icon:@"pause.circle.fill"
                          colorHex:@"#8E8E93"];
    [store setStatusForWorkspaceID:@"*"
                               key:@"battery"
                             value:@"90%"
                              icon:@"battery.100"
                          colorHex:@"#34C759"];
    [store setStatusForWorkspaceID:@"workspace-1"
                               key:@"shell_state"
                             value:@"Running"
                              icon:@"bolt.fill"
                          colorHex:@"#007AFF"];
    [store setStatusForWorkspaceID:@"workspace-1"
                               key:@"agent"
                             value:@"Claude"
                              icon:@"sparkles"
                          colorHex:@"#4C8DFF"];

    NSArray *workspaceEntries = [store statusEntriesForWorkspaceID:@"workspace-1"];
    XCTAssertEqualObjects([workspaceEntries valueForKey:@"key"], (@[ @"agent", @"battery", @"shell_state" ]));
    XCTAssertEqualObjects([workspaceEntries valueForKey:@"value"], (@[ @"Claude", @"90%", @"Running" ]));

    NSArray *otherWorkspaceEntries = [store statusEntriesForWorkspaceID:@"workspace-2"];
    XCTAssertEqualObjects([otherWorkspaceEntries valueForKey:@"key"], (@[ @"battery", @"shell_state" ]));
    XCTAssertEqualObjects([otherWorkspaceEntries valueForKey:@"value"], (@[ @"90%", @"Idle" ]));
}

- (void)testHasStatusForWorkspaceIncludesBroadcastEntries {
    TideyStatusStore *store = [self freshStore];

    [store setStatusForWorkspaceID:@"*"
                               key:@"shell_state"
                             value:@"Idle"
                              icon:@"pause.circle.fill"
                          colorHex:@"#8E8E93"];

    XCTAssertTrue([store hasStatusForWorkspaceID:@"workspace-1"]);
    XCTAssertFalse([store hasStatusForWorkspaceID:@""]);
    XCTAssertEqual([store statusEntriesForWorkspaceID:@"workspace-1"].count, 1);
    XCTAssertEqual([store statusEntriesForWorkspaceID:@""].count, 0);
}

- (void)testClearStatusRemovesWorkspaceBucketWhenLastEntryIsDeleted {
    TideyStatusStore *store = [self freshStore];

    [store setStatusForWorkspaceID:@"workspace-1"
                               key:@"shell_state"
                             value:@"Running"
                              icon:@"bolt.fill"
                          colorHex:@"#007AFF"];
    [store setStatusForWorkspaceID:@"workspace-1"
                               key:@"agent"
                             value:@"Claude"
                              icon:@"sparkles"
                          colorHex:@"#4C8DFF"];

    XCTAssertEqualObjects([NSSet setWithArray:[store allWorkspaceIDs]], [NSSet setWithObject:@"workspace-1"]);

    [store clearStatusForWorkspaceID:@"workspace-1" key:@"shell_state"];
    XCTAssertEqual([store statusEntriesForWorkspaceID:@"workspace-1"].count, 1);

    [store clearStatusForWorkspaceID:@"workspace-1" key:@"agent"];

    XCTAssertFalse([store hasStatusForWorkspaceID:@"workspace-1"]);
    XCTAssertEqual([store statusEntriesForWorkspaceID:@"workspace-1"].count, 0);
    XCTAssertEqual([store allWorkspaceIDs].count, 0);
}

- (void)testInvalidOperationsDoNotPostChanges {
    TideyStatusStore *store = [self freshStore];

    [store setStatusForWorkspaceID:@""
                               key:@"shell_state"
                             value:@"Running"
                              icon:nil
                          colorHex:nil];
    [store setStatusForWorkspaceID:@"workspace-1"
                               key:@""
                             value:@"Running"
                              icon:nil
                          colorHex:nil];
    [store clearStatusForWorkspaceID:@"workspace-1" key:@"missing"];
    [store clearStatusForWorkspaceID:@"" key:@"shell_state"];

    XCTAssertEqual(_changeCount, 0);
    XCTAssertEqual([store allWorkspaceIDs].count, 0);
}

@end
