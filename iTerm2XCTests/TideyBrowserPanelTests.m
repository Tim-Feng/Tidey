//
//  TideyBrowserPanelTests.m
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
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *path;
+ (instancetype)tabWithPath:(NSString *)path
                displayName:(NSString *)displayName
                   language:(NSString *)language
                    content:(NSString *)content;
+ (instancetype)browserTabWithURL:(NSURL *)url;
@end

@interface iTermRootTerminalView (TideyBrowserPanelTests)
+ (NSString *)tideyNormalizedBrowserURLString:(NSString *)input;
+ (NSString *)tideyBrowserHomepageURLString;
+ (void)tideySetBrowserHomepageURLString:(NSString *)urlString;
+ (NSString *)tideyBrowserDisplayNameForURL:(NSURL *)url pageTitle:(NSString *)pageTitle;
+ (NSInteger)tideyIndexOfExistingBrowserTabForURL:(NSString *)urlString
                                           inTabs:(NSArray<TideyEditorTab *> *)tabs;
@end

@interface TideyBrowserPanelTests : XCTestCase
@end

@implementation TideyBrowserPanelTests

#pragma mark - URL Normalization

- (void)testNormalizedBrowserURLStringAddsHTTPSForBareHost {
    NSString *result = [iTermRootTerminalView tideyNormalizedBrowserURLString:@"google.com"];
    XCTAssertEqualObjects(result, @"https://google.com");
}

- (void)testNormalizedBrowserURLStringPreservesHTTPS {
    NSString *result = [iTermRootTerminalView tideyNormalizedBrowserURLString:@"https://example.com/path"];
    XCTAssertEqualObjects(result, @"https://example.com/path");
}

- (void)testNormalizedBrowserURLStringPreservesHTTP {
    NSString *result = [iTermRootTerminalView tideyNormalizedBrowserURLString:@"http://localhost:3000"];
    XCTAssertEqualObjects(result, @"http://localhost:3000");
}

- (void)testNormalizedBrowserURLStringReturnsNilForEmpty {
    XCTAssertNil([iTermRootTerminalView tideyNormalizedBrowserURLString:@""]);
    XCTAssertNil([iTermRootTerminalView tideyNormalizedBrowserURLString:@"  "]);
    XCTAssertNil([iTermRootTerminalView tideyNormalizedBrowserURLString:nil]);
}

- (void)testBrowserHomepageDefaultsToTideySite {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *original = [defaults stringForKey:@"TideyBrowserHomepageURL"];
    [defaults removeObjectForKey:@"TideyBrowserHomepageURL"];
    XCTAssertEqualObjects([iTermRootTerminalView tideyBrowserHomepageURLString], @"https://github.com/Tim-Feng/Tidey");
    if (original.length > 0) {
        [defaults setObject:original forKey:@"TideyBrowserHomepageURL"];
    }
}

- (void)testBrowserHomepageSetterNormalizesBareHost {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *original = [defaults stringForKey:@"TideyBrowserHomepageURL"];
    [iTermRootTerminalView tideySetBrowserHomepageURLString:@"example.com/start"];
    XCTAssertEqualObjects([iTermRootTerminalView tideyBrowserHomepageURLString], @"https://example.com/start");
    if (original.length > 0) {
        [defaults setObject:original forKey:@"TideyBrowserHomepageURL"];
    } else {
        [defaults removeObjectForKey:@"TideyBrowserHomepageURL"];
    }
}

- (void)testBrowserHomepageSetterResetsInvalidInput {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *original = [defaults stringForKey:@"TideyBrowserHomepageURL"];
    [iTermRootTerminalView tideySetBrowserHomepageURLString:@"example.com/start"];
    [iTermRootTerminalView tideySetBrowserHomepageURLString:@" "];
    XCTAssertEqualObjects([iTermRootTerminalView tideyBrowserHomepageURLString], @"https://github.com/Tim-Feng/Tidey");
    if (original.length > 0) {
        [defaults setObject:original forKey:@"TideyBrowserHomepageURL"];
    } else {
        [defaults removeObjectForKey:@"TideyBrowserHomepageURL"];
    }
}

