#import "TideyTerminalAppearanceProfileAdapter.h"

#import "ITAddressBookMgr.h"
#import "NSFont+iTerm.h"
#import "ProfileModel.h"
#import "iTermDynamicProfileManager.h"
#import "iTermProfilePreferences.h"

@implementation TideyTerminalAppearanceProfileAdapter

- (Profile *)defaultBookmark {
    return [[ProfileModel sharedInstance] defaultBookmark];
}

- (NSFont *)normalFont {
    Profile *profile = [self defaultBookmark];
    NSFont *font = [iTermProfilePreferences fontForKey:KEY_NORMAL_FONT
                                             inProfile:profile
                                      ligaturesEnabled:YES];
    return font ?: [NSFont userFixedPitchFontOfSize:13] ?: [NSFont fontWithName:@"Menlo" size:13];
}

- (NSColor *)colorForKey:(NSString *)key {
    Profile *profile = [self defaultBookmark];
    NSColor *color = [iTermProfilePreferences colorForKey:key dark:YES profile:profile];
    return [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color ?: [NSColor clearColor];
}

- (NSColor *)ansiColorAtIndex:(NSInteger)index {
    NSString *key = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)index];
    return [self colorForKey:key];
}

- (void)updateNormalFont:(NSFont *)font {
    NSDictionary *updates = @{
        KEY_NORMAL_FONT: font.stringValue,
        KEY_NON_ASCII_FONT: font.stringValue,
        KEY_USE_NONASCII_FONT: @NO,
    };
    [self applyUpdates:updates];
}

- (void)updateColor:(NSColor *)color forKey:(NSString *)key {
    [self applyUpdates:[self expandedColorUpdatesForColor:color key:key]];
}

- (void)updateANSIColor:(NSColor *)color atIndex:(NSInteger)index {
    NSString *key = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)index];
    [self applyUpdates:[self expandedColorUpdatesForColor:color key:key]];
}

- (NSDictionary *)expandedColorUpdatesForColor:(NSColor *)color key:(NSString *)key {
    NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    NSDictionary *encoded = [ITAddressBookMgr encodeColor:srgb];
    if (encoded.count == 0 || key.length == 0) {
        return @{};
    }
    return @{
        key: encoded,
        [key stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX]: encoded,
        [key stringByAppendingString:COLORS_DARK_MODE_SUFFIX]: encoded,
    };
}

- (void)applyUpdates:(NSDictionary *)updates {
    if (updates.count == 0) {
        return;
    }
    ProfileModel *model = [ProfileModel sharedInstance];
    Profile *profile = [self defaultBookmark];
    if (!profile) {
        return;
    }
    [[iTermDynamicProfileManager sharedInstance] performAtomically:^{
        [iTermProfilePreferences setObjectsFromDictionary:updates
                                                inProfile:profile
                                                    model:model];
    }];
}

@end
