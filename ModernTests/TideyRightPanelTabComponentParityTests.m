#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

@interface iTermRootTerminalView (TideyRightPanelTabComponentParityTests)
+ (NSDictionary<NSString *, NSNumber *> *)tideyRightPanelTabComponentMetricsForWarmTheme:(BOOL)warm;
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

- (void)testWarmMetricsAreIdenticalToClassicMetrics {
    NSDictionary<NSString *, NSNumber *> *classic =
        [iTermRootTerminalView tideyRightPanelTabComponentMetricsForWarmTheme:NO];
    NSDictionary<NSString *, NSNumber *> *warm =
        [iTermRootTerminalView tideyRightPanelTabComponentMetricsForWarmTheme:YES];

    XCTAssertEqual(classic.count, 10);
    XCTAssertEqualObjects(warm, classic);
}

@end
