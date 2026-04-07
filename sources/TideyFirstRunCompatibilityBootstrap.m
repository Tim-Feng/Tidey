#import "TideyFirstRunCompatibilityBootstrap.h"

#import "ITAddressBookMgr.h"
#import "NSFont+iTerm.h"
#import "ProfileModel.h"
#import "iTermColorPresets.h"
#import "iTermUserDefaults.h"

static NSString *const kTideyFirstRunBootstrapDone = @"TideyFirstRunBootstrapDone";
static NSString *const kTideyFirstRunBootstrapSource = @"TideyFirstRunBootstrapSource";

@implementation TideyFirstRunCompatibilityBootstrap


+ (nullable NSString *)tideyBootstrapSourceForAlreadyDone:(BOOL)done
                             defaultBookmarkUntouched:(BOOL)untouched
                                        importedSource:(NSString *)importedSource {
    if (done) {
        return nil;
    }
    if (!untouched) {
        return @"existing-settings";
    }
    return importedSource ?: @"limited";
}

+ (nullable NSString *)tideyPreferredBootstrapSourceForITerm2:(BOOL)hasITerm2
                                                      ghostty:(BOOL)hasGhostty
                                                  terminalApp:(BOOL)hasTerminalApp
                                                        kitty:(BOOL)hasKitty
                                                     alacritty:(BOOL)hasAlacritty {
    if (hasITerm2) {
        return @"iterm2";
    }
    if (hasGhostty) {
        return @"ghostty";
    }
    if (hasTerminalApp) {
        return @"terminal-app";
    }
    if (hasKitty) {
        return @"kitty";
    }
    if (hasAlacritty) {
        return @"alacritty";
    }
    return nil;
}

+ (NSDictionary *)tideyITerm2ProfileUpdatesForSourceProfile:(NSDictionary *)sourceProfile {
    return [[self sharedInstance] iTerm2ProfileUpdatesForSourceProfile:sourceProfile];
}

+ (NSDictionary *)tideyGhosttyProfileUpdatesForConfigContents:(NSString *)contents {
    return [[self sharedInstance] ghosttyProfileUpdatesForConfigContents:contents];
}

+ (NSDictionary *)tideyKittyProfileUpdatesForConfigContents:(NSString *)contents {
    return [[self sharedInstance] kittyProfileUpdatesForConfigContents:contents];
}

+ (NSDictionary *)tideyAlacrittyProfileUpdatesForConfigContents:(NSString *)contents {
    return [[self sharedInstance] alacrittyProfileUpdatesForConfigContents:contents];
}

+ (NSDictionary *)tideyProfileUpdatesForArchivedFont:(NSFont *)font {
    if (!font) {
        return @{};
    }
    NSData *data = nil;
    @try {
        data = [NSKeyedArchiver archivedDataWithRootObject:font];
    } @catch (NSException *exception) {
        data = nil;
    }
    return [[[self sharedInstance] profileUpdatesForArchivedFontData:data] copy] ?: @{};
}

+ (instancetype)sharedInstance {
    static TideyFirstRunCompatibilityBootstrap *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

+ (void)performIfNeeded {
    [[self sharedInstance] performIfNeeded];
}

- (void)performIfNeeded {
    if ([[iTermUserDefaults userDefaults] boolForKey:kTideyFirstRunBootstrapDone]) {
        return;
    }
    if (![self defaultBookmarkLooksUntouched]) {
        [self finishWithSource:@"existing-settings"];
        return;
    }
    NSString *source = [self importFromKnownTerminalApps];
    if (source) {
        [self finishWithSource:source];
        return;
    }
    [self applyCompatibilityDarkPreset];
    [self finishWithSource:@"limited"];
}

- (NSArray<NSString *> *)terminalBootstrapKeys {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *array = [NSMutableArray arrayWithArray:@[
            KEY_NORMAL_FONT,
            KEY_NON_ASCII_FONT,
            KEY_USE_NONASCII_FONT,
            KEY_POWERLINE,
            KEY_USE_SEPARATE_COLORS_FOR_LIGHT_AND_DARK_MODE,
            KEY_FOREGROUND_COLOR,
            KEY_BACKGROUND_COLOR,
            KEY_BOLD_COLOR,
            KEY_CURSOR_COLOR,
            KEY_CURSOR_TEXT_COLOR,
            KEY_SELECTION_COLOR,
            KEY_SELECTED_TEXT_COLOR,
        ]];
        NSArray<NSString *> *colorKeys = @[
            KEY_FOREGROUND_COLOR,
            KEY_BACKGROUND_COLOR,
            KEY_BOLD_COLOR,
            KEY_CURSOR_COLOR,
            KEY_CURSOR_TEXT_COLOR,
            KEY_SELECTION_COLOR,
            KEY_SELECTED_TEXT_COLOR,
        ];
        for (NSString *baseKey in colorKeys) {
            [array addObject:[baseKey stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX]];
            [array addObject:[baseKey stringByAppendingString:COLORS_DARK_MODE_SUFFIX]];
        }
        for (NSInteger i = 0; i < 16; i++) {
            NSString *baseKey = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)i];
            [array addObject:baseKey];
            [array addObject:[baseKey stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX]];
            [array addObject:[baseKey stringByAppendingString:COLORS_DARK_MODE_SUFFIX]];
        }
        keys = [array copy];
    });
    return keys;
}

