#import <Cocoa/Cocoa.h>

/// A simple color swatch view that draws a filled rounded rectangle.
/// Replaces NSColorWell to avoid system-drawn chrome/border.
@interface TideyColorSwatchView : NSView

/// The displayed color. Setting this redraws the swatch.
@property(nonatomic, strong) NSColor *color;

/// Target/action pair fired when the user picks a new color via NSColorPanel.
@property(nonatomic, weak) id target;
@property(nonatomic, assign) SEL action;

/// Override NSView's readonly tag to make it settable.
- (void)setTag:(NSInteger)tag;
- (NSInteger)tag;

@end
