#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

typedef NS_ENUM(NSInteger, TideyRightPanelTabKind) {
    TideyRightPanelTabKindEditor = 0,
    TideyRightPanelTabKindBrowser = 1,
};

@interface TideyEditorTab : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) BOOL dirty;
@property(nonatomic) TideyRightPanelTabKind kind;
@end

@interface iTermRootTerminalView (TideyRightPanelTabOverflowTests)
+ (CGFloat)tideyRightPanelTrailingOcclusionForStripFrame:(NSRect)stripFrame
                                             overlayFrame:(NSRect)overlayFrame;
+ (NSArray<NSNumber *> *)tideyRightPanelEffectiveTabWidthsForPreferredWidths:(NSArray<NSNumber *> *)preferredWidths
                                                               tabBodyBudget:(CGFloat)tabBodyBudget;
+ (BOOL)tideyRightPanelShouldShowCloseButtonForWidth:(CGFloat)width selected:(BOOL)selected;
+ (NSArray<TideyEditorTab *> *)tideyRightPanelBulkCloseTargetsForTabs:(NSArray<TideyEditorTab *> *)tabs
                                                     clickedIdentifier:(NSString *)clickedIdentifier
                                                      closeTabsToRight:(BOOL)closeTabsToRight;
+ (BOOL)tideyRightPanelBulkCloseTargetsAreEligible:(NSArray<TideyEditorTab *> *)targets;
@end

@interface TideyRightPanelTabOverflowTests : XCTestCase
@end

@implementation TideyRightPanelTabOverflowTests

- (TideyEditorTab *)tabWithIdentifier:(NSString *)identifier kind:(TideyRightPanelTabKind)kind {
    TideyEditorTab *tab = [[TideyEditorTab alloc] init];
    tab.identifier = identifier;
    tab.kind = kind;
    return tab;
}

- (NSArray<NSString *> *)identifiersForTabs:(NSArray<TideyEditorTab *> *)tabs {
    return [tabs valueForKey:@"identifier"];
}

- (void)testPureOverflowPolicySeamsAreAvailable {
    XCTAssertTrue([iTermRootTerminalView respondsToSelector:
        @selector(tideyRightPanelTrailingOcclusionForStripFrame:overlayFrame:)]);
    XCTAssertTrue([iTermRootTerminalView respondsToSelector:
        @selector(tideyRightPanelEffectiveTabWidthsForPreferredWidths:tabBodyBudget:)]);
    XCTAssertTrue([iTermRootTerminalView respondsToSelector:
        @selector(tideyRightPanelShouldShowCloseButtonForWidth:selected:)]);
    XCTAssertTrue([iTermRootTerminalView respondsToSelector:
        @selector(tideyRightPanelBulkCloseTargetsForTabs:clickedIdentifier:closeTabsToRight:)]);
    XCTAssertTrue([iTermRootTerminalView respondsToSelector:
        @selector(tideyRightPanelBulkCloseTargetsAreEligible:)]);
}

- (void)testExtractedWidthPolicyPreservesPreferredWidths {
    NSArray<NSNumber *> *preferred = @[ @112, @176, @240 ];

    XCTAssertEqualObjects(
        [iTermRootTerminalView tideyRightPanelEffectiveTabWidthsForPreferredWidths:preferred
                                                                     tabBodyBudget:600],
        preferred);
}

