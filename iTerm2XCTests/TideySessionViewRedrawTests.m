//
//  TideySessionViewRedrawTests.m
//  ModernTests
//

#import <XCTest/XCTest.h>

#import "PTYSession.h"
#import "SessionView.h"

@interface TideySessionViewRedrawTestView : SessionView
@property(nonatomic) BOOL fakeUsesMetal;
@property(nonatomic) BOOL fakeWindowIsMiniaturized;
@property(nonatomic) NSInteger metalInvalidationCount;
@end

@implementation TideySessionViewRedrawTestView

- (BOOL)tideyUsesMetalForRedraw {
    return self.fakeUsesMetal;
}

- (BOOL)tideyWindowIsMiniaturized {
    return self.fakeWindowIsMiniaturized;
}

- (void)tideyInvalidateMetalRedraw {
    self.metalInvalidationCount++;
}

@end

@interface TideySessionViewRedrawTests : XCTestCase
@end

@implementation TideySessionViewRedrawTests

- (void)testVisibleMetalRedrawUsesOverridableInvalidationSeam {
    TideySessionViewRedrawTestView *view = [[TideySessionViewRedrawTestView alloc] initWithFrame:NSZeroRect];
    view.fakeUsesMetal = YES;

    [view requestRedraw];

    XCTAssertEqual(view.metalInvalidationCount, 1);
    XCTAssertFalse(view.tideyHasDeferredMetalRedraw);
}

- (void)testDeminiaturizeNotificationIdentityRequiresOwningWindow {
    NSObject *window = [[NSObject alloc] init];
    NSObject *otherWindow = [[NSObject alloc] init];

    XCTAssertTrue([PTYSession tideyShouldFlushDeferredMetalRedrawForNotificationObject:window
                                                                          parentWindow:window]);
    XCTAssertFalse([PTYSession tideyShouldFlushDeferredMetalRedrawForNotificationObject:otherWindow
                                                                           parentWindow:window]);
    XCTAssertFalse([PTYSession tideyShouldFlushDeferredMetalRedrawForNotificationObject:nil
                                                                           parentWindow:nil]);
}

- (void)testMinimizedMetalRedrawDefersAndFlushesOnceAfterOwnWindowRestores {
    TideySessionViewRedrawTestView *view = [[TideySessionViewRedrawTestView alloc] initWithFrame:NSZeroRect];
    view.fakeUsesMetal = YES;
    view.fakeWindowIsMiniaturized = YES;

    [view requestRedraw];
    [view requestRedraw];

    XCTAssertEqual(view.metalInvalidationCount, 0);
    XCTAssertTrue(view.tideyHasDeferredMetalRedraw);

    view.fakeWindowIsMiniaturized = NO;
    [view tideyFlushDeferredMetalRedrawIfVisible];

    XCTAssertEqual(view.metalInvalidationCount, 1);
    XCTAssertFalse(view.tideyHasDeferredMetalRedraw);

    [view tideyFlushDeferredMetalRedrawIfVisible];

    XCTAssertEqual(view.metalInvalidationCount, 1);
}

- (void)testFlushWhileStillMiniaturizedKeepsPendingRedraw {
    TideySessionViewRedrawTestView *view = [[TideySessionViewRedrawTestView alloc] initWithFrame:NSZeroRect];
    view.fakeUsesMetal = YES;
    view.fakeWindowIsMiniaturized = YES;

    [view requestRedraw];
    [view tideyFlushDeferredMetalRedrawIfVisible];

    XCTAssertEqual(view.metalInvalidationCount, 0);
    XCTAssertTrue(view.tideyHasDeferredMetalRedraw);
}

@end
