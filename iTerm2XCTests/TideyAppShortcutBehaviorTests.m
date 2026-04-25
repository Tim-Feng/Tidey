#import <XCTest/XCTest.h>

#import "PseudoTerminal.h"
#import "TideyEditorDocumentStore.h"
#import "iTermApplicationDelegate.h"
#import "iTermRootTerminalView.h"

@interface PseudoTerminal (TideyAppShortcutBehaviorTests)
+ (BOOL)tideyShouldIgnoreCloseCurrentSessionWithTabCount:(NSInteger)tabCount
                                  currentTabSessionCount:(NSInteger)sessionCount
                                 didCloseRightPanelTab:(BOOL)didCloseRightPanelTab;
+ (NSDictionary<NSString *, id> *)tideyDockBadgeStateForBellCount:(NSInteger)bellCount
                                           hasUnreadNotifications:(BOOL)hasUnreadNotifications;
+ (NSInteger)tideyBellCountByIncrementingDockBellCount:(NSInteger)bellCount;
+ (NSInteger)tideyClearedDockBellCount;
+ (NSArray<NSString *> *)tideyTmuxPaneIdentityCommandsForPane:(int)pane
                                                  workspaceID:(NSString *)workspaceID
                                                      panelID:(NSString *)panelID;
+ (BOOL)tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:(NSString *)selectedWorkspaceID
                                                             notificationWorkspaceID:(NSString *)workspaceID
                                                                         appIsActive:(BOOL)appIsActive
                                                                    isCurrentTerminal:(BOOL)isCurrentTerminal
                                                                          isKeyWindow:(BOOL)isKeyWindow;
+ (BOOL)tideyShouldProcessAutoMarkReadForNotificationArrivalWithNotificationID:(NSString *)notificationID;
@end

@interface iTermApplicationDelegate (TideyAppShortcutBehaviorTests)
+ (BOOL)tideyShouldRequireQuitConfirmationAtDate:(NSDate *)now
                            lastConfirmationDate:(NSDate *)lastConfirmationDate
                           systemIsShuttingDown:(BOOL)systemIsShuttingDown
                              sparkleRestarting:(BOOL)sparkleRestarting
                                       interval:(NSTimeInterval)interval;
+ (NSString *)tideyFullscreenShortcutKeyEquivalentForProfileShortcutChange:(NSNumber *)fShortcut;
+ (NSEventModifierFlags)tideyFullscreenShortcutModifierMaskForProfileShortcutChange:(NSNumber *)fShortcut;
+ (NSInteger)tideyAlternateNewSessionActionForBrowserFocus:(BOOL)browserHasFocus
                                       editorPaneHasFocus:(BOOL)editorPaneHasFocus
                                       showingTideySidebar:(BOOL)showingTideySidebar;
@end

@interface iTermRootTerminalView (TideySplitViewTesting)
+ (NSDictionary<NSString *, id> *)tideyTabMoveResultByMovingObjectAtSourceIndex:(NSInteger)sourceIndex
                                                              fromSourceObjects:(NSArray *)sourceObjects
                                                            sourceSelectedIndex:(NSInteger)sourceSelectedIndex
                                                       toDestinationObjects:(NSArray *)destinationObjects
                                                 destinationSelectedIndex:(NSInteger)destinationSelectedIndex
                                                           destinationIndex:(NSInteger)destinationIndex
                                                                    samePane:(BOOL)samePane
                                                             sourceIsPrimary:(BOOL)sourceIsPrimary
                                                            splitWasVisible:(BOOL)splitWasVisible;
+ (BOOL)tideyNextSplitVisibilityAfterToggleFromVisible:(BOOL)splitVisible;
@end

@interface TideyBrowserContainerView : NSView
@property(nonatomic, copy) void (^tideyNewTabHandler)(void);
@end

@interface TideyAppShortcutBehaviorTests : XCTestCase
@end

@implementation TideyAppShortcutBehaviorTests