- (void)testTrailingOcclusionUsesOnlyStripTrailingIntersection {
    NSRect strip = NSMakeRect(0, 40, 300, 34);

    XCTAssertEqualWithAccuracy(
        [iTermRootTerminalView tideyRightPanelTrailingOcclusionForStripFrame:strip
                                                                overlayFrame:NSMakeRect(200, 40, 100, 34)],
        100,
        0.001);
    XCTAssertEqualWithAccuracy(
        [iTermRootTerminalView tideyRightPanelTrailingOcclusionForStripFrame:strip
                                                                overlayFrame:NSMakeRect(260, 40, 100, 34)],
        40,
        0.001);
    XCTAssertEqualWithAccuracy(
        [iTermRootTerminalView tideyRightPanelTrailingOcclusionForStripFrame:strip
                                                                overlayFrame:NSMakeRect(320, 40, 100, 34)],
        0,
        0.001);
    XCTAssertEqualWithAccuracy(
        [iTermRootTerminalView tideyRightPanelTrailingOcclusionForStripFrame:strip
                                                                overlayFrame:NSMakeRect(200, 0, 100, 20)],
        0,
        0.001);
    XCTAssertEqualWithAccuracy(
        [iTermRootTerminalView tideyRightPanelTrailingOcclusionForStripFrame:strip
                                                                overlayFrame:NSMakeRect(50, 40, 50, 34)],
        0,
        0.001);
}

- (void)testEffectiveWidthsShrinkEquallyThenStopAtFloor {
    NSArray<NSNumber *> *preferred = @[ @150, @180, @200 ];

    XCTAssertEqualObjects(
        [iTermRootTerminalView tideyRightPanelEffectiveTabWidthsForPreferredWidths:preferred
                                                                     tabBodyBudget:300],
        (@[ @100, @100, @100 ]));
    XCTAssertEqualObjects(
        [iTermRootTerminalView tideyRightPanelEffectiveTabWidthsForPreferredWidths:preferred
                                                                     tabBodyBudget:150],
        (@[ @72, @72, @72 ]));
}

- (void)testCloseVisibilityUsesComputedWidthAndAlwaysShowsSelectedClose {
    XCTAssertTrue([iTermRootTerminalView tideyRightPanelShouldShowCloseButtonForWidth:112 selected:NO]);
    XCTAssertFalse([iTermRootTerminalView tideyRightPanelShouldShowCloseButtonForWidth:111 selected:NO]);
    XCTAssertTrue([iTermRootTerminalView tideyRightPanelShouldShowCloseButtonForWidth:72 selected:YES]);
}

- (void)testBulkTargetsFollowClickedTabsVisibleGroupOrder {
    TideyEditorTab *codeA = [self tabWithIdentifier:@"code-a" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *webA = [self tabWithIdentifier:@"web-a" kind:TideyRightPanelTabKindBrowser];
    TideyEditorTab *codeB = [self tabWithIdentifier:@"code-b" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *webB = [self tabWithIdentifier:@"web-b" kind:TideyRightPanelTabKindBrowser];
    TideyEditorTab *codeC = [self tabWithIdentifier:@"code-c" kind:TideyRightPanelTabKindEditor];
    NSArray<TideyEditorTab *> *modelOrder = @[ codeA, webA, codeB, webB, codeC ];

    XCTAssertEqualObjects(
        [self identifiersForTabs:
            [iTermRootTerminalView tideyRightPanelBulkCloseTargetsForTabs:modelOrder
                                                       clickedIdentifier:@"code-b"
                                                        closeTabsToRight:NO]],
        (@[ @"code-a", @"code-c" ]));
    XCTAssertEqualObjects(
        [self identifiersForTabs:
            [iTermRootTerminalView tideyRightPanelBulkCloseTargetsForTabs:modelOrder
                                                       clickedIdentifier:@"code-b"
                                                        closeTabsToRight:YES]],
        (@[ @"code-c" ]));
    XCTAssertEqualObjects(
        [self identifiersForTabs:
            [iTermRootTerminalView tideyRightPanelBulkCloseTargetsForTabs:modelOrder
                                                       clickedIdentifier:@"web-a"
                                                        closeTabsToRight:YES]],
        (@[ @"web-b" ]));
    XCTAssertEqualObjects(
        [iTermRootTerminalView tideyRightPanelBulkCloseTargetsForTabs:modelOrder
                                                   clickedIdentifier:@"missing"
                                                    closeTabsToRight:NO],
        (@[]));
}

@end
