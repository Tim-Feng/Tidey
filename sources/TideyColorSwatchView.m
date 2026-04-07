#import "TideyColorSwatchView.h"

static const CGFloat kSwatchCornerRadius = 6.0;

@implementation TideyColorSwatchView {
    BOOL _isActive;  // YES while this swatch owns the shared NSColorPanel
    NSInteger _settableTag;
}

- (void)setTag:(NSInteger)tag {
    _settableTag = tag;
}

- (NSInteger)tag {
    return _settableTag;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _color = [NSColor blackColor];
        self.wantsLayer = YES;
        self.layer.cornerRadius = kSwatchCornerRadius;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)dealloc {
    if (_isActive) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSColorPanelColorDidChangeNotification
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSWindowWillCloseNotification
                                                      object:nil];
    }
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                         xRadius:kSwatchCornerRadius
                                                         yRadius:kSwatchCornerRadius];
    [self.color setFill];
    [path fill];
}

#pragma mark - Properties

- (void)setColor:(NSColor *)color {
    _color = color ?: [NSColor blackColor];
    [self setNeedsDisplay:YES];
}

#pragma mark - Mouse handling

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];

    if (_isActive) {
        // Already active — close the panel to toggle off.
        [panel close];
        return;
    }

    _isActive = YES;
    panel.color = self.color;
    panel.showsAlpha = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(colorPanelColorDidChange:)
                                                 name:NSColorPanelColorDidChangeNotification
                                               object:panel];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(colorPanelWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:panel];

    [panel makeKeyAndOrderFront:nil];
}

- (void)colorPanelColorDidChange:(NSNotification *)note {
    if (!_isActive) return;
    NSColorPanel *panel = note.object;
    self.color = panel.color;

    id strongTarget = self.target;
    SEL sel = self.action;
    if (strongTarget && sel) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [strongTarget performSelector:sel withObject:self];
#pragma clang diagnostic pop
    }
}

- (void)colorPanelWillClose:(NSNotification *)note {
    (void)note;
    [self deactivate];
}

- (void)deactivate {
    if (!_isActive) return;
    _isActive = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSColorPanelColorDidChangeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillCloseNotification
                                                  object:nil];
}

#pragma mark - Accessibility

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityColorWellRole;
}

@end
