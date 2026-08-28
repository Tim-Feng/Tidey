#import <XCTest/XCTest.h>
#import "PTYSession.h"

#import "ITAddressBookMgr.h"
#import "NSColor+iTerm.h"
#import "ProfileModel.h"
#import "iTerm2SharedARC-Swift.h"
#import "iTermColorMap.h"
#import "iTermPasteHelper.h"
#import "iTermProfilePreferences.h"
#import "iTermWarning.h"

typedef NSModalResponse (^WarningBlockType)(NSAlert *alert, NSString *identifier);

@interface FakePasteHelper : iTermPasteHelper
@property(nonatomic, copy) NSString *string;
@property(nonatomic) BOOL slowly;
@property(nonatomic) BOOL escapeShellChars;
@property(nonatomic) iTermTabTransformTags tabTransform;
@property(nonatomic) int spacesPerTab;
@end

@implementation FakePasteHelper

- (void)pasteString:(NSString *)theString
             slowly:(BOOL)slowly
   escapeShellChars:(BOOL)escapeShellChars
           isUpload:(BOOL)isUpload
    allowBracketing:(BOOL)allowBracketing
       tabTransform:(iTermTabTransformTags)tabTransform
       spacesPerTab:(int)spacesPerTab {
    self.string = theString;
    self.slowly = slowly;
    self.escapeShellChars = escapeShellChars;
    self.tabTransform = tabTransform;
    self.spacesPerTab = spacesPerTab;
}

- (void)dealloc {
    [_string release];
    [super dealloc];
}

@end

@interface PTYSessionTest : XCTestCase <iTermWarningHandler>
@end

@interface PTYSession (Internal)
- (void)setPasteHelper:(iTermPasteHelper *)pasteHelper;
@end

@implementation PTYSessionTest {
    PTYSession *_session;
    FakePasteHelper *_fakePasteHelper;
    WarningBlockType _warningBlock;
    NSMutableSet *_warningIdentifiers;
}

- (void)setUp {
    _session = [[PTYSession alloc] initSynthetic:NO];
    _fakePasteHelper = [[[FakePasteHelper alloc] init] autorelease];
    [_session setPasteHelper:_fakePasteHelper];
    _warningIdentifiers = [[NSMutableSet alloc] init];
    [iTermWarning setWarningHandler:self];
}

- (void)tearDown {
    [_session release];
    [_warningIdentifiers release];
}

- (void)testPasteEmptyString {
    [_session pasteString:@"" flags:0];
    XCTAssert(_fakePasteHelper.string == nil);
}

- (void)testBasicPaste {
    NSString *theString = @".";
    [_session pasteString:theString flags:0];
    XCTAssert([_fakePasteHelper.string isEqualToString:theString]);
    XCTAssert(_fakePasteHelper.tabTransform == kTabTransformNone);
    XCTAssert(!_fakePasteHelper.slowly);
    XCTAssert(!_fakePasteHelper.escapeShellChars);
}

- (void)testEscapeShellTabs {
    NSString *theString = @"\t";
    [_session pasteString:theString flags:kPTYSessionPasteWithShellEscapedTabs];
    XCTAssert([_fakePasteHelper.string isEqualToString:theString]);
    XCTAssert(_fakePasteHelper.tabTransform == kTabTransformEscapeWithCtrlV);
    XCTAssert(!_fakePasteHelper.slowly);
    XCTAssert(!_fakePasteHelper.escapeShellChars);
}

- (void)testPasteSlowly {
    NSString *theString = @".";
    [_session pasteString:theString flags:kPTYSessionPasteSlowly];
    XCTAssert([_fakePasteHelper.string isEqualToString:theString]);
    XCTAssert(_fakePasteHelper.tabTransform == kTabTransformNone);
    XCTAssert(_fakePasteHelper.slowly);
    XCTAssert(!_fakePasteHelper.escapeShellChars);
}

- (void)testEscapeSpecialChars {
    NSString *theString = @".";
    [_session pasteString:theString flags:kPTYSessionPasteEscapingSpecialCharacters];
    XCTAssert([_fakePasteHelper.string isEqualToString:theString]);
    XCTAssert(_fakePasteHelper.tabTransform == kTabTransformNone);
    XCTAssert(!_fakePasteHelper.slowly);
    XCTAssert(
           _fakePasteHelper.escapeShellChars);
}

- (void)testEmbeddedTabsConvertToSpaces {
    NSString *theString = @"a\tb";
    _warningBlock = ^NSModalResponse(NSAlert *alert, NSString *identifier) {
        XCTAssert([identifier isEqualToString:@"AboutToPasteTabsWithCancel"]);
        BOOL found = NO;
        for (NSView *subview in alert.accessoryView.subviews) {
            if ([subview isKindOfClass:[NSTextField class]] &&
                [(NSTextField *)subview isEditable]) {
                found = YES;
                NSTextField *textField = (NSTextField *)subview;
                textField.intValue = 8;
                [(id)textField.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                                           object:nil]];
                break;
            }
        }
        XCTAssert(found);
        return NSAlertThirdButtonReturn;
    };
    [_session pasteString:theString flags:0];
    XCTAssert([_warningIdentifiers containsObject:@"AboutToPasteTabsWithCancel"]);

    XCTAssert([_fakePasteHelper.string isEqualToString:theString]);
    XCTAssert(_fakePasteHelper.tabTransform == kTabTransformConvertToSpaces);
    XCTAssert(!_fakePasteHelper.slowly);
    XCTAssert(!_fakePasteHelper.escapeShellChars);
    XCTAssert(_fakePasteHelper.spacesPerTab == 8);
}