- (void)testCloseCurrentSessionIsIgnoredForLastTerminalTabAndSession {
    XCTAssertTrue([PseudoTerminal tideyShouldIgnoreCloseCurrentSessionWithTabCount:1
                                                            currentTabSessionCount:1
                                                           didCloseRightPanelTab:NO]);
    XCTAssertFalse([PseudoTerminal tideyShouldIgnoreCloseCurrentSessionWithTabCount:2
                                                             currentTabSessionCount:1
                                                            didCloseRightPanelTab:NO]);
    XCTAssertFalse([PseudoTerminal tideyShouldIgnoreCloseCurrentSessionWithTabCount:1
                                                             currentTabSessionCount:2
                                                            didCloseRightPanelTab:NO]);
    XCTAssertTrue([PseudoTerminal tideyShouldIgnoreCloseCurrentSessionWithTabCount:2
                                                            currentTabSessionCount:3
                                                           didCloseRightPanelTab:YES]);
}

- (void)testDockBadgeStatePrefersBellCountOverUnreadDot {
    NSDictionary<NSString *, id> *badgeState =
        [PseudoTerminal tideyDockBadgeStateForBellCount:3 hasUnreadNotifications:YES];
    XCTAssertEqualObjects(badgeState[@"label"], @"3");
    XCTAssertEqualObjects(badgeState[@"showsBadge"], @YES);
}

- (void)testDockBadgeStatePrefersExplicitBellStateOverUnreadDot {
    NSDictionary<NSString *, id> *badgeState =
        [PseudoTerminal tideyDockBadgeStateForBellCount:[PseudoTerminal tideyBellCountByIncrementingDockBellCount:0]
                                 hasUnreadNotifications:YES];
    XCTAssertEqualObjects(badgeState[@"label"], @"1");
    XCTAssertEqualObjects(badgeState[@"showsBadge"], @YES);
}

- (void)testDockBadgeStateUsesDotOnlyWhenBellCountIsZero {
    NSDictionary<NSString *, id> *badgeState =
        [PseudoTerminal tideyDockBadgeStateForBellCount:0 hasUnreadNotifications:YES];
    XCTAssertEqualObjects(badgeState[@"label"], @"•");
    XCTAssertEqualObjects(badgeState[@"showsBadge"], @YES);
}

- (void)testDockBellCountIncrementClampsAt999 {
    XCTAssertEqual([PseudoTerminal tideyBellCountByIncrementingDockBellCount:0], 1);
    XCTAssertEqual([PseudoTerminal tideyBellCountByIncrementingDockBellCount:998], 999);
    XCTAssertEqual([PseudoTerminal tideyBellCountByIncrementingDockBellCount:999], 999);
}

- (void)testDockBellCountClearResetsToZero {
    XCTAssertEqual([PseudoTerminal tideyClearedDockBellCount], 0);
}

- (void)testDockBadgeStateClearsWhenThereIsNoBellOrUnreadNotification {
    NSDictionary<NSString *, id> *badgeState =
        [PseudoTerminal tideyDockBadgeStateForBellCount:0 hasUnreadNotifications:NO];
    XCTAssertEqualObjects(badgeState[@"label"], @"");
    XCTAssertEqualObjects(badgeState[@"showsBadge"], @NO);
}

- (void)testFocusedSelectedWorkspaceNotificationAutoMarkReadDecision {
    XCTAssertTrue([PseudoTerminal tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:@"workspace-1"
                                                                              notificationWorkspaceID:@"workspace-1"
                                                                                          appIsActive:YES
                                                                                     isCurrentTerminal:YES
                                                                                           isKeyWindow:YES]);
}

- (void)testBackgroundSelectedWorkspaceNotificationDoesNotAutoMarkRead {
    XCTAssertFalse([PseudoTerminal tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:@"workspace-1"
                                                                               notificationWorkspaceID:@"workspace-1"
                                                                                           appIsActive:NO
                                                                                      isCurrentTerminal:YES
                                                                                            isKeyWindow:YES]);
}

- (void)testNonKeyWindowSelectedWorkspaceNotificationDoesNotAutoMarkRead {
    XCTAssertFalse([PseudoTerminal tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:@"workspace-1"
                                                                               notificationWorkspaceID:@"workspace-1"
                                                                                           appIsActive:YES
                                                                                      isCurrentTerminal:YES
                                                                                            isKeyWindow:NO]);
}

- (void)testNonCurrentTerminalSelectedWorkspaceNotificationDoesNotAutoMarkRead {
    XCTAssertFalse([PseudoTerminal tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:@"workspace-1"
                                                                               notificationWorkspaceID:@"workspace-1"
                                                                                           appIsActive:YES
                                                                                      isCurrentTerminal:NO
                                                                                            isKeyWindow:YES]);
}

