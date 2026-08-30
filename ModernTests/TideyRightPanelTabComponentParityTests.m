#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

typedef NS_ENUM(NSInteger, TideyPaneBoundaryEdge) {
    TideyPaneBoundaryEdgeLeft,
    TideyPaneBoundaryEdgeRight,
    TideyPaneBoundaryEdgeBottom,
};

@interface iTermRootTerminalView (TideyRightPanelTabComponentParityTests)
+ (NSDictionary<NSString *, NSNumber *> *)tideyRightPanelTabComponentMetrics;
+ (NSDictionary<NSString *, NSNumber *> *)tideyRightPanelGroupMetrics;
+ (NSRect)tideyPaneBoundaryFrameForEdge:(TideyPaneBoundaryEdge)edge
                        superviewBounds:(NSRect)bounds;
+ (BOOL)tideyPaneBoundaryEdgeIsResizer:(TideyPaneBoundaryEdge)edge;
+ (BOOL)tideyPaneBoundaryJoinGradientIsActiveWithUsesPaperTabJoinGradient:(BOOL)usesPaperTabJoinGradient
                                                boundaryColor:(NSColor *)boundaryColor
                                                 tabJoinColor:(NSColor *)tabJoinColor;
+ (NSRect)tideyPaneBoundaryFrameForEdge:(TideyPaneBoundaryEdge)edge
                        superviewBounds:(NSRect)bounds
                           pullBarMidY:(CGFloat)pullBarMidY;
+ (NSRect)tideyPaneBoundaryFrame:(NSRect)frame
      byExcludingTopHeight:(CGFloat)topInset
           superviewBounds:(NSRect)bounds;
+ (CGFloat)tideyChromeToggleButtonMidYForContainerHeight:(CGFloat)containerHeight;
+ (CGFloat)tideyFileTreePullBarMidYForEditorPanelHeight:(CGFloat)editorPanelHeight
                                   fileTreeContainerFrame:(NSRect)containerFrame;
+ (NSRect)tideyWorkspaceSeparatorFrameForSidebarWidth:(CGFloat)sidebarWidth
                                           rootBounds:(NSRect)rootBounds
                                         tabRowHeight:(CGFloat)tabRowHeight;
+ (NSRect)tideyWorkspaceSeparatorJoinRowForTabBarFrame:(NSRect)tabBarFrame;
+ (CGFloat)tideyPaneBoundaryCornerRadiusForFrame:(NSRect)frame;
+ (BOOL)tideyWorkspaceSeparatorUsesTabJoinGradientForSelectedTabFrame:(NSRect)selectedTabFrame
                                                          tabBarBounds:(NSRect)tabBarBounds;
+ (BOOL)tideyEditorPaneBoundaryUsesPaperTabJoinGradient;
+ (NSRect)tideyRightPanelLeadingCornerOverlayFrameForSelectedTabFrame:(NSRect)selectedTabFrame
                                                        tabStripBounds:(NSRect)tabStripBounds;
@end

// Every theme reuses the production tab/group component geometry; only colors
// differ through theme tokens. These assertions pin that contract.
@interface TideyRightPanelTabComponentParityTests : XCTestCase
@end

@implementation TideyRightPanelTabComponentParityTests

- (void)testMetricsMatchProductionComponentSystem {
    NSDictionary<NSString *, NSNumber *> *metrics =
        [iTermRootTerminalView tideyRightPanelTabComponentMetrics];

    XCTAssertEqualObjects(metrics[@"tabFontSize"], @11);
    XCTAssertEqualObjects(metrics[@"groupLabelFontSize"], @9);
    XCTAssertEqualObjects(metrics[@"groupButtonHeight"], @20);
    XCTAssertEqualObjects(metrics[@"tabVerticalInset"], @0);
    XCTAssertEqualObjects(metrics[@"titleLeadingInset"], @10);
    XCTAssertEqualObjects(metrics[@"titleTrailingInsetWithClose"], @34);
    XCTAssertEqualObjects(metrics[@"titleTrailingInsetWithoutClose"], @18);
    XCTAssertEqualObjects(metrics[@"closeButtonWidth"], @20);
    XCTAssertEqualObjects(metrics[@"closeButtonTrailingInset"], @2);
    XCTAssertEqualObjects(metrics[@"addButtonSize"], @22);
}

- (void)testGroupTagUsesPaperIndexMetricsInEveryTheme {
    NSDictionary<NSString *, NSNumber *> *metrics =
        [iTermRootTerminalView tideyRightPanelGroupMetrics];
    XCTAssertEqualObjects(metrics[@"horizontalPadding"], @10);
    XCTAssertEqualObjects(metrics[@"tabsGap"], @0);
    XCTAssertEqualObjects(metrics[@"usesPaperIndexStyle"], @YES);
}