- (NSMutableDictionary *)bundledDefaultBookmark {
    NSMutableDictionary *bookmark = [NSMutableDictionary dictionary];
    [ITAddressBookMgr setDefaultsInBookmark:bookmark];
    return bookmark;
}

- (BOOL)defaultBookmarkLooksUntouched {
    Profile *defaultBookmark = [[ProfileModel sharedInstance] defaultBookmark];
    if (!defaultBookmark) {
        return YES;
    }
    NSDictionary *baseline = [self bundledDefaultBookmark];
    for (NSString *key in [self terminalBootstrapKeys]) {
        id currentValue = defaultBookmark[key];
        id baselineValue = baseline[key];
        if (currentValue == baselineValue) {
            continue;
        }
        if (currentValue == nil || baselineValue == nil) {
            return NO;
        }
        if (![currentValue isEqual:baselineValue]) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)iTerm2PreferencesPath {
    return [@"~/Library/Preferences/com.googlecode.iterm2.plist" stringByExpandingTildeInPath];
}

- (nullable NSDictionary *)iTerm2DefaultProfileDictionary {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[self iTerm2PreferencesPath]];
    NSArray *bookmarks = [prefs[KEY_NEW_BOOKMARKS] isKindOfClass:[NSArray class]] ? prefs[KEY_NEW_BOOKMARKS] : nil;
    if (bookmarks.count == 0) {
        return nil;
    }
    NSString *defaultGuid = [prefs[KEY_DEFAULT_GUID] isKindOfClass:[NSString class]] ? prefs[KEY_DEFAULT_GUID] : nil;
    NSDictionary *fallback = nil;
    for (NSDictionary *bookmark in bookmarks) {
        if (![bookmark isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        if (!fallback && [bookmark[KEY_DEFAULT_BOOKMARK] isKindOfClass:[NSString class]] &&
            [bookmark[KEY_DEFAULT_BOOKMARK] isEqualToString:@"Yes"]) {
            fallback = bookmark;
        }
        if (defaultGuid.length > 0 &&
            [bookmark[KEY_GUID] isKindOfClass:[NSString class]] &&
            [bookmark[KEY_GUID] isEqualToString:defaultGuid]) {
            return bookmark;
        }
    }
    return fallback;
}

- (BOOL)importITerm2DefaultProfileIfPossible {
    NSDictionary *sourceProfile = [self iTerm2DefaultProfileDictionary];
    if (!sourceProfile) {
        return NO;
    }
    NSDictionary *updates = [self iTerm2ProfileUpdatesForSourceProfile:sourceProfile];
    if (updates.count == 0) {
        return NO;
    }
    [self applyProfileUpdates:updates];
    return YES;
}

- (NSDictionary *)iTerm2ProfileUpdatesForSourceProfile:(NSDictionary *)sourceProfile {
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];
    for (NSString *key in [self terminalBootstrapKeys]) {
        id value = sourceProfile[key];
        if (value) {
            updates[key] = value;
        }
    }
    NSMutableArray<NSString *> *baseColorKeys = [NSMutableArray arrayWithArray:@[
        KEY_FOREGROUND_COLOR,
        KEY_BACKGROUND_COLOR,
        KEY_BOLD_COLOR,
        KEY_CURSOR_COLOR,
        KEY_CURSOR_TEXT_COLOR,
        KEY_SELECTION_COLOR,
        KEY_SELECTED_TEXT_COLOR,
    ]];
    for (NSInteger i = 0; i < 16; i++) {
        [baseColorKeys addObject:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)i]];
    }
    for (NSString *baseKey in baseColorKeys) {
        id value = sourceProfile[baseKey];
        NSDictionary *colorDict = [value isKindOfClass:[NSDictionary class]] ? value : nil;
        if (!colorDict) {
            continue;
        }
        NSString *lightKey = [baseKey stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX];
        NSString *darkKey = [baseKey stringByAppendingString:COLORS_DARK_MODE_SUFFIX];
        if (!updates[lightKey]) {
            updates[lightKey] = colorDict;
        }
        if (!updates[darkKey]) {
            updates[darkKey] = colorDict;
        }
    }
    return updates;
}