#pragma mark - Browser Tab Creation

- (void)testBrowserTabCreatedWithCorrectKindAndURL {
    NSURL *url = [NSURL URLWithString:@"https://github.com/Tim-Feng/Tidey"];
    TideyEditorTab *tab = [TideyEditorTab browserTabWithURL:url];

    XCTAssertEqual(tab.kind, TideyRightPanelTabKindBrowser);
    XCTAssertEqualObjects(tab.path, @"https://github.com/Tim-Feng/Tidey");
    XCTAssertGreaterThan(tab.identifier.length, 0U);
}

- (void)testBrowserTabDisplayNameUsesURLHost {
    NSURL *url = [NSURL URLWithString:@"https://docs.anthropic.com/en/docs"];
    TideyEditorTab *tab = [TideyEditorTab browserTabWithURL:url];

    XCTAssertEqualObjects(tab.displayName, @"docs.anthropic.com");
}

#pragma mark - Display Name

- (void)testBrowserDisplayNamePrefersPageTitleOverHost {
    NSURL *url = [NSURL URLWithString:@"https://github.com"];
    NSString *name = [iTermRootTerminalView tideyBrowserDisplayNameForURL:url pageTitle:@"GitHub"];
    XCTAssertEqualObjects(name, @"GitHub");
}

- (void)testBrowserDisplayNameFallsBackToHost {
    NSURL *url = [NSURL URLWithString:@"https://example.com/page"];
    NSString *name = [iTermRootTerminalView tideyBrowserDisplayNameForURL:url pageTitle:nil];
    XCTAssertEqualObjects(name, @"example.com");
}

- (void)testBrowserDisplayNameFallsBackToFullURL {
    NSURL *url = [NSURL URLWithString:@"file:///tmp/test.html"];
    NSString *name = [iTermRootTerminalView tideyBrowserDisplayNameForURL:url pageTitle:nil];
    XCTAssertEqualObjects(name, @"file:///tmp/test.html");
}

#pragma mark - Existing Tab Lookup

- (void)testBrowserOpenResultSelectsExistingMatchingBrowserTab {
    TideyEditorTab *editorTab = [TideyEditorTab tabWithPath:@"/tmp/foo.txt"
                                                displayName:@"foo.txt"
                                                   language:@"plaintext"
                                                    content:@""];
    TideyEditorTab *browserTab = [TideyEditorTab browserTabWithURL:[NSURL URLWithString:@"https://github.com"]];

    NSArray *tabs = @[ editorTab, browserTab ];
    NSInteger index = [iTermRootTerminalView tideyIndexOfExistingBrowserTabForURL:@"https://github.com"
                                                                           inTabs:tabs];
    XCTAssertEqual(index, 1);
}

- (void)testBrowserOpenResultCreatesNewBrowserTabWithHostDisplayName {
    TideyEditorTab *editorTab = [TideyEditorTab tabWithPath:@"/tmp/foo.txt"
                                                displayName:@"foo.txt"
                                                   language:@"plaintext"
                                                    content:@""];
    NSArray *tabs = @[ editorTab ];
    NSInteger index = [iTermRootTerminalView tideyIndexOfExistingBrowserTabForURL:@"https://example.com"
                                                                           inTabs:tabs];
    XCTAssertEqual(index, NSNotFound);
}

- (void)testBrowserMetadataPrefersPageTitleOverHost {
    NSURL *url = [NSURL URLWithString:@"https://anthropic.com"];
    NSString *before = [iTermRootTerminalView tideyBrowserDisplayNameForURL:url pageTitle:nil];
    XCTAssertEqualObjects(before, @"anthropic.com");

    NSString *after = [iTermRootTerminalView tideyBrowserDisplayNameForURL:url pageTitle:@"Anthropic \\ AI Safety"];
    XCTAssertEqualObjects(after, @"Anthropic \\ AI Safety");
}

@end
