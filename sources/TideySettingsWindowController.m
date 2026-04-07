#import "TideySettingsWindowController.h"

#import "TideyKeyboardShortcutsViewController.h"
#import "TideyTerminalAppearanceViewController.h"

typedef NS_ENUM(NSInteger, TideySettingsPage) {
    TideySettingsPageAppearance = 0,
    TideySettingsPageShortcuts = 1,
};

@interface TideySettingsTabButton : NSButton
@property(nonatomic, assign) BOOL isActiveTab;
@end

@implementation TideySettingsTabButton

- (void)drawRect:(NSRect)dirtyRect {
    if (self.isActiveTab) {
        // Accent dim background: rgba(88,178,220,0.12)
        NSColor *accentDim = [NSColor colorWithSRGBRed:88/255.0 green:178/255.0 blue:220/255.0 alpha:0.12];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6];
        [accentDim setFill];
        [path fill];
    }
    // Draw title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    NSColor *textColor;
    if (self.isActiveTab) {
        textColor = [NSColor colorWithSRGBRed:88/255.0 green:178/255.0 blue:220/255.0 alpha:1.0]; // accent #58B2DC
    } else {
        textColor = [NSColor colorWithSRGBRed:0x88/255.0 green:0x88/255.0 blue:0x88/255.0 alpha:1.0]; // secondary
    }
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: textColor,
        NSParagraphStyleAttributeName: style,
    };
    NSRect textRect = self.bounds;
    NSSize textSize = [self.title sizeWithAttributes:attrs];
    textRect.origin.y = (NSHeight(self.bounds) - textSize.height) / 2.0;
    textRect.size.height = textSize.height;
    [self.title drawInRect:textRect withAttributes:attrs];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

@end

@interface TideySettingsWindowController ()

@property(nonatomic, strong) TideySettingsTabButton *appearanceTabButton;
@property(nonatomic, strong) TideySettingsTabButton *shortcutsTabButton;
@property(nonatomic, strong) NSView *contentContainerView;
@property(nonatomic, strong) TideyTerminalAppearanceViewController *appearanceViewController;
@property(nonatomic, strong) TideyKeyboardShortcutsViewController *shortcutsViewController;
@property(nonatomic, strong) NSViewController *currentViewController;

@end

@implementation TideySettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 580)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        window.title = @"Settings";
        window.backgroundColor = [NSColor colorWithSRGBRed:0x1a/255.0 green:0x1a/255.0 blue:0x1a/255.0 alpha:1.0];
        [window center];
        [window setFrameAutosaveName:@"TideySettingsWindow"];

        _appearanceViewController = [[TideyTerminalAppearanceViewController alloc] init];
        _shortcutsViewController = [[TideyKeyboardShortcutsViewController alloc] init];

        [self buildUI];
        [self selectPage:TideySettingsPageAppearance];
    }
    return self;
}

- (void)showWindowSelectingAppearance {
    [self selectPage:TideySettingsPageAppearance];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)buildUI {
    NSView *contentView = self.window.contentView;
    CGFloat windowWidth = 560;
    CGFloat windowHeight = 580;

    // Tab bar area: two pill buttons near the top
    CGFloat tabBarY = windowHeight - 52;
    CGFloat tabButtonWidth = 100;
    CGFloat tabButtonHeight = 28;
    CGFloat tabBarX = 20;

    self.appearanceTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.appearanceTabButton.title = @"Appearance";
    self.appearanceTabButton.bordered = NO;
    self.appearanceTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.appearanceTabButton.target = self;
    self.appearanceTabButton.action = @selector(tabButtonClicked:);
    self.appearanceTabButton.tag = TideySettingsPageAppearance;
    [contentView addSubview:self.appearanceTabButton];

    self.shortcutsTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + tabButtonWidth + 2, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.shortcutsTabButton.title = @"Shortcuts";
    self.shortcutsTabButton.bordered = NO;
    self.shortcutsTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.shortcutsTabButton.target = self;
    self.shortcutsTabButton.action = @selector(tabButtonClicked:);
    self.shortcutsTabButton.tag = TideySettingsPageShortcuts;
    [contentView addSubview:self.shortcutsTabButton];

    // Content container below tab bar
    CGFloat contentTop = tabBarY - 12; // 12pt padding below tab bar
    self.contentContainerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, windowWidth, contentTop)];
    [contentView addSubview:self.contentContainerView];
}

- (void)tabButtonClicked:(TideySettingsTabButton *)sender {
    [self selectPage:(TideySettingsPage)sender.tag];
}

- (void)selectPage:(TideySettingsPage)page {
    self.appearanceTabButton.isActiveTab = (page == TideySettingsPageAppearance);
    self.shortcutsTabButton.isActiveTab = (page == TideySettingsPageShortcuts);
    [self.appearanceTabButton setNeedsDisplay:YES];
    [self.shortcutsTabButton setNeedsDisplay:YES];

    NSViewController *nextViewController = (page == TideySettingsPageAppearance
                                            ? self.appearanceViewController
                                            : self.shortcutsViewController);
    if (self.currentViewController == nextViewController) {
        return;
    }
    [self.currentViewController.view removeFromSuperview];
    self.currentViewController = nextViewController;
    NSView *view = nextViewController.view;
    view.frame = self.contentContainerView.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.contentContainerView addSubview:view];
}

@end
