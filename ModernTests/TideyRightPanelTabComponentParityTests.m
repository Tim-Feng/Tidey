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

// Regression for 798ce69eb: the workspace/terminal separator was shifted to
// x = sidebarWidth, outside the sidebar and under the terminal view. The
// root-hosted seam must stay inside the sidebar column and inside the root.
- (void)testWorkspaceSeparatorStaysInsideTheSidebarColumnAndBelowTheTabRow {
    const NSRect root = NSMakeRect(0, 0, 1200, 700);
    const CGFloat sidebarWidth = 200;
    const NSRect warm = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:sidebarWidth
                                                                                rootBounds:root
                                                                              tabRowHeight:34
                                                                                 warmTheme:YES];
    XCTAssertTrue(NSEqualRects(warm, NSMakeRect(199, 0, 1, 666)));
    XCTAssertTrue(NSContainsRect(root, warm));
    // The terminal begins at x == sidebarWidth; the line must end before it.
    XCTAssertLessThanOrEqual(NSMaxX(warm), sidebarWidth);
    XCTAssertFalse(NSEqualRects(warm, NSMakeRect(200, 0, 1, 666)), @"798ce69eb geometry must not come back");

    const NSRect classic = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:sidebarWidth
                                                                                   rootBounds:root
                                                                                 tabRowHeight:34
                                                                                    warmTheme:NO];
    XCTAssertTrue(NSEqualRects(classic, NSMakeRect(199, 0, 1, 700)));
}

- (void)testWorkspaceSeparatorFollowsTabRowVisibilityAndDegenerateSizes {
    const NSRect root = NSMakeRect(0, 0, 1200, 700);
    // Hidden tab bar (height 0): the line runs full height.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                                        rootBounds:root
                                                                                      tabRowHeight:0
                                                                                         warmTheme:YES],
                               NSMakeRect(199, 0, 1, 700)));
    // Root shorter than the tab row: zero-height line, never negative.
    const NSRect tiny = [iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:200
                                                                                 rootBounds:NSMakeRect(0, 0, 1200, 20)
                                                                               tabRowHeight:34
                                                                                  warmTheme:YES];
    XCTAssertEqual(NSHeight(tiny), 0);
    XCTAssertEqual(NSMinX(tiny), 199);
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
    // Re-pin after a resize is a pure function of the new inputs.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyWorkspaceSeparatorFrameForSidebarWidth:260
                                                                                        rootBounds:NSMakeRect(0, 0, 900, 500)
                                                                                      tabRowHeight:34
                                                                                         warmTheme:YES],
                               NSMakeRect(259, 0, 1, 466)));
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