- (void)testOtherWorkspaceNotificationDoesNotAutoMarkRead {
    XCTAssertFalse([PseudoTerminal tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:@"workspace-1"
                                                                               notificationWorkspaceID:@"workspace-2"
                                                                                           appIsActive:YES
                                                                                      isCurrentTerminal:YES
                                                                                            isKeyWindow:YES]);
}

- (void)testFocusedBroadcastNotificationAutoMarkReadDecision {
    XCTAssertTrue([PseudoTerminal tideyShouldAutoMarkReadWorkspaceOnNotificationArrivalForSelectedWorkspaceID:@"workspace-1"
                                                                              notificationWorkspaceID:@"*"
                                                                                          appIsActive:YES
                                                                                     isCurrentTerminal:YES
                                                                                           isKeyWindow:YES]);
}

- (void)testNotificationStoreChangeWithoutNotificationIDDoesNotCountAsArrival {
    XCTAssertFalse([PseudoTerminal tideyShouldProcessAutoMarkReadForNotificationArrivalWithNotificationID:nil]);
    XCTAssertFalse([PseudoTerminal tideyShouldProcessAutoMarkReadForNotificationArrivalWithNotificationID:@""]);
    XCTAssertTrue([PseudoTerminal tideyShouldProcessAutoMarkReadForNotificationArrivalWithNotificationID:@"notification-1"]);
}

- (void)testTmuxPaneIdentityCommandIncludesPaneScopedWorkspaceAndPanelOptions {
    NSArray<NSString *> *commands =
        [PseudoTerminal tideyTmuxPaneIdentityCommandsForPane:42
                                                 workspaceID:@"workspace-123"
                                                     panelID:@"panel-456"];
    XCTAssertEqual(commands.count, 2);
    XCTAssertEqualObjects(commands[0], @"set-option -p -t %42 @tidey_workspace_id 'workspace-123'");
    XCTAssertEqualObjects(commands[1], @"set-option -p -t %42 @tidey_panel_id 'panel-456'");
}

- (void)testTmuxPaneIdentityCommandReturnsEmptyWhenPaneOrIdentifiersAreMissing {
    XCTAssertEqual([PseudoTerminal tideyTmuxPaneIdentityCommandsForPane:0
                                                            workspaceID:@"workspace-123"
                                                                panelID:@"panel-456"].count,
                   0);
    XCTAssertEqual([PseudoTerminal tideyTmuxPaneIdentityCommandsForPane:42
                                                            workspaceID:nil
                                                                panelID:@"panel-456"].count,
                   0);
    XCTAssertEqual([PseudoTerminal tideyTmuxPaneIdentityCommandsForPane:42
                                                            workspaceID:@"workspace-123"
                                                                panelID:nil].count,
                   0);
}

- (void)testQuitConfirmationRequiresSecondCommandQWithinTimeout {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:100];
    NSDate *recent = [NSDate dateWithTimeIntervalSince1970:98];
    NSDate *expired = [NSDate dateWithTimeIntervalSince1970:96];

    XCTAssertTrue([iTermApplicationDelegate tideyShouldRequireQuitConfirmationAtDate:now
                                                                 lastConfirmationDate:nil
                                                                systemIsShuttingDown:NO
                                                                   sparkleRestarting:NO
                                                                            interval:3.0]);
    XCTAssertFalse([iTermApplicationDelegate tideyShouldRequireQuitConfirmationAtDate:now
                                                                  lastConfirmationDate:recent
                                                                 systemIsShuttingDown:NO
                                                                    sparkleRestarting:NO
                                                                             interval:3.0]);
    XCTAssertTrue([iTermApplicationDelegate tideyShouldRequireQuitConfirmationAtDate:now
                                                                 lastConfirmationDate:expired
                                                                systemIsShuttingDown:NO
                                                                   sparkleRestarting:NO
                                                                            interval:3.0]);
    XCTAssertFalse([iTermApplicationDelegate tideyShouldRequireQuitConfirmationAtDate:now
                                                                  lastConfirmationDate:nil
                                                                 systemIsShuttingDown:YES
                                                                    sparkleRestarting:NO
                                                                             interval:3.0]);
}

