#import <XCTest/XCTest.h>

#import "PseudoTerminal.h"
#import "iTermApplicationDelegate.h"

@interface PseudoTerminal (TideyAppShortcutBehaviorTests)
+ (BOOL)tideyShouldIgnoreCloseCurrentSessionWithTabCount:(NSInteger)tabCount
                                  currentTabSessionCount:(NSInteger)sessionCount
                                 didCloseRightPanelTab:(BOOL)didCloseRightPanelTab;
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
                                       showingTideySidebar:(BOOL)showingTideySidebar;
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
                                                                       showingTideySidebar:NO],
                   1);
}

- (void)testAlternateNewSessionRoutingUsesTerminalTabOutsideTideySidebar {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:NO
                                                                       showingTideySidebar:NO],
                   0);
}

- (void)testAlternateNewSessionRoutingUsesTideyPanelInsideSidebar {
    XCTAssertEqual([iTermApplicationDelegate tideyAlternateNewSessionActionForBrowserFocus:NO
                                                                       showingTideySidebar:YES],
                   2);
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
