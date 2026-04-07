#import "TideyKeyboardShortcutsViewController.h"

@implementation TideyKeyboardShortcutsViewController

- (void)loadView {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 680, 480)];
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.automaticallyAdjustsContentInsets = NO;

    NSView *documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 560)];
    scrollView.documentView = documentView;
    self.view = scrollView;

    NSArray<NSArray<NSString *> *> *shortcuts = @[
        @[@"New Workspace", @"⌘N"],
        @[@"New Panel", @"⌘T"],
        @[@"Close", @"⌘W"],
        @[@"Switch Workspace", @"⌘1-9 (⌘9 = last)"],
        @[@"Next / Previous Workspace", @"⌃⌘] / ⌃⌘["],
        @[@"Last Workspace", @"⌃⌘\\"],
        @[@"Show/Hide Sidebar", @"⌘B"],
        @[@"Show/Hide Editor", @"⇧⌘E"],
        @[@"Show/Hide Terminal", @"⇧⌘T"],
        @[@"Show/Hide File Tree", @"⌃⌘F"],
        @[@"Find in Editor", @"⌘F"],
        @[@"Switch Panel / Editor Tab", @"⌃1-9"],
        @[@"Save", @"⌘S"],
        @[@"Reset Layout", @"double-click divider"],
    ];

    NSTextField *title = [NSTextField labelWithString:@"Keyboard Shortcuts"];
    title.font = [NSFont boldSystemFontOfSize:15];
    title.frame = NSMakeRect(24, 522, 240, 22);
    [documentView addSubview:title];

    NSTextField *subtitle = [NSTextField labelWithString:@"Built-in shortcuts for workspace, editor, browser, and file tree actions."];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor secondaryLabelColor];
    subtitle.frame = NSMakeRect(24, 500, 560, 18);
    [documentView addSubview:subtitle];

    CGFloat y = 462;
    for (NSArray<NSString *> *row in shortcuts) {
        NSTextField *action = [NSTextField labelWithString:row[0]];
        action.font = [NSFont systemFontOfSize:12];
        action.frame = NSMakeRect(24, y, 280, 18);
        [documentView addSubview:action];

        NSTextField *key = [NSTextField labelWithString:row[1]];
        key.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
        key.alignment = NSTextAlignmentRight;
        key.frame = NSMakeRect(330, y, 320, 18);
        [documentView addSubview:key];

        y -= 28;
    }
}

@end