- (void)testPaneBoundariesStayFullLength {
    const NSRect bounds = NSMakeRect(0, 0, 240, 600);
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                                   superviewBounds:bounds],
                               NSMakeRect(0, 0, 1, 600)));
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeRight
                                                                   superviewBounds:bounds],
                               NSMakeRect(239, 0, 1, 600)));
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeBottom
                                                                   superviewBounds:bounds],
                               NSMakeRect(0, 0, 240, 1)));
}

- (void)testResizerBoundariesStayFullHeightWhenGivenAPullBarMidpoint {
    // Tim parked the short pull-bar experiment; midpoint input does not alter
    // the shared full-height 1px geometry.
    const NSRect bounds = NSMakeRect(0, 0, 240, 600);
    for (NSNumber *edgeNumber in @[ @(TideyPaneBoundaryEdgeLeft), @(TideyPaneBoundaryEdgeRight), @(TideyPaneBoundaryEdgeBottom) ]) {
        const TideyPaneBoundaryEdge edge = edgeNumber.integerValue;
        const NSRect standard = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:edge
                                                                     superviewBounds:bounds];
        const NSRect withMidpoint = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:edge
                                                                         superviewBounds:bounds
                                                                            pullBarMidY:317];
        XCTAssertTrue(NSEqualRects(standard, withMidpoint), @"edge %ld", (long)edge);
    }
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                                   superviewBounds:bounds],
                               NSMakeRect(0, 0, 1, 600)));
    XCTAssertTrue([iTermRootTerminalView tideyPaneBoundaryEdgeIsResizer:TideyPaneBoundaryEdgeLeft]);
    XCTAssertTrue([iTermRootTerminalView tideyPaneBoundaryEdgeIsResizer:TideyPaneBoundaryEdgeRight]);
    XCTAssertFalse([iTermRootTerminalView tideyPaneBoundaryEdgeIsResizer:TideyPaneBoundaryEdgeBottom]);
}

- (void)testFileTreeArrowMidpointSeamStillConvertsContainerOrigin {
    // Pure midpoint helpers stay available for re-enabling the pull-bar experiment.
    XCTAssertEqual([iTermRootTerminalView tideyChromeToggleButtonMidYForContainerHeight:634], 317);
    XCTAssertEqual([iTermRootTerminalView tideyFileTreePullBarMidYForEditorPanelHeight:634
                                                              fileTreeContainerFrame:NSMakeRect(400, 40, 200, 560)],
                   277);
}

- (void)testWorkspaceAndEditorBoundariesStopBelowTheirTabStrips {
    const NSRect bounds = NSMakeRect(0, 0, 400, 600);
    const NSRect full = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                             superviewBounds:bounds];
    const NSRect shortened = [iTermRootTerminalView tideyPaneBoundaryFrame:full
                                                      byExcludingTopHeight:34
                                                           superviewBounds:bounds];
    XCTAssertTrue(NSEqualRects(shortened, NSMakeRect(0, 0, 1, 566)));
    // No inset leaves the line untouched.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrame:full
                                                        byExcludingTopHeight:0
                                                             superviewBounds:bounds],
                               full));
}

// The root-hosted seam sits on the terminal side (x = sidebarWidth) so its
// center is the same coordinate as the focused paper tab's leading outline
// (PSM strokes cell.frame.minX + 0.5, first tab at x = sidebarWidth). It is a
// root subview above _tabView, so it is never clipped by the sidebar (the
// 798ce69eb failure was a sidebar-hosted view pushed outside its host).
- (void)testWorkspaceSeparatorCenterMatchesTheFocusedTabLeadingStroke {
    const NSRect root = NSMakeRect(0, 0, 1200, 700);
    const CGFloat sidebarWidth = 200;
    const NSRect separator = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:sidebarWidth
                                                                                      rootBounds:root
                                                                                    tabRowHeight:34];
    XCTAssertTrue(NSEqualRects(separator, NSMakeRect(200, 0, 1, 666)));
    XCTAssertTrue(NSContainsRect(root, separator));
    const NSRect firstTabCell = NSMakeRect(sidebarWidth, 0, 120, 34);
    const CGFloat tabLeadingStrokeCenter = NSMinX(firstTabCell) + 0.5;
    XCTAssertEqual(NSMidX(separator), tabLeadingStrokeCenter);
    XCTAssertEqual(NSMaxY(separator), NSHeight(root) - 34);
}

