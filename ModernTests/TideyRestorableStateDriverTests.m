#import <XCTest/XCTest.h>

#import "iTermRestorableStateDriver.h"

@interface TideyNativeRestorableStateSaverSpy : NSObject <iTermRestorableStateSaver>
@property(nonatomic, weak) id<iTermRestorableStateSaving> delegate;
@property(nonatomic, copy, nullable) void (^saveCompletion)(void);
@end

@implementation TideyNativeRestorableStateSaverSpy

- (BOOL)saveSynchronously:(BOOL)synchronously
           withCompletion:(void (^)(void))completion {
    self.saveCompletion = completion;
    return YES;
}

- (void)completeSave {
    void (^completion)(void) = self.saveCompletion;
    self.saveCompletion = nil;
    completion();
}

@end

@interface TideyRestorableStateDriverTests : XCTestCase
@end

@implementation TideyRestorableStateDriverTests

- (void)testNativeSaveCompletionSeamCompiles {
    iTermRestorableStateDriver *driver = [[iTermRestorableStateDriver alloc] init];
    TideyNativeRestorableStateSaverSpy *saver =
        [[TideyNativeRestorableStateSaverSpy alloc] init];
    driver.saver = saver;

    XCTAssertTrue([driver respondsToSelector:@selector(saveWithCompletion:)]);
    if (![driver respondsToSelector:@selector(saveWithCompletion:)]) {
        return;
    }

    __block NSInteger completionCount = 0;
    const BOOL accepted = [driver saveWithCompletion:^{
        completionCount += 1;
    }];

    XCTAssertTrue(accepted);
    XCTAssertEqual(completionCount, 0);

    [saver completeSave];

    XCTAssertEqual(completionCount, 1);
}

@end
