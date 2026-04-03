//
//  TideyThemeStillWater.m
//  iTerm2SharedARC
//

#import "TideyThemeStillWater.h"

#import "TideyPalette.h"

@implementation TideyThemeStillWater

+ (TideyTheme *)theme {
    return [[TideyTheme alloc] initWithDictionary:@{
        @"bgBase": [TideyPalette kurotsurubami],
        @"bgSurface": [TideyPalette kon],
        @"bgControl": [TideyPalette rindoh],
        @"bgSelected": [[TideyPalette seiran] colorWithAlphaComponent:0.5],
        @"bgHover": [[TideyPalette geppaku] colorWithAlphaComponent:0.06],
        @"borderDefault": [[TideyPalette fukaganezumi] colorWithAlphaComponent:0.20],
        @"borderStrong": [[TideyPalette ginnezumi] colorWithAlphaComponent:0.35],
        @"lineActive": [TideyPalette mizuasagi],
        @"lineHairline": [[TideyPalette geppaku] colorWithAlphaComponent:0.10],
        @"textPrimary": [TideyPalette geppaku],
        @"textSecondary": [TideyPalette fukaganezumi],
        @"textTertiary": [TideyPalette nezu],
        @"textOnAccent": [NSColor whiteColor],
        @"accentPrimary": [TideyPalette mizuasagi],
        @"accentMuted": [TideyPalette sabiasagi],
        @"accentIndicator": [TideyPalette chigusa],
        @"stateSuccess": [TideyPalette wakatake],
        @"stateWarning": [TideyPalette tanpopo],
        @"stateError": [TideyPalette benihi],
        @"ansiBlack": [TideyPalette katsuiro],
        @"ansiRed": [TideyPalette benihi],
        @"ansiGreen": [TideyPalette matsuba],
        @"ansiYellow": [TideyPalette karashi],
        @"ansiBlue": [TideyPalette hana],
        @"ansiMagenta": [TideyPalette shion],
        @"ansiCyan": [TideyPalette sabiasagi],
        @"ansiWhite": [TideyPalette ginnezumi],
        @"ansiBrightBlack": [TideyPalette nezu],
        @"ansiBrightRed": [TideyPalette usubeni],
        @"ansiBrightGreen": [TideyPalette wakatake],
        @"ansiBrightYellow": [TideyPalette tanpopo],
        @"ansiBrightBlue": [TideyPalette sora],
        @"ansiBrightMagenta": [TideyPalette botan],
        @"ansiBrightCyan": [TideyPalette mizuasagi],
        @"ansiBrightWhite": [TideyPalette geppaku],
        @"background": [TideyPalette kurotsurubami],
        @"foreground": [TideyPalette geppaku],
        @"cursor": [TideyPalette sora],
        @"imeCursor": [TideyPalette sora],
        @"selection": [TideyPalette seiran],
    }];
}

@end
