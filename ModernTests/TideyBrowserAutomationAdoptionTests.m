#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

typedef NS_ENUM(NSInteger, TideyRightPanelTabKind) {
    TideyRightPanelTabKindEditor = 0,
    TideyRightPanelTabKindBrowser = 1,
};

@interface TideyEditorTab : NSObject
@property(nonatomic) TideyRightPanelTabKind kind;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) id browserEngine;
@end

@interface iTermRootTerminalView (TideyBrowserAutomationAdoptionTests)
+ (TideyEditorTab *)tideyBrowserAutomationTabWithIdentifier:(NSString *)identifier
                                                         URL:(NSURL *)url
                                                      engine:(id)engine;
@end

@interface TideyBrowserAutomationAdoptionTests : XCTestCase
@end

@implementation TideyBrowserAutomationAdoptionTests

- (void)testAdoptsPrivateBrowserEngineWithoutChangingIdentity {
    NSObject *engine = [[NSObject alloc] init];
    TideyEditorTab *tab = [iTermRootTerminalView
        tideyBrowserAutomationTabWithIdentifier:@"private-tab-1"
                                             URL:[NSURL URLWithString:@"https://example.com"]
                                          engine:engine];

    XCTAssertEqualObjects(tab.identifier, @"private-tab-1");
    XCTAssertEqual(tab.browserEngine, engine);
    XCTAssertEqualObjects(tab.path, @"https://example.com");
    XCTAssertEqual(tab.kind, TideyRightPanelTabKindBrowser);
}

@end
