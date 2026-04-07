#import "TideySettingsWindowController.h"

#import "TideyKeyboardShortcutsViewController.h"
#import "TideyTerminalAppearanceViewController.h"

typedef NS_ENUM(NSInteger, TideySettingsPage) {
    TideySettingsPageAppearance = 0,
    TideySettingsPageShortcuts = 1,
};

@interface TideySettingsWindowController ()

@property(nonatomic, strong) NSSegmentedControl *pageControl;
@property(nonatomic, strong) NSView *contentContainerView;
@property(nonatomic, strong) TideyTerminalAppearanceViewController *appearanceViewController;
@property(nonatomic, strong) TideyKeyboardShortcutsViewController *shortcutsViewController;
@property(nonatomic, strong) NSViewController *currentViewController;

@end

@implementation TideySettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 560)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        window.title = @"Settings";
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

    self.pageControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(24, 514, 320, 28)];
    self.pageControl.segmentCount = 2;
    [self.pageControl setLabel:@"Terminal Appearance" forSegment:0];
    [self.pageControl setLabel:@"Keyboard Shortcuts" forSegment:1];
    self.pageControl.target = self;
    self.pageControl.action = @selector(pageControlDidChange:);
    [contentView addSubview:self.pageControl];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 494, 720, 1)];
    separator.boxType = NSBoxSeparator;
    [contentView addSubview:separator];

    self.contentContainerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 492)];
    [contentView addSubview:self.contentContainerView];
}

- (void)pageControlDidChange:(NSSegmentedControl *)sender {
    [self selectPage:(TideySettingsPage)sender.selectedSegment];
}

- (void)selectPage:(TideySettingsPage)page {
    self.pageControl.selectedSegment = page;
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