- (void)testWorkspaceSeparatorFollowsTabRowVisibilityAndDegenerateSizes {
    const NSRect root = NSMakeRect(0, 0, 1200, 700);
    // Hidden tab bar (height 0): the line runs full height.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                                        rootBounds:root
                                                                                      tabRowHeight:0],
                               NSMakeRect(200, 0, 1, 700)));
    // Root shorter than the tab row: zero-height line, never negative.
    const NSRect tiny = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                                 rootBounds:NSMakeRect(0, 0, 1200, 20)
                                                                               tabRowHeight:34];
    XCTAssertEqual(NSHeight(tiny), 0);
    XCTAssertEqual(NSMinX(tiny), 200);
    // No sidebar: no line.
    XCTAssertTrue(NSIsEmptyRect([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:0
                                                                                         rootBounds:root
                                                                                       tabRowHeight:34]));
    // Sidebar wider than the root (mid-resize): clamped to the last root column.
    const NSRect clamped = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:5000
                                                                                    rootBounds:root
                                                                                  tabRowHeight:34];
    XCTAssertTrue(NSContainsRect(root, clamped));
    XCTAssertEqual(NSMinX(clamped), NSMaxX(root) - 1);
    // Re-pin after a resize is a pure function of the new inputs.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:260
                                                                                        rootBounds:NSMakeRect(0, 0, 900, 500)
                                                                                      tabRowHeight:34],
                               NSMakeRect(260, 0, 1, 466)));
}

// The focused first tab's leading outline ends on the tab bar's bottom row;
// the separator's top row must be that same row (no uncovered row between
// them), in both real layouts: with the 1pt division row reserved under the
// tab bar (bar bottom = H - 35) and without it (bar bottom = H - 34).
- (void)testWorkspaceSeparatorTopRowIsTheFocusedTabOutlineBottomRow {
    const NSRect root = NSMakeRect(0, 0, 1200, 700);
    const CGFloat sidebarWidth = 200;
    const CGFloat tabBarHeight = 34;
    const NSRect separator = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:sidebarWidth
                                                                                     rootBounds:root
                                                                                   tabRowHeight:tabBarHeight];

    // Layout with the division row: decorationTop = 34 + 1, tab bar at y = 665.
    const NSRect tabBarWithDivision = NSMakeRect(sidebarWidth, 700 - tabBarHeight - 1, 800, tabBarHeight);
    const NSRect joinRow = [iTermRootTerminalView tideyWorkspaceSeparatorJoinRowForTabBarFrame:tabBarWithDivision];
    XCTAssertTrue(NSEqualRects(joinRow, NSMakeRect(200, 665, 800, 1)));
    // The seam column intersects the join row fully: no uncovered row at the corner.
    const NSRect seamJoin = NSIntersectionRect(separator, joinRow);
    XCTAssertEqual(NSHeight(seamJoin), 1);
    XCTAssertEqual(NSMinX(seamJoin), sidebarWidth);
    // And the seam does not run further up into the tab row proper.
    XCTAssertLessThanOrEqual(NSMaxY(separator), NSMinY(tabBarWithDivision) + 1);

    // Layout without the division row: tab bar at y = 666, seam ends exactly there.
    const NSRect tabBarNoDivision = NSMakeRect(sidebarWidth, 700 - tabBarHeight, 800, tabBarHeight);
    XCTAssertEqual(NSMaxY(separator), NSMinY(tabBarNoDivision));
    XCTAssertTrue(NSIsEmptyRect(NSIntersectionRect(separator, tabBarNoDivision)));
}

// Regression for afd0165d4: the workspace seam layer still carried the
// parked pull-bar corner radius (1pt on a 1pt-wide layer), which rounded its
// top end and left the join row only partially painted. A 1pt line gets no
// radius; only a wider bar does.
- (void)testOnePointBoundaryLinesHaveNoCornerRadiusSoTheJoinRowIsFullyPainted {
    const NSRect seam = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                               rootBounds:NSMakeRect(0, 0, 1200, 700)
                                                                             tabRowHeight:34];
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:seam], 0);
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:NSMakeRect(0, 0, 1, 566)], 0);
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:NSMakeRect(0, 0, 400, 1)], 0);
    // The parked 2pt pull bar keeps rounded ends.
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:NSMakeRect(0, 283, 2, 34)], 1);
}