- (void)testFullscreenShortcutMappingUsesCommandEnterWhenProfilesChangeFShortcut {
    XCTAssertEqualObjects([iTermApplicationDelegate tideyFullscreenShortcutKeyEquivalentForProfileShortcutChange:@YES], @"\n");
    XCTAssertEqual([iTermApplicationDelegate tideyFullscreenShortcutModifierMaskForProfileShortcutChange:@YES],
                   NSEventModifierFlagCommand);
    XCTAssertEqualObjects([iTermApplicationDelegate tideyFullscreenShortcutKeyEquivalentForProfileShortcutChange:@NO], @"\n");
    XCTAssertEqual([iTermApplicationDelegate tideyFullscreenShortcutModifierMaskForProfileShortcutChange:@NO],
                   NSEventModifierFlagCommand);
}

- (void)testToggleFullScreenMenuDoesNotOwnControlCommandF {
    NSString *path = @"/Users/timfeng/GitHub/Tidey/Interfaces/MainMenu.xib";
    NSString *xib = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    XCTAssertNotNil(xib);

    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"<menuItem title=\"Toggle Full Screen\" keyEquivalent=\"\" identifier=\"Toggle Full Screen\"[\\s\\S]*?<modifierMask key=\"keyEquivalentModifierMask\"/>"
                                                  options:0
                                                    error:nil];
    NSUInteger matches = [regex numberOfMatchesInString:xib options:0 range:NSMakeRange(0, xib.length)];
    XCTAssertEqual(matches, 1U);
    XCTAssertFalse([xib containsString:@"<menuItem title=\"Toggle Full Screen\" keyEquivalent=\"f\""]);
}

- (void)testAlternateNewSessionRoutingUsesBrowserTabWhenBrowserHasFocus {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:YES
                                                                        editorPaneHasFocus:NO
                                                                       showingTideySidebar:NO],
                   1);
}

- (void)testAlternateNewSessionRoutingUsesEditorTabWhenEditorPaneHasFocus {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:NO
                                                                        editorPaneHasFocus:YES
                                                                        showingTideySidebar:NO],
                   3);
}

- (void)testAlternateNewSessionRoutingPrefersBrowserOverEditor {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:YES
                                                                        editorPaneHasFocus:YES
                                                                        showingTideySidebar:NO],
                   1);
}

- (void)testAlternateNewSessionRoutingUsesTerminalTabOutsideTideySidebar {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:NO
                                                                        editorPaneHasFocus:NO
                                                                       showingTideySidebar:NO],
                   0);
}

- (void)testAlternateNewSessionRoutingUsesTideyPanelInsideSidebar {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:NO
                                                                        editorPaneHasFocus:NO
                                                                       showingTideySidebar:YES],
                   2);
}

- (void)testDocumentStoreReturnsSameDocumentForCanonicalizedPath {
    TideyEditorDocumentStore *store = [[TideyEditorDocumentStore alloc] init];
    id doc1 = [store documentForPath:@"/foo/bar/../baz.txt"];
    id doc2 = [store documentForPath:@"/foo/baz.txt"];
    XCTAssertNotNil(doc1);
    XCTAssertEqual(doc1, doc2);
}

- (void)testDocumentStoreCreatesDistinctUntitledDocuments {
    TideyEditorDocumentStore *store = [[TideyEditorDocumentStore alloc] init];
    id doc1 = [store createUntitledDocument];
    id doc2 = [store createUntitledDocument];
    XCTAssertNotNil(doc1);
    XCTAssertNotNil(doc2);
    XCTAssertNotEqual(doc1, doc2);
    XCTAssertNotEqualObjects([doc1 identifier], [doc2 identifier]);
}

- (void)testDocumentStoreRemoveDocumentDropsStoredInstance {
    TideyEditorDocumentStore *store = [[TideyEditorDocumentStore alloc] init];
    id doc1 = [store documentForPath:@"/tmp/test.txt"];
    [store removeDocument:doc1];
    id doc2 = [store documentForPath:@"/tmp/test.txt"];
    XCTAssertNotEqual(doc1, doc2);
}

