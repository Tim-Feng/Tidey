#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

typedef NS_ENUM(NSInteger, TideyPaneBoundaryEdge) {
    TideyPaneBoundaryEdgeLeft,
    TideyPaneBoundaryEdgeRight,
    TideyPaneBoundaryEdgeBottom,
};

@interface iTermRootTerminalView (TideyRightPanelTabComponentParityTests)
+ (NSDictionary<NSString *, NSNumber *> *)tideyRightPanelTabComponentMetricsForWarmTheme:(BOOL)warm;
+ (NSRect)tideyPaneBoundaryFrameForEdge:(TideyPaneBoundaryEdge)edge
                        superviewBounds:(NSRect)bounds
                              warmTheme:(BOOL)warm;
+ (BOOL)tideyPaneBoundaryEdgeIsResizer:(TideyPaneBoundaryEdge)edge;
+ (NSRect)tideyPaneBoundaryFrameForEdge:(TideyPaneBoundaryEdge)edge
                        superviewBounds:(NSRect)bounds
                           pullBarMidY:(CGFloat)pullBarMidY
                              warmTheme:(BOOL)warm;
+ (NSRect)tideyPaneBoundaryFrame:(NSRect)frame
      byExcludingTopHeight:(CGFloat)topInset
           superviewBounds:(NSRect)bounds;
+ (CGFloat)tideyChromeToggleButtonMidYForContainerHeight:(CGFloat)containerHeight;
+ (CGFloat)tideyFileTreePullBarMidYForEditorPanelHeight:(CGFloat)editorPanelHeight
                                   fileTreeContainerFrame:(NSRect)containerFrame;
+ (NSRect)tideyWorkspaceSeparatorFrameForSidebarWidth:(CGFloat)sidebarWidth
                                           rootBounds:(NSRect)rootBounds
                                         tabRowHeight:(CGFloat)tabRowHeight
                                            warmTheme:(BOOL)warm;
+ (NSRect)tideyWorkspaceSeparatorJoinRowForTabBarFrame:(NSRect)tabBarFrame;
+ (CGFloat)tideyPaneBoundaryCornerRadiusForFrame:(NSRect)frame;
@end

// The Warm editor strip must reuse the production tab/group component geometry;
// only colors differ (through theme tokens). These assertions pin that contract.
@interface TideyRightPanelTabComponentParityTests : XCTestCase
@end

@implementation TideyRightPanelTabComponentParityTests

- (void)testClassicMetricsMatchProductionComponentSystem {
    NSDictionary<NSString *, NSNumber *> *metrics =
        [iTermRootTerminalView tideyRightPanelTabComponentMetricsForWarmTheme:NO];

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

- (void)testClassicPaneBoundariesStayFullLength {
    const NSRect bounds = NSMakeRect(0, 0, 240, 600);
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                                   superviewBounds:bounds
                                                                         warmTheme:NO],
                               NSMakeRect(0, 0, 1, 600)));
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeRight
                                                                   superviewBounds:bounds
                                                                         warmTheme:NO],
                               NSMakeRect(239, 0, 1, 600)));
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeBottom
                                                                   superviewBounds:bounds
                                                                         warmTheme:NO],
                               NSMakeRect(0, 0, 240, 1)));
}