- (void)testWarmTerminalPaletteRoundTripsToClassicWithoutModifyingProfile {
    NSString *priorThemeIdentifier = [TideyInterfaceThemeController.shared.currentThemeIdentifier copy];
    @try {
        TideyInterfaceThemeController.shared.currentThemeIdentifier = @"classic";
        NSMutableDictionary *profile = [self factoryProfile];
        NSDictionary *originalProfile = [[profile copy] autorelease];
        _session.profile = profile;
        [_session setPreferencesFromAddressBookEntry:profile];
        NSColor *classicBackground = [_session.screen.colorMap colorForKey:kColorMapBackground];
        NSColor *classicForeground = [_session.screen.colorMap colorForKey:kColorMapForeground];
        NSColor *classicBlue = [_session.screen.colorMap colorForKey:kColorMap8bitBase + 4];

        TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";

        [self assertColor:[_session.screen.colorMap colorForKey:kColorMapBackground] hex:0x151413];
        [self assertColor:[_session.screen.colorMap colorForKey:kColorMapForeground] hex:0xEAE4D4];
        [self assertColor:[_session.screen.colorMap colorForKey:kColorMap8bitBase + 4] hex:0x7E9CB8];
        XCTAssertEqualObjects(profile, originalProfile);

        TideyInterfaceThemeController.shared.currentThemeIdentifier = @"classic";

        [self assertColor:[_session.screen.colorMap colorForKey:kColorMapBackground]
             equalsColor:classicBackground];
        [self assertColor:[_session.screen.colorMap colorForKey:kColorMapForeground]
             equalsColor:classicForeground];
        [self assertColor:[_session.screen.colorMap colorForKey:kColorMap8bitBase + 4]
             equalsColor:classicBlue];
        XCTAssertEqualObjects(profile, originalProfile);
    } @finally {
        TideyInterfaceThemeController.shared.currentThemeIdentifier = priorThemeIdentifier;
        [priorThemeIdentifier release];
    }
}

- (void)testWarmTerminalPaletteDoesNotChangeCustomProfile {
    NSString *priorThemeIdentifier = [TideyInterfaceThemeController.shared.currentThemeIdentifier copy];
    @try {
        TideyInterfaceThemeController.shared.currentThemeIdentifier = @"classic";
        NSMutableDictionary *profile = [self factoryProfile];
        NSDictionary *customBackgroundValue = [[NSColor colorWithSRGBRed:0.01
                                                                    green:0.02
                                                                     blue:0.03
                                                                    alpha:1] dictionaryValue];
        profile[KEY_BACKGROUND_COLOR] = customBackgroundValue;
        profile[iTermAmendedColorKey2(KEY_BACKGROUND_COLOR, YES, NO)] = customBackgroundValue;
        profile[iTermAmendedColorKey2(KEY_BACKGROUND_COLOR, YES, YES)] = customBackgroundValue;
        NSDictionary *originalProfile = [[profile copy] autorelease];
        _session.profile = profile;
        [_session setPreferencesFromAddressBookEntry:profile];
        NSColor *customBackground = [_session.screen.colorMap colorForKey:kColorMapBackground];
        NSColor *factoryRed = [_session.screen.colorMap colorForKey:kColorMap8bitBase + 1];

        TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";

        [self assertColor:[_session.screen.colorMap colorForKey:kColorMapBackground]
             equalsColor:customBackground];
        [self assertColor:[_session.screen.colorMap colorForKey:kColorMap8bitBase + 1]
             equalsColor:factoryRed];
        XCTAssertEqualObjects(profile, originalProfile);
    } @finally {
        TideyInterfaceThemeController.shared.currentThemeIdentifier = priorThemeIdentifier;
        [priorThemeIdentifier release];
    }
}

- (NSMutableDictionary *)factoryProfile {
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    [ITAddressBookMgr setDefaultsInBookmark:profile];
    profile[KEY_GUID] = [ProfileModel freshGuid];
    return profile;
}

- (void)assertColor:(NSColor *)actual hex:(NSInteger)hex {
    NSColor *expected = [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0
                                           green:((hex >> 8) & 0xff) / 255.0
                                            blue:(hex & 0xff) / 255.0
                                           alpha:1];
    [self assertColor:actual equalsColor:expected];
}

- (void)assertColor:(NSColor *)actual equalsColor:(NSColor *)expected {
    actual = [actual colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    expected = [expected colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertNotNil(actual);
    XCTAssertNotNil(expected);
    XCTAssertEqualWithAccuracy(actual.redComponent, expected.redComponent, 0.001);
    XCTAssertEqualWithAccuracy(actual.greenComponent, expected.greenComponent, 0.001);
    XCTAssertEqualWithAccuracy(actual.blueComponent, expected.blueComponent, 0.001);
    XCTAssertEqualWithAccuracy(actual.alphaComponent, expected.alphaComponent, 0.001);
}

#pragma mark - iTermWarningHandler

- (NSModalResponse)warningWouldShowAlert:(NSAlert *)alert identifier:(NSString *)identifier {
    [_warningIdentifiers addObject:identifier];
    return _warningBlock(alert, identifier);
}

@end