- (nullable NSString *)importFromKnownTerminalApps {
    if ([self importITerm2DefaultProfileIfPossible]) {
        return @"iterm2";
    }
    if ([self importGhosttyConfigIfPossible]) {
        return @"ghostty";
    }
    if ([self importTerminalAppProfileIfPossible]) {
        return @"terminal-app";
    }
    if ([self importKittyConfigIfPossible]) {
        return @"kitty";
    }
    if ([self importAlacrittyConfigIfPossible]) {
        return @"alacritty";
    }
    return nil;
}

- (void)applyCompatibilityDarkPreset {
    // Tidey 靜水深流（Still Water Runs Deep）和色 palette
    // 色碼 source of truth: TideyPalette.h
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];

    // Font: Menlo-Regular 14pt (PostScript name required by iTerm2 font parser)
    NSDictionary *fontUpdates = [self profileUpdatesForFontName:@"Menlo-Regular" size:14];
    if (fontUpdates) {
        [updates addEntriesFromDictionary:fontUpdates];
    }

    // Core colors
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#0B1013" targetKey:KEY_BACKGROUND_COLOR]];   // 黒橡
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#EAF4FC" targetKey:KEY_FOREGROUND_COLOR]];   // 月白
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#58B2DC" targetKey:KEY_CURSOR_COLOR]];       // 空
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#274A78" targetKey:KEY_SELECTION_COLOR]];     // 青藍

    // ANSI Normal 0-7
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#181B26" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 0]]];   // 勝色
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#CB4042" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 1]]];   // 紅緋
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#839B5C" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 2]]];   // 松葉
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#CAAD5F" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 3]]];   // 芥子
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#5B7E91" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 4]]];   // 花
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#8B81C3" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 5]]];   // 紫苑
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#5C9291" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 6]]];   // 錆浅葱
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#91989F" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 7]]];   // 銀鼠

    // ANSI Bright 8-15
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#656765" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 8]]];   // 涅
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#E87A90" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 9]]];   // 薄紅
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#68BE8D" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 10]]];  // 若竹
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#FFB11B" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 11]]];  // 蒲公英
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#58B2DC" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 12]]];  // 空
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#E7609E" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 13]]];  // 牡丹
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#70C5BA" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 14]]];  // 水浅葱
    [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:@"#EAF4FC" targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, 15]]];  // 月白

    [self applyProfileUpdates:updates];
}

- (nullable NSFont *)installedFontWithName:(NSString *)fontName size:(CGFloat)size {
    if (fontName.length == 0 || size <= 0) {
        return nil;
    }
    NSFont *font = [NSFont fontWithName:fontName size:size];
    if (font) {
        return font;
    }
    NSFontDescriptor *descriptor = [NSFontDescriptor fontDescriptorWithFontAttributes:@{
        NSFontFamilyAttribute: fontName,
        NSFontSizeAttribute: @(size),
    }];
    font = [NSFont fontWithDescriptor:descriptor size:size];
    if (font) {
        return font;
    }
    return [[NSFontManager sharedFontManager] fontWithFamily:fontName
                                                     traits:0
                                                     weight:5
                                                       size:size];
}

- (nullable NSDictionary *)profileUpdatesForFontName:(NSString *)fontName size:(CGFloat)size {
    NSFont *font = [self installedFontWithName:fontName size:size];
    if (!font) {
        return nil;
    }
    return @{
        KEY_NORMAL_FONT: font.stringValue,
        KEY_NON_ASCII_FONT: font.stringValue,
        KEY_USE_NONASCII_FONT: @NO,
        KEY_POWERLINE: @YES,
    };
}

