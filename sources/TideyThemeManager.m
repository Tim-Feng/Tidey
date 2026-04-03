//
//  TideyThemeManager.m
//  iTerm2SharedARC
//

#import "TideyThemeManager.h"

#import "TideyThemeOkaRanman.h"
#import "TideyThemeStillWater.h"
#import "iTermPreferences.h"

NSNotificationName const TideyThemeDidChangeNotification = @"TideyThemeDidChangeNotification";

@interface TideyThemeManager ()
@property (nonatomic, readwrite) TideyTheme *currentTheme;
@end

@implementation TideyThemeManager

+ (TideyTheme *)themeForStyle:(TideyThemeStyle)style {
    switch (style) {
        case TideyThemeStyleOkaRanman:
            return [TideyThemeOkaRanman theme];

        case TideyThemeStyleStillWater:
        default:
            return [TideyThemeStillWater theme];
    }
}

+ (TideyThemeStyle)styleForTheme:(TideyTheme *)theme {
    if ([theme isKindOfClass:[TideyTheme class]] &&
        [[theme bgBase] isEqual:[TideyThemeOkaRanman theme].bgBase] &&
        [[theme accentPrimary] isEqual:[TideyThemeOkaRanman theme].accentPrimary]) {
        return TideyThemeStyleOkaRanman;
    }
    return TideyThemeStyleStillWater;
}

+ (instancetype)shared {
    static TideyThemeManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] initPrivate];
    });
    return manager;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        const TideyThemeStyle style = [iTermPreferences integerForKey:kPreferenceKeyTideyTheme];
        _currentTheme = [[self class] themeForStyle:style];
    }
    return self;
}

- (instancetype)init {
    return [[self class] shared];
}

- (void)setTheme:(TideyTheme *)theme {
    if (!theme || theme == _currentTheme) {
        return;
    }
    _currentTheme = theme;
    [iTermPreferences setInteger:[[self class] styleForTheme:theme]
                          forKey:kPreferenceKeyTideyTheme];
    [[NSNotificationCenter defaultCenter] postNotificationName:TideyThemeDidChangeNotification
                                                        object:self];
}

@end
