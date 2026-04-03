//
//  TideyTheme.m
//  iTerm2SharedARC
//

#import "TideyTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface TideyTheme ()
@property (nonatomic, readwrite) NSColor *bgBase;
@property (nonatomic, readwrite) NSColor *bgSurface;
@property (nonatomic, readwrite) NSColor *bgControl;
@property (nonatomic, readwrite) NSColor *bgSelected;
@property (nonatomic, readwrite) NSColor *bgHover;
@property (nonatomic, readwrite) NSColor *borderDefault;
@property (nonatomic, readwrite) NSColor *borderStrong;
@property (nonatomic, readwrite) NSColor *lineActive;
@property (nonatomic, readwrite) NSColor *lineHairline;
@property (nonatomic, readwrite) NSColor *textPrimary;
@property (nonatomic, readwrite) NSColor *textSecondary;
@property (nonatomic, readwrite) NSColor *textTertiary;
@property (nonatomic, readwrite) NSColor *textOnAccent;
@property (nonatomic, readwrite) NSColor *accentPrimary;
@property (nonatomic, readwrite) NSColor *accentMuted;
@property (nonatomic, readwrite) NSColor *accentIndicator;
@property (nonatomic, readwrite) NSColor *stateSuccess;
@property (nonatomic, readwrite) NSColor *stateWarning;
@property (nonatomic, readwrite) NSColor *stateError;
@property (nonatomic, readwrite) NSColor *ansiBlack;
@property (nonatomic, readwrite) NSColor *ansiRed;
@property (nonatomic, readwrite) NSColor *ansiGreen;
@property (nonatomic, readwrite) NSColor *ansiYellow;
@property (nonatomic, readwrite) NSColor *ansiBlue;
@property (nonatomic, readwrite) NSColor *ansiMagenta;
@property (nonatomic, readwrite) NSColor *ansiCyan;
@property (nonatomic, readwrite) NSColor *ansiWhite;
@property (nonatomic, readwrite) NSColor *ansiBrightBlack;
@property (nonatomic, readwrite) NSColor *ansiBrightRed;
@property (nonatomic, readwrite) NSColor *ansiBrightGreen;
@property (nonatomic, readwrite) NSColor *ansiBrightYellow;
@property (nonatomic, readwrite) NSColor *ansiBrightBlue;
@property (nonatomic, readwrite) NSColor *ansiBrightMagenta;
@property (nonatomic, readwrite) NSColor *ansiBrightCyan;
@property (nonatomic, readwrite) NSColor *ansiBrightWhite;
@property (nonatomic, readwrite) NSColor *background;
@property (nonatomic, readwrite) NSColor *foreground;
@property (nonatomic, readwrite) NSColor *cursor;
@property (nonatomic, readwrite) NSColor *imeCursor;
@property (nonatomic, readwrite) NSColor *selection;
@end

@implementation TideyTheme

static NSColor *TideyThemeRequireColor(NSDictionary<NSString *, NSColor *> *dictionary, NSString *key) {
    NSColor *color = dictionary[key];
    NSCAssert(color != nil, @"Missing TideyTheme color for key %@", key);
    return color;
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *,NSColor *> *)dictionary {
    self = [super init];
    if (self) {
        _bgBase = TideyThemeRequireColor(dictionary, @"bgBase");
        _bgSurface = TideyThemeRequireColor(dictionary, @"bgSurface");
        _bgControl = TideyThemeRequireColor(dictionary, @"bgControl");
        _bgSelected = TideyThemeRequireColor(dictionary, @"bgSelected");
        _bgHover = TideyThemeRequireColor(dictionary, @"bgHover");
        _borderDefault = TideyThemeRequireColor(dictionary, @"borderDefault");
        _borderStrong = TideyThemeRequireColor(dictionary, @"borderStrong");
        _lineActive = TideyThemeRequireColor(dictionary, @"lineActive");
        _lineHairline = TideyThemeRequireColor(dictionary, @"lineHairline");
        _textPrimary = TideyThemeRequireColor(dictionary, @"textPrimary");
        _textSecondary = TideyThemeRequireColor(dictionary, @"textSecondary");
        _textTertiary = TideyThemeRequireColor(dictionary, @"textTertiary");
        _textOnAccent = TideyThemeRequireColor(dictionary, @"textOnAccent");
        _accentPrimary = TideyThemeRequireColor(dictionary, @"accentPrimary");
        _accentMuted = TideyThemeRequireColor(dictionary, @"accentMuted");
        _accentIndicator = TideyThemeRequireColor(dictionary, @"accentIndicator");
        _stateSuccess = TideyThemeRequireColor(dictionary, @"stateSuccess");
        _stateWarning = TideyThemeRequireColor(dictionary, @"stateWarning");
        _stateError = TideyThemeRequireColor(dictionary, @"stateError");
        _ansiBlack = TideyThemeRequireColor(dictionary, @"ansiBlack");
        _ansiRed = TideyThemeRequireColor(dictionary, @"ansiRed");
        _ansiGreen = TideyThemeRequireColor(dictionary, @"ansiGreen");
        _ansiYellow = TideyThemeRequireColor(dictionary, @"ansiYellow");
        _ansiBlue = TideyThemeRequireColor(dictionary, @"ansiBlue");
        _ansiMagenta = TideyThemeRequireColor(dictionary, @"ansiMagenta");
        _ansiCyan = TideyThemeRequireColor(dictionary, @"ansiCyan");
        _ansiWhite = TideyThemeRequireColor(dictionary, @"ansiWhite");
        _ansiBrightBlack = TideyThemeRequireColor(dictionary, @"ansiBrightBlack");
        _ansiBrightRed = TideyThemeRequireColor(dictionary, @"ansiBrightRed");
        _ansiBrightGreen = TideyThemeRequireColor(dictionary, @"ansiBrightGreen");
        _ansiBrightYellow = TideyThemeRequireColor(dictionary, @"ansiBrightYellow");
        _ansiBrightBlue = TideyThemeRequireColor(dictionary, @"ansiBrightBlue");
        _ansiBrightMagenta = TideyThemeRequireColor(dictionary, @"ansiBrightMagenta");
        _ansiBrightCyan = TideyThemeRequireColor(dictionary, @"ansiBrightCyan");
        _ansiBrightWhite = TideyThemeRequireColor(dictionary, @"ansiBrightWhite");
        _background = TideyThemeRequireColor(dictionary, @"background");
        _foreground = TideyThemeRequireColor(dictionary, @"foreground");
        _cursor = TideyThemeRequireColor(dictionary, @"cursor");
        _imeCursor = TideyThemeRequireColor(dictionary, @"imeCursor");
        _selection = TideyThemeRequireColor(dictionary, @"selection");
    }
    return self;
}

@end

NS_ASSUME_NONNULL_END