- (nullable id)decodedArchivedObject:(NSData *)data {
    id object = nil;
    @try {
        if (@available(macOS 10.13, *)) {
            NSSet *classes = [NSSet setWithArray:@[
                [NSFont class],
                [NSColor class],
                [NSDictionary class],
                [NSArray class],
                [NSString class],
                [NSNumber class],
            ]];
            object = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:nil];
        }
    } @catch (NSException *exception) {
        object = nil;
    }
    return object;
}

- (nullable NSDictionary *)profileUpdatesForArchivedFontData:(id)value {
    id object = [self decodedArchivedObject:value];
    if (![object isKindOfClass:[NSFont class]]) {
        return nil;
    }
    NSFont *font = object;
    if ([font.fontName hasPrefix:@"."]) {
        return nil;
    }
    if (![self installedFontWithName:font.fontName size:font.pointSize]) {
        return nil;
    }
    return @{
        KEY_NORMAL_FONT: font.stringValue,
        KEY_NON_ASCII_FONT: font.stringValue,
        KEY_USE_NONASCII_FONT: @NO,
    };
}

- (NSDictionary *)expandedColorUpdatesForEncodedColor:(NSDictionary *)encodedColor targetKey:(NSString *)targetKey {
    if (encodedColor.count == 0 || targetKey.length == 0) {
        return @{};
    }
    return @{
        targetKey: encodedColor,
        [targetKey stringByAppendingString:COLORS_LIGHT_MODE_SUFFIX]: encodedColor,
        [targetKey stringByAppendingString:COLORS_DARK_MODE_SUFFIX]: encodedColor,
    };
}

- (nullable NSDictionary *)profileColorDictionaryForArchivedColorData:(id)value targetKey:(NSString *)targetKey {
    id object = [self decodedArchivedObject:value];
    if (![object isKindOfClass:[NSColor class]]) {
        return nil;
    }
    NSColor *color = [object colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: object;
    return [self expandedColorUpdatesForEncodedColor:[ITAddressBookMgr encodeColor:color] targetKey:targetKey];
}

- (nullable NSColor *)colorFromHexString:(NSString *)hexString {
    NSString *trimmed = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([trimmed hasPrefix:@"#"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    if (trimmed.length != 6 && trimmed.length != 8) {
        return nil;
    }
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:trimmed] scanHexInt:&value]) {
        return nil;
    }
    CGFloat alpha = 1;
    if (trimmed.length == 8) {
        alpha = ((value >> 24) & 0xFF) / 255.0;
        value &= 0xFFFFFF;
    }
    CGFloat red = ((value >> 16) & 0xFF) / 255.0;
    CGFloat green = ((value >> 8) & 0xFF) / 255.0;
    CGFloat blue = (value & 0xFF) / 255.0;
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

- (NSDictionary *)profileColorUpdateForHexString:(NSString *)hexString targetKey:(NSString *)targetKey {
    NSColor *color = [self colorFromHexString:hexString];
    if (!color) {
        return @{};
    }
    return [self expandedColorUpdatesForEncodedColor:[ITAddressBookMgr encodeColor:color] targetKey:targetKey];
}

- (BOOL)applyImportedProfileUpdates:(NSDictionary *)updates {
    if (updates.count == 0) {
        return NO;
    }
    [self applyProfileUpdates:updates];
    return YES;
}

- (NSDictionary<NSString *, NSString *> *)flatKeyValueConfigAtPath:(NSString *)path separator:(NSString *)separator {
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [self flatKeyValueConfigFromContents:contents separator:separator];
}

- (NSDictionary<NSString *, NSString *> *)flatKeyValueConfigFromContents:(NSString *)contents separator:(NSString *)separator {
    if (contents.length == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }
        NSRange separatorRange = [trimmed rangeOfString:separator];
        if (separatorRange.location == NSNotFound) {
            continue;
        }
        NSString *key = [[trimmed substringToIndex:separatorRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = [[trimmed substringFromIndex:NSMaxRange(separatorRange)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSRange inlineCommentRange = [value rangeOfString:@" #"];
        if (inlineCommentRange.location != NSNotFound) {
            value = [[value substringToIndex:inlineCommentRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""] && value.length >= 2) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }
        if (key.length > 0 && value.length > 0) {
            result[key] = value;
        }
    }
    return result;
}

- (BOOL)importGhosttyConfigIfPossible {
    NSString *path = [@"~/.config/ghostty/config" stringByExpandingTildeInPath];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [self applyImportedProfileUpdates:[self ghosttyProfileUpdatesForConfigContents:contents]];
}

- (NSDictionary *)ghosttyProfileUpdatesForConfigContents:(NSString *)contents {
    NSDictionary<NSString *, NSString *> *config = [self flatKeyValueConfigFromContents:contents separator:@"="];
    return [self profileUpdatesForFontName:config[@"font-family"]
                                      size:config[@"font-size"].doubleValue] ?: @{};
}

- (BOOL)importKittyConfigIfPossible {
    NSString *path = [@"~/.config/kitty/kitty.conf" stringByExpandingTildeInPath];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [self applyImportedProfileUpdates:[self kittyProfileUpdatesForConfigContents:contents]];
}

- (NSDictionary *)kittyProfileUpdatesForConfigContents:(NSString *)contents {
    NSDictionary<NSString *, NSString *> *config = [self flatKeyValueConfigFromContents:contents separator:@" "];
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];
    NSDictionary *fontUpdates = [self profileUpdatesForFontName:config[@"font_family"]
                                                           size:config[@"font_size"].doubleValue];
    if (fontUpdates) {
        [updates addEntriesFromDictionary:fontUpdates];
    }
    NSDictionary<NSString *, NSString *> *colorKeyMap = @{
        @"foreground": KEY_FOREGROUND_COLOR,
        @"background": KEY_BACKGROUND_COLOR,
        @"selection_background": KEY_SELECTION_COLOR,
        @"selection_foreground": KEY_SELECTED_TEXT_COLOR,
        @"cursor": KEY_CURSOR_COLOR,
        @"cursor_text_color": KEY_CURSOR_TEXT_COLOR,
    };
    [colorKeyMap enumerateKeysAndObjectsUsingBlock:^(NSString *sourceKey, NSString *targetKey, BOOL *stop) {
        [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:config[sourceKey] targetKey:targetKey]];
    }];
    for (NSInteger i = 0; i < 16; i++) {
        NSString *sourceKey = [NSString stringWithFormat:@"color%ld", (long)i];
        NSString *targetKey = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)i];
        [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:config[sourceKey] targetKey:targetKey]];
    }
    return updates;
}

