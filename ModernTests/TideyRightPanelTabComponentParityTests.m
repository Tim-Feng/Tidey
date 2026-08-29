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

- (void)testWarmResizerBoundariesBecomeShortPullBarsCenteredOnTheArrow {
    const NSRect bounds = NSMakeRect(0, 0, 240, 600);
    // Arrow controls are 34pt tall and vertically centered; the pull bar matches.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                                   superviewBounds:bounds
                                                                         warmTheme:YES],
                               NSMakeRect(0, 283, 2, 34)));
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeRight
                                                                   superviewBounds:bounds
                                                                         warmTheme:YES],
                               NSMakeRect(238, 283, 2, 34)));
    // Horizontal strip baselines are not resizers and keep their full width.
    XCTAssertTrue(NSEqualRects([iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeBottom
                                                                   superviewBounds:bounds
                                                                         warmTheme:YES],
                               NSMakeRect(0, 0, 240, 1)));
    XCTAssertTrue([iTermRootTerminalView tideyPaneBoundaryEdgeIsResizer:TideyPaneBoundaryEdgeLeft]);
    XCTAssertTrue([iTermRootTerminalView tideyPaneBoundaryEdgeIsResizer:TideyPaneBoundaryEdgeRight]);
    XCTAssertFalse([iTermRootTerminalView tideyPaneBoundaryEdgeIsResizer:TideyPaneBoundaryEdgeBottom]);
}

- (void)testWarmPullBarShrinksToShortSuperviews {
    const NSRect frame = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                              superviewBounds:NSMakeRect(0, 0, 100, 20)
                                                                    warmTheme:YES];
    XCTAssertTrue(NSEqualRects(frame, NSMakeRect(0, 0, 2, 20)));
}

// The file-tree boundary lives inside the file-tree container, which excludes
// the editor tab strip, while its arrow is centered in the whole editor panel.
// The pull bar must follow the arrow's midpoint after coordinate conversion,
// not center itself in its own (shorter) superview.
- (void)testWarmFileTreePullBarFollowsArrowMidpointAcrossUnequalHeights {
    const CGFloat editorPanelHeight = 634;   // includes a 34pt tab strip
    const NSRect containerFrame = NSMakeRect(400, 0, 200, 600);

    const CGFloat arrowMidY = [iTermRootTerminalView tideyChromeToggleButtonMidYForContainerHeight:editorPanelHeight];
    XCTAssertEqual(arrowMidY, 317);   // floor((634 - 34) / 2) + 17

    const CGFloat pullBarMidY = [iTermRootTerminalView tideyFileTreePullBarMidYForEditorPanelHeight:editorPanelHeight
                                                                            fileTreeContainerFrame:containerFrame];
    XCTAssertEqual(pullBarMidY, arrowMidY - NSMinY(containerFrame));

    const NSRect frame = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                              superviewBounds:NSMakeRect(0, 0, 200, 600)
                                                                 pullBarMidY:pullBarMidY
                                                                    warmTheme:YES];
    XCTAssertTrue(NSEqualRects(frame, NSMakeRect(0, 300, 2, 34)));
    XCTAssertEqual(NSMidY(frame), arrowMidY);
    // Independent centering in the container would have landed 17pt lower.
    XCTAssertNotEqual(NSMidY(frame), 300);
}

- (void)testWarmFileTreePullBarConvertsContainerOrigin {
    const NSRect containerFrame = NSMakeRect(400, 40, 200, 560);
    const CGFloat arrowMidY = [iTermRootTerminalView tideyChromeToggleButtonMidYForContainerHeight:634];
    const CGFloat pullBarMidY = [iTermRootTerminalView tideyFileTreePullBarMidYForEditorPanelHeight:634
                                                                            fileTreeContainerFrame:containerFrame];
    XCTAssertEqual(pullBarMidY, arrowMidY - 40);
    const NSRect frame = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                              superviewBounds:NSMakeRect(0, 0, 200, 560)
                                                                 pullBarMidY:pullBarMidY
                                                                    warmTheme:YES];
    XCTAssertEqual(NSMidY(frame) + NSMinY(containerFrame), arrowMidY);
}

- (void)testClassicIgnoresPullBarMidpoint {
    const NSRect frame = [iTermRootTerminalView tideyPaneBoundaryFrameForEdge:TideyPaneBoundaryEdgeLeft
                                                              superviewBounds:NSMakeRect(0, 0, 200, 600)
                                                                 pullBarMidY:317
                                                                    warmTheme:NO];
    XCTAssertTrue(NSEqualRects(frame, NSMakeRect(0, 0, 1, 600)));
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
