#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TideyTerminalAppearanceProfileAdapter : NSObject

- (NSFont *)normalFont;
- (NSColor *)colorForKey:(NSString *)key;
- (NSColor *)ansiColorAtIndex:(NSInteger)index;

- (void)updateNormalFont:(NSFont *)font;
- (void)updateColor:(NSColor *)color forKey:(NSString *)key;
- (void)updateANSIColor:(NSColor *)color atIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
