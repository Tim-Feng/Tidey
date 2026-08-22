#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

@class TideyEditorTab;

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

@end
