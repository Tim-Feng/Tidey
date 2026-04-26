#import "TideySettingsWindowController.h"

#import "TideyKeyboardShortcutsViewController.h"
#import "TideyTerminalAppearanceViewController.h"

typedef NS_ENUM(NSInteger, TideySettingsPage) {
    TideySettingsPageAppearance = 0,
    TideySettingsPageShortcuts = 1,
    TideySettingsPageRemote = 2,
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

@interface TideyRemoteSettingsViewController : NSViewController
@end

@implementation TideyRemoteSettingsViewController

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 520)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor colorWithSRGBRed:0x1a/255.0 green:0x1a/255.0 blue:0x1a/255.0 alpha:1.0].CGColor;

    NSTextField *titleLabel = [self labelWithFrame:NSMakeRect(32, 460, 496, 28)
                                             string:@"Sync to Remote"
                                               font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                              color:[NSColor colorWithSRGBRed:0xf4/255.0 green:0xf4/255.0 blue:0xf4/255.0 alpha:1.0]];
    [view addSubview:titleLabel];

    NSTextField *bodyLabel = [self labelWithFrame:NSMakeRect(32, 414, 496, 42)
                                            string:@"Pair Tidey Remote on your phone with this Mac. The LAN QR code will appear here once the Bridge is available."
                                              font:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
                                             color:[NSColor colorWithSRGBRed:0x9a/255.0 green:0x9a/255.0 blue:0x9a/255.0 alpha:1.0]];
    bodyLabel.maximumNumberOfLines = 2;
    [view addSubview:bodyLabel];

    NSTextField *placeholderLabel = [self labelWithFrame:NSMakeRect(32, 260, 496, 24)
                                                   string:@"Remote pairing UI is loading."
                                                     font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                                    color:[NSColor colorWithSRGBRed:88/255.0 green:178/255.0 blue:220/255.0 alpha:1.0]];
    placeholderLabel.alignment = NSTextAlignmentCenter;
    [view addSubview:placeholderLabel];

    self.view = view;
}

- (NSTextField *)labelWithFrame:(NSRect)frame string:(NSString *)string font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = string;
    label.font = font;
    label.textColor = color;
    label.drawsBackground = NO;
    label.bezeled = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

@end

@interface TideySettingsWindowController ()

@property(nonatomic, strong) TideySettingsTabButton *appearanceTabButton;
@property(nonatomic, strong) TideySettingsTabButton *shortcutsTabButton;
@property(nonatomic, strong) TideySettingsTabButton *remoteTabButton;
@property(nonatomic, strong) NSView *contentContainerView;
@property(nonatomic, strong) TideyTerminalAppearanceViewController *appearanceViewController;
@property(nonatomic, strong) TideyKeyboardShortcutsViewController *shortcutsViewController;
@property(nonatomic, strong) TideyRemoteSettingsViewController *remoteViewController;
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
        _remoteViewController = [[TideyRemoteSettingsViewController alloc] init];

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

- (void)showWindowSelectingRemote {
    [self selectPage:TideySettingsPageRemote];
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

    self.remoteTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + (tabButtonWidth + 2) * 2, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.remoteTabButton.title = @"Remote";
    self.remoteTabButton.bordered = NO;
    self.remoteTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.remoteTabButton.target = self;
    self.remoteTabButton.action = @selector(tabButtonClicked:);
    self.remoteTabButton.tag = TideySettingsPageRemote;
    [contentView addSubview:self.remoteTabButton];

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
    self.remoteTabButton.isActiveTab = (page == TideySettingsPageRemote);
    [self.appearanceTabButton setNeedsDisplay:YES];
    [self.shortcutsTabButton setNeedsDisplay:YES];
    [self.remoteTabButton setNeedsDisplay:YES];

    NSViewController *nextViewController;
    switch (page) {
        case TideySettingsPageAppearance:
            nextViewController = self.appearanceViewController;
            break;
        case TideySettingsPageShortcuts:
            nextViewController = self.shortcutsViewController;
            break;
        case TideySettingsPageRemote:
            nextViewController = self.remoteViewController;
            break;
    }
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
