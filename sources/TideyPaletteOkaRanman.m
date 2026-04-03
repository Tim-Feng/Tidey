//
//  TideyPaletteOkaRanman.m
//  iTerm2SharedARC
//

#import "TideyPaletteOkaRanman.h"

static NSColor *TideyOkaRanmanColor(NSUInteger hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0
                               green:((hex >> 8) & 0xFF) / 255.0
                                blue:(hex & 0xFF) / 255.0
                               alpha:1.0];
}

@implementation TideyPaletteOkaRanman

+ (NSColor *)sakura { return TideyOkaRanmanColor(0xFEDFE1); }
+ (NSColor *)shironeri { return TideyOkaRanmanColor(0xFCFAF2); }
+ (NSColor *)neri { return TideyOkaRanmanColor(0xF2E8D0); }
+ (NSColor *)hada { return TideyOkaRanmanColor(0xF3E2B9); }
+ (NSColor *)kogecha { return TideyOkaRanmanColor(0x563F2E); }
+ (NSColor *)umenezumi { return TideyOkaRanmanColor(0x9E7A7A); }
+ (NSColor *)sakuranezumi { return TideyOkaRanmanColor(0xB19693); }
+ (NSColor *)gofun { return TideyOkaRanmanColor(0xFFFFFB); }
+ (NSColor *)imayoh { return TideyOkaRanmanColor(0xD05A6E); }
+ (NSColor *)nadeshiko { return TideyOkaRanmanColor(0xDC9FB4); }
+ (NSColor *)ikkonzome { return TideyOkaRanmanColor(0xF4A7B9); }
+ (NSColor *)taikoh { return TideyOkaRanmanColor(0xF8C3CD); }
+ (NSColor *)kohbai { return TideyOkaRanmanColor(0xE16B8C); }
+ (NSColor *)usubeni { return TideyOkaRanmanColor(0xE87A90); }
+ (NSColor *)nakabeni { return TideyOkaRanmanColor(0xDB4D6D); }
+ (NSColor *)suoh { return TideyOkaRanmanColor(0x8E354A); }
+ (NSColor *)kuwazome { return TideyOkaRanmanColor(0x64363C); }
+ (NSColor *)botan { return TideyOkaRanmanColor(0xE7609E); }
+ (NSColor *)kikyo { return TideyOkaRanmanColor(0x6A4C9C); }
+ (NSColor *)fujimurasaki { return TideyOkaRanmanColor(0x8A6BBE); }
+ (NSColor *)shion { return TideyOkaRanmanColor(0x8B81C3); }
+ (NSColor *)matsuba { return TideyOkaRanmanColor(0x42602D); }
+ (NSColor *)wakatake { return TideyOkaRanmanColor(0x5DAC81); }
+ (NSColor *)aotake { return TideyOkaRanmanColor(0x00896C); }
+ (NSColor *)rokusyoh { return TideyOkaRanmanColor(0x24936E); }
+ (NSColor *)yamabukicha { return TideyOkaRanmanColor(0xD19826); }
+ (NSColor *)tamago { return TideyOkaRanmanColor(0xF9BF45); }
+ (NSColor *)yamabuki { return TideyOkaRanmanColor(0xFFB11B); }
+ (NSColor *)kenpoh { return TideyOkaRanmanColor(0x43341B); }

@end
