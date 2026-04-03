//
//  TideyPalette.m
//  iTerm2SharedARC
//

#import "TideyPalette.h"

static NSColor *TideyPaletteColor(NSUInteger hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0
                               green:((hex >> 8) & 0xFF) / 255.0
                                blue:(hex & 0xFF) / 255.0
                               alpha:1.0];
}

@implementation TideyPalette

+ (NSColor *)kurotsurubami { return TideyPaletteColor(0x0B1013); }
+ (NSColor *)kachi { return TideyPaletteColor(0x08192D); }
+ (NSColor *)katsuiro { return TideyPaletteColor(0x181B26); }
+ (NSColor *)kon { return TideyPaletteColor(0x192236); }
+ (NSColor *)rindoh { return TideyPaletteColor(0x2B2F4A); }
+ (NSColor *)seiran { return TideyPaletteColor(0x274A78); }
+ (NSColor *)nezu { return TideyPaletteColor(0x656765); }
+ (NSColor *)fukaganezumi { return TideyPaletteColor(0x77969A); }
+ (NSColor *)ginnezumi { return TideyPaletteColor(0x91989F); }
+ (NSColor *)geppaku { return TideyPaletteColor(0xEAF4FC); }
+ (NSColor *)chigusa { return TideyPaletteColor(0x3A8FB7); }
+ (NSColor *)sora { return TideyPaletteColor(0x58B2DC); }
+ (NSColor *)sabiasagi { return TideyPaletteColor(0x5C9291); }
+ (NSColor *)mizuasagi { return TideyPaletteColor(0x70C5BA); }
+ (NSColor *)hana { return TideyPaletteColor(0x5B7E91); }
+ (NSColor *)karashi { return TideyPaletteColor(0xCAAD5F); }
+ (NSColor *)tanpopo { return TideyPaletteColor(0xFFB11B); }
+ (NSColor *)yamabuki { return TideyPaletteColor(0xF8B500); }
+ (NSColor *)matsuba { return TideyPaletteColor(0x839B5C); }
+ (NSColor *)wakatake { return TideyPaletteColor(0x68BE8D); }
+ (NSColor *)benihi { return TideyPaletteColor(0xCB4042); }
+ (NSColor *)usubeni { return TideyPaletteColor(0xE87A90); }
+ (NSColor *)shion { return TideyPaletteColor(0x8B81C3); }
+ (NSColor *)botan { return TideyPaletteColor(0xE7609E); }
+ (NSColor *)aitetsu { return TideyPaletteColor(0x003A47); }

@end
