#import "TideySidebarViews.h"

#import "iTerm2SharedARC-Swift.h"

const CGFloat kTideySidebarBadgeSize = 6;
const CGFloat kTideySidebarBadgeLeadingInset = 1;
const CGFloat kTideySidebarTrailingSlotSize = 24;
const CGFloat kTideySidebarTrailingSlotTrailingInset = 6;
const CGFloat kTideySidebarCloseGlyphSize = 16;

NSUserInterfaceItemIdentifier const kTideySidebarCloseViewIdentifier = @"TideySidebarCloseView";
NSUserInterfaceItemIdentifier const kTideySidebarBadgeViewIdentifier = @"TideySidebarBadgeView";

NSView *TideyFindCloseView(NSView *container) {
    for (NSView *subview in container.subviews) {
        if ([subview.identifier isEqualToString:kTideySidebarCloseViewIdentifier]) {
            return subview;
        }
    }
    return nil;
}

@implementation TideySidebarTableView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _tideyHoveredRow = -1;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tideyTrackingArea) {
        [self removeTrackingArea:_tideyTrackingArea];
    }
    _tideyTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                      options:(NSTrackingActiveAlways |
                                                               NSTrackingInVisibleRect |
                                                               NSTrackingMouseMoved |
                                                               NSTrackingMouseEnteredAndExited)
                                                        owner:self
                                                     userInfo:nil];
    [self addTrackingArea:_tideyTrackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self tideyUpdateHoveredRowForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    _tideyHoveredRow = -1;
    [self updateTideyCloseButtonVisibility];
}

- (void)mouseMoved:(NSEvent *)event {
    [super mouseMoved:event];
    [self tideyUpdateHoveredRowForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:point];
    if (row >= 0) {
        NSRect closeRect = [self tideyCloseRectForRow:row];
        if (!NSIsEmptyRect(closeRect) && NSPointInRect(point, closeRect)) {
            [self.tideyCloseActionTarget tideySidebarCloseWorkspaceAtIndex:row];
            return;
        }
    }
    [super mouseDown:event];
}

- (void)tideyUpdateHoveredRowForPoint:(NSPoint)point {
    NSInteger row = [self rowAtPoint:point];
    if (row < 0) {
        row = -1;
    }
    if (_tideyHoveredRow != row) {
        _tideyHoveredRow = row;
        [self updateTideyCloseButtonVisibility];
    }
}

- (NSInteger)tideyHoveredRowForCurrentMouseLocation {
    if (!self.window) {
        return -1;
    }
    NSPoint point = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    if (!NSPointInRect(point, self.bounds)) {
        return -1;
    }
    NSInteger row = [self rowAtPoint:point];
    return (row >= 0) ? row : -1;
}

- (BOOL)tideyShouldShowCloseButtonForRow:(NSInteger)row {
    _tideyHoveredRow = [self tideyHoveredRowForCurrentMouseLocation];
    return (row >= 0 && row == _tideyHoveredRow);
}

- (NSRect)tideyCloseRectForRow:(NSInteger)row {
    NSTableCellView *cellView = [self viewAtColumn:0 row:row makeIfNecessary:NO];
    NSView *closeView = TideyFindCloseView(cellView);
    if (closeView) {
        return [closeView convertRect:closeView.bounds toView:self];
    }
    NSRect rowRect = [self rectOfRow:row];
    if (NSIsEmptyRect(rowRect)) {
        return NSZeroRect;
    }
    return NSMakeRect(NSMaxX(rowRect) -
                          kTideySidebarTrailingSlotTrailingInset -
                          kTideySidebarTrailingSlotSize,
                      NSMinY(rowRect) + 29,
                      kTideySidebarTrailingSlotSize,
                      kTideySidebarTrailingSlotSize);
}

- (void)updateTideyCloseButtonVisibility {
    _tideyHoveredRow = [self tideyHoveredRowForCurrentMouseLocation];
    NSRange rows = [self rowsInRect:self.visibleRect];
    NSInteger limit = NSMaxRange(rows);
    for (NSInteger row = rows.location; row < limit; row++) {
        NSTableCellView *cellView = [self viewAtColumn:0 row:row makeIfNecessary:NO];
        NSView *closeView = TideyFindCloseView(cellView);
        if (!closeView) {
            continue;
        }
        BOOL visible = (row == _tideyHoveredRow);
        closeView.hidden = !visible;
        closeView.alphaValue = visible ? 1.0 : 0.0;
    }
}

@end

@implementation TideySidebarRowView

- (void)tideyDrawWarmSelection {
    if (!self.isSelected) {
        return;
    }
    TideyInterfaceThemeTokens *tokens = TideyInterfaceThemeController.shared.currentTokens;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 6, 4)
                                                         xRadius:TideyChromeLayoutPolicy.sidebarSelectionCornerRadius
                                                         yRadius:TideyChromeLayoutPolicy.sidebarSelectionCornerRadius];
    [tokens.sidebarSelectionColor setFill];
    [path fill];
    [tokens.sidebarSelectionBorderColor setStroke];
    path.lineWidth = 1;
    [path stroke];
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    [self tideyDrawWarmSelection];
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // Selection chrome is drawn from the active theme's tokens above.
}

- (BOOL)isEmphasized {
    return YES;
}

@end

@implementation TideyFileTreeRowView

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    if (!self.isSelected) {
        return;
    }
    TideyInterfaceThemeTokens *tokens = TideyInterfaceThemeController.shared.currentTokens;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 1)
                                                         xRadius:6
                                                         yRadius:6];
    [tokens.fileTreeSelectionColor setFill];
    [path fill];
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // Selection chrome is drawn from the active theme's tokens above.
}

- (BOOL)isEmphasized {
    return YES;
}

@end

@implementation TideySidebarCellView

- (void)layout {
    [super layout];

    NSView *closeView = TideyFindCloseView(self);
    if (!closeView) {
        return;
    }
    // The close hit target shares the name row's trailing control slot.
    const CGFloat closeX = MAX(0,
                               NSWidth(self.bounds) -
                                   kTideySidebarTrailingSlotTrailingInset -
                                   kTideySidebarTrailingSlotSize);
    const CGFloat closeY = MAX(0,
                               NSHeight(self.bounds) - 35);
    closeView.frame = NSMakeRect(closeX,
                                 closeY,
                                 kTideySidebarTrailingSlotSize,
                                 kTideySidebarTrailingSlotSize);
}

@end
