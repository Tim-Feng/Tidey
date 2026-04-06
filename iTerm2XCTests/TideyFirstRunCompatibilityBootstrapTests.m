#import <XCTest/XCTest.h>

#import "ITAddressBookMgr.h"
#import "TideyFirstRunCompatibilityBootstrap.h"

@interface TideyFirstRunCompatibilityBootstrap (Testing)
+ (nullable NSString *)tideyBootstrapSourceForAlreadyDone:(BOOL)done
                             defaultBookmarkUntouched:(BOOL)untouched
                                       importedSource:(NSString *)importedSource;
+ (nullable NSString *)tideyPreferredBootstrapSourceForITerm2:(BOOL)hasITerm2
                                                      ghostty:(BOOL)hasGhostty
                                                  terminalApp:(BOOL)hasTerminalApp
                                                        kitty:(BOOL)hasKitty
                                                   alacritty:(BOOL)hasAlacritty;
+ (NSDictionary *)tideyITerm2ProfileUpdatesForSourceProfile:(NSDictionary *)sourceProfile;
+ (NSDictionary *)tideyGhosttyProfileUpdatesForConfigContents:(NSString *)contents;
+ (NSDictionary *)tideyKittyProfileUpdatesForConfigContents:(NSString *)contents;
+ (NSDictionary *)tideyAlacrittyProfileUpdatesForConfigContents:(NSString *)contents;
@end

@interface TideyFirstRunCompatibilityBootstrapTests : XCTestCase
@end

@implementation TideyFirstRunCompatibilityBootstrapTests

- (void)testBootstrapStateMachineResults {
    XCTAssertNil([TideyFirstRunCompatibilityBootstrap tideyBootstrapSourceForAlreadyDone:YES
                                                                 defaultBookmarkUntouched:YES
                                                                            importedSource:@"iterm2"]);
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyBootstrapSourceForAlreadyDone:NO
                                                                            defaultBookmarkUntouched:NO
                                                                                       importedSource:nil],
                          @"existing-settings");
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyBootstrapSourceForAlreadyDone:NO
                                                                            defaultBookmarkUntouched:YES
                                                                                       importedSource:@"ghostty"],
                          @"ghostty");
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyBootstrapSourceForAlreadyDone:NO
                                                                            defaultBookmarkUntouched:YES
                                                                                       importedSource:nil],
                          @"limited");
}

- (void)testBootstrapSourcePreferenceOrder {
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyPreferredBootstrapSourceForITerm2:YES
                                                                                              ghostty:YES
                                                                                          terminalApp:YES
                                                                                                kitty:YES
                                                                                           alacritty:YES],
                          @"iterm2");
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyPreferredBootstrapSourceForITerm2:NO
                                                                                              ghostty:YES
                                                                                          terminalApp:YES
                                                                                                kitty:YES
                                                                                           alacritty:YES],
                          @"ghostty");
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyPreferredBootstrapSourceForITerm2:NO
                                                                                              ghostty:NO
                                                                                          terminalApp:YES
                                                                                                kitty:YES
                                                                                           alacritty:YES],
                          @"terminal-app");
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyPreferredBootstrapSourceForITerm2:NO
                                                                                              ghostty:NO
                                                                                          terminalApp:NO
                                                                                                kitty:YES
                                                                                           alacritty:YES],
                          @"kitty");
    XCTAssertEqualObjects([TideyFirstRunCompatibilityBootstrap tideyPreferredBootstrapSourceForITerm2:NO
                                                                                              ghostty:NO
                                                                                          terminalApp:NO
                                                                                                kitty:NO
                                                                                           alacritty:YES],
                          @"alacritty");
    XCTAssertNil([TideyFirstRunCompatibilityBootstrap tideyPreferredBootstrapSourceForITerm2:NO
                                                                                      ghostty:NO
                                                                                  terminalApp:NO
                                                                                        kitty:NO
                                                                                   alacritty:NO]);
}