- (void)testWarmResizerBoundariesAreFullHeightLinesLikeClassic {
    // Tim parked the short pull-bar experiment: Warm resizer edges are the same
    // full-height 1px lines as Classic; only the color token differs.
    const NSRect bounds = NSMakeRect(0, 0, 240, 600);
    for (NSNumber *edgeNumber in @[ @(TideyPaneBoundaryEdgeLeft), @(TideyPaneBoundaryEdgeRight), @(TideyPaneBoundaryEdgeBottom) ]) {
        const TideyPaneBoundaryEdge edge = edgeNumber.integerValue;
        const NSRect classic = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:edge
                                                                    superviewBounds:bounds
                                                                          warmTheme:NO];
        const NSRect warm = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:edge
                                                                 superviewBounds:bounds
                                                                    pullBarMidY:317
                                                                       warmTheme:YES];
        XCTAssertTrue(NSEqualRects(classic, warm), @"edge %ld", (long)edge);
    }
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                                   superviewBounds:bounds
                                                                         warmTheme:YES],
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
                                                             superviewBounds:bounds
                                                                   warmTheme:YES];
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
    const NSRect warm = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:sidebarWidth
                                                                                rootBounds:root
                                                                              tabRowHeight:34
                                                                                 warmTheme:YES];
    XCTAssertTrue(NSEqualRects(warm, NSMakeRect(200, 0, 1, 666)));
    XCTAssertTrue(NSContainsRect(root, warm));
    const NSRect firstTabCell = NSMakeRect(sidebarWidth, 0, 120, 34);
    const CGFloat tabLeadingStrokeCenter = NSMinX(firstTabCell) + 0.5;
    XCTAssertEqual(NSMidX(warm), tabLeadingStrokeCenter);
    // Warm: absent across the tab row, present below it.
    XCTAssertEqual(NSMaxY(warm), NSHeight(root) - 34);

    const NSRect classic = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:sidebarWidth
                                                                                   rootBounds:root
                                                                                 tabRowHeight:34
                                                                                    warmTheme:NO];
    XCTAssertTrue(NSEqualRects(classic, NSMakeRect(200, 0, 1, 700)));
}

- (void)testWorkspaceSeparatorFollowsTabRowVisibilityAndDegenerateSizes {
    const NSRect root = NSMakeRect(0, 0, 1200, 700);
    // Hidden tab bar (height 0): the line runs full height.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                                        rootBounds:root
                                                                                      tabRowHeight:0
                                                                                         warmTheme:YES],
                               NSMakeRect(200, 0, 1, 700)));
    // Root shorter than the tab row: zero-height line, never negative.
    const NSRect tiny = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                                 rootBounds:NSMakeRect(0, 0, 1200, 20)
                                                                               tabRowHeight:34
                                                                                  warmTheme:YES];
    XCTAssertEqual(NSHeight(tiny), 0);
    XCTAssertEqual(NSMinX(tiny), 200);
    // No sidebar: no line.
    XCTAssertTrue(NSIsEmptyRect([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:0
                                                                                         rootBounds:root
                                                                                       tabRowHeight:34
                                                                                          warmTheme:YES]));
    // Sidebar wider than the root (mid-resize): clamped to the last root column.
    const NSRect clamped = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:5000
                                                                                    rootBounds:root
                                                                                  tabRowHeight:34
                                                                                     warmTheme:YES];
    XCTAssertTrue(NSContainsRect(root, clamped));
    XCTAssertEqual(NSMinX(clamped), NSMaxX(root) - 1);
    // Re-pin after a resize is a pure function of the new inputs.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:260
                                                                                        rootBounds:NSMakeRect(0, 0, 900, 500)
                                                                                      tabRowHeight:34
                                                                                         warmTheme:YES],
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
                                                                                   tabRowHeight:tabBarHeight
                                                                                      warmTheme:YES];

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
                                                                             tabRowHeight:34
                                                                                warmTheme:YES];
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:seam], 0);
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:NSMakeRect(0, 0, 1, 566)], 0);
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:NSMakeRect(0, 0, 400, 1)], 0);
    // The parked 2pt pull bar keeps rounded ends.
    XCTAssertEqual([iTermRootTerminalView tideyPaneBoundaryCornerRadiusForFrame:NSMakeRect(0, 283, 2, 34)], 1);
}

- (void)testWarmMetricsAreIdenticalToClassicMetrics {
    NSDictionary<NSString *, NSNumber *> *classic =
        [iTermRootTerminalView tideyRightPanelTabComponentMetricsForWarmTheme:NO];
    NSDictionary<NSString *, NSNumber *> *warm =
        [iTermRootTerminalView tideyRightPanelTabComponentMetricsForWarmTheme:YES];

    XCTAssertEqual(classic.count, 10);
    XCTAssertEqualObjects(warm, classic);
}

@end
