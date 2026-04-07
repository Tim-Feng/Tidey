#import "TideyKeyboardShortcutsViewController.h"

#import "iTermFlippedView.h"

// Reuse the same card view class. Forward declare to avoid coupling.
@interface TideyShortcutsCardView : NSView
@end

@implementation TideyShortcutsCardView

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
                                                         xRadius:13
                                                         yRadius:13];
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.04] setFill];
    [path fill];
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.08] setStroke];
    [path setLineWidth:1.0];
    [path stroke];
}

@end

@interface TideyShortcutsCardDivider : NSView
@end

@implementation TideyShortcutsCardDivider

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.06] setFill];
    NSRectFill(self.bounds);
}

@end

@implementation TideyKeyboardShortcutsViewController

static NSColor *TideyShortcutsPrimaryTextColor(void) {
    return [NSColor colorWithSRGBRed:0xe8/255.0 green:0xe8/255.0 blue:0xe8/255.0 alpha:1.0];
}

static NSColor *TideyShortcutsSecondaryTextColor(void) {
    return [NSColor colorWithSRGBRed:0x88/255.0 green:0x88/255.0 blue:0x88/255.0 alpha:1.0];
}

- (void)loadView {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 516)];
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    iTermFlippedView *documentView = [[iTermFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 560, 800)];
    scrollView.documentView = documentView;
    self.view = scrollView;

    static const CGFloat kPadding = 20;
    static const CGFloat kRowHeight = 36;
    static const CGFloat kCardPaddingH = 14;

    NSArray<NSArray<NSString *> *> *shortcuts = @[
        @[@"New Workspace", @"\u2318N"],
        @[@"New Panel", @"\u2318T"],
        @[@"Close", @"\u2318W"],
        @[@"Switch Workspace", @"\u23181\u20139 (\u23189 = last)"],
        @[@"Next / Previous Workspace", @"\u2303\u2318] / \u2303\u2318["],
        @[@"Last Workspace", @"\u2303\u2318\\"],
        @[@"Show/Hide Sidebar", @"\u2318B"],
        @[@"Show/Hide Editor", @"\u21E7\u2318E"],
        @[@"Show/Hide Terminal", @"\u21E7\u2318T"],
        @[@"Show/Hide File Tree", @"\u2303\u2318F"],
        @[@"Find in Editor", @"\u2318F"],
        @[@"Switch Panel / Editor Tab", @"\u23031\u20139"],
        @[@"Save", @"\u2318S"],
        @[@"Reset Layout", @"double-click divider"],
    ];

    CGFloat contentWidth = 560 - kPadding * 2;
    CGFloat y = 0;

    // Section header
    {
        NSTextField *header = [NSTextField labelWithString:@"KEYBOARD SHORTCUTS"];
        header.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        header.textColor = TideyShortcutsSecondaryTextColor();
        header.frame = NSMakeRect(kPadding + 2, y, contentWidth, 16);
        [documentView addSubview:header];
        y += 16 + 8;
    }

    // Card containing all shortcut rows
    NSInteger rowCount = (NSInteger)shortcuts.count;
    CGFloat cardHeight = kRowHeight * rowCount + (rowCount - 1); // rows + dividers
    TideyShortcutsCardView *card = [[TideyShortcutsCardView alloc] initWithFrame:NSMakeRect(kPadding, y, contentWidth, cardHeight)];
    [documentView addSubview:card];

    CGFloat rowY = 0;
    for (NSInteger i = 0; i < rowCount; i++) {
        if (i > 0) {
            TideyShortcutsCardDivider *div = [[TideyShortcutsCardDivider alloc] initWithFrame:NSMakeRect(kCardPaddingH, rowY, contentWidth - kCardPaddingH * 2, 1)];
            [card addSubview:div];
            rowY += 1;
        }

        NSTextField *action = [NSTextField labelWithString:shortcuts[i][0]];
        action.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        action.textColor = TideyShortcutsPrimaryTextColor();
        action.frame = NSMakeRect(kCardPaddingH, rowY + 8, contentWidth * 0.5, 20);
        [card addSubview:action];

        NSTextField *key = [NSTextField labelWithString:shortcuts[i][1]];
        key.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
        key.textColor = TideyShortcutsSecondaryTextColor();
        key.alignment = NSTextAlignmentRight;
        key.frame = NSMakeRect(contentWidth * 0.5, rowY + 8, contentWidth * 0.5 - kCardPaddingH, 20);
        [card addSubview:key];

        rowY += kRowHeight;
    }

    y += cardHeight + 24; // bottom padding

    // Set document view height
    NSRect docFrame = documentView.frame;
    docFrame.size.height = y;
    documentView.frame = docFrame;
}

@end