- (void)testITerm2ProfileUpdatesFanOutBaseColorsToVariants {
    NSDictionary *color = @{
        @"Red Component": @0.1,
        @"Green Component": @0.2,
        @"Blue Component": @0.3,
        @"Alpha Component": @1.0,
        @"Color Space": @"sRGB",
    };
    NSDictionary *source = @{
        KEY_NORMAL_FONT: @"Menlo 18",
        KEY_BACKGROUND_COLOR: color,
        KEY_CURSOR_COLOR: color,
    };
    NSDictionary *updates = [TideyFirstRunCompatibilityBootstrap tideyITerm2ProfileUpdatesForSourceProfile:source];
    XCTAssertEqualObjects(updates[KEY_BACKGROUND_COLOR], color);
    XCTAssertEqualObjects(updates[[KEY_BACKGROUND_COLOR stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX]], color);
    XCTAssertEqualObjects(updates[[KEY_BACKGROUND_COLOR stringByAppendingString:COLORS_DARK_MODE_SUFFIX]], color);
    XCTAssertEqualObjects(updates[[KEY_CURSOR_COLOR stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX]], color);
    XCTAssertEqualObjects(updates[[KEY_CURSOR_COLOR stringByAppendingString:COLORS_DARK_MODE_SUFFIX]], color);
}

- (void)testGhosttyConfigImportsFontOnly {
    NSString *contents = @"font-family = Menlo\nfont-size = 14\n";
    NSDictionary *updates = [TideyFirstRunCompatibilityBootstrap tideyGhosttyProfileUpdatesForConfigContents:contents];
    XCTAssertTrue([updates[KEY_NORMAL_FONT] containsString:@"Menlo"]);
    XCTAssertNil(updates[KEY_BACKGROUND_COLOR]);
    XCTAssertNil(updates[[KEY_BACKGROUND_COLOR stringByAppendingString:COLORS_DARK_MODE_SUFFIX]]);
}

- (void)testKittyConfigImportsFontAndColors {
    NSString *contents =
        @"font_family Menlo\n"
        @"font_size 13.0\n"
        @"foreground #dddddd\n"
        @"background #1e1e2e\n"
        @"color3 #aabbcc\n";
    NSDictionary *updates = [TideyFirstRunCompatibilityBootstrap tideyKittyProfileUpdatesForConfigContents:contents];
    NSString *ansi3Key = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 3];
    NSString *ansi3DarkKey = [ansi3Key stringByAppendingString:COLORS_DARK_MODE_SUFFIX];
    XCTAssertTrue([updates[KEY_NORMAL_FONT] containsString:@"Menlo"]);
    XCTAssertNotNil(updates[KEY_BACKGROUND_COLOR]);
    XCTAssertNotNil(updates[ansi3Key]);
    XCTAssertNotNil(updates[ansi3DarkKey]);
}

- (void)testAlacrittyConfigImportsFontAndColors {
    NSString *contents =
        @"[font]\n"
        @"size = 13.0\n"
        @"[font.normal]\n"
        @"family = \"Menlo\"\n"
        @"[colors.primary]\n"
        @"background = \"#1e1e2e\"\n"
        @"foreground = \"#cdd6f4\"\n"
        @"[colors.normal]\n"
        @"black = \"#111111\"\n"
        @"red = \"#222222\"\n"
        @"green = \"#333333\"\n"
        @"yellow = \"#444444\"\n"
        @"blue = \"#555555\"\n"
        @"magenta = \"#666666\"\n"
        @"cyan = \"#777777\"\n"
        @"white = \"#888888\"\n"
        @"[colors.bright]\n"
        @"black = \"#999999\"\n"
        @"red = \"#aaaaaa\"\n"
        @"green = \"#bbbbbb\"\n"
        @"yellow = \"#cccccc\"\n"
        @"blue = \"#dddddd\"\n"
        @"magenta = \"#eeeeee\"\n"
        @"cyan = \"#fafafa\"\n"
        @"white = \"#ffffff\"\n";
    NSDictionary *updates = [TideyFirstRunCompatibilityBootstrap tideyAlacrittyProfileUpdatesForConfigContents:contents];
    NSString *ansi0Key = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 0];
    NSString *ansi15Key = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 15];
    XCTAssertTrue([updates[KEY_NORMAL_FONT] containsString:@"Menlo"]);
    XCTAssertNotNil(updates[KEY_BACKGROUND_COLOR]);
    XCTAssertNotNil(updates[ansi0Key]);
    XCTAssertNotNil(updates[ansi15Key]);
}

@end