- (BOOL)importAlacrittyConfigIfPossible {
    NSString *path = [@"~/.config/alacritty/alacritty.toml" stringByExpandingTildeInPath];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [self applyImportedProfileUpdates:[self alacrittyProfileUpdatesForConfigContents:contents]];
}

- (NSDictionary *)alacrittyProfileUpdatesForConfigContents:(NSString *)contents {
    if (contents.length == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    NSString *section = @"";
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }
        if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
            section = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
            continue;
        }
        NSRange range = [trimmed rangeOfString:@"="];
        if (range.location == NSNotFound) {
            continue;
        }
        NSString *key = [[trimmed substringToIndex:range.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = [[trimmed substringFromIndex:NSMaxRange(range)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""] && value.length >= 2) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }
        if (key.length > 0 && value.length > 0) {
            values[[NSString stringWithFormat:@"%@.%@", section, key]] = value;
        }
    }
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];
    NSDictionary *fontUpdates = [self profileUpdatesForFontName:values[@"font.normal.family"]
                                                           size:values[@"font.size"].doubleValue];
    if (fontUpdates) {
        [updates addEntriesFromDictionary:fontUpdates];
    }
    NSDictionary<NSString *, NSString *> *colorKeyMap = @{
        @"colors.primary.foreground": KEY_FOREGROUND_COLOR,
        @"colors.primary.background": KEY_BACKGROUND_COLOR,
    };
    [colorKeyMap enumerateKeysAndObjectsUsingBlock:^(NSString *sourceKey, NSString *targetKey, BOOL *stop) {
        [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:values[sourceKey] targetKey:targetKey]];
    }];
    NSArray<NSString *> *ansiNames = @[ @"black", @"red", @"green", @"yellow", @"blue", @"magenta", @"cyan", @"white" ];
    for (NSInteger i = 0; i < ansiNames.count; i++) {
        NSString *targetKey = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)i];
        [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:values[[NSString stringWithFormat:@"colors.normal.%@", ansiNames[i]]] targetKey:targetKey]];
        targetKey = [NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)(i + 8)];
        [updates addEntriesFromDictionary:[self profileColorUpdateForHexString:values[[NSString stringWithFormat:@"colors.bright.%@", ansiNames[i]]] targetKey:targetKey]];
    }
    return updates;
}

