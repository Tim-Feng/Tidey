//
//  TideyThemeOkaRanman.m
//  iTerm2SharedARC
//

#import "TideyThemeOkaRanman.h"

#import "TideyPaletteOkaRanman.h"

@implementation TideyThemeOkaRanman

+ (TideyTheme *)theme {
    return [[TideyTheme alloc] initWithDictionary:@{
        @"bgBase": [TideyPaletteOkaRanman sakura],
        @"bgSurface": [TideyPaletteOkaRanman shironeri],
        @"bgControl": [TideyPaletteOkaRanman neri],
        @"bgSelected": [[TideyPaletteOkaRanman imayoh] colorWithAlphaComponent:0.55],
        @"bgHover": [[TideyPaletteOkaRanman taikoh] colorWithAlphaComponent:0.25],
        @"borderDefault": [[TideyPaletteOkaRanman umenezumi] colorWithAlphaComponent:0.25],
        @"borderStrong": [[TideyPaletteOkaRanman sakuranezumi] colorWithAlphaComponent:0.45],
        @"lineActive": [TideyPaletteOkaRanman imayoh],
        @"lineHairline": [[TideyPaletteOkaRanman kogecha] colorWithAlphaComponent:0.12],
        @"textPrimary": [TideyPaletteOkaRanman kogecha],
        @"textSecondary": [TideyPaletteOkaRanman umenezumi],
        @"textTertiary": [TideyPaletteOkaRanman sakuranezumi],
        @"textOnAccent": [TideyPaletteOkaRanman gofun],
        @"accentPrimary": [TideyPaletteOkaRanman imayoh],
        @"accentMuted": [TideyPaletteOkaRanman nadeshiko],
        @"accentIndicator": [TideyPaletteOkaRanman ikkonzome],
        @"stateSuccess": [TideyPaletteOkaRanman wakatake],
        @"stateWarning": [TideyPaletteOkaRanman yamabuki],
        @"stateError": [TideyPaletteOkaRanman nakabeni],
        @"ansiBlack": [TideyPaletteOkaRanman kenpoh],
        @"ansiRed": [TideyPaletteOkaRanman imayoh],
        @"ansiGreen": [TideyPaletteOkaRanman matsuba],
        @"ansiYellow": [TideyPaletteOkaRanman yamabukicha],
        @"ansiBlue": [TideyPaletteOkaRanman kikyo],
        @"ansiMagenta": [TideyPaletteOkaRanman kohbai],
        @"ansiCyan": [TideyPaletteOkaRanman aotake],
        @"ansiWhite": [TideyPaletteOkaRanman shironeri],
        @"ansiBrightBlack": [TideyPaletteOkaRanman kuwazome],
        @"ansiBrightRed": [TideyPaletteOkaRanman nakabeni],
        @"ansiBrightGreen": [TideyPaletteOkaRanman wakatake],
        @"ansiBrightYellow": [TideyPaletteOkaRanman tamago],
        @"ansiBrightBlue": [TideyPaletteOkaRanman fujimurasaki],
        @"ansiBrightMagenta": [TideyPaletteOkaRanman usubeni],
        @"ansiBrightCyan": [TideyPaletteOkaRanman rokusyoh],
        @"ansiBrightWhite": [TideyPaletteOkaRanman gofun],
        @"background": [TideyPaletteOkaRanman sakura],
        @"foreground": [TideyPaletteOkaRanman kogecha],
        @"cursor": [TideyPaletteOkaRanman imayoh],
        @"imeCursor": [TideyPaletteOkaRanman imayoh],
        @"selection": [[TideyPaletteOkaRanman ikkonzome] colorWithAlphaComponent:0.25],
    }];
}

@end
