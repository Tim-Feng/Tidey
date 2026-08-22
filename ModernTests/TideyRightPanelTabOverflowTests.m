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

@end