- (void)testWorkspaceSeparatorJoinGradientOnlyFollowsTheLeadingFocusedTab {
    const NSRect bounds = NSMakeRect(0, 0, 500, 30);
    XCTAssertTrue([iTermRootTerminalView tideyWorkspaceSeparatorUsesTabJoinGradientForSelectedTabFrame:
                       NSMakeRect(0, 0, 120, 30)
                                                                                                  tabBarBounds:bounds]);
    XCTAssertFalse([iTermRootTerminalView tideyWorkspaceSeparatorUsesTabJoinGradientForSelectedTabFrame:
                        NSMakeRect(120, 0, 120, 30)
                                                                                                   tabBarBounds:bounds]);
    XCTAssertFalse([iTermRootTerminalView tideyWorkspaceSeparatorUsesTabJoinGradientForSelectedTabFrame:NSZeroRect
                                                                                           tabBarBounds:bounds]);
}

// The editor pane boundary sits under the `Code` group chrome, not under a
// selected paper-tab leg. It must remain the ordinary pane separator; the
// selected file tab owns the focus transition at its own lower-left corner.
- (void)testEditorPaneBoundaryDoesNotClaimTheSelectedPaperTabJoin {
    XCTAssertFalse([iTermRootTerminalView tideyEditorPaneBoundaryUsesPaperTabJoinGradient]);
}

// Regression for b68618806: `Code` is group chrome, but it still creates real
// strip space before the first file tab. Since that tab's leading leg cannot
// continue into the pane boundary, it must turn and fade into the baseline.
- (void)testEditorLeadingCornerOverlayFollowsActualStripSpaceBeforeTheTab {
    const NSRect bounds = NSMakeRect(0, 0, 700, 30);
    const NSRect firstFileTabAfterPill = NSMakeRect(146, 0, 478, 30);
    XCTAssertTrue(NSEqualRects(
        [iTermRootTerminalView tideyRightPanelLeadingCornerOverlayFrameForSelectedTabFrame:firstFileTabAfterPill
                                                                               tabStripBounds:bounds],
        NSMakeRect(122, 0, 25, 30)));
    // A short amount of real strip space clamps the horizontal fade.
    XCTAssertTrue(NSEqualRects(
        [iTermRootTerminalView tideyRightPanelLeadingCornerOverlayFrameForSelectedTabFrame:NSMakeRect(6, 0, 120, 30)
                                                                               tabStripBounds:bounds],
        NSMakeRect(0, 0, 7, 30)));
    // Only a tab whose left leg truly coincides with the strip boundary keeps
    // the hard continuation instead of a lower-left turn.
    XCTAssertTrue(NSIsEmptyRect(
        [iTermRootTerminalView tideyRightPanelLeadingCornerOverlayFrameForSelectedTabFrame:NSMakeRect(0, 0, 120, 30)
                                                                               tabStripBounds:bounds]));
}

// The join gradient is a shared component behavior and never depends on a
// theme identity. It is off only when the boundary opts out or a color is missing.
- (void)testPaneBoundaryJoinGradientActivationFollowsLayoutPolicyNotTheme {
    NSColor *classicBoundary = [NSColor colorWithWhite:1 alpha:0.14];
    NSColor *classicJoin = [NSColor colorWithWhite:1 alpha:0.40];
    NSColor *warmBoundary = [NSColor colorWithSRGBRed:240 / 255.0 green:230 / 255.0 blue:210 / 255.0 alpha:0.06];
    NSColor *warmJoin = [NSColor colorWithSRGBRed:240 / 255.0 green:230 / 255.0 blue:210 / 255.0 alpha:0.40];
    XCTAssertTrue([iTermRootTerminalView tideyPaneBoundaryJoinGradientIsActiveWithUsesPaperTabJoinGradient:YES
                                                                           boundaryColor:classicBoundary
                                                                            tabJoinColor:classicJoin]);
    XCTAssertTrue([iTermRootTerminalView tideyPaneBoundaryJoinGradientIsActiveWithUsesPaperTabJoinGradient:YES
                                                                           boundaryColor:warmBoundary
                                                                            tabJoinColor:warmJoin]);
    XCTAssertFalse([iTermRootTerminalView tideyPaneBoundaryJoinGradientIsActiveWithUsesPaperTabJoinGradient:NO
                                                                            boundaryColor:classicBoundary
                                                                             tabJoinColor:classicJoin]);
    XCTAssertFalse([iTermRootTerminalView tideyPaneBoundaryJoinGradientIsActiveWithUsesPaperTabJoinGradient:YES
                                                                            boundaryColor:nil
                                                                             tabJoinColor:classicJoin]);
}

- (void)testSharedMetricsExposeOneComponentContract {
    XCTAssertEqual([iTermRootTerminalView tideyRightPanelTabComponentMetrics].count, 10);
}

@end
