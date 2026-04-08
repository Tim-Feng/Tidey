#import <XCTest/XCTest.h>

#import "PTYMouseHandler.h"

@interface PTYMouseHandler (Testing)
+ (long long)tideySelectionAbsoluteYForSelectionY:(int)selectionY
                                         overflow:(long long)overflow
                          numberOfScrollbackLines:(int)numberOfScrollbackLines;
@end

@interface PTYMouseHandlerSelectionTests : XCTestCase
@end

@implementation PTYMouseHandlerSelectionTests

- (void)testSelectionAbsoluteYAddsScrollbackLines {
    long long value = [PTYMouseHandler tideySelectionAbsoluteYForSelectionY:2
                                                                   overflow:0
                                                    numberOfScrollbackLines:38];
    XCTAssertEqual(value, 40);
}

- (void)testSelectionAbsoluteYMatchesOriginalBehaviorWithoutScrollback {
    long long value = [PTYMouseHandler tideySelectionAbsoluteYForSelectionY:12
                                                                   overflow:7
                                                    numberOfScrollbackLines:0];
    XCTAssertEqual(value, 19);
}

@end
