//
//  TideyRightPanelTabGroupingTests.m
//  iTerm2XCTests
//

#import <XCTest/XCTest.h>
#import "iTermRootTerminalView.h"

typedef NS_ENUM(NSInteger, TideyRightPanelTabKind) {
    TideyRightPanelTabKindEditor = 0,
    TideyRightPanelTabKindBrowser = 1,
};

@interface TideyEditorTab : NSObject
@property(nonatomic) TideyRightPanelTabKind kind;
@property(nonatomic, copy) NSString *displayName;
+ (instancetype)tabWithPath:(NSString *)path
                displayName:(NSString *)displayName
                   language:(NSString *)language
                    content:(NSString *)content;
@end

@interface iTermRootTerminalView (TideyRightPanelTabGroupingTests)
+ (NSArray<NSArray<TideyEditorTab *> *> *)tideyRightPanelTabsGroupedByKind:(NSArray<TideyEditorTab *> *)tabs;
@end

@interface TideyRightPanelTabGroupingTests : XCTestCase
@end

@implementation TideyRightPanelTabGroupingTests

- (TideyEditorTab *)tabNamed:(NSString *)name kind:(TideyRightPanelTabKind)kind {
    TideyEditorTab *tab = [TideyEditorTab tabWithPath:[@"/tmp" stringByAppendingPathComponent:name]
                                          displayName:name
                                             language:@"plaintext"
                                              content:@""];
    tab.kind = kind;
    return tab;
}

- (NSArray<NSString *> *)namesForTabs:(NSArray<TideyEditorTab *> *)tabs {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (TideyEditorTab *tab in tabs) {
        [names addObject:tab.displayName ?: @""];
    }
    return names;
}

- (void)testEditorTabsDefaultToEditorKind {
    TideyEditorTab *tab = [TideyEditorTab tabWithPath:@"/tmp/a"
                                          displayName:@"Editor"
                                             language:@"plaintext"
                                              content:@""];
    XCTAssertEqual(tab.kind, TideyRightPanelTabKindEditor);
}

- (void)testMixedRightPanelTabsGroupByKind {
    NSArray<NSArray<TideyEditorTab *> *> *groups =
        [iTermRootTerminalView tideyRightPanelTabsGroupedByKind:@[
            [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor],
            [self tabNamed:@"Browser A" kind:TideyRightPanelTabKindBrowser],
            [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor],
            [self tabNamed:@"Browser B" kind:TideyRightPanelTabKindBrowser],
        ]];

    XCTAssertEqual(groups.count, 2U);
    XCTAssertEqualObjects([self namesForTabs:groups[0]], (@[ @"Editor A", @"Editor B" ]));
    XCTAssertEqualObjects([self namesForTabs:groups[1]], (@[ @"Browser A", @"Browser B" ]));
}

- (void)testEditorTabsStayInSingleGroupInOriginalOrder {
    NSArray<NSArray<TideyEditorTab *> *> *groups =
        [iTermRootTerminalView tideyRightPanelTabsGroupedByKind:@[
            [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor],
            [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor],
            [self tabNamed:@"Editor C" kind:TideyRightPanelTabKindEditor],
        ]];

    XCTAssertEqual(groups.count, 1U);
    XCTAssertEqualObjects([self namesForTabs:groups.firstObject],
                          (@[ @"Editor B", @"Editor A", @"Editor C" ]));
}

@end