- (BOOL)importTerminalAppProfileIfPossible {
    NSString *path = [@"~/Library/Preferences/com.apple.Terminal.plist" stringByExpandingTildeInPath];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    NSDictionary *windowSettings = [plist[@"Window Settings"] isKindOfClass:[NSDictionary class]] ? plist[@"Window Settings"] : nil;
    NSString *defaultName = [plist[@"Default Window Settings"] isKindOfClass:[NSString class]] ? plist[@"Default Window Settings"] : nil;
    NSDictionary *profile = [windowSettings[defaultName] isKindOfClass:[NSDictionary class]] ? windowSettings[defaultName] : nil;
    if (!profile) {
        NSString *startupName = [plist[@"Startup Window Settings"] isKindOfClass:[NSString class]] ? plist[@"Startup Window Settings"] : nil;
        profile = [windowSettings[startupName] isKindOfClass:[NSDictionary class]] ? windowSettings[startupName] : nil;
    }
    if (!profile) {
        return NO;
    }
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];
    NSDictionary *fontUpdates = [self profileUpdatesForArchivedFontData:profile[@"Font"]];
    if (fontUpdates) {
        [updates addEntriesFromDictionary:fontUpdates];
    }
    NSDictionary<NSString *, NSString *> *colorKeyMap = @{
        @"TextColor": KEY_FOREGROUND_COLOR,
        @"BackgroundColor": KEY_BACKGROUND_COLOR,
        @"BoldTextColor": KEY_BOLD_COLOR,
        @"CursorColor": KEY_CURSOR_COLOR,
        @"SelectionColor": KEY_SELECTION_COLOR,
    };
    [colorKeyMap enumerateKeysAndObjectsUsingBlock:^(NSString *sourceKey, NSString *targetKey, BOOL *stop) {
        NSDictionary *colorUpdate = [self profileColorDictionaryForArchivedColorData:profile[sourceKey] targetKey:targetKey];
        if (colorUpdate) {
            [updates addEntriesFromDictionary:colorUpdate];
        }
    }];
    NSArray<NSString *> *ansiKeys = @[
        @"ANSIBlackColor", @"ANSIRedColor", @"ANSIGreenColor", @"ANSIYellowColor",
        @"ANSIBlueColor", @"ANSIMagentaColor", @"ANSICyanColor", @"ANSIWhiteColor",
        @"ANSIBrightBlackColor", @"ANSIBrightRedColor", @"ANSIBrightGreenColor", @"ANSIBrightYellowColor",
        @"ANSIBrightBlueColor", @"ANSIBrightMagentaColor", @"ANSIBrightCyanColor", @"ANSIBrightWhiteColor",
    ];
    for (NSInteger i = 0; i < ansiKeys.count; i++) {
        NSDictionary *colorUpdate = [self profileColorDictionaryForArchivedColorData:profile[ansiKeys[i]]
                                                                            targetKey:[NSString stringWithFormat:KEYTEMPLATE_ANSI_X_COLOR, (int)i]];
        if (colorUpdate) {
            [updates addEntriesFromDictionary:colorUpdate];
        }
    }
    return [self applyImportedProfileUpdates:updates];
}

- (void)applyProfileUpdates:(NSDictionary *)updates {
    ProfileModel *model = [ProfileModel sharedInstance];
    Profile *defaultBookmark = [model defaultBookmark];
    if (!defaultBookmark) {
        return;
    }
    [model setObjectsFromDictionary:updates inProfile:defaultBookmark];
    [model flush];
    [model postChangeNotification];
}

- (void)finishWithSource:(NSString *)source {
    [[iTermUserDefaults userDefaults] setBool:YES forKey:kTideyFirstRunBootstrapDone];
    [[iTermUserDefaults userDefaults] setObject:source forKey:kTideyFirstRunBootstrapSource];
}

@end