- (void)testTabDragStateMovesTabAcrossPanesAndFixesSelection {
    NSDictionary *result = [iTermRootTerminalView tideyTabMoveResultByMovingObjectAtSourceIndex:1
                                                                               fromSourceObjects:@[@"a", @"b", @"c"]
                                                                             sourceSelectedIndex:2
                                                                        toDestinationObjects:@[@"x"]
                                                                  destinationSelectedIndex:0
                                                                            destinationIndex:1
                                                                                     samePane:NO
                                                                              sourceIsPrimary:NO
                                                                             splitWasVisible:YES];
    XCTAssertEqualObjects(result[@"sourceObjects"], (@[@"a", @"c"]));
    XCTAssertEqualObjects(result[@"destinationObjects"], (@[@"x", @"b"]));
    XCTAssertEqual([result[@"sourceSelectedIndex"] integerValue], 1);
    XCTAssertEqual([result[@"destinationSelectedIndex"] integerValue], 1);
    XCTAssertTrue([result[@"splitVisible"] boolValue]);
}

- (void)testTabDragStateCollapsesWhenSecondaryBecomesEmpty {
    NSDictionary *result = [iTermRootTerminalView tideyTabMoveResultByMovingObjectAtSourceIndex:0
                                                                               fromSourceObjects:@[@"b"]
                                                                             sourceSelectedIndex:0
                                                                        toDestinationObjects:@[@"a"]
                                                                  destinationSelectedIndex:0
                                                                            destinationIndex:1
                                                                                     samePane:NO
                                                                              sourceIsPrimary:NO
                                                                             splitWasVisible:YES];
    XCTAssertEqualObjects(result[@"sourceObjects"], (@[]));
    XCTAssertEqualObjects(result[@"destinationObjects"], (@[@"a", @"b"]));
    XCTAssertEqual([result[@"sourceSelectedIndex"] integerValue], NSNotFound);
    XCTAssertFalse([result[@"splitVisible"] boolValue]);
}

- (void)testTabDragStateMergesSecondaryIntoPrimaryWhenPrimaryBecomesEmpty {
    NSDictionary *result = [iTermRootTerminalView tideyTabMoveResultByMovingObjectAtSourceIndex:0
                                                                               fromSourceObjects:@[@"a"]
                                                                             sourceSelectedIndex:0
                                                                        toDestinationObjects:@[@"b", @"c"]
                                                                  destinationSelectedIndex:1
                                                                            destinationIndex:1
                                                                                     samePane:NO
                                                                              sourceIsPrimary:YES
                                                                             splitWasVisible:YES];
    XCTAssertEqualObjects(result[@"sourceObjects"], (@[@"b", @"a", @"c"]));
    XCTAssertEqualObjects(result[@"destinationObjects"], (@[]));
    XCTAssertEqual([result[@"sourceSelectedIndex"] integerValue], 1);
    XCTAssertTrue([result[@"mergedPrimary"] boolValue]);
    XCTAssertFalse([result[@"splitVisible"] boolValue]);
}

- (void)testSplitToggleStateFlipsVisibility {
    XCTAssertTrue([iTermRootTerminalView tideyNextSplitVisibilityAfterToggleFromVisible:NO]);
    XCTAssertFalse([iTermRootTerminalView tideyNextSplitVisibilityAfterToggleFromVisible:YES]);
}

- (void)testBrowserContainerPerformKeyEquivalentInterceptsCommandT {
    TideyBrowserContainerView *view = [[NSClassFromString(@"TideyBrowserContainerView") alloc] initWithFrame:NSZeroRect];
    XCTAssertNotNil(view);

    __block NSInteger invocationCount = 0;
    view.tideyNewTabHandler = ^{
        invocationCount++;
    };

    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagCommand
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                    characters:@"t"
                   charactersIgnoringModifiers:@"t"
                                     isARepeat:NO
                                       keyCode:17];
    XCTAssertTrue([view performKeyEquivalent:event]);
    XCTAssertEqual(invocationCount, 1);
}

- (void)testBrowserContainerPerformKeyEquivalentIgnoresOtherKeys {
    TideyBrowserContainerView *view = [[NSClassFromString(@"TideyBrowserContainerView") alloc] initWithFrame:NSZeroRect];
    XCTAssertNotNil(view);

    __block NSInteger invocationCount = 0;
    view.tideyNewTabHandler = ^{
        invocationCount++;
    };

    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagCommand
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                    characters:@"w"
                   charactersIgnoringModifiers:@"w"
                                     isARepeat:NO
                                       keyCode:13];
    XCTAssertFalse([view performKeyEquivalent:event]);
    XCTAssertEqual(invocationCount, 0);
}

@end
