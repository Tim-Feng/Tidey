#import <XCTest/XCTest.h>

#import "PSMMinimalTabStyle.h"

@interface TideyMinimalTabStyleDelegateStub : NSObject <PSMMinimalTabStyleDelegate>
@property(nonatomic, strong) NSColor *backgroundColor;
@end

@implementation TideyMinimalTabStyleDelegateStub

- (NSColor *)minimalTabStyleBackgroundColor {
    return self.backgroundColor;
}

@end

@interface PSMMinimalTabStyleTests : XCTestCase
@end

@implementation PSMMinimalTabStyleTests

- (void)testTabBarColorUsesDelegateColor {
    NSColor *expected = [NSColor colorWithSRGBRed:0.082
                                            green:0.078
                                             blue:0.075
                                            alpha:1];
    TideyMinimalTabStyleDelegateStub *delegate = [[TideyMinimalTabStyleDelegateStub alloc] init];
    delegate.backgroundColor = expected;
    PSMMinimalTabStyle *style = [[PSMMinimalTabStyle alloc] init];
    style.delegate = delegate;

    XCTAssertEqualObjects(style.tabBarColor, expected);
}

@end
