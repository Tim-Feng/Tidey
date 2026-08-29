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
+ (NSRect)tideyPaneBoundaryFrame:(NSRect)frame
                byOffsettingX:(CGFloat)xOffset;
+ (CGFloat)tideyChromeToggleButtonMidYForContainerHeight:(CGFloat)containerHeight;
+ (CGFloat)tideyFileTreePullBarMidYForEditorPanelHeight:(CGFloat)editorPanelHeight
                                   fileTreeContainerFrame:(NSRect)containerFrame;
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

- (void)testWorkspaceBoundaryMovesOntoTheFirstTabLeadingStrokeColumn {
    const NSRect sidebarBoundary = NSMakeRect(199, 0, 1, 566);
    const NSRect aligned = [iTermRootTerminalView tideyPaneBoundaryFrame:sidebarBoundary
                                                          byOffsettingX:1];
    XCTAssertTrue(NSEqualRects(aligned, NSMakeRect(200, 0, 1, 566)));
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrame:sidebarBoundary
                                                              byOffsettingX:0],
                               sidebarBoundary));
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
