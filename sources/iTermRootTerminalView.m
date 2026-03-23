//
//  iTermRootTerminalView.m
//  iTerm2
//
//  Created by George Nachman on 7/3/15.
//
//

#import "iTermRootTerminalView.h"

#import "DebugLogging.h"
#import "iTermLayoutCalculator.h"

#import "NSAppearance+iTerm.h"
#import "NSEvent+iTerm.h"
#import "NSImage+iTerm.h"
#import "NSObject+iTerm.h"
#import "NSTextField+iTerm.h"
#import "NSView+RecursiveDescription.h"
#import "NSView+iTerm.h"
#import "NSWindow+iTerm.h"
#import "PTYTabView.h"
#import "PTYTabView.h"
#import "PTYWindow.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermApplication.h"
#import "iTermDragHandleView.h"
#import "iTermFakeWindowTitleLabel.h"
#import "iTermGenericStatusBarContainer.h"
#import "iTermImageView.h"
#import "iTermPreferences.h"
#import "iTermStandardWindowButtonsView.h"
#import "iTermStatusBarViewController.h"
#import "iTermStoplightHotbox.h"
#import "iTermTabBarControlView.h"
#import "iTermToolbeltView.h"
#import "iTermUserDefaults.h"
#import "iTermWindowShortcutLabelTitlebarAccessoryViewController.h"
#import "iTermWindowSizeView.h"
#import "NSJSONSerialization+iTerm.h"
#import "TideyNotificationStore.h"

#import <WebKit/WebKit.h>

static const CGFloat iTermWindowBorderRadius = 12;

const CGFloat iTermStandardButtonsViewHeight = 25;
const CGFloat iTermStandardButtonsViewWidth = 69;
const CGFloat iTermStoplightHotboxWidth = iTermStandardButtonsViewWidth + 28 + 24;
const CGFloat iTermStoplightHotboxHeight = iTermStandardButtonsViewHeight + 8;
const CGFloat kDivisionViewHeight = 1;

const NSInteger iTermRootTerminalViewWindowNumberLabelMargin = 6;
const NSInteger iTermRootTerminalViewWindowNumberLabelWidth = 40;

static const CGFloat kMinimumToolbeltSizeInPoints = 100;
static const CGFloat kMinimumToolbeltSizeAsFractionOfWindow = 0.05;
static const CGFloat kMaximumToolbeltSizeAsFractionOfWindow = 0.5;
static const CGFloat kTideySidebarWidth = 200;
static const CGFloat kTideyEditorFileTreeWidth = 200;
static const CGFloat kTideyMinimumSidebarWidth = 160;
static const CGFloat kTideyMinimumTerminalWidth = 200;
static const CGFloat kTideyMinimumEditorPanelWidth = 280;
static const CGFloat kTideyMinimumEditorContentWidth = 160;
static const CGFloat kTideyMinimumFileTreeWidth = 120;
static const CGFloat kTideyEditorTabStripHeight = 34;
static const CGFloat kTideyDragHandleWidth = 4;
static const CGFloat kTideyChromeToggleButtonWidth = 18;
static const CGFloat kTideyChromeToggleButtonHeight = 34;
static const CGFloat kTideySidebarBadgeSize = 16;
static NSString *const kTideyBundledMonacoVersion = @"0.52.2";
static NSString *const kTideyLastEditorFilePathDefaultsKey = @"TideyLastEditorFilePath";
static NSString *const kTideyLastEditorFileTreeRootDefaultsKey = @"TideyLastEditorFileTreeRoot";
static NSString *const kTideySidebarWidthDefaultsKey = @"TideySidebarWidth";
static NSString *const kTideyEditorPanelWidthDefaultsKey = @"TideyEditorPanelWidth";
static NSString *const kTideyEditorFileTreeWidthDefaultsKey = @"TideyEditorFileTreeWidth";
static NSString *const kTideySidebarVisibleDefaultsKey = @"TideySidebarVisible";
static NSString *const kTideyEditorPanelVisibleDefaultsKey = @"TideyEditorPanelVisible";
static NSString *const kTideyEditorFileTreeVisibleDefaultsKey = @"TideyEditorFileTreeVisible";
static NSString *const kTideyTerminalVisibleDefaultsKey = @"TideyTerminalVisible";
static NSUserInterfaceItemIdentifier const kTideySidebarCloseViewIdentifier = @"TideySidebarCloseView";
static NSUserInterfaceItemIdentifier const kTideySidebarBadgeViewIdentifier = @"TideySidebarBadgeView";
static NSPasteboardType const iTermRootTerminalViewTideySidebarWorkspacePasteboardType =
    @"com.tidey.workspace-row";

typedef struct {
    CGFloat top;
    CGFloat bottom;
} iTermDecorationHeights;

static NSView *TideyFindCloseView(NSView *container) {
    for (NSView *subview in container.subviews) {
        if ([subview.identifier isEqualToString:kTideySidebarCloseViewIdentifier]) {
            return subview;
        }
    }
    return nil;
}

static NSView *TideyFindSubviewWithIdentifier(NSView *container, NSUserInterfaceItemIdentifier identifier) {
    for (NSView *subview in container.subviews) {
        if ([subview.identifier isEqualToString:identifier]) {
            return subview;
        }
    }
    return nil;
}

static CGFloat TideyEditorEffectiveTabStripHeight(CGFloat terminalTabBarHeight) {
    if (terminalTabBarHeight > 0) {
        return round(terminalTabBarHeight);
    }
    return kTideyEditorTabStripHeight;
}

@class TideyEditorFileNode;
@class TideyEditorTab;

@interface iTermRootTerminalView()<
    iTermTabBarControlViewDelegate,
    iTermDragHandleViewDelegate,
    iTermGenericStatusBarContainer,
    iTermStoplightHotboxDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    WKNavigationDelegate>

@property(nonatomic, strong) PTYTabView *tabView;
@property(nonatomic, strong) iTermTabBarControlView *tabBarControl;
@property(nonatomic, strong) SolidColorView *divisionView;
@property(nonatomic, strong) iTermToolbeltView *toolbelt;
@property(nonatomic, strong) iTermDragHandleView *leftTabBarDragHandle;
@property(nonatomic, strong) iTermDragHandleView *tideySidebarDragHandle;
@property(nonatomic, strong) iTermDragHandleView *tideyEditorDragHandle;
@property(nonatomic, strong) iTermDragHandleView *tideyEditorFileTreeDragHandle;
@property(nonatomic, strong) NSButton *tideySidebarToggleButton;
@property(nonatomic, strong) NSButton *tideyTerminalToggleButton;
@property(nonatomic, strong) NSButton *tideyEditorToggleButton;
@property(nonatomic, strong) NSButton *tideyEditorFileTreeToggleButton;

- (CGFloat)tideySidebarWidth;
- (CGFloat)tideyEditorPanelWidth;
- (CGFloat)tideyEditorFileTreeWidth;
- (void)layoutTideySidebar;
- (void)layoutTideyEditorPanelWithOutputs:(iTermLayoutOutputs)outputs;
- (iTermLayoutOutputs)layoutOutputsByApplyingTideyChromeOffsets:(iTermLayoutOutputs)outputs;
- (void)updateTideyChromeDragHandles;
- (void)updateTideyChromeToggleButtons;
- (void)syncTideyEditorFileTreeRootIfNeeded;
- (void)ensureTideyEditorWebView;
- (void)loadTideyEditorShellIfNeeded;
- (void)tideyEditorLoadDemoFileIfNeeded;
- (BOOL)tideyEditorIsDemoFilePath:(NSString *)path;
- (void)tideyEditorLoadFileAtPath:(NSString *)path;
- (void)tideyOpenEditorFileAtPath:(NSString *)path preview:(BOOL)preview;
- (void)tideyOpenOrSelectEditorTabAtPath:(NSString *)path;
- (void)tideyRestoreEditorStateFromDefaults;
- (void)tideyPersistEditorState;
- (void)tideyRestoreLayoutStateFromDefaults;
- (void)tideyPersistLayoutState;
- (NSString *)tideyEditorLanguageForPath:(NSString *)path;
- (NSString *)tideyEditorPreferredRootPathForFileAtPath:(NSString *)path;
- (void)tideyEditorRevealFileAtPath:(NSString *)path;
- (void)tideyEditorSetValue:(NSString *)content;
- (void)tideyEditorSetLanguage:(NSString *)language;
- (void)tideyEditorSetEditable:(BOOL)editable;
- (void)tideyEditorApplyPendingStateIfReady;
- (void)tideyEditorDidBecomeReady;
- (void)tideyEditorDidReceiveScriptMessage:(WKScriptMessage *)message;
- (NSString *)tideyEditorHTML;
- (void)reloadTideyEditorFileTree;
- (NSString *)tideyEditorFileTreeRootPath;
- (void)layoutTideyEditorContents;
- (NSTableCellView *)newTideyEditorFileTreeCellView;
- (NSMenu *)tideyEditorFileTreeMenuForNode:(TideyEditorFileNode *)node;
- (NSMenuItem *)tideyEditorFileTreeMenuItemWithTitle:(NSString *)title
                                              action:(SEL)action
                                                path:(NSString *)path;
- (NSString *)tideyEditorRelativePathForPath:(NSString *)path;
- (void)tideyEditorCopyFileTreePath:(id)sender;
- (void)tideyEditorCopyFileTreeRelativePath:(id)sender;
- (void)tideyEditorOpenFileTreeItemInExternalEditor:(id)sender;
- (void)tideyEditorRevealFileTreeItemInFinder:(id)sender;
- (TideyEditorTab *)tideyCurrentEditorTab;
- (void)reloadTideyEditorTabs;
- (void)selectTideyEditorTabAtIndex:(NSInteger)index;
- (void)closeTideyEditorTabAtIndex:(NSInteger)index;
- (void)tideyEditorSelectTab:(id)sender;
- (void)tideyEditorCloseTab:(id)sender;
- (void)tideyEditorOpenSelectedFilePermanently:(id)sender;
- (void)tideyUpdateEditorPlaceholder;
- (void)tideyEditorDidChangeValue:(NSString *)value;
- (NSString *)tideyEditorDisplayNameForPath:(NSString *)path;
- (NSString *)tideySidebarWorkspaceTitleAtIndex:(NSInteger)index;
- (NSString *)tideySidebarWorkspaceSubtitleAtIndex:(NSInteger)index;
- (NSString *)tideySidebarWorkspaceIdentifierAtIndex:(NSInteger)index;
- (NSInteger)tideySidebarWorkspaceUnreadCountAtIndex:(NSInteger)index;
- (BOOL)tideySidebarWorkspacePinnedAtIndex:(NSInteger)index;
- (NSInteger)tideySidebarSelectedWorkspaceIndex;
- (void)syncTideySidebarSelection;
- (void)tideyNotificationStoreDidChange:(NSNotification *)notification;
- (NSInteger)tideySidebarWorkspaceIndexForIdentifier:(NSString *)workspaceIdentifier;
- (TideyNotificationItem *)tideySidebarLatestUnreadNotificationAtIndex:(NSInteger)index;
- (BOOL)tideySidebarHasReadNotificationsAtIndex:(NSInteger)index;
- (NSTableCellView *)newTideySidebarCellView;
- (void)configureTideySidebarCellView:(NSTableCellView *)cellView row:(NSInteger)row;
- (NSView *)tideySidebarDragPreviewForRow:(NSInteger)row width:(CGFloat)width height:(CGFloat)height;
- (NSImage *)tideySidebarDragPreviewImageForRow:(NSInteger)row width:(CGFloat)width height:(CGFloat)height;
- (NSMenu *)tideySidebarMenuForRow:(NSInteger)row;
- (NSMenuItem *)tideySidebarMenuItemWithTitle:(NSString *)title
                                       action:(SEL)action
                                          row:(NSInteger)row;
- (NSInteger)tideySidebarWorkspaceIndexFromSender:(id)sender;
- (void)tideySidebarNewWorkspace:(id)sender;
- (void)tideySidebarTogglePinnedWorkspace:(id)sender;
- (void)tideySidebarMarkWorkspaceRead:(id)sender;
- (void)tideySidebarMarkWorkspaceUnread:(id)sender;
- (void)tideySidebarRenameWorkspace:(id)sender;
- (void)tideySidebarRemoveCustomWorkspaceName:(id)sender;
- (void)tideySidebarMoveWorkspaceUp:(id)sender;
- (void)tideySidebarMoveWorkspaceDown:(id)sender;
- (void)tideySidebarMoveWorkspaceToTop:(id)sender;
- (void)tideySidebarCloseWorkspace:(id)sender;
- (void)tideySidebarCloseWorkspaceAtIndex:(NSInteger)row;
- (void)tideySidebarCloseOtherWorkspaces:(id)sender;
- (void)tideySidebarCloseWorkspacesAbove:(id)sender;
- (void)tideySidebarCloseWorkspacesBelow:(id)sender;

@end

NS_CLASS_AVAILABLE_MAC(10_14)
@interface iTermTabBarBacking : NSView<iTermTabBarControlViewContainer>
@property (nonatomic) BOOL hidesWhenTabBarHidden;
@property (nonatomic, readonly) NSVisualEffectView *visualEffectView;
@end

@implementation iTermTabBarBacking

- (instancetype)init {
    self = [super initWithFrame:NSMakeRect(0, 0, 100, 100)];
    if (self) {
        [self addWindowColorView];

        _visualEffectView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
        _visualEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSVisualEffectState state = NSVisualEffectStateActive;
        if (![iTermAdvancedSettingsModel allowTabbarInTitlebarAccessoryBigSur]) {
            if (@available(macOS 10.16, *)) {
                state = NSVisualEffectStateFollowsWindowActiveState;
            }
        }
        _visualEffectView.state = state;

        _visualEffectView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        _visualEffectView.material = NSVisualEffectMaterialTitlebar;
        [self addSubview:_visualEffectView];

        self.autoresizesSubviews = YES;
    }
    return self;
}

- (void)addWindowColorView {
    if (![iTermAdvancedSettingsModel allowTabbarInTitlebarAccessoryBigSur]) {
        if (@available(macOS 10.16, *)) {
            return;
        }
    }
    NSView *windowColorView = [[NSView alloc] initWithFrame:self.bounds];
    windowColorView.wantsLayer = YES;
    windowColorView.layer = [[CALayer alloc] init];
    windowColorView.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
    windowColorView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:windowColorView];
}

- (void)tabBarControlViewWillHide:(BOOL)hidden {
    if (_hidesWhenTabBarHidden || !hidden) {
        [self setHidden:hidden];
    }
}

@end

@protocol TideySidebarCloseAction <NSObject>
- (void)tideySidebarCloseWorkspaceAtIndex:(NSInteger)row;
@end

@interface TideySidebarTableView : NSTableView {
    NSTrackingArea *_tideyTrackingArea;
    NSInteger _tideyHoveredRow;
}
@property(nonatomic, weak) id<TideySidebarCloseAction> tideyCloseActionTarget;
- (void)updateTideyCloseButtonVisibility;
@end

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
    return NSMakeRect(NSMaxX(rowRect) - 24, NSMinY(rowRect) + 28, 16, 16);
}

- (void)updateTideyCloseButtonVisibility {
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

@interface TideySidebarRowView : NSTableRowView {
}
@end

@implementation TideySidebarRowView

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (!self.selectionHighlightStyle || !self.isSelected) {
        return;
    }
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 6, 4)
                                                         xRadius:8
                                                         yRadius:8];
    [[NSColor selectedContentBackgroundColor] setFill];
    [path fill];
}

- (BOOL)isEmphasized {
    return YES;
}

@end

@interface TideySidebarCellView : NSTableCellView
@end

@implementation TideySidebarCellView

@end

@interface TideyEditorTabItemView : NSView {
    NSTrackingArea *_trackingArea;
}
@property(nonatomic) BOOL tideySelected;
@property(nonatomic) BOOL tideyHovered;
@property(nonatomic, strong) NSView *tideyHoverView;
@property(nonatomic, strong) NSView *tideySelectionLineView;
@property(nonatomic, strong) NSView *tideySeparatorView;
- (void)tideyUpdateAppearance;
@end

@implementation TideyEditorTabItemView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _tideyHoverView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideyHoverView.wantsLayer = YES;
        _tideyHoverView.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.06].CGColor;
        _tideyHoverView.hidden = YES;
        [self addSubview:_tideyHoverView];

        _tideySelectionLineView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideySelectionLineView.wantsLayer = YES;
        _tideySelectionLineView.layer.backgroundColor = NSColor.controlAccentColor.CGColor;
        _tideySelectionLineView.hidden = YES;
        [self addSubview:_tideySelectionLineView];

        _tideySeparatorView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideySeparatorView.wantsLayer = YES;
        _tideySeparatorView.layer.backgroundColor = [NSColor colorWithWhite:0.25 alpha:1].CGColor;
        [self addSubview:_tideySeparatorView];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                 options:(NSTrackingActiveInKeyWindow |
                                                          NSTrackingInVisibleRect |
                                                          NSTrackingMouseEnteredAndExited)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    self.tideyHovered = YES;
    [self tideyUpdateAppearance];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    self.tideyHovered = NO;
    [self tideyUpdateAppearance];
}

- (void)layout {
    [super layout];
    _tideyHoverView.frame = self.bounds;
    _tideySelectionLineView.frame = NSMakeRect(0, 0, NSWidth(self.bounds), 2);
    _tideySeparatorView.frame = NSMakeRect(NSWidth(self.bounds) - 1, 6, 1, MAX(0, NSHeight(self.bounds) - 12));
}

- (void)tideyUpdateAppearance {
    _tideySelectionLineView.hidden = !_tideySelected;
    _tideyHoverView.hidden = (_tideySelected || !_tideyHovered);
    _tideyHoverView.alphaValue = _tideyHoverView.hidden ? 0 : 1;
}

@end

@class iTermRootTerminalView;

@interface TideyEditorScriptMessageHandler : NSObject<WKScriptMessageHandler>
@property(nonatomic, weak) iTermRootTerminalView *rootView;
@end

@implementation TideyEditorScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.rootView tideyEditorDidReceiveScriptMessage:message];
}

@end

@interface TideyEditorFileNode : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic) BOOL directory;
@property(nonatomic) BOOL childrenLoaded;
@property(nonatomic, strong) NSArray<TideyEditorFileNode *> *children;
+ (instancetype)nodeWithPath:(NSString *)path displayName:(NSString *)displayName directory:(BOOL)directory;
- (NSArray<TideyEditorFileNode *> *)loadChildren;
@end

@implementation TideyEditorFileNode

+ (instancetype)nodeWithPath:(NSString *)path displayName:(NSString *)displayName directory:(BOOL)directory {
    TideyEditorFileNode *node = [[self alloc] init];
    node.path = path;
    node.displayName = displayName.length ? displayName : path.lastPathComponent;
    node.directory = directory;
    node.children = @[];
    return node;
}

- (NSArray<TideyEditorFileNode *> *)loadChildren {
    if (!self.directory) {
        return @[];
    }
    if (self.childrenLoaded) {
        return self.children;
    }
    self.childrenLoaded = YES;

    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.path]
                                                            includingPropertiesForKeys:@[ NSURLIsDirectoryKey, NSURLNameKey ]
                                                                               options:(NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants)
                                                                                 error:nil];
    NSMutableArray<TideyEditorFileNode *> *children = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSNumber *isDirectory = nil;
        NSString *name = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        [url getResourceValue:&name forKey:NSURLNameKey error:nil];
        [children addObject:[TideyEditorFileNode nodeWithPath:url.path
                                                  displayName:name
                                                    directory:isDirectory.boolValue]];
    }
    [children sortUsingComparator:^NSComparisonResult(TideyEditorFileNode *lhs, TideyEditorFileNode *rhs) {
        if (lhs.directory != rhs.directory) {
            return lhs.directory ? NSOrderedAscending : NSOrderedDescending;
        }
        return [lhs.displayName localizedCaseInsensitiveCompare:rhs.displayName];
    }];
    self.children = children;
    return self.children;
}

@end

@interface TideyEditorTab : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *language;
@property(nonatomic, copy) NSString *content;
@property(nonatomic) BOOL dirty;
@property(nonatomic) BOOL preview;
+ (instancetype)tabWithPath:(NSString *)path
                displayName:(NSString *)displayName
                   language:(NSString *)language
                    content:(NSString *)content;
@end

@implementation TideyEditorTab

+ (instancetype)tabWithPath:(NSString *)path
                displayName:(NSString *)displayName
                   language:(NSString *)language
                    content:(NSString *)content {
    TideyEditorTab *tab = [[self alloc] init];
    tab.path = path;
    tab.displayName = displayName;
    tab.language = language ?: @"plaintext";
    tab.content = content ?: @"";
    tab.dirty = NO;
    return tab;
}

@end

@implementation iTermRootTerminalView {
    BOOL _tabViewFrameReduced;
    BOOL _haveShownToolbelt;
    iTermStoplightHotbox *_stoplightHotbox;
    iTermStandardWindowButtonsView *_standardWindowButtonsView;
    NSMutableDictionary<NSNumber *, NSButton *> *_standardButtons;
    NSString *_windowTitle;
    NSNumber *_windowNumber;
    NSTextField *_windowNumberLabel;
    iTermFakeWindowTitleLabel *_windowTitleLabel;
    iTermTabBarBacking *_tabBarBacking NS_AVAILABLE_MAC(10_14);
    iTermGenericStatusBarContainer *_statusBarContainer;
    NSDictionary *_desiredToolbeltProportions;
    iTermWindowSizeView *_windowSizeView NS_AVAILABLE_MAC(10_14);
    NSView *_tideySidebarView;
    NSScrollView *_tideySidebarScrollView;
    NSTableView *_tideySidebarTableView;
    NSView *_tideyEditorPanelView;
    NSTextField *_tideyEditorPanelLabel;
    NSView *_tideyEditorTabStripView;
    WKWebView *_tideyEditorWebView;
    NSView *_tideyEditorFileTreeContainerView;
    NSScrollView *_tideyEditorFileTreeScrollView;
    NSOutlineView *_tideyEditorFileTreeView;
    TideyEditorFileNode *_tideyEditorFileTreeRootNode;
    TideyEditorScriptMessageHandler *_tideyEditorScriptMessageHandler;
    BOOL _tideyEditorShellLoaded;
    BOOL _tideyEditorReady;
    BOOL _tideyEditorLoadedDemoFile;
    NSString *_tideyEditorPendingValue;
    NSString *_tideyEditorPendingLanguage;
    NSNumber *_tideyEditorPendingEditable;
    NSString *_tideyEditorLoadedPath;
    NSString *_tideyEditorCurrentRootPath;
    NSString *_tideyEditorRootOverridePath;
    NSMutableArray<TideyEditorTab *> *_tideyEditorTabs;
    NSInteger _tideySelectedEditorTabIndex;
    BOOL _tideyEditorIsRevealingSelection;
    BOOL _tideyIgnoreNextSidebarSelection;
    CGFloat _tideySidebarPreferredWidth;
    CGFloat _tideyEditorPreferredWidth;
    CGFloat _tideyEditorPreferredWidthBeforeTerminalCollapse;
    CGFloat _tideyEditorFileTreePreferredWidth;

    iTermLayerBackedSolidColorView *_titleBackgroundView NS_AVAILABLE_MAC(10_14);
    
    NSImageView *_topLeftCornerHalfRoundImageView NS_AVAILABLE_MAC(10_14);
    NSImageView *_topRightCornerHalfRoundImageView NS_AVAILABLE_MAC(10_14);
    NSImageView *_bottomLeftCornerHalfRoundImageView NS_AVAILABLE_MAC(10_14);
    NSImageView *_bottomRightCornerHalfRoundImageView NS_AVAILABLE_MAC(10_14);

    NSImageView *_topLeftCornerFullRoundImageView NS_AVAILABLE_MAC(10_14);
    NSImageView *_topRightCornerFullRoundImageView NS_AVAILABLE_MAC(10_14);
    NSImageView *_bottomLeftCornerFullRoundImageView NS_AVAILABLE_MAC(10_14);
    NSImageView *_bottomRightCornerFullRoundImageView NS_AVAILABLE_MAC(10_14);

    NSView *_leftBorderView NS_AVAILABLE_MAC(10_14);
    NSView *_rightBorderView NS_AVAILABLE_MAC(10_14);
    NSView *_topBorderView NS_AVAILABLE_MAC(10_14);
    NSView *_bottomBorderView NS_AVAILABLE_MAC(10_14);
    
    iTermImageView *_backgroundImage NS_AVAILABLE_MAC(10_14);
    NSView *_workaroundView;  // 10.14 only. See issue 8701.
    iTermLayerBackedSolidColorView *_notchMask NS_AVAILABLE_MAC(12_0);
}

- (NSButton *)newTideyChromeToggleButtonWithAction:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0,
                                                                  kTideyChromeToggleButtonWidth,
                                                                  kTideyChromeToggleButtonHeight)];
    button.bordered = NO;
    button.buttonType = NSButtonTypeMomentaryPushIn;
    button.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    button.focusRingType = NSFocusRingTypeNone;
    button.alignment = NSTextAlignmentCenter;
    button.wantsLayer = YES;
    button.layer.cornerRadius = 7;
    button.layer.backgroundColor = NSColor.clearColor.CGColor;
    button.contentTintColor = [NSColor colorWithWhite:0.50 alpha:0.25];
    button.alphaValue = 1.0;
    button.target = _delegate;
    button.action = action;
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
               owner:self
            userInfo:@{@"tideyToggleButton": button}];
    [button addTrackingArea:trackingArea];
    return button;
}

- (void)mouseEntered:(NSEvent *)event {
    NSButton *button = event.trackingArea.userInfo[@"tideyToggleButton"];
    if (button) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.15;
            button.animator.contentTintColor = [NSColor colorWithWhite:0.92 alpha:1.0];
        }];
        return;
    }
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event {
    NSButton *button = event.trackingArea.userInfo[@"tideyToggleButton"];
    if (button) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.3;
            button.animator.contentTintColor = [NSColor colorWithWhite:0.50 alpha:0.25];
        }];
        return;
    }
    [super mouseExited:event];
}

- (instancetype)initWithFrame:(NSRect)frameRect
                        color:(NSColor *)color
               tabBarDelegate:(id<iTermTabBarControlViewDelegate,PSMTabBarControlDelegate>)tabBarDelegate
                     delegate:(id<iTermRootTerminalViewDelegate, iTermToolbeltViewDelegate>)delegate {
    self = [super initWithFrame:frameRect color:color];
    if (self) {
        _delegate = delegate;
        _shouldShowTideySidebar = YES;
        _shouldShowTideyTerminal = YES;
        _shouldShowTideyEditorPanel = NO;
        _shouldShowTideyEditorFileTree = YES;
        _tideyEditorTabs = [[NSMutableArray alloc] init];
        _tideySelectedEditorTabIndex = -1;
        _tideySidebarPreferredWidth = kTideySidebarWidth;
        _tideyEditorFileTreePreferredWidth = kTideyEditorFileTreeWidth;
        _tideyEditorPreferredWidth = MAX(kTideyMinimumEditorPanelWidth,
                                         floor(NSWidth(frameRect) / 2.0));
        _tideyEditorPreferredWidthBeforeTerminalCollapse = _tideyEditorPreferredWidth;
        [self tideyRestoreEditorStateFromDefaults];
        [self tideyRestoreLayoutStateFromDefaults];

        self.autoresizesSubviews = YES;
        _leftTabBarPreferredWidth = round([iTermPreferences doubleForKey:kPreferenceKeyLeftTabBarWidth]);
        [self setLeftTabBarWidthFromPreferredWidth];

        _backgroundImage = [[iTermImageView alloc] init];
        _backgroundImage.frame = self.bounds;
        _backgroundImage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _backgroundImage.hidden = YES;
        [self addSubview:_backgroundImage];

        _tideySidebarView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideySidebarView.autoresizingMask = NSViewHeightSizable;
        _tideySidebarView.wantsLayer = YES;
        _tideySidebarView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11
                                                                      green:0.12
                                                                       blue:0.15
                                                                      alpha:1].CGColor;
        [self addSubview:_tideySidebarView];

        _tideySidebarScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _tideySidebarScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _tideySidebarScrollView.drawsBackground = NO;
        _tideySidebarScrollView.hasVerticalScroller = YES;
        _tideySidebarScrollView.borderType = NSNoBorder;

        TideySidebarTableView *sidebarTableView = [[TideySidebarTableView alloc] initWithFrame:NSZeroRect];
        sidebarTableView.delegate = self;
        sidebarTableView.dataSource = self;
        sidebarTableView.headerView = nil;
        sidebarTableView.focusRingType = NSFocusRingTypeNone;
        sidebarTableView.tideyCloseActionTarget = (id<TideySidebarCloseAction>)self;
        _tideySidebarTableView = sidebarTableView;
        if (@available(macOS 11.0, *)) {
            _tideySidebarTableView.style = NSTableViewStyleSourceList;
        }
        _tideySidebarTableView.intercellSpacing = NSMakeSize(0, 0);
        _tideySidebarTableView.rowHeight = 60;
        [_tideySidebarTableView registerForDraggedTypes:@[ iTermRootTerminalViewTideySidebarWorkspacePasteboardType ]];
        [_tideySidebarTableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];

        NSTableColumn *sidebarColumn = [[NSTableColumn alloc] initWithIdentifier:@"TideySidebarColumn"];
        sidebarColumn.resizingMask = NSTableColumnAutoresizingMask;
        [_tideySidebarTableView addTableColumn:sidebarColumn];

        _tideySidebarScrollView.documentView = _tideySidebarTableView;
        [_tideySidebarView addSubview:_tideySidebarScrollView];

        [_tideySidebarTableView reloadData];
        [self layoutTideySidebar];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(tideyNotificationStoreDidChange:)
                                                     name:TideyNotificationStoreDidChangeNotification
                                                   object:[TideyNotificationStore sharedStore]];

        _tideyEditorPanelView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideyEditorPanelView.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
        _tideyEditorPanelView.wantsLayer = YES;
        _tideyEditorPanelView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.10
                                                                          green:0.11
                                                                           blue:0.14
                                                                          alpha:1].CGColor;
        _tideyEditorPanelView.hidden = YES;
        [self addSubview:_tideyEditorPanelView];

        _tideyEditorTabStripView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideyEditorTabStripView.autoresizingMask = NSViewWidthSizable;
        _tideyEditorTabStripView.wantsLayer = YES;
        _tideyEditorTabStripView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.09
                                                                             green:0.10
                                                                              blue:0.13
                                                                             alpha:1].CGColor;
        [_tideyEditorPanelView addSubview:_tideyEditorTabStripView];

        _tideyEditorPanelLabel = [NSTextField labelWithString:@"Loading Editor…"];
        _tideyEditorPanelLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1];
        _tideyEditorPanelLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
        _tideyEditorPanelLabel.alignment = NSTextAlignmentCenter;
        _tideyEditorPanelLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_tideyEditorPanelView addSubview:_tideyEditorPanelLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_tideyEditorPanelLabel.centerXAnchor constraintEqualToAnchor:_tideyEditorPanelView.centerXAnchor],
            [_tideyEditorPanelLabel.centerYAnchor constraintEqualToAnchor:_tideyEditorPanelView.centerYAnchor]
        ]];

        _tideyEditorFileTreeContainerView = [[NSView alloc] initWithFrame:NSZeroRect];
        _tideyEditorFileTreeContainerView.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
        _tideyEditorFileTreeContainerView.wantsLayer = YES;
        _tideyEditorFileTreeContainerView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.12
                                                                                      green:0.13
                                                                                       blue:0.17
                                                                                      alpha:1].CGColor;
        [_tideyEditorPanelView addSubview:_tideyEditorFileTreeContainerView];

        _tideyEditorFileTreeScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _tideyEditorFileTreeScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _tideyEditorFileTreeScrollView.drawsBackground = NO;
        _tideyEditorFileTreeScrollView.hasVerticalScroller = YES;
        _tideyEditorFileTreeScrollView.borderType = NSNoBorder;
        [_tideyEditorFileTreeContainerView addSubview:_tideyEditorFileTreeScrollView];

        _tideyEditorFileTreeView = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
        _tideyEditorFileTreeView.delegate = self;
        _tideyEditorFileTreeView.dataSource = self;
        _tideyEditorFileTreeView.headerView = nil;
        _tideyEditorFileTreeView.focusRingType = NSFocusRingTypeNone;
        if (@available(macOS 11.0, *)) {
            _tideyEditorFileTreeView.style = NSTableViewStyleSourceList;
        }
        _tideyEditorFileTreeView.rowHeight = 22;
        _tideyEditorFileTreeView.indentationPerLevel = 12;
        _tideyEditorFileTreeView.autoresizesOutlineColumn = YES;
        _tideyEditorFileTreeView.target = self;
        _tideyEditorFileTreeView.doubleAction = @selector(tideyEditorOpenSelectedFilePermanently:);
        NSTableColumn *fileTreeColumn = [[NSTableColumn alloc] initWithIdentifier:@"TideyEditorFileTreeColumn"];
        fileTreeColumn.resizingMask = NSTableColumnAutoresizingMask;
        [_tideyEditorFileTreeView addTableColumn:fileTreeColumn];
        _tideyEditorFileTreeView.outlineTableColumn = fileTreeColumn;
        _tideyEditorFileTreeScrollView.documentView = _tideyEditorFileTreeView;
        [self reloadTideyEditorFileTree];

        self.tideySidebarDragHandle = [[iTermDragHandleView alloc] initWithFrame:NSZeroRect];
        self.tideySidebarDragHandle.delegate = self;
        [self addSubview:self.tideySidebarDragHandle];

        self.tideyEditorDragHandle = [[iTermDragHandleView alloc] initWithFrame:NSZeroRect];
        self.tideyEditorDragHandle.delegate = self;
        [self addSubview:self.tideyEditorDragHandle];

        self.tideyEditorFileTreeDragHandle = [[iTermDragHandleView alloc] initWithFrame:NSZeroRect];
        self.tideyEditorFileTreeDragHandle.delegate = self;
        [_tideyEditorPanelView addSubview:self.tideyEditorFileTreeDragHandle];

        self.tideySidebarToggleButton = [self newTideyChromeToggleButtonWithAction:@selector(toggleTideySidebar:)];
        [self addSubview:self.tideySidebarToggleButton];

        self.tideyTerminalToggleButton = [self newTideyChromeToggleButtonWithAction:@selector(toggleTideyTerminal:)];
        [self addSubview:self.tideyTerminalToggleButton];

        self.tideyEditorToggleButton = [self newTideyChromeToggleButtonWithAction:@selector(toggleTideyEditorPanel:)];
        [self addSubview:self.tideyEditorToggleButton];

        self.tideyEditorFileTreeToggleButton = [self newTideyChromeToggleButtonWithAction:@selector(toggleTideyEditorFileTree:)];
        [_tideyEditorPanelView addSubview:self.tideyEditorFileTreeToggleButton];

        // Create the tab view.
        self.tabView = [[PTYTabView alloc] initWithFrame:self.bounds];
        self.tabView.drawsBackground = NO;
        _tabView.autoresizingMask = (NSViewWidthSizable | NSViewHeightSizable);
        _tabView.autoresizesSubviews = YES;
        _tabView.allowsTruncatedLabels = NO;
        _tabView.controlSize = NSControlSizeSmall;
        _tabView.tabViewType = NSNoTabsNoBorder;
        _tabView.swipeHandler = delegate;
        [self addSubview:_tabView];
        [self addSubview:self.tideySidebarDragHandle positioned:NSWindowAbove relativeTo:_tabView];
        [self addSubview:self.tideyEditorDragHandle positioned:NSWindowAbove relativeTo:_tabView];
        [self addSubview:self.tideySidebarToggleButton positioned:NSWindowAbove relativeTo:_tabView];
        [self addSubview:self.tideyTerminalToggleButton positioned:NSWindowAbove relativeTo:_tabView];
        [self addSubview:self.tideyEditorToggleButton positioned:NSWindowAbove relativeTo:_tabView];
        [_tideyEditorPanelView addSubview:self.tideyEditorFileTreeDragHandle positioned:NSWindowAbove relativeTo:nil];
        [_tideyEditorPanelView addSubview:self.tideyEditorFileTreeToggleButton positioned:NSWindowAbove relativeTo:nil];

        // Create the tab bar.
        NSRect tabBarFrame = self.bounds;
        tabBarFrame.size.height = _tabBarControl.height;
        _tabBarBacking = [[iTermTabBarBacking alloc] init];
        _tabBarBacking.hidesWhenTabBarHidden = [delegate rootTerminalViewShouldHideTabBarBackingWhenTabBarIsHidden];
        _tabBarBacking.autoresizesSubviews = YES;

        self.tabBarControl = [[iTermTabBarControlView alloc] initWithFrame:tabBarFrame];
        self.tabBarControl.height = [delegate rootTerminalViewHeightOfTabBar:self];

        _tabBarControl.itermTabBarDelegate = self;

        NSRect stoplightFrame = NSMakeRect(0,
                                           0,
                                           iTermStoplightHotboxWidth,
                                           iTermStoplightHotboxHeight);
        _stoplightHotbox = [[iTermStoplightHotbox alloc] initWithFrame:stoplightFrame];
        [self addSubview:_stoplightHotbox];
        _stoplightHotbox.hidden = YES;
        _stoplightHotbox.delegate = self;
        
        NSUInteger theModifier =
            [iTermPreferences maskForModifierTag:[iTermPreferences intForKey:kPreferenceKeySwitchTabModifier]];
        if (theModifier == NSUIntegerMax) {
            theModifier = 0;
        }
        [_tabBarControl setModifier:theModifier];
        _tabBarControl.insets = [self.delegate tabBarInsets];
        switch ([iTermPreferences intForKey:kPreferenceKeyTabPosition]) {
            case PSMTab_BottomTab:
                _tabBarControl.orientation = PSMTabBarHorizontalOrientation;
                [self setTabBarControlAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
                break;

            case PSMTab_TopTab:
                _tabBarControl.orientation = PSMTabBarHorizontalOrientation;
                [self setTabBarControlAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
                break;

            case PSMTab_LeftTab:
                _tabBarControl.orientation = PSMTabBarVerticalOrientation;
                [self setTabBarControlAutoresizingMask:(NSViewHeightSizable | NSViewMaxXMargin)];
                break;
        }
        [self addSubview:_tabBarBacking];
        [_tabBarBacking addSubview:_tabBarControl];
        _tabBarControl.tabView = _tabView;
        [_tabView setDelegate:_tabBarControl];
        _tabBarControl.delegate = tabBarDelegate;
        _tabBarControl.hideForSingleTab = NO;

        // Create the toolbelt with its current default size.
        _toolbeltWidth = [iTermPreferences floatForKey:kPreferenceKeyDefaultToolbeltWidth];

        self.toolbelt = [[iTermToolbeltView alloc] initWithFrame:[self toolbeltFrameInWindow:nil]
                                                        delegate:(id)_delegate];
        // Wait until whoever is creating the window sets it to its proper size before laying out the toolbelt.
        // The hope is that the window controller will call updateToolbeltProportionsIfNeeded during this spin
        // of the runloop, but if not we'll get it next time 'round.
        [self setToolbeltProportions:[iTermToolbeltView savedProportions]];
        _toolbelt.autoresizingMask = (NSViewMinXMargin | NSViewHeightSizable);
        [self addSubview:_toolbelt];
        [self updateToolbeltForWindow:nil];

        _windowNumberLabel = [NSTextField newLabelStyledTextField];
        if (@available(macOS 10.16, *)) {
            _windowNumberLabel.font = [NSFont titleBarFontOfSize:[NSFont systemFontSize]];
        }
        _windowNumberLabel.alphaValue = 0.75;
        _windowNumberLabel.hidden = YES;
        _windowNumberLabel.autoresizingMask = (NSViewMaxXMargin | NSViewMinYMargin);
        [self addSubview:_windowNumberLabel];

        _windowTitleLabel = [iTermFakeWindowTitleLabel newLabelStyledTextField];
        if (@available(macOS 10.16, *)) {
            _windowTitleLabel.font = [NSFont titleBarFontOfSize:[NSFont systemFontSize]];
        }
        _windowTitleLabel.alphaValue = 1;
        _windowTitleLabel.alignment = NSTextAlignmentCenter;
        _windowTitleLabel.hidden = YES;
        _windowTitleLabel.autoresizingMask = (NSViewMinYMargin | NSViewWidthSizable);
        [self addSubview:_windowTitleLabel];
        
        NSColor *borderColor = [NSColor colorWithWhite:0.5 alpha:0.75];
        {
            static NSImage *gTopLeftCornerHalfImage;
            static NSImage *gTopRightCornerHalfImage;
            static NSImage *gBottomLeftCornerHalfImage;
            static NSImage *gBottomRightCornerHalfImage;

            static NSImage *gTopLeftCornerFullImage;
            static NSImage *gTopRightCornerFullImage;
            static NSImage *gBottomLeftCornerFullImage;
            static NSImage *gBottomRightCornerFullImage;

            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                NSString *halfName = @"WindowCorner";
                if (@available(macOS 10.16, *)) {
                    halfName = @"WindowCorner_BigSur";
                }
                if ([iTermAdvancedSettingsModel squareWindowCorners]) {
                    halfName = @"WindowCorner_Square";
                }
                gTopLeftCornerHalfImage = [[NSImage it_imageNamed:halfName forClass:self.class] it_verticallyFlippedImage];
                gTopRightCornerHalfImage = [gTopLeftCornerHalfImage it_horizontallyFlippedImage];
                gBottomLeftCornerHalfImage = [NSImage it_imageNamed:halfName forClass:self.class];
                gBottomRightCornerHalfImage = [gBottomLeftCornerHalfImage it_horizontallyFlippedImage];

                NSString *fullName = @"WindowCornerFull";
                if (@available(macOS 10.16, *)) {
                    fullName = @"WindowCornerFull_BigSur";
                }
                if ([iTermAdvancedSettingsModel squareWindowCorners]) {
                    fullName = @"WindowCornerFull_Square";
                }
                gTopLeftCornerFullImage = [[NSImage it_imageNamed:fullName forClass:self.class] it_verticallyFlippedImage];
                gTopRightCornerFullImage = [gTopLeftCornerFullImage it_horizontallyFlippedImage];
                gBottomLeftCornerFullImage = [NSImage it_imageNamed:fullName forClass:self.class];
                gBottomRightCornerFullImage = [gBottomLeftCornerFullImage it_horizontallyFlippedImage];
            });
            // Half
            NSImage *topLeftCornerHalfImage = gTopLeftCornerHalfImage;
            NSImage *topRightCornerHalfImage = gTopRightCornerHalfImage;
            NSImage *bottomLeftCornerHalfImage = gBottomLeftCornerHalfImage;
            NSImage *bottomRightCornerHalfImage = gBottomRightCornerHalfImage;

            _topLeftCornerHalfRoundImageView = [NSImageView imageViewWithImage:topLeftCornerHalfImage];
            _topLeftCornerHalfRoundImageView.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
            _topLeftCornerHalfRoundImageView.alphaValue = 0.75;

            _topRightCornerHalfRoundImageView = [NSImageView imageViewWithImage:topRightCornerHalfImage];
            _topRightCornerHalfRoundImageView.alphaValue = 0.75;
            _topRightCornerHalfRoundImageView.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;

            _bottomLeftCornerHalfRoundImageView = [NSImageView imageViewWithImage:bottomLeftCornerHalfImage];
            _bottomLeftCornerHalfRoundImageView.alphaValue = 0.75;
            _bottomLeftCornerHalfRoundImageView.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;

            _bottomRightCornerHalfRoundImageView = [NSImageView imageViewWithImage:bottomRightCornerHalfImage];
            _bottomRightCornerHalfRoundImageView.alphaValue = 0.75;
            _bottomRightCornerHalfRoundImageView.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;

            _topLeftCornerHalfRoundImageView.hidden = YES;
            _topRightCornerHalfRoundImageView.hidden = YES;
            _bottomLeftCornerHalfRoundImageView.hidden = YES;
            _bottomRightCornerHalfRoundImageView.hidden = YES;

            [self addSubview:_topLeftCornerHalfRoundImageView];
            [self addSubview:_topRightCornerHalfRoundImageView];
            [self addSubview:_bottomLeftCornerHalfRoundImageView];
            [self addSubview:_bottomRightCornerHalfRoundImageView];

            // Full

            NSImage *topLeftCornerFullImage = gTopLeftCornerFullImage;
            NSImage *topRightCornerFullImage = gTopRightCornerFullImage;
            NSImage *bottomLeftCornerFullImage = gBottomLeftCornerFullImage;
            NSImage *bottomRightCornerFullImage = gBottomRightCornerFullImage;

            _topLeftCornerFullRoundImageView = [NSImageView imageViewWithImage:topLeftCornerFullImage];
            _topLeftCornerFullRoundImageView.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
            _topLeftCornerFullRoundImageView.alphaValue = 0.75;

            _topRightCornerFullRoundImageView = [NSImageView imageViewWithImage:topRightCornerFullImage];
            _topRightCornerFullRoundImageView.alphaValue = 0.75;
            _topRightCornerFullRoundImageView.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;

            _bottomLeftCornerFullRoundImageView = [NSImageView imageViewWithImage:bottomLeftCornerFullImage];
            _bottomLeftCornerFullRoundImageView.alphaValue = 0.75;
            _bottomLeftCornerFullRoundImageView.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;

            _bottomRightCornerFullRoundImageView = [NSImageView imageViewWithImage:bottomRightCornerFullImage];
            _bottomRightCornerFullRoundImageView.alphaValue = 0.75;
            _bottomRightCornerFullRoundImageView.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;

            _topLeftCornerFullRoundImageView.hidden = YES;
            _topRightCornerFullRoundImageView.hidden = YES;
            _bottomLeftCornerFullRoundImageView.hidden = YES;
            _bottomRightCornerFullRoundImageView.hidden = YES;

            [self addSubview:_topLeftCornerFullRoundImageView];
            [self addSubview:_topRightCornerFullRoundImageView];
            [self addSubview:_bottomLeftCornerFullRoundImageView];
            [self addSubview:_bottomRightCornerFullRoundImageView];
        }
        {
            _leftBorderView = [[NSView alloc] init];
            _leftBorderView.wantsLayer = YES;
            _leftBorderView.layer.backgroundColor = borderColor.CGColor;
            _leftBorderView.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;

            _rightBorderView = [[NSView alloc] init];
            _rightBorderView.wantsLayer = YES;
            _rightBorderView.layer.backgroundColor = borderColor.CGColor;
            _rightBorderView.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;

            _topBorderView = [[NSView alloc] init];
            _topBorderView.wantsLayer = YES;
            _topBorderView.layer.backgroundColor = borderColor.CGColor;
            _topBorderView.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;

            _bottomBorderView = [[NSView alloc] init];
            _bottomBorderView.wantsLayer = YES;
            _bottomBorderView.layer.backgroundColor = borderColor.CGColor;
            _bottomBorderView.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable;

            [self addSubview:_leftBorderView];
            [self addSubview:_rightBorderView];
            [self addSubview:_topBorderView];
            [self addSubview:_bottomBorderView];
        }


        if (@available(macOS 10.15, *)) {} else {
            // 10.14 only
            _workaroundView = [[SolidColorView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1) color:[NSColor clearColor]];
            [self addSubview:_workaroundView];
        }
        if (@available(macOS 12.0, *)) {
            _notchMask = [[iTermLayerBackedSolidColorView alloc] initWithFrame:NSMakeRect(0, 0, 0, 0) color:[NSColor blackColor]];
            _notchMask.hidden = YES;
            [self addSubview:_notchMask];
        }
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:TideyNotificationStoreDidChangeNotification
                                                  object:[TideyNotificationStore sharedStore]];
    _tabBarControl.itermTabBarDelegate = nil;
    _tabBarControl.delegate = nil;
    _leftTabBarDragHandle.delegate = nil;
    _tideySidebarDragHandle.delegate = nil;
    _tideyEditorDragHandle.delegate = nil;
    _tideyEditorFileTreeDragHandle.delegate = nil;
    [_tideyEditorWebView.configuration.userContentController removeScriptMessageHandlerForName:@"tideyEditorReady"];
    _tideyEditorWebView.navigationDelegate = nil;
}

- (void)setDelegate:(id<iTermRootTerminalViewDelegate>)delegate {
    _delegate = delegate;
    _tabView.swipeHandler = delegate;
}

- (void)invalidateAutomaticTabBarBackingHiding {
    _tabBarBacking.hidesWhenTabBarHidden = [self.delegate rootTerminalViewShouldHideTabBarBackingWhenTabBarIsHidden];
    if (_tabBarControl.isHidden) {
        _tabBarBacking.hidden = _tabBarBacking.hidesWhenTabBarHidden;
    }
}

- (NSView *)hitTest:(NSPoint)point {
    NSView *view = [super hitTest:point];
    if (!_tabBarControlOnLoan && !_windowNumberLabel.hidden && view == _windowNumberLabel && !_tabBarControl.isHidden) {
        return _tabBarControl;
    } else if (!_windowTitleLabel.hidden && view == _windowTitleLabel) {
        return self;
    } else {
        return view;
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (!_windowTitleLabel.hidden && event.clickCount == 2) {
        const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        const CGFloat titleBarHeight = _tabBarControl.height;
        NSRect rect = NSMakeRect(0, self.bounds.size.height - titleBarHeight, self.bounds.size.width, titleBarHeight);
        if (NSPointInRect(point, rect)) {
            [self.window it_titleBarDoubleClick];
        }
    }
    [super mouseUp:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (_tideySidebarView && !_tideySidebarView.hidden) {
        const NSPoint pointInTable = [_tideySidebarTableView convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(pointInTable, _tideySidebarTableView.bounds)) {
            NSInteger row = [_tideySidebarTableView rowAtPoint:pointInTable];
            if (row >= 0) {
                _tideyIgnoreNextSidebarSelection = YES;
                [_tideySidebarTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                   byExtendingSelection:NO];
            }
            return [self tideySidebarMenuForRow:row];
        }
    }
    if (_tideyEditorPanelView && !_tideyEditorPanelView.hidden) {
        const NSPoint pointInFileTree = [_tideyEditorFileTreeView convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(pointInFileTree, _tideyEditorFileTreeView.bounds)) {
            NSInteger row = [_tideyEditorFileTreeView rowAtPoint:pointInFileTree];
            if (row >= 0) {
                [_tideyEditorFileTreeView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                      byExtendingSelection:NO];
                TideyEditorFileNode *node = [_tideyEditorFileTreeView itemAtRow:row];
                return [self tideyEditorFileTreeMenuForNode:node];
            }
            return nil;
        }
    }
    if (_windowTitleLabel.hidden) {
        return nil;
    }
    return [_tabBarControl menuForEvent:event];
}

- (BOOL)mouseDownCanMoveWindow {
    return YES;
}

- (CGFloat)leftInsetForWindowButtons {
    if (@available(macOS 26, *)) {
        const iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
        switch (preferredStyle) {
            case TAB_STYLE_MINIMAL:
                return 2.5;
            case TAB_STYLE_COMPACT:
                return 6 + 3;
            case TAB_STYLE_DARK:
            case TAB_STYLE_LIGHT:
            case TAB_STYLE_AUTOMATIC:
            case TAB_STYLE_DARK_HIGH_CONTRAST:
            case TAB_STYLE_LIGHT_HIGH_CONTRAST:
                break;
        }
    }
    return 6;
}

- (CGFloat)widthForStandardButtonsView {
    if (@available(macOS 26, *)) {
        const iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
        switch (preferredStyle) {
            case TAB_STYLE_COMPACT:
                return iTermStandardButtonsViewWidth + 3;
            case TAB_STYLE_MINIMAL:
            case TAB_STYLE_DARK:
            case TAB_STYLE_LIGHT:
            case TAB_STYLE_AUTOMATIC:
            case TAB_STYLE_DARK_HIGH_CONTRAST:
            case TAB_STYLE_LIGHT_HIGH_CONTRAST:
                break;
        }
    }
    return iTermStandardButtonsViewWidth;
}

- (CGFloat)strideForWindowButtons {
    if (@available(macOS 26, *)) {
        const iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
        switch (preferredStyle) {
            case TAB_STYLE_MINIMAL:
                return 23;
            case TAB_STYLE_COMPACT:
            case TAB_STYLE_DARK:
            case TAB_STYLE_LIGHT:
            case TAB_STYLE_AUTOMATIC:
            case TAB_STYLE_DARK_HIGH_CONTRAST:
            case TAB_STYLE_LIGHT_HIGH_CONTRAST:
                break;
        }
    }
    return 20;
}

- (NSEdgeInsets)insetsForStoplightHotbox {
    if (![self.delegate enableStoplightHotbox]) {
        NSEdgeInsets insets = NSEdgeInsetsZero;
        const iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
        insets.bottom = -[self.delegate rootTerminalViewStoplightButtonsOffset:self];
        switch (preferredStyle) {
            case TAB_STYLE_MINIMAL:
                if (@available(macOS 26, *)) {
                    // Use fixed value on macOS 26 regardless of tab bar height.
                    // This matches the default tab bar height of 38: (38-25)/2 = 6.5
                    insets.left = insets.right = 6.5;
                } else {
                    insets.left = insets.right = MAX(0, -insets.bottom);
                }
                break;
            case TAB_STYLE_COMPACT:
                if (@available(macOS 26, *)) {
                    insets.left = insets.right = 3;
                } else {
                    insets.left = insets.right = 0;
                }
                break;
            case TAB_STYLE_DARK:
            case TAB_STYLE_LIGHT:
            case TAB_STYLE_AUTOMATIC:
            case TAB_STYLE_DARK_HIGH_CONTRAST:
            case TAB_STYLE_LIGHT_HIGH_CONTRAST:
                insets.left = insets.right = 0;
                break;
        }

        insets.left = [self retinaRound:insets.left];
        insets.top = [self retinaRound:insets.top];
        insets.bottom = [self retinaRound:insets.bottom];
        insets.right = [self retinaRound:insets.right];

        return insets;
    }

    const CGFloat hotboxSideInset = (iTermStoplightHotboxWidth - [self widthForStandardButtonsView]) / 2.0;
    const CGFloat hotboxVerticalInset = (iTermStoplightHotboxHeight - iTermStandardButtonsViewHeight) / 2.0;
    return NSEdgeInsetsMake(hotboxVerticalInset, hotboxSideInset, hotboxVerticalInset, hotboxSideInset);
}

- (NSRect)frameForStandardWindowButtons {
    const NSEdgeInsets insets = [self insetsForStoplightHotbox];
    CGFloat height;
    if ([self.delegate enableStoplightHotbox]) {
        height = iTermStoplightHotboxHeight;
    } else {
        height = iTermStandardButtonsViewHeight;
    }
    NSRect frame = NSMakeRect(insets.left,
                              self.frame.size.height - height + insets.bottom + 1,
                              [self widthForStandardButtonsView],
                              iTermStandardButtonsViewHeight);
    return [self retinaRoundRect:frame];
}

- (NSRect)frameForWindowNumberLabel {
    if (_tabBarControlOnLoan) {
        return NSZeroRect;
    }
    [_windowNumberLabel sizeToFit];
    const NSRect standardButtonsFrame = [self frameForStandardWindowButtons];
    const CGFloat tabBarHeight = [iTermPreferences intForKey:kPreferenceKeyTabPosition] == PSMTab_LeftTab ? 26.0 : _tabBarControl.height;
    const CGFloat windowNumberHeight = _windowNumberLabel.frame.size.height;
    const CGFloat baselineOffset = -_windowNumberLabel.font.descender;
    const CGFloat capHeight = _windowNumberLabel.font.capHeight;
    const CGFloat myHeight = self.frame.size.height;
    iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
    CGFloat shift = (preferredStyle == TAB_STYLE_MINIMAL) ? 0 : 1;
    if (@available(macOS 26, *)) {
        if (preferredStyle == TAB_STYLE_MINIMAL) {
            shift = 1;  // Move down by 3 points on macOS 26 for minimal theme
        }
    }
    NSRect rect = NSMakeRect(NSMaxX(standardButtonsFrame) + iTermRootTerminalViewWindowNumberLabelMargin,
                             myHeight - tabBarHeight + (tabBarHeight - capHeight) / 2.0 - baselineOffset - shift,
                             iTermRootTerminalViewWindowNumberLabelWidth,
                             windowNumberHeight);
    return [self retinaRoundRect:rect];
}

- (NSRect)frameForWindowTitleLabel {
    return [self frameForWindowTitleLabel:_windowTitleLabel
                              hasSubtitle:_windowTitleLabel.subtitle.length > 0
                           getLeftAligned:nil];
}

- (NSRect)frameForWindowTitleLabel:(NSTextField *)textField
                       hasSubtitle:(BOOL)hasSubtitle
                    getLeftAligned:(BOOL *)leftAlignedPtr {
    if (_tabBarControlOnLoan) {
        return NSZeroRect;
    }
    const CGFloat tabBarHeight = _tabBarControl.height;
    const CGFloat baselineOffset = -textField.font.descender;
    const CGFloat capHeight = textField.font.capHeight;
    const CGFloat myHeight = self.frame.size.height;
    const NSEdgeInsets insets = [self.delegate tabBarInsets];

    // Prefer to center it, using the same inset on both sides. There's no need
    // to have an inset on the right otherwise so if the title doesn't fit then
    // left-align it and make it as wide as the available space.
    // This mirrors what NSWindow's title does.
    const CGFloat mostGenerousInset = MAX(MAX(insets.left, insets.right), iTermRootTerminalViewWindowNumberLabelMargin);
    const CGFloat containerWidth = NSWidth(self.frame) - ([self shouldShowToolbelt] ? NSWidth(_toolbelt.frame) : 0);
    const NSSize fittingSize = textField.fittingSize;
    const CGFloat desiredWidth = fittingSize.width;
    CGFloat leftInset = mostGenerousInset;
    CGFloat rightInset = mostGenerousInset;
    CGFloat proposedWidth = containerWidth - leftInset - rightInset;
    const CGFloat overage = desiredWidth - proposedWidth;
    if (overage > 0) {
        rightInset = MAX(4, rightInset - overage);
        if (leftAlignedPtr) {
            DLog(@"Use left alignment with text “%@” desiredWidth %@, proposedWidth %@, containerWidth %@",
                 textField.stringValue, @(desiredWidth), @(proposedWidth), @(containerWidth));
            *leftAlignedPtr = YES;
        }
    }
    if (@available(macOS 26, *)) {
        if (leftAlignedPtr && [iTermAdvancedSettingsModel leftAlignTitleBarMinimalTahoe]) {
            *leftAlignedPtr = YES;
        }
    }
    CGFloat y;
    if (hasSubtitle) {
        y = [self retinaRound:myHeight - (tabBarHeight - fittingSize.height) / 2.0 - ceil(fittingSize.height)];
    } else {
        y = [self retinaRound:myHeight - tabBarHeight + (tabBarHeight - capHeight) / 2.0 - baselineOffset];
        if (@available(macOS 26, *)) {
            y -= 1.5;
        }
    }
    NSRect rect = NSMakeRect([self retinaRound:leftInset],
                             y,
                             ceil(MAX(0, containerWidth - leftInset - rightInset)),
                             ceil(fittingSize.height));
    return [self retinaRoundRect:rect];
}

- (NSWindowButton *)windowButtonTypes {
    static NSWindowButton buttons[] = {
        NSWindowCloseButton,
        NSWindowMiniaturizeButton,
        NSWindowZoomButton
    };
    return buttons;
}

- (NSInteger)numberOfWindowButtons {
    return 3;
}

- (void)viewDidMoveToWindow {
    if (!self.window) {
        return;
    }
    [self didChangeCompactness];
    for (int i = 0; i < self.numberOfWindowButtons; i++) {
        NSButton *button = _standardButtons[@(self.windowButtonTypes[i])];
        if (self.windowButtonTypes[i] == NSWindowZoomButton) {
            button.target = _standardWindowButtonsView;
            button.action = @selector(zoomButtonEvent);
        } else {
            button.target = self.window;
        }
    }
}

- (void)didChangeCompactness {
    id<PTYWindow> ptyWindow = self.window.ptyWindow;
    const BOOL needCustomButtons = (ptyWindow.isCompact && [self.delegate rootTerminalViewShouldDrawStoplightButtons]);
    if (!needCustomButtons) {
        [_standardWindowButtonsView removeFromSuperview];
        _standardWindowButtonsView = nil;
        if ([self.delegate rootTerminalViewShouldRevealStandardWindowButtons]) {
            for (int i = 0; i < self.numberOfWindowButtons; i++) {
                [[self.window standardWindowButton:self.windowButtonTypes[i]] setHidden:NO];
            }
        }
        return;
    }
    if (_standardWindowButtonsView) {
        return;
    }
    
    // This is a compact window that gets special handling for the stoplights buttons.
    CGFloat x = self.leftInsetForWindowButtons;
    const CGFloat stride = self.strideForWindowButtons;
    _standardWindowButtonsView = [[iTermStandardWindowButtonsView alloc] initWithFrame:[self frameForStandardWindowButtons]];
    _standardWindowButtonsView.autoresizingMask = (NSViewMaxXMargin | NSViewMinYMargin);
    [self addSubview:_standardWindowButtonsView];

    const NSUInteger styleMask = self.window.styleMask;
    _standardButtons = [[NSMutableDictionary alloc] init];
    for (int i = 0; i < self.numberOfWindowButtons; i++) {
        NSButton *button = [NSWindow standardWindowButton:self.windowButtonTypes[i]
                                             forStyleMask:styleMask];
        NSRect frame = button.frame;
        frame.origin.x = x;
        frame.origin.y = 4;
        button.frame = frame;

        [_standardWindowButtonsView addSubview:button];
        _standardButtons[@(self.windowButtonTypes[i])] = button;
        if (self.windowButtonTypes[i] == NSWindowZoomButton) {
            // 😠
            // In issue 8401 a user reported that option-clicking the zoom button doesn't work after
            // exiting full screen.
            //
            // A disassembly of -[NSWindow _setNeedsZoom:] shows that option-clicking only works if
            // -[NSWindow _lastLeftHit] == -[NSWindow standardWindowButton:2]. So for some reason,
            // Apple intended option+zoom to only work with their own zoom button.
            //
            // Chrome ran into the same thing here:
            // https://bugs.chromium.org/p/chromium/issues/detail?id=393808
            //
            // Worth reading for the mention of _evilHackToClearlastLeftHitInWindow.
            //
            // Their analysis is different than mine. I see that _lastLeftHit is actually MY button,
            // which is not what they saw. I suspect a different etiology.
            //
            // I don't recall why I implemented zoomButtonEvent: in the first place; I suspect it
            // was a less well-informed attempt to work around this issue when I added compact
            // windows originally. Since I can't use the "real" button for this window, this seems
            // like the only reasonable fix.
            //
            // Apologies to my future self for whatever bugs this introduces.
            button.target = _standardWindowButtonsView;
            button.action = @selector(zoomButtonEvent);
        }
        x += stride;
        dispatch_async(dispatch_get_main_queue(), ^{
            [button setNeedsDisplay:YES];
        });
    }
    [self layoutSubviews];
}

- (void)flagsChanged:(NSEvent *)event {
    if (_standardWindowButtonsView) {
        NSUInteger modifiers = ([NSEvent modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask);
        BOOL optionKey = modifiers & NSEventModifierFlagOption ? YES : NO;
        
        [_standardWindowButtonsView setOptionModifier:optionKey];
    }
    [super flagsChanged:event];
}

- (NSRect)frameForTitleBackgroundView {
    const CGFloat height = [_delegate rootTerminalViewHeightOfTabBar:self];
    return NSMakeRect(0,
                      self.frame.size.height - height,
                      self.frame.size.width,
                      height);
}

- (void)drawRect:(NSRect)dirtyRect {
}

- (NSRect)frameForLeftBorderView {
    return NSMakeRect(0, 0, 1, self.bounds.size.height);
}

- (NSRect)frameForRightBorderView {
    return NSMakeRect(self.bounds.size.width - 1, 0, 1, self.bounds.size.height);
}

- (NSRect)frameForTopBorderView {
    return NSMakeRect(0, self.bounds.size.height - 1, self.bounds.size.width, 1);
}

- (NSRect)frameForBottomBorderView {
    return NSMakeRect(0, 0, self.bounds.size.width, 1);
}

- (void)updateTitleAndBorderViews NS_AVAILABLE_MAC(10_14) {
    const BOOL wantsTitleBackgroundView = [_delegate rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar];
    if (wantsTitleBackgroundView) {
        if (!_titleBackgroundView) {
            _titleBackgroundView = [[iTermLayerBackedSolidColorView alloc] initWithFrame:self.frameForTitleBackgroundView];
            _titleBackgroundView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        }
        _titleBackgroundView.color = [_delegate rootTerminalViewTabBarBackgroundColorIgnoringTabColor:NO];
        _titleBackgroundView.frame = self.frameForTitleBackgroundView;
        if (_titleBackgroundView.superview != self) {
            [self insertSubview:_titleBackgroundView atIndex:1];
        }
    } else {
        [_titleBackgroundView removeFromSuperview];
    }

    [self updateBorderViews];
    [self updateTextColors];
}

- (void)updateBorderViews NS_AVAILABLE_MAC(10_14) {
    const BOOL haveLeft = self.delegate.haveLeftBorder;
    const BOOL haveTop = self.delegate.haveTopBorder;
    const BOOL haveRight = self.delegate.haveRightBorderRegardlessOfScrollBar;
    const BOOL haveBottom = self.delegate.haveBottomBorder;
    const BOOL fullThickness = self.effectiveAppearance.it_isDark || (self.window.backingScaleFactor <= 1);
    const CGFloat radius = iTermWindowBorderRadius;
    {
        const CGFloat top = self.bounds.size.height - radius;
        const CGFloat right = self.bounds.size.width - radius;
        const CGFloat bottom = 0;
        
        _topLeftCornerHalfRoundImageView.frame = NSMakeRect(0, top, radius, radius);
        _topRightCornerHalfRoundImageView.frame = NSMakeRect(right, top, radius, radius);
        _bottomLeftCornerHalfRoundImageView.frame = NSMakeRect(0, bottom, radius, radius);
        _bottomRightCornerHalfRoundImageView.frame = NSMakeRect(right, bottom, radius, radius);

        _topLeftCornerFullRoundImageView.frame = NSMakeRect(0, top, radius, radius);
        _topRightCornerFullRoundImageView.frame = NSMakeRect(right, top, radius, radius);
        _bottomLeftCornerFullRoundImageView.frame = NSMakeRect(0, bottom, radius, radius);
        _bottomRightCornerFullRoundImageView.frame = NSMakeRect(right, bottom, radius, radius);
    }
    
    {
        _leftBorderView.hidden = !haveLeft;
        _rightBorderView.hidden = !haveRight;
        _topBorderView.hidden = !haveTop;
        _bottomBorderView.hidden = !haveBottom;

        const CGFloat topInset = haveTop ? radius : 0;
        const CGFloat bottomInset = haveBottom ? radius : 0;
        const CGFloat leftInset = haveLeft ? radius : 0;
        const CGFloat rightInset = haveRight ? radius : 0;

        const CGFloat thickness = fullThickness ? 1 : 0.5;
        _leftBorderView.frame = NSMakeRect(0,
                                         bottomInset,
                                         thickness,
                                         self.bounds.size.height - topInset - bottomInset);
        
        _rightBorderView.frame = NSMakeRect(self.bounds.size.width - thickness,
                                          bottomInset,
                                          thickness,
                                          self.bounds.size.height - topInset - bottomInset);
        _bottomBorderView.frame = NSMakeRect(leftInset,
                                            0,
                                            self.bounds.size.width - leftInset - rightInset,
                                            thickness);
        
        _topBorderView.frame = NSMakeRect(leftInset,
                                         self.bounds.size.height - thickness,
                                         self.bounds.size.width - leftInset - rightInset,
                                         thickness);
    }

    _bottomLeftCornerHalfRoundImageView.hidden = !(haveLeft && haveBottom && !fullThickness);
    _bottomRightCornerHalfRoundImageView.hidden = !(haveRight && haveBottom && !fullThickness);
    _topLeftCornerHalfRoundImageView.hidden = !(haveLeft && haveTop && !fullThickness);
    _topRightCornerHalfRoundImageView.hidden = !(haveRight && haveTop && !fullThickness);

    _bottomLeftCornerFullRoundImageView.hidden = !(haveLeft && haveBottom && fullThickness);
    _bottomRightCornerFullRoundImageView.hidden = !(haveRight && haveBottom && fullThickness);
    _topLeftCornerFullRoundImageView.hidden = !(haveLeft && haveTop && fullThickness);
    _topRightCornerFullRoundImageView.hidden = !(haveRight && haveTop && fullThickness);
}

- (void)setUseMetal:(BOOL)useMetal {
    if (useMetal == _useMetal) {
        return;
    }
    _useMetal = useMetal;
    self.tabView.drawsBackground = NO;
    if (@available(macOS 10.15, *)) { } else {
        if (useMetal) {
            self.wantsLayer = YES;
            self.layer = [[CALayer alloc] init];
        } else {
            self.wantsLayer = NO;
            self.layer = nil;
        }
    }
    [self updateTitleAndBorderViews];

    [_divisionView removeFromSuperview];
    _divisionView = nil;

    [self updateDivisionViewAndWindowNumberLabel];
}

- (void)viewDidChangeEffectiveAppearance NS_AVAILABLE_MAC(10_14) {
    // This can be called from within -[NSWindow setStyleMask:]
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rootTerminalViewDidChangeEffectiveAppearance];
    });
    [self updateBorderViews];
}

- (void)windowTitleDidChangeTo:(NSString *)title {
    _windowTitle = [title copy];
    [self syncTideyEditorFileTreeRootIfNeeded];

    [self setWindowTitleLabelToString:_windowTitle
                             subtitle:[self.delegate rootTerminalViewCurrentTabSubtitle]
                                 icon:[self.delegate rootTerminalViewCurrentTabIcon]];
    if (!_windowTitleLabel.hidden) {
        [self layoutWindowPaneDecorations];
    }
}

- (void)setSubtitle:(NSString *)subtitle {
    [self syncTideyEditorFileTreeRootIfNeeded];
    [self setWindowTitleLabelToString:_windowTitleLabel.windowTitle
                             subtitle:subtitle
                                 icon:_windowTitleLabel.windowIcon];
}

- (void)setWindowTitleLabelToString:(NSString *)title subtitle:(NSString *)subtitle icon:(NSImage *)icon {
    _windowTitleLabel.puaFontProvider = [self.delegate rootTerminalViewPUAFontProvider];
    [_windowTitleLabel setTitle:title subtitle:subtitle icon:icon alignmentProvider:
     ^NSTextAlignment(NSTextField * _Nonnull scratch) {
         BOOL leftAligned = NO;
         [self frameForWindowTitleLabel:scratch
                            hasSubtitle:subtitle.length > 0
                         getLeftAligned:&leftAligned];

         return leftAligned ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    }];
}

- (void)setWindowTitleIcon:(NSImage *)icon {
    [self setWindowTitleLabelToString:_windowTitle
                             subtitle:[self.delegate rootTerminalViewCurrentTabSubtitle]
                                 icon:icon];
}

- (iTermTabBarControlView *)borrowTabBarControl {
    DLog(@"Borrow tabbar control");
    assert(!_tabBarControlOnLoan);
    iTermTabBarControlView *view = _tabBarControl;
    _tabBarControlOnLoan = YES;
    _tabBarBacking.hidden = YES;
    [_tabBarControl removeFromSuperview];
    // Fix size in case we just went from left-of to top-of since it's now going full-width.
    [self.tabBarControl setTabLocation:[iTermPreferences intForKey:kPreferenceKeyTabPosition]];
    const CGFloat desiredHeight = [self.delegate rootTerminalViewHeightOfTabBar:self];
    _tabBarControl.height = desiredHeight;
    _tabBarControl.frame = NSMakeRect(0, 0, _tabBarControl.frame.size.width, desiredHeight);
    _tabBarControl.hidden = NO;

    return view;
}

- (void)returnTabBarControlView:(iTermTabBarControlView *)tabBarControl {
    DLog(@"Return tabbar control");
    assert(_tabBarControlOnLoan);
    _tabBarControlOnLoan = NO;
    [_tabBarBacking addSubview:tabBarControl];
    _tabBarControl.frame = _tabBarBacking.bounds;
    _tabBarControl = tabBarControl;
    [self.tabBarControl updateFlashing];
    _tabBarBacking.hidden = NO;
}

- (void)windowNumberDidChangeTo:(NSNumber *)number {
    _windowNumber = number;
    BOOL deemphasized;
    _windowNumberLabel.stringValue = [iTermWindowShortcutLabelTitlebarAccessoryViewController stringForOrdinal:number.intValue deemphasized:&deemphasized];
}

- (void)setNeedsDisplay:(BOOL)needsDisplay {
    [super setNeedsDisplay:YES];
    [_statusBarContainer setNeedsDisplay:YES];
    [_tabBarBacking setNeedsDisplay:YES];
    [_tabBarControl setNeedsDisplay:YES];
}

- (void)setToolbeltProportions:(NSDictionary *)proportions {
    _desiredToolbeltProportions = [proportions copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateToolbeltProportionsIfNeeded];
    });
}

- (void)updateToolbeltProportionsIfNeeded {
    if (_desiredToolbeltProportions) {
        [self.toolbelt setProportions:_desiredToolbeltProportions];
        _desiredToolbeltProportions = nil;
    }
}

- (void)setShowsWindowSize:(BOOL)showsWindowSize {
    if (!showsWindowSize) {
        // Hide
        [_windowSizeView removeFromSuperview];
        _windowSizeView = nil;
        return;
    }

    // Show
    if (_windowSizeView) {
        return;
    }
    _windowSizeView = [[iTermWindowSizeView alloc] initWithDetail:[self.delegate rootTerminalViewWindowSizeViewDetailString]];
    [self addSubview:_windowSizeView];
    NSRect myBounds = self.bounds;
    _windowSizeView.frame = NSMakeRect(NSMidX(myBounds), NSMidY(myBounds), 0, 0);
    _windowSizeView.autoresizingMask = (NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin);
    [_windowSizeView setWindowSize:[self.delegate rootTerminalViewCurrentSessionSize]];
}

- (void)windowDidResize {
    [_windowSizeView setWindowSize:[self.delegate rootTerminalViewCurrentSessionSize]];
}

- (void)setCurrentSessionAlpha:(CGFloat)alpha {
    _tabBarBacking.visualEffectView.hidden = PSMShouldExtendTransparencyIntoMinimalTabBar() && (alpha < 1);
}

#pragma mark - Division View

- (void)updateDivisionViewAndWindowNumberLabel {
    BOOL shouldBeVisible = _delegate.divisionViewShouldBeVisible;
    if (shouldBeVisible) {
        NSRect tabViewFrame = _tabView.frame;
        NSRect divisionViewFrame = NSMakeRect(0,
                                              NSMaxY(tabViewFrame),
                                              self.bounds.size.width,
                                              kDivisionViewHeight);
        if ([_delegate rootTerminalViewSharedStatusBarViewController] &&
            [iTermPreferences boolForKey:kPreferenceKeyStatusBarPosition] == iTermStatusBarPositionTop) {
            // Have a top status bar. Move the division view to sit above it.
            divisionViewFrame.origin.y += iTermGetStatusBarHeight();
        }
        if (!_divisionView) {
            Class theClass;
            if (@available(macOS 14.0, *)) {
                // There's a bug in Sonoma (first seen in 14.0 Beta (23A5301h) which I believe is beta 4)
                // where using a non-layer-backed division view caused all the other views to disappear, including those over it.
                // I don't remember why I fell back to a non-layer-backed view for non-metal. Probably bugs in old macOS versions.
                theClass = [iTermLayerBackedSolidColorView class];
            } else {
                theClass = _useMetal ? [iTermLayerBackedSolidColorView class] : [SolidColorView class];
            }
            _divisionView = [[theClass alloc] initWithFrame:divisionViewFrame];
            _divisionView.autoresizingMask = (NSViewWidthSizable | NSViewMinYMargin);
            [self addSubview:_divisionView];
        }
        iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
        switch ([self.effectiveAppearance it_tabStyle:preferredStyle]) {
            case TAB_STYLE_AUTOMATIC:
            case TAB_STYLE_COMPACT:
            case TAB_STYLE_MINIMAL:
                assert(NO);
                
            case TAB_STYLE_LIGHT:
            case TAB_STYLE_LIGHT_HIGH_CONTRAST:
                _divisionView.color = (self.window.isKeyWindow
                                       ? [NSColor colorWithCalibratedHue:1 saturation:0 brightness:0.70 alpha:1]
                                       : [NSColor colorWithCalibratedHue:1 saturation:0 brightness:0.86 alpha:1]);
                break;

            case TAB_STYLE_DARK:
            case TAB_STYLE_DARK_HIGH_CONTRAST:
                _divisionView.color = (self.window.isKeyWindow
                                       ? [NSColor colorWithCalibratedHue:1 saturation:0 brightness:0.1 alpha:1]
                                       : [NSColor colorWithCalibratedHue:1 saturation:0 brightness:0.07 alpha:1]);
                break;
        }

        _divisionView.frame = divisionViewFrame;
    } else if (_divisionView) {
        // Remove existing division
        [_divisionView removeFromSuperview];
        _divisionView = nil;
    }
    [self updateTextColors];
    if (_windowTitleLabel.windowIcon) {
        [self setWindowTitleLabelToString:_windowTitleLabel.windowTitle
                                 subtitle:_windowTitleLabel.subtitle
                                     icon:_windowTitleLabel.windowIcon];
    }
}

- (void)updateTextColors {
    _windowNumberLabel.textColor = [self.delegate rootTerminalViewTabBarTextColorForWindowNumber];
    _windowTitleLabel.textColor = [self.delegate rootTerminalViewTabBarTextColorForTitle];
}

#pragma mark - Toolbelt

- (void)updateToolbeltForWindow:(NSWindow *)thisWindow {
    _toolbelt.frame = [self toolbeltFrameInWindow:thisWindow];
    _toolbelt.hidden = ![self shouldShowToolbelt];
    [_delegate repositionWidgets];
    [_toolbelt relayoutAllTools];
}

- (void)constrainToolbeltWidth {
    _toolbeltWidth = [self maximumToolbeltWidthForViewWidth:self.frame.size.width];
}

- (CGFloat)maximumToolbeltWidthForViewWidth:(CGFloat)viewWidth {
    CGFloat minSize = MIN(kMinimumToolbeltSizeInPoints,
                          viewWidth * kMinimumToolbeltSizeAsFractionOfWindow);
    return MAX(MIN(_toolbeltWidth,
                   viewWidth * kMaximumToolbeltSizeAsFractionOfWindow),
               minSize);
}

- (NSRect)toolbeltFrameInWindow:(NSWindow *)thisWindow {
    // Use calculator for toolbelt frame calculation
    iTermLayoutInputs inputs = [self layoutInputsForWindow:thisWindow];
    NSRect frame = [iTermLayoutCalculator toolbeltFrameWithInputs:inputs];
    frame.origin.x += self.tideySidebarWidth;
    return frame;
}

- (void)setShouldShowToolbelt:(BOOL)shouldShowToolbelt {
    if (shouldShowToolbelt == _shouldShowToolbelt) {
        return;
    }
    if (shouldShowToolbelt && !_haveShownToolbelt) {
        _toolbeltWidth = [iTermPreferences floatForKey:kPreferenceKeyDefaultToolbeltWidth];
        _haveShownToolbelt = YES;
    }
    _shouldShowToolbelt = shouldShowToolbelt;
    _toolbelt.hidden = !shouldShowToolbelt;
}

- (void)updateToolbeltFrameForWindow:(NSWindow *)thisWindow {
    const NSRect toolbeltFrame = [self toolbeltFrameInWindow:thisWindow];
    DLog(@"Set toolbelt frame to %@", NSStringFromRect(toolbeltFrame));
    [self constrainToolbeltWidth];
    [self.toolbelt setFrame:toolbeltFrame];
}

- (void)shutdown {
    [_toolbelt shutdown];
    _toolbelt = nil;
    _delegate = nil;
}

- (BOOL)scrollbarShouldBeVisible {
    return ![iTermPreferences boolForKey:kPreferenceKeyHideScrollbar];
}

- (BOOL)tabBarShouldBeVisible {
    if (_tabBarControlOnLoan) {
        DLog(@"Tab bar should not be visible because it is on loan");
        return NO;
    }
    return [self tabBarShouldBeVisibleEvenWhenOnLoan];
}

- (BOOL)tabBarShouldBeVisibleEvenWhenOnLoan {
    if (self.tabBarControl.flashing) {
        DLog(@"Tabbar should be visible because it is flashing");
        return YES;
    } else {
        return [self tabBarShouldBeVisibleWithAdditionalTabs:0];
    }
}

- (BOOL)tabBarShouldBeVisibleWithAdditionalTabs:(int)numberOfAdditionalTabs {
    if (([_delegate anyFullScreen] || [_delegate enteringLionFullscreen]) &&
        ![iTermPreferences boolForKey:kPreferenceKeyShowFullscreenTabBar]) {
        DLog(@"Tabbar should not be visible because in full screen");
        return NO;
    }
    if ([_delegate tabBarAlwaysVisible]) {
        DLog(@"Tabbar should be visible because it is configured to always be visible");
        return YES;
    }
    const BOOL result = [self.tabView numberOfTabViewItems] + numberOfAdditionalTabs > 1;
    DLog(@"returning %@", @(result));
    return result;
}

- (void)removeLeftTabBarDragHandle {
    [self.leftTabBarDragHandle removeFromSuperview];
    self.leftTabBarDragHandle = nil;
}

- (void)updateWindowNumberFont {
    if ([self tabBarShouldBeVisible]) {
        if (@available(macOS 10.16, *)) {
            _windowNumberLabel.font = [NSFont titleBarFontOfSize:[NSFont smallSystemFontSize]];
        } else {
            _windowNumberLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        }
    } else {
        if (@available(macOS 10.16, *)) {
            _windowNumberLabel.font = [NSFont titleBarFontOfSize:[NSFont systemFontSize]];
        } else {
            _windowNumberLabel.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
        }
    }
}

- (void)layoutSubviewsWithVisibleTabBarForWindow:(NSWindow *)thisWindow inlineToolbelt:(BOOL)showToolbeltInline {
    assert(!_tabBarControlOnLoan);
    // The tabBar control is visible.
    DLog(@"repositionWidgets - tabs are visible. Adjusting window size...");
    self.tabBarControl.hidden = NO;
    [self.tabBarControl setTabLocation:[iTermPreferences intForKey:kPreferenceKeyTabPosition]];

    switch ([iTermPreferences intForKey:kPreferenceKeyTabPosition]) {
        case PSMTab_TopTab: {
            // Place tabs at the top.
            // Add 1px border
            [self layoutSubviewsTopTabBarVisible:YES forWindow:thisWindow];
            break;
        }

        case PSMTab_BottomTab: {
            [self layoutSubviewsWithVisibleBottomTabBarForWindow:thisWindow];
            break;
        }

        case PSMTab_LeftTab: {
            [self layoutSubviewsWithVisibleLeftTabBarAndInlineToolbelt:showToolbeltInline forWindow:thisWindow];
            break;
        }
    }
}

- (BOOL)shouldLeaveEmptyAreaAtTop {
    if (!_tabBarControlOnLoan) {
        DLog(@"NO: Tabbar control not on loan");
        return NO;
    }
    if (![self tabBarShouldBeVisibleWithAdditionalTabs:0]) {
        DLog(@"NO: tabbar should not be visible");
        return NO;
    }
    if (![self.delegate rootTerminalViewShouldLeaveEmptyAreaAtTop]) {
        DLog(@"NO: delegate says not to leave an empty area on top");
        return NO;
    }
    DLog(@"YES");
    return YES;
}

- (CGFloat)notchInset {
    if (![_delegate fullScreen]) {
        return 0;
    }
    const BOOL wantToHideMenuBar = [iTermPreferences boolForKey:kPreferenceKeyHideMenuBarInFullscreen];
    if (!wantToHideMenuBar) {
        // No need to use a notch mask because the menu bar serves that purpose.
        return 0;
    }
    const CGFloat fakeHeight = [iTermAdvancedSettingsModel fakeNotchHeight];
    if (fakeHeight > 0) {
        return fakeHeight;
    }
    if (@available(macOS 12, *)) {
        // self.safeAreaInsets is all 0s on a notch Mac. Why the hell doesn't anything work right?
        const NSEdgeInsets safeAreaInsets = self.window.screen.safeAreaInsets;
        return safeAreaInsets.top;
    }
    return 0;
}

#pragma mark - Layout Calculator Integration

- (iTermLayoutInputs)layoutInputsForWindow:(NSWindow *)thisWindow {
    iTermLayoutInputs inputs = {0};

    // Content view dimensions - fall back to self.bounds if window is nil
    // (e.g., during initialization before window is set)
    NSRect contentFrame;
    if (thisWindow) {
        contentFrame = [[thisWindow contentView] frame];
    } else {
        contentFrame = self.bounds;
    }
    inputs.contentViewWidth = MAX(0, contentFrame.size.width - self.tideySidebarWidth);
    inputs.contentViewHeight = contentFrame.size.height;

    // Tab bar dimensions
    inputs.tabBarHeight = _tabBarControl.height;
    inputs.leftTabBarWidth = _leftTabBarWidth;

    // Toolbelt
    inputs.toolbeltWidth = floor(self.toolbeltWidth);
    inputs.shouldShowToolbelt = self.shouldShowToolbelt;

    // Status bar
    iTermStatusBarViewController *statusBarViewController = [_delegate rootTerminalViewSharedStatusBarViewController];
    inputs.statusBarHeight = statusBarViewController ? iTermGetStatusBarHeight() : 0;
    inputs.hasStatusBar = (statusBarViewController != nil);
    inputs.statusBarOnTop = ([iTermPreferences unsignedIntegerForKey:kPreferenceKeyStatusBarPosition] == iTermStatusBarPositionTop);

    // Tab bar state
    inputs.tabBarVisible = [self tabBarShouldBeVisibleWithAdditionalTabs:0];
    inputs.tabBarOnLoan = _tabBarControlOnLoan;
    inputs.tabBarFlashing = _tabBarControl.flashing;
    inputs.tabBarShouldBeAccessory = [self tabBarShouldBeVisibleEvenWhenOnLoan];
    inputs.tabBarAccessoryOverlapsContent = [self.delegate rootTerminalViewFullScreenTabBarAccessoryOverlapsContent];

    // Fullscreen state
    inputs.enteringFullscreen = [self.delegate enteringLionFullscreen];
    inputs.inFullscreen = [self.delegate fullScreen] || [self.delegate lionFullScreen];

    // Tab position
    inputs.tabPosition = [iTermPreferences intForKey:kPreferenceKeyTabPosition];

    // Division view
    inputs.divisionViewVisible = self.delegate.divisionViewShouldBeVisible;
    inputs.divisionViewHeight = kDivisionViewHeight;

    // Notch inset
    inputs.notchInset = [self notchInset];

    // Transitional state
    inputs.shouldLeaveEmptyAreaAtTop = [self shouldLeaveEmptyAreaAtTop];

    // Title in tab bar
    inputs.drawWindowTitleInPlaceOfTabBar = [self.delegate rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar];

    return inputs;
}

- (CGFloat)tideySidebarWidth {
    if (!self.shouldShowTideySidebar) {
        return 0;
    }
    const CGFloat minimumTerminalWidth = self.shouldShowTideyTerminal ? kTideyMinimumTerminalWidth : 0;
    const CGFloat availableWidth = MAX(0, NSWidth(self.bounds) - (self.shouldShowToolbelt ? floor(self.toolbeltWidth) : 0));
    const CGFloat reservedEditorWidth = self.shouldShowTideyEditorPanel ? _tideyEditorPreferredWidth : 0;
    const CGFloat maxWidth = MAX(0, availableWidth - reservedEditorWidth - minimumTerminalWidth);
    if (maxWidth <= 0) {
        return 0;
    }
    const CGFloat minWidth = MIN(kTideyMinimumSidebarWidth, maxWidth);
    return MAX(minWidth, MIN(_tideySidebarPreferredWidth, maxWidth));
}

- (void)setShouldShowTideySidebar:(BOOL)shouldShowTideySidebar {
    if (_shouldShowTideySidebar == shouldShowTideySidebar) {
        return;
    }
    _shouldShowTideySidebar = shouldShowTideySidebar;
    [self tideyPersistLayoutState];
}

- (CGFloat)tideyEditorPanelWidth {
    if (!self.shouldShowTideyEditorPanel) {
        return 0;
    }
    if (!self.shouldShowTideyTerminal) {
        const CGFloat availableWidth = MAX(0, NSWidth(self.bounds) - (self.shouldShowToolbelt ? floor(self.toolbeltWidth) : 0));
        return MAX(0, availableWidth - self.tideySidebarWidth);
    }
    const CGFloat minimumTerminalWidth = self.shouldShowTideyTerminal ? kTideyMinimumTerminalWidth : 0;
    const CGFloat availableWidth = MAX(0, NSWidth(self.bounds) - (self.shouldShowToolbelt ? floor(self.toolbeltWidth) : 0));
    const CGFloat maxWidth = MAX(0, availableWidth - self.tideySidebarWidth - minimumTerminalWidth);
    if (maxWidth <= 0) {
        return 0;
    }
    const CGFloat minWidth = MIN(kTideyMinimumEditorPanelWidth, maxWidth);
    return MAX(minWidth, MIN(_tideyEditorPreferredWidth, maxWidth));
}

- (void)setShouldShowTideyEditorPanel:(BOOL)shouldShowTideyEditorPanel {
    if (_shouldShowTideyEditorPanel == shouldShowTideyEditorPanel) {
        return;
    }
    _shouldShowTideyEditorPanel = shouldShowTideyEditorPanel;
    [self tideyPersistLayoutState];
}

- (void)setShouldShowTideyTerminal:(BOOL)shouldShowTideyTerminal {
    if (_shouldShowTideyTerminal == shouldShowTideyTerminal) {
        return;
    }
    if (!shouldShowTideyTerminal) {
        _tideyEditorPreferredWidthBeforeTerminalCollapse = MAX(kTideyMinimumEditorPanelWidth, self.tideyEditorPanelWidth);
    } else if (_tideyEditorPreferredWidthBeforeTerminalCollapse > 0) {
        _tideyEditorPreferredWidth = _tideyEditorPreferredWidthBeforeTerminalCollapse;
    }
    _shouldShowTideyTerminal = shouldShowTideyTerminal;
    [self tideyPersistLayoutState];
}

- (CGFloat)tideyEditorFileTreeWidth {
    const CGFloat panelWidth = self.tideyEditorPanelWidth;
    if (panelWidth <= 0) {
        return 0;
    }
    const CGFloat maxWidth = MAX(0, panelWidth - kTideyMinimumEditorContentWidth);
    if (maxWidth <= 0) {
        return 0;
    }
    const CGFloat minWidth = MIN(kTideyMinimumFileTreeWidth, maxWidth);
    return MAX(minWidth, MIN(_tideyEditorFileTreePreferredWidth, maxWidth));
}

- (void)setShouldShowTideyEditorFileTree:(BOOL)shouldShowTideyEditorFileTree {
    if (_shouldShowTideyEditorFileTree == shouldShowTideyEditorFileTree) {
        return;
    }
    _shouldShowTideyEditorFileTree = shouldShowTideyEditorFileTree;
    [self tideyPersistLayoutState];
}

- (void)ensureTideyEditorWebView {
    if (_tideyEditorWebView != nil) {
        return;
    }

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.applicationNameForUserAgent = @"iTerm2";
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    WKPreferences *preferences = [[WKPreferences alloc] init];
    preferences.javaScriptCanOpenWindowsAutomatically = NO;
    @try {
        [preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    } @catch (NSException *exception) {
        DLog(@"When setting developerExtrasEnabled for Tidey editor: %@", exception);
    }
    configuration.preferences = preferences;

    WKUserContentController *contentController = [[WKUserContentController alloc] init];
    _tideyEditorScriptMessageHandler = [[TideyEditorScriptMessageHandler alloc] init];
    _tideyEditorScriptMessageHandler.rootView = self;
    [contentController addScriptMessageHandler:_tideyEditorScriptMessageHandler name:@"tideyEditorReady"];
    [contentController addScriptMessageHandler:_tideyEditorScriptMessageHandler name:@"tideyEditorChanged"];
    [contentController addScriptMessageHandler:_tideyEditorScriptMessageHandler name:@"tideyEditorSaveRequested"];
    configuration.userContentController = contentController;

    _tideyEditorWebView = [[WKWebView alloc] initWithFrame:_tideyEditorPanelView.bounds configuration:configuration];
    _tideyEditorWebView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _tideyEditorWebView.navigationDelegate = self;
    if (@available(macOS 13.3, *)) {
        _tideyEditorWebView.inspectable = YES;
    }
    [_tideyEditorPanelView addSubview:_tideyEditorWebView positioned:NSWindowBelow relativeTo:_tideyEditorPanelLabel];
    [self layoutTideyEditorContents];
}

- (void)loadTideyEditorShellIfNeeded {
    [self ensureTideyEditorWebView];
    if (_tideyEditorShellLoaded) {
        return;
    }
    _tideyEditorShellLoaded = YES;
    NSURL *baseURL = [self tideyEditorMonacoBaseURL];
    [_tideyEditorWebView loadHTMLString:[self tideyEditorHTML]
                                baseURL:baseURL];
}

- (NSURL *)tideyEditorMonacoBundleURL {
    return [[NSBundle mainBundle] URLForResource:@"monaco-editor" withExtension:nil];
}

- (NSURL *)tideyEditorMonacoBaseURL {
    NSURL *bundleURL = [self tideyEditorMonacoBundleURL];
    if (bundleURL) {
        return [bundleURL URLByAppendingPathComponent:@"min/" isDirectory:YES];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.jsdelivr.net/npm/monaco-editor@%@/min/",
                                 kTideyBundledMonacoVersion]];
}

- (NSURL *)tideyEditorMonacoVSURL {
    NSURL *bundleURL = [self tideyEditorMonacoBundleURL];
    if (bundleURL) {
        return [bundleURL URLByAppendingPathComponent:@"min/vs" isDirectory:YES];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.jsdelivr.net/npm/monaco-editor@%@/min/vs",
                                 kTideyBundledMonacoVersion]];
}

- (NSURL *)tideyEditorMonacoLoaderURL {
    NSURL *bundleURL = [self tideyEditorMonacoBundleURL];
    if (bundleURL) {
        return [bundleURL URLByAppendingPathComponent:@"min/vs/loader.js"];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.jsdelivr.net/npm/monaco-editor@%@/min/vs/loader.js",
                                 kTideyBundledMonacoVersion]];
}

- (NSURL *)tideyEditorMonacoWorkerURL {
    NSURL *bundleURL = [self tideyEditorMonacoBundleURL];
    if (bundleURL) {
        return [bundleURL URLByAppendingPathComponent:@"min/vs/base/worker/workerMain.js"];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.jsdelivr.net/npm/monaco-editor@%@/min/vs/base/worker/workerMain.js",
                                 kTideyBundledMonacoVersion]];
}

- (NSString *)tideyEditorFileTreeRootPath {
    NSString *overrideRoot = [_tideyEditorRootOverridePath stringByStandardizingPath];
    if (overrideRoot.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:overrideRoot]) {
        return overrideRoot;
    }
    NSString *cwd = [[self.delegate rootTerminalViewCurrentWorkingDirectory] stringByStandardizingPath];
    if (cwd.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:cwd]) {
        return cwd;
    }
    return NSHomeDirectory();
}

- (BOOL)tideyEditorIsDemoFilePath:(NSString *)path {
    NSString *normalizedPath = [path stringByStandardizingPath];
    if (normalizedPath.length == 0) {
        return NO;
    }
    NSString *sourcePath = [NSString stringWithUTF8String:__FILE__];
    NSString *sourcesDir = [sourcePath stringByDeletingLastPathComponent];
    NSString *repoRoot = [sourcesDir stringByDeletingLastPathComponent];
    NSArray<NSString *> *candidates = @[
        [[repoRoot stringByAppendingPathComponent:@"README.md"] stringByStandardizingPath],
        [[repoRoot stringByAppendingPathComponent:@"sources/PseudoTerminal.m"] stringByStandardizingPath],
    ];
    return [candidates containsObject:normalizedPath];
}

- (void)tideyRestoreEditorStateFromDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSString *savedFilePath = [[defaults stringForKey:kTideyLastEditorFilePathDefaultsKey] stringByStandardizingPath];
    if ([self tideyEditorIsDemoFilePath:savedFilePath]) {
        [defaults removeObjectForKey:kTideyLastEditorFilePathDefaultsKey];
        [defaults removeObjectForKey:kTideyLastEditorFileTreeRootDefaultsKey];
        savedFilePath = nil;
    }
    BOOL isDirectory = NO;
    if (savedFilePath.length > 0 &&
        [fileManager fileExistsAtPath:savedFilePath isDirectory:&isDirectory] &&
        !isDirectory) {
        _tideyEditorLoadedPath = [savedFilePath copy];
        _shouldShowTideyEditorPanel = YES;

        NSString *savedRootPath = [[defaults stringForKey:kTideyLastEditorFileTreeRootDefaultsKey] stringByStandardizingPath];
        BOOL savedRootIsDirectory = NO;
        if (savedRootPath.length > 0 &&
            [fileManager fileExistsAtPath:savedRootPath isDirectory:&savedRootIsDirectory] &&
            savedRootIsDirectory) {
            _tideyEditorRootOverridePath = [savedRootPath copy];
        } else {
            _tideyEditorRootOverridePath = [[self tideyEditorPreferredRootPathForFileAtPath:savedFilePath] copy];
        }
        return;
    }

    [defaults removeObjectForKey:kTideyLastEditorFilePathDefaultsKey];
    [defaults removeObjectForKey:kTideyLastEditorFileTreeRootDefaultsKey];
    _tideyEditorLoadedPath = nil;
    _tideyEditorRootOverridePath = nil;
}

- (void)tideyPersistEditorState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL isDirectory = NO;
    NSString *loadedPath = [_tideyEditorLoadedPath stringByStandardizingPath];
    if (loadedPath.length > 0 &&
        ![self tideyEditorIsDemoFilePath:loadedPath] &&
        [fileManager fileExistsAtPath:loadedPath isDirectory:&isDirectory] &&
        !isDirectory) {
        [defaults setObject:loadedPath forKey:kTideyLastEditorFilePathDefaultsKey];
    } else {
        [defaults removeObjectForKey:kTideyLastEditorFilePathDefaultsKey];
    }

    NSString *rootPath = [[self tideyEditorFileTreeRootPath] stringByStandardizingPath];
    BOOL rootIsDirectory = NO;
    if (rootPath.length > 0 &&
        [fileManager fileExistsAtPath:rootPath isDirectory:&rootIsDirectory] &&
        rootIsDirectory) {
        [defaults setObject:rootPath forKey:kTideyLastEditorFileTreeRootDefaultsKey];
    } else {
        [defaults removeObjectForKey:kTideyLastEditorFileTreeRootDefaultsKey];
    }
}

- (void)tideyRestoreLayoutStateFromDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if ([defaults objectForKey:kTideySidebarWidthDefaultsKey] != nil) {
        _tideySidebarPreferredWidth = [defaults doubleForKey:kTideySidebarWidthDefaultsKey];
    }
    if ([defaults objectForKey:kTideyEditorPanelWidthDefaultsKey] != nil) {
        _tideyEditorPreferredWidth = [defaults doubleForKey:kTideyEditorPanelWidthDefaultsKey];
        _tideyEditorPreferredWidthBeforeTerminalCollapse = _tideyEditorPreferredWidth;
    }
    if ([defaults objectForKey:kTideyEditorFileTreeWidthDefaultsKey] != nil) {
        _tideyEditorFileTreePreferredWidth = [defaults doubleForKey:kTideyEditorFileTreeWidthDefaultsKey];
    }

    if ([defaults objectForKey:kTideySidebarVisibleDefaultsKey] != nil) {
        _shouldShowTideySidebar = [defaults boolForKey:kTideySidebarVisibleDefaultsKey];
    }
    if ([defaults objectForKey:kTideyEditorPanelVisibleDefaultsKey] != nil) {
        _shouldShowTideyEditorPanel = [defaults boolForKey:kTideyEditorPanelVisibleDefaultsKey];
    }
    if ([defaults objectForKey:kTideyEditorFileTreeVisibleDefaultsKey] != nil) {
        _shouldShowTideyEditorFileTree = [defaults boolForKey:kTideyEditorFileTreeVisibleDefaultsKey];
    }
    if ([defaults objectForKey:kTideyTerminalVisibleDefaultsKey] != nil) {
        _shouldShowTideyTerminal = [defaults boolForKey:kTideyTerminalVisibleDefaultsKey];
    }
}

- (void)tideyPersistLayoutState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:_tideySidebarPreferredWidth forKey:kTideySidebarWidthDefaultsKey];
    [defaults setDouble:_tideyEditorPreferredWidth forKey:kTideyEditorPanelWidthDefaultsKey];
    [defaults setDouble:_tideyEditorFileTreePreferredWidth forKey:kTideyEditorFileTreeWidthDefaultsKey];
    [defaults setBool:_shouldShowTideySidebar forKey:kTideySidebarVisibleDefaultsKey];
    [defaults setBool:_shouldShowTideyEditorPanel forKey:kTideyEditorPanelVisibleDefaultsKey];
    [defaults setBool:_shouldShowTideyEditorFileTree forKey:kTideyEditorFileTreeVisibleDefaultsKey];
    [defaults setBool:_shouldShowTideyTerminal forKey:kTideyTerminalVisibleDefaultsKey];
}

- (void)reloadTideyEditorFileTree {
    NSString *rootPath = [self tideyEditorFileTreeRootPath];
    BOOL isDirectory = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:rootPath isDirectory:&isDirectory];
    _tideyEditorFileTreeRootNode = [TideyEditorFileNode nodeWithPath:rootPath
                                                         displayName:rootPath.lastPathComponent
                                                           directory:isDirectory];
    _tideyEditorCurrentRootPath = [rootPath copy];
    [_tideyEditorFileTreeView reloadData];
    [self tideyPersistEditorState];
}

- (void)syncTideyEditorFileTreeRootIfNeeded {
    NSString *rootPath = [self tideyEditorFileTreeRootPath];
    if ((_tideyEditorCurrentRootPath ?: @"").length > 0 &&
        [rootPath isEqualToString:_tideyEditorCurrentRootPath]) {
        return;
    }
    [self reloadTideyEditorFileTree];
}

- (void)layoutTideyEditorContents {
    if (_tideyEditorPanelView.hidden) {
        [self updateTideyChromeToggleButtons];
        return;
    }
    const NSRect bounds = _tideyEditorPanelView.bounds;
    const CGFloat tabStripHeight = TideyEditorEffectiveTabStripHeight(_tabBarControl.height);
    _tideyEditorTabStripView.frame = NSMakeRect(0, NSHeight(bounds) - tabStripHeight, NSWidth(bounds), tabStripHeight);
    const CGFloat contentHeight = MAX(0, NSHeight(bounds) - tabStripHeight);
    const CGFloat fileTreeWidth = self.shouldShowTideyEditorFileTree
        ? MIN(self.tideyEditorFileTreeWidth, MAX(0, NSWidth(bounds) - kTideyMinimumEditorContentWidth))
        : 0;
    const CGFloat editorWidth = MAX(0, NSWidth(bounds) - fileTreeWidth);
    _tideyEditorWebView.frame = NSMakeRect(0, 0, editorWidth, contentHeight);
    _tideyEditorFileTreeContainerView.hidden = !self.shouldShowTideyEditorFileTree;
    _tideyEditorFileTreeContainerView.frame = NSMakeRect(editorWidth, 0, fileTreeWidth, contentHeight);
    _tideyEditorFileTreeScrollView.frame = _tideyEditorFileTreeContainerView.bounds;
    self.tideyEditorFileTreeDragHandle.frame = NSMakeRect(MAX(0, editorWidth - kTideyDragHandleWidth / 2.0),
                                                          0,
                                                          kTideyDragHandleWidth,
                                                          contentHeight);
    [self reloadTideyEditorTabs];
    [self updateTideyChromeToggleButtons];
}

- (void)tideyEditorLoadDemoFileIfNeeded {
    if (_tideyEditorLoadedDemoFile) {
        return;
    }

    NSString *sourcePath = [NSString stringWithUTF8String:__FILE__];
    NSString *sourcesDir = [sourcePath stringByDeletingLastPathComponent];
    NSString *repoRoot = [sourcesDir stringByDeletingLastPathComponent];
    NSArray<NSString *> *candidates = @[
        [repoRoot stringByAppendingPathComponent:@"README.md"],
        [repoRoot stringByAppendingPathComponent:@"sources/PseudoTerminal.m"],
    ];
    for (NSString *candidate in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            [self tideyOpenOrSelectEditorTabAtPath:candidate];
            _tideyEditorLoadedDemoFile = YES;
            return;
        }
    }

    [_tideyEditorTabs removeAllObjects];
    _tideySelectedEditorTabIndex = -1;
    [self tideyEditorSetLanguage:@"plaintext"];
    [self tideyEditorSetEditable:NO];
    [self tideyEditorSetValue:@"// Tidey editor panel\n// Demo file not found."];
    [self reloadTideyEditorTabs];
    [self tideyUpdateEditorPlaceholder];
    _tideyEditorLoadedDemoFile = YES;
}

- (TideyEditorTab *)tideyCurrentEditorTab {
    if (_tideySelectedEditorTabIndex < 0 || _tideySelectedEditorTabIndex >= (NSInteger)_tideyEditorTabs.count) {
        return nil;
    }
    return _tideyEditorTabs[_tideySelectedEditorTabIndex];
}

- (NSString *)tideyEditorDisplayNameForPath:(NSString *)path {
    NSString *name = path.lastPathComponent;
    return name.length > 0 ? name : @"Untitled";
}

- (void)tideyUpdateEditorPlaceholder {
    TideyEditorTab *tab = [self tideyCurrentEditorTab];
    BOOL hasCurrentTab = (tab != nil);
    if (!_tideyEditorReady) {
        _tideyEditorPanelLabel.hidden = NO;
        _tideyEditorPanelLabel.stringValue = @"Loading Editor…";
        return;
    }
    _tideyEditorPanelLabel.stringValue = hasCurrentTab ? @"" : @"Open a file";
    _tideyEditorPanelLabel.hidden = hasCurrentTab;
    if (!hasCurrentTab) {
        [self tideyEditorSetLanguage:@"plaintext"];
        [self tideyEditorSetEditable:NO];
        [self tideyEditorSetValue:@""];
    }
}

- (void)reloadTideyEditorTabs {
    for (NSView *subview in [_tideyEditorTabStripView.subviews copy]) {
        [subview removeFromSuperview];
    }

    _tideyEditorTabStripView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.102
                                                                         green:0.108
                                                                          blue:0.135
                                                                         alpha:1].CGColor;
    const CGFloat stripHeight = NSHeight(_tideyEditorTabStripView.bounds) > 0 ?
        NSHeight(_tideyEditorTabStripView.bounds) :
        TideyEditorEffectiveTabStripHeight(_tabBarControl.height);
    const CGFloat insetX = 0;
    const CGFloat tabHeight = MAX(22, stripHeight);
    CGFloat x = insetX;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
    };
    for (NSInteger i = 0; i < (NSInteger)_tideyEditorTabs.count; i++) {
        TideyEditorTab *tab = _tideyEditorTabs[i];
        NSString *title = tab.dirty ? [NSString stringWithFormat:@"● %@", tab.displayName ?: @"Untitled"] : (tab.displayName ?: @"Untitled");
        CGFloat textWidth = ceil([title sizeWithAttributes:attributes].width);
        CGFloat tabWidth = MIN(MAX(112, textWidth + 38), 240);

        TideyEditorTabItemView *tabView = [[TideyEditorTabItemView alloc] initWithFrame:NSMakeRect(x, 0, tabWidth, tabHeight)];
        BOOL selected = (i == _tideySelectedEditorTabIndex);
        tabView.tideySelected = selected;
        tabView.tideyHovered = NO;
        [tabView tideyUpdateAppearance];

        NSButton *selectButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 2, tabWidth - 34, tabHeight - 2)];
        selectButton.bordered = NO;
        selectButton.buttonType = NSButtonTypeMomentaryChange;
        selectButton.alignment = NSTextAlignmentLeft;
        NSFont *baseFont = [NSFont systemFontOfSize:11 weight:selected ? NSFontWeightSemibold : NSFontWeightMedium];
        selectButton.font = tab.preview ? [[NSFontManager sharedFontManager] convertFont:baseFont toHaveTrait:NSItalicFontMask] : baseFont;
        selectButton.contentTintColor = selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
        selectButton.title = title;
        selectButton.imagePosition = NSNoImage;
        selectButton.tag = i;
        selectButton.target = self;
        selectButton.action = @selector(tideyEditorSelectTab:);
        [tabView addSubview:selectButton];

        NSButton *closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(tabWidth - 22, 2, 20, tabHeight - 2)];
        closeButton.bordered = NO;
        closeButton.buttonType = NSButtonTypeMomentaryChange;
        closeButton.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        closeButton.contentTintColor = selected ? NSColor.labelColor : NSColor.secondaryLabelColor;
        closeButton.title = @"✕";
        closeButton.tag = i;
        closeButton.target = self;
        closeButton.action = @selector(tideyEditorCloseTab:);
        [tabView addSubview:closeButton];

        tabView.tideySeparatorView.hidden = (i == (NSInteger)_tideyEditorTabs.count - 1);

        [_tideyEditorTabStripView addSubview:tabView];
        x += tabWidth;
    }
}

- (void)selectTideyEditorTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tideyEditorTabs.count) {
        return;
    }
    _tideySelectedEditorTabIndex = index;
    TideyEditorTab *tab = _tideyEditorTabs[index];
    _tideyEditorLoadedPath = [tab.path copy];
    _tideyEditorRootOverridePath = [[self tideyEditorPreferredRootPathForFileAtPath:tab.path] copy];
    [self reloadTideyEditorTabs];
    [self reloadTideyEditorFileTree];
    [self tideyEditorSetLanguage:tab.language ?: @"plaintext"];
    [self tideyEditorSetEditable:YES];
    [self tideyEditorSetValue:tab.content ?: @""];
    [self tideyEditorRevealFileAtPath:tab.path];
    [self tideyPersistEditorState];
    [self tideyUpdateEditorPlaceholder];
}

- (void)closeTideyEditorTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tideyEditorTabs.count) {
        return;
    }
    [_tideyEditorTabs removeObjectAtIndex:index];
    if (_tideyEditorTabs.count == 0) {
        _tideySelectedEditorTabIndex = -1;
        _tideyEditorLoadedPath = nil;
        _tideyEditorRootOverridePath = nil;
        [self reloadTideyEditorFileTree];
        [self reloadTideyEditorTabs];
        [self tideyUpdateEditorPlaceholder];
        [self tideyPersistEditorState];
        return;
    }
    NSInteger newIndex = MIN(index, (NSInteger)_tideyEditorTabs.count - 1);
    [self selectTideyEditorTabAtIndex:newIndex];
}

- (void)tideyEditorSelectTab:(id)sender {
    [self selectTideyEditorTabAtIndex:[sender tag]];
}

- (void)tideyEditorCloseTab:(id)sender {
    [self closeTideyEditorTabAtIndex:[sender tag]];
}

- (void)tideyOpenOrSelectEditorTabAtPath:(NSString *)path {
    [self tideyOpenEditorFileAtPath:path preview:NO];
}

- (void)tideyOpenEditorFileAtPath:(NSString *)path preview:(BOOL)preview {
    NSString *normalizedPath = [path stringByStandardizingPath];
    if (normalizedPath.length == 0) {
        return;
    }
    for (NSInteger i = 0; i < (NSInteger)_tideyEditorTabs.count; i++) {
        TideyEditorTab *existing = _tideyEditorTabs[i];
        if ([[existing.path stringByStandardizingPath] isEqualToString:normalizedPath]) {
            if (!preview && existing.preview) {
                existing.preview = NO;
                [self reloadTideyEditorTabs];
            }
            [self selectTideyEditorTabAtIndex:i];
            return;
        }
    }

    TideyEditorTab *previewTab = nil;
    NSInteger previewIndex = NSNotFound;
    if (preview) {
        for (NSInteger i = 0; i < (NSInteger)_tideyEditorTabs.count; i++) {
            TideyEditorTab *candidate = _tideyEditorTabs[i];
            if (candidate.preview) {
                previewTab = candidate;
                previewIndex = i;
                break;
            }
        }
        if (previewTab.dirty) {
            previewTab.preview = NO;
            [self reloadTideyEditorTabs];
            previewTab = nil;
            previewIndex = NSNotFound;
        }
    }

    if (preview && previewTab != nil) {
        NSError *replaceError = nil;
        NSString *replacementContents = [NSString stringWithContentsOfFile:normalizedPath
                                                                  encoding:NSUTF8StringEncoding
                                                                     error:&replaceError];
        if (replacementContents == nil) {
            replacementContents = [NSString stringWithFormat:@"Unable to load %@\n\n%@",
                                   normalizedPath.lastPathComponent,
                                   replaceError.localizedDescription ?: @"Unknown error"];
        }
        previewTab.path = normalizedPath;
        previewTab.displayName = [self tideyEditorDisplayNameForPath:normalizedPath];
        previewTab.language = [self tideyEditorLanguageForPath:normalizedPath];
        previewTab.content = replacementContents ?: @"";
        previewTab.dirty = NO;
        previewTab.preview = YES;
        [self selectTideyEditorTabAtIndex:previewIndex];
        return;
    }

    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:normalizedPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    if (contents == nil) {
        contents = [NSString stringWithFormat:@"Unable to load %@\n\n%@",
                    normalizedPath.lastPathComponent,
                    error.localizedDescription ?: @"Unknown error"];
    }
    TideyEditorTab *tab = [TideyEditorTab tabWithPath:normalizedPath
                                          displayName:[self tideyEditorDisplayNameForPath:normalizedPath]
                                             language:[self tideyEditorLanguageForPath:normalizedPath]
                                              content:contents];
    tab.preview = preview;
    [_tideyEditorTabs addObject:tab];
    [self selectTideyEditorTabAtIndex:_tideyEditorTabs.count - 1];
}

- (void)tideyEditorLoadFileAtPath:(NSString *)path {
    [self tideyOpenOrSelectEditorTabAtPath:path];
}

- (NSString *)tideyEditorPreferredRootPathForFileAtPath:(NSString *)path {
    NSString *normalizedPath = [path stringByStandardizingPath];
    if (normalizedPath.length == 0) {
        return [self tideyEditorFileTreeRootPath];
    }
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:normalizedPath isDirectory:&isDirectory]) {
        return [self tideyEditorFileTreeRootPath];
    }
    NSString *candidate = isDirectory ? normalizedPath : normalizedPath.stringByDeletingLastPathComponent;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    while (candidate.length > 1) {
        NSString *gitPath = [candidate stringByAppendingPathComponent:@".git"];
        BOOL gitExists = [fileManager fileExistsAtPath:gitPath];
        if (gitExists) {
            return candidate;
        }
        NSString *parent = candidate.stringByDeletingLastPathComponent;
        if (parent.length == 0 || [parent isEqualToString:candidate]) {
            break;
        }
        candidate = parent;
    }
    NSString *homePath = [NSHomeDirectory() stringByStandardizingPath];
    if (homePath.length > 0 &&
        ([normalizedPath isEqualToString:homePath] ||
         [normalizedPath hasPrefix:[homePath stringByAppendingString:@"/"]])) {
        return homePath;
    }
    return isDirectory ? normalizedPath : normalizedPath.stringByDeletingLastPathComponent;
}

- (void)tideyEditorRevealFileAtPath:(NSString *)path {
    NSString *targetPath = [path stringByStandardizingPath];
    NSString *rootPath = [[self tideyEditorFileTreeRootPath] stringByStandardizingPath];
    if (targetPath.length == 0 || rootPath.length == 0) {
        return;
    }

    if (![targetPath isEqualToString:rootPath] &&
        ![targetPath hasPrefix:[rootPath stringByAppendingString:@"/"]]) {
        return;
    }

    NSString *relativePath = [targetPath isEqualToString:rootPath]
        ? @""
        : [targetPath substringFromIndex:[rootPath stringByAppendingString:@"/"].length];
    NSArray<NSString *> *components = relativePath.length > 0 ? [relativePath pathComponents] : @[];

    TideyEditorFileNode *currentNode = _tideyEditorFileTreeRootNode;
    TideyEditorFileNode *targetNode = nil;
    NSString *currentPath = rootPath;
    for (NSString *component in components) {
        NSString *nextPath = [currentPath stringByAppendingPathComponent:component];
        TideyEditorFileNode *nextNode = nil;
        for (TideyEditorFileNode *child in [currentNode loadChildren]) {
            if ([[child.path stringByStandardizingPath] isEqualToString:nextPath]) {
                nextNode = child;
                break;
            }
        }
        if (!nextNode) {
            return;
        }
        targetNode = nextNode;
        currentPath = nextPath;
        currentNode = nextNode;
        if (nextNode.directory) {
            [_tideyEditorFileTreeView expandItem:nextNode];
        }
    }

    if (!targetNode) {
        return;
    }
    NSInteger row = [_tideyEditorFileTreeView rowForItem:targetNode];
    if (row != -1) {
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:row];
        _tideyEditorIsRevealingSelection = YES;
        [_tideyEditorFileTreeView selectRowIndexes:indexSet byExtendingSelection:NO];
        [_tideyEditorFileTreeView scrollRowToVisible:row];
        _tideyEditorIsRevealingSelection = NO;
    }
}

- (void)openTideyEditorFileAtPath:(NSString *)path {
    if (path.length == 0) {
        return;
    }
    _tideyEditorRootOverridePath = [[self tideyEditorPreferredRootPathForFileAtPath:path] copy];
    if (_tideyEditorPanelView.hidden) {
        self.shouldShowTideyEditorPanel = YES;
        [self layoutSubviews];
    }
    [self reloadTideyEditorFileTree];
    [self tideyOpenOrSelectEditorTabAtPath:path];
}

- (NSString *)tideyEditorLanguageForPath:(NSString *)path {
    NSString *extension = path.pathExtension.lowercaseString;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"m": @"objective-c",
            @"mm": @"objective-cpp",
            @"h": @"objective-c",
            @"swift": @"swift",
            @"md": @"markdown",
            @"markdown": @"markdown",
            @"js": @"javascript",
            @"ts": @"typescript",
            @"json": @"json",
            @"html": @"html",
            @"css": @"css",
            @"py": @"python",
            @"sh": @"shell",
            @"zsh": @"shell",
            @"yaml": @"yaml",
            @"yml": @"yaml",
            @"xml": @"xml",
            @"plist": @"xml",
        };
    });
    return map[extension] ?: @"plaintext";
}

- (void)tideyEditorSetValue:(NSString *)content {
    _tideyEditorPendingValue = [content copy] ?: @"";
    [self tideyEditorApplyPendingStateIfReady];
}

- (void)tideyEditorSetLanguage:(NSString *)language {
    _tideyEditorPendingLanguage = [language copy] ?: @"plaintext";
    [self tideyEditorApplyPendingStateIfReady];
}

- (void)tideyEditorSetEditable:(BOOL)editable {
    _tideyEditorPendingEditable = @(editable);
    [self tideyEditorApplyPendingStateIfReady];
}

- (void)tideyEditorApplyPendingStateIfReady {
    if (!_tideyEditorReady || _tideyEditorWebView == nil) {
        return;
    }
    if (_tideyEditorPendingLanguage != nil) {
        NSString *js = [NSString stringWithFormat:@"window.tideyNative && window.tideyNative.setLanguage(%@);",
                        [NSJSONSerialization it_jsonStringForObject:_tideyEditorPendingLanguage]];
        [_tideyEditorWebView evaluateJavaScript:js completionHandler:nil];
    }
    if (_tideyEditorPendingValue != nil) {
        NSString *js = [NSString stringWithFormat:@"window.tideyNative && window.tideyNative.setValue(%@);",
                        [NSJSONSerialization it_jsonStringForObject:_tideyEditorPendingValue]];
        [_tideyEditorWebView evaluateJavaScript:js completionHandler:nil];
    }
    if (_tideyEditorPendingEditable != nil) {
        NSString *js = [NSString stringWithFormat:@"window.tideyNative && window.tideyNative.setEditable(%@);",
                        _tideyEditorPendingEditable.boolValue ? @"true" : @"false"];
        [_tideyEditorWebView evaluateJavaScript:js completionHandler:nil];
    }
    [_tideyEditorWebView evaluateJavaScript:@"window.__tideyEditor && window.__tideyEditor.layout();"
                          completionHandler:nil];
}

- (void)tideyEditorDidBecomeReady {
    _tideyEditorReady = YES;
    [self tideyEditorApplyPendingStateIfReady];
    NSString *restoredPath = [_tideyEditorLoadedPath stringByStandardizingPath];
    BOOL isDirectory = NO;
    if (restoredPath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:restoredPath isDirectory:&isDirectory] &&
        !isDirectory) {
        [self reloadTideyEditorFileTree];
        [self tideyOpenOrSelectEditorTabAtPath:restoredPath];
        [self tideyEditorRevealFileAtPath:restoredPath];
        _tideyEditorLoadedDemoFile = YES;
    } else {
        _tideyEditorLoadedPath = nil;
        _tideyEditorRootOverridePath = nil;
        [self reloadTideyEditorFileTree];
    }
    [self tideyUpdateEditorPlaceholder];
}

- (void)tideyEditorDidReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"tideyEditorReady"]) {
        [self tideyEditorDidBecomeReady];
        return;
    }
    if ([message.name isEqualToString:@"tideyEditorChanged"] &&
        [message.body isKindOfClass:[NSDictionary class]]) {
        NSString *value = [message.body[@"value"] isKindOfClass:[NSString class]] ? message.body[@"value"] : @"";
        [self tideyEditorDidChangeValue:value];
        return;
    }
    if ([message.name isEqualToString:@"tideyEditorSaveRequested"]) {
        [self saveTideyEditorCurrentTab];
    }
}

- (void)tideyEditorDidChangeValue:(NSString *)value {
    TideyEditorTab *tab = [self tideyCurrentEditorTab];
    if (!tab) {
        return;
    }
    BOOL wasDirty = tab.dirty;
    BOOL wasPreview = tab.preview;
    tab.content = value ?: @"";
    tab.dirty = YES;
    if (wasPreview) {
        tab.preview = NO;
    }
    if (!wasDirty || wasPreview) {
        [self reloadTideyEditorTabs];
    }
}

- (BOOL)hasSaveableTideyEditorTab {
    return ([self tideyCurrentEditorTab] != nil);
}

- (BOOL)saveTideyEditorCurrentTab {
    TideyEditorTab *tab = [self tideyCurrentEditorTab];
    if (!tab || tab.path.length == 0) {
        return NO;
    }
    NSError *error = nil;
    BOOL ok = [(tab.content ?: @"") writeToFile:tab.path
                                     atomically:YES
                                       encoding:NSUTF8StringEncoding
                                          error:&error];
    if (!ok) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Unable to Save File";
        alert.informativeText = error.localizedDescription ?: @"Unknown error";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return NO;
    }
    tab.dirty = NO;
    [self reloadTideyEditorTabs];
    [self tideyPersistEditorState];
    return YES;
}

- (BOOL)tideyEditorShouldHandleFindPanelAction {
    if (_tideyEditorPanelView.hidden || !_tideyEditorWebView) {
        return NO;
    }
    id responder = self.window.firstResponder;
    if (![responder isKindOfClass:[NSView class]]) {
        return NO;
    }
    return [(NSView *)responder isDescendantOf:_tideyEditorWebView];
}

- (BOOL)tideyEditorHasFocus {
    return [self tideyEditorShouldHandleFindPanelAction];
}

- (BOOL)closeCurrentTideyEditorTab {
    if (![self tideyEditorHasFocus] || _tideySelectedEditorTabIndex < 0) {
        return NO;
    }
    [self closeTideyEditorTabAtIndex:_tideySelectedEditorTabIndex];
    return YES;
}

- (IBAction)performFindPanelAction:(id)sender {
    if ([self tideyEditorShouldHandleFindPanelAction]) {
        NSInteger tag = [sender isKindOfClass:[NSMenuItem class]] ? ((NSMenuItem *)sender).tag : NSFindPanelActionShowFindPanel;
        NSString *js = nil;
        switch ((NSFindPanelAction)tag) {
            case NSFindPanelActionShowFindPanel:
                js = @"window.__tideyEditor && window.__tideyEditor.getAction('actions.find').run();";
                break;
            case NSFindPanelActionNext:
                js = @"window.__tideyEditor && window.__tideyEditor.getAction('editor.action.nextMatchFindAction').run();";
                break;
            case NSFindPanelActionPrevious:
                js = @"window.__tideyEditor && window.__tideyEditor.getAction('editor.action.previousMatchFindAction').run();";
                break;
            default:
                break;
        }
        if (js) {
            [_tideyEditorWebView evaluateJavaScript:js completionHandler:nil];
            return;
        }
    }

    NSResponder *nextResponder = self.nextResponder;
    if ([nextResponder respondsToSelector:@selector(performFindPanelAction:)]) {
        [(id)nextResponder performFindPanelAction:sender];
    }
}

- (NSString *)tideyEditorHTML {
    NSString *baseURLString = [[self tideyEditorMonacoBaseURL] absoluteString];
    NSString *vsURLString = [[self tideyEditorMonacoVSURL] absoluteString];
    NSString *loaderURLString = [[self tideyEditorMonacoLoaderURL] absoluteString];
    NSString *workerURLString = [[self tideyEditorMonacoWorkerURL] absoluteString];
    return [NSString stringWithFormat:@"<!doctype html>"
            "<html><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            "<style>"
            "html, body, #editor { margin:0; padding:0; width:100%%; height:100%%; overflow:hidden; background:#16181d; }"
            "body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }"
            "</style>"
            "<script>"
            "window.MonacoEnvironment = {"
            "  getWorkerUrl: function() {"
            "    const worker = `self.MonacoEnvironment = { baseUrl: '%@' };"
            "importScripts('%@');`;"
            "    return 'data:text/javascript;charset=utf-8,' + encodeURIComponent(worker);"
            "  }"
            "};"
            "window.tideyNative = {"
            "  setValue(value) {"
            "    window.__tideyPendingValue = value || '';"
            "    if (window.__tideyEditor) { window.__tideyApplyingNativeUpdate = true; window.__tideyEditor.setValue(window.__tideyPendingValue); window.__tideyApplyingNativeUpdate = false; }"
            "  },"
            "  setLanguage(language) {"
            "    window.__tideyPendingLanguage = language || 'plaintext';"
            "    if (window.__tideyEditor) {"
            "      const model = window.__tideyEditor.getModel();"
            "      if (model) { monaco.editor.setModelLanguage(model, window.__tideyPendingLanguage); }"
            "    }"
            "  },"
            "  setEditable(editable) {"
            "    window.__tideyPendingEditable = !!editable;"
            "    if (window.__tideyEditor) { window.__tideyEditor.updateOptions({ readOnly: !window.__tideyPendingEditable }); }"
            "  }"
            "};"
            "</script>"
            "<script src='%@'></script>"
            "</head><body><div id='editor'></div>"
            "<script>"
            "require.config({ paths: { vs: '%@' } });"
            "require(['vs/editor/editor.main'], function() {"
            "  window.__tideyEditor = monaco.editor.create(document.getElementById('editor'), {"
            "    value: '',"
            "    language: 'plaintext',"
            "    theme: 'vs-dark',"
            "    readOnly: false,"
            "    automaticLayout: true,"
            "    wordWrap: 'on',"
            "    wordWrapColumn: 80,"
            "    minimap: { enabled: false },"
            "    scrollBeyondLastLine: false,"
            "    fontSize: 13"
            "  });"
            "  window.__tideyEditor.onDidChangeModelContent(function() {"
            "    if (window.__tideyApplyingNativeUpdate) { return; }"
            "    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tideyEditorChanged) {"
            "      window.webkit.messageHandlers.tideyEditorChanged.postMessage({ value: window.__tideyEditor.getValue() });"
            "    }"
            "  });"
            "  window.addEventListener('keydown', function(event) {"
            "    if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && (event.key === 's' || event.key === 'S')) {"
            "      event.preventDefault();"
            "      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tideyEditorSaveRequested) {"
            "        window.webkit.messageHandlers.tideyEditorSaveRequested.postMessage({});"
            "      }"
            "    }"
            "  });"
            "  if (window.__tideyPendingLanguage) { window.tideyNative.setLanguage(window.__tideyPendingLanguage); }"
            "  if (window.__tideyPendingValue !== undefined) { window.tideyNative.setValue(window.__tideyPendingValue); }"
            "  if (window.__tideyPendingEditable !== undefined) { window.tideyNative.setEditable(window.__tideyPendingEditable); }"
            "  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tideyEditorReady) {"
            "    window.webkit.messageHandlers.tideyEditorReady.postMessage({ ready: true });"
            "  }"
            "});"
            "</script></body></html>",
            baseURLString,
            workerURLString,
            loaderURLString,
            vsURLString];
}

- (NSString *)tideySidebarWorkspaceTitleAtIndex:(NSInteger)index {
    return [self.delegate rootTerminalViewTideySidebarWorkspaceTitleAtIndex:index] ?: @"Untitled";
}

- (NSString *)tideySidebarWorkspaceSubtitleAtIndex:(NSInteger)index {
    return [self.delegate rootTerminalViewTideySidebarWorkspaceSubtitleAtIndex:index] ?: @"";
}

- (NSString *)tideySidebarWorkspaceIdentifierAtIndex:(NSInteger)index {
    return [self.delegate rootTerminalViewTideySidebarWorkspaceIdentifierAtIndex:index] ?: @"";
}

- (NSInteger)tideySidebarWorkspaceUnreadCountAtIndex:(NSInteger)index {
    NSString *workspaceID = [self tideySidebarWorkspaceIdentifierAtIndex:index];
    if (workspaceID.length == 0) {
        return 0;
    }
    return [[TideyNotificationStore sharedStore] unreadCountForWorkspaceID:workspaceID];
}

- (BOOL)tideySidebarWorkspacePinnedAtIndex:(NSInteger)index {
    return [self.delegate rootTerminalViewTideySidebarWorkspaceIsPinnedAtIndex:index];
}

- (NSInteger)tideySidebarSelectedWorkspaceIndex {
    return [self.delegate rootTerminalViewSelectedTideySidebarWorkspaceIndex];
}

- (void)syncTideySidebarSelection {
    const NSInteger index = self.tideySidebarSelectedWorkspaceIndex;
    if (index < 0 || index >= self.numberOfTideySidebarWorkspaces) {
        [_tideySidebarTableView deselectAll:nil];
        return;
    }
    NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:index];
    [_tideySidebarTableView selectRowIndexes:indexSet byExtendingSelection:NO];
    [_tideySidebarTableView scrollRowToVisible:index];
}

- (TideyNotificationItem *)tideySidebarLatestUnreadNotificationAtIndex:(NSInteger)index {
    NSString *workspaceID = [self tideySidebarWorkspaceIdentifierAtIndex:index];
    if (workspaceID.length == 0) {
        return nil;
    }
    return [[TideyNotificationStore sharedStore] latestUnreadForWorkspaceID:workspaceID];
}

- (NSInteger)tideySidebarWorkspaceIndexForIdentifier:(NSString *)workspaceIdentifier {
    if (workspaceIdentifier.length == 0) {
        return NSNotFound;
    }
    NSInteger count = self.numberOfTideySidebarWorkspaces;
    for (NSInteger i = 0; i < count; i++) {
        if ([[self tideySidebarWorkspaceIdentifierAtIndex:i] isEqualToString:workspaceIdentifier]) {
            return i;
        }
    }
    return NSNotFound;
}

- (void)tideyNotificationStoreDidChange:(NSNotification *)notification {
    (void)notification;
    [self layoutTideySidebar];
    [self reloadTideySidebar];
}

- (void)layoutTideySidebar {
    const CGFloat width = self.tideySidebarWidth;
    _tideySidebarView.hidden = (width <= 0);
    if (width > 0) {
        _tideySidebarView.frame = NSMakeRect(0, 0, width, NSHeight(self.bounds));
        CGFloat sidebarHeight = NSHeight(_tideySidebarView.bounds);
        _tideySidebarScrollView.frame = NSMakeRect(0, 0, width, sidebarHeight);
    }
    [self updateTideyChromeToggleButtons];
}

- (void)layoutTideyEditorPanelWithOutputs:(iTermLayoutOutputs)outputs {
    const CGFloat width = self.tideyEditorPanelWidth;
    _tideyEditorPanelView.hidden = (width <= 0);
    if (width <= 0) {
        return;
    }

    [self loadTideyEditorShellIfNeeded];
    [self syncTideyEditorFileTreeRootIfNeeded];

    const CGFloat rightEdge = self.shouldShowToolbelt ? NSMinX(outputs.toolbeltFrame) : NSWidth(self.bounds);
    const CGFloat originX = MAX(0, rightEdge - width);
    _tideyEditorPanelView.frame = NSMakeRect(originX, 0, MIN(width, rightEdge), NSHeight(self.bounds));
    [self layoutTideyEditorContents];
    if (_tideyEditorReady) {
        [_tideyEditorWebView evaluateJavaScript:@"window.__tideyEditor && window.__tideyEditor.layout();"
                              completionHandler:nil];
    }
}

- (iTermLayoutOutputs)layoutOutputsByApplyingTideyChromeOffsets:(iTermLayoutOutputs)outputs {
    const CGFloat sidebarWidth = self.tideySidebarWidth;
    if (sidebarWidth > 0) {
        outputs.tabViewFrame.origin.x += sidebarWidth;
        outputs.statusBarFrame.origin.x += sidebarWidth;
        outputs.toolbeltFrame.origin.x += sidebarWidth;
        outputs.tabBarFrame.origin.x += sidebarWidth;
    }

    const CGFloat editorWidth = self.tideyEditorPanelWidth;
    if (editorWidth > 0) {
        outputs.tabViewFrame.size.width = MAX(0, outputs.tabViewFrame.size.width - editorWidth);
        outputs.statusBarFrame.size.width = MAX(0, outputs.statusBarFrame.size.width - editorWidth);
        outputs.tabBarFrame.size.width = MAX(0, outputs.tabBarFrame.size.width - editorWidth);
    }

    if (!self.shouldShowTideyTerminal) {
        outputs.tabViewFrame.size.width = 0;
        outputs.statusBarFrame.size.width = 0;
        outputs.tabBarFrame.size.width = 0;
    }

    return outputs;
}

- (void)updateTideyChromeDragHandles {
    const CGFloat sidebarWidth = self.tideySidebarWidth;
    self.tideySidebarDragHandle.hidden = (sidebarWidth <= 0);
    if (sidebarWidth > 0) {
        self.tideySidebarDragHandle.frame = NSMakeRect(MAX(0, sidebarWidth - kTideyDragHandleWidth / 2.0),
                                                       0,
                                                       kTideyDragHandleWidth,
                                                       NSHeight(self.bounds));
    }

    const CGFloat editorWidth = self.tideyEditorPanelWidth;
    self.tideyEditorDragHandle.hidden = (editorWidth <= 0 || _tideyEditorPanelView.hidden || !self.shouldShowTideyTerminal);
    if (editorWidth > 0 && !_tideyEditorPanelView.hidden && self.shouldShowTideyTerminal) {
        self.tideyEditorDragHandle.frame = NSMakeRect(MAX(0, NSMinX(_tideyEditorPanelView.frame) - kTideyDragHandleWidth / 2.0),
                                                      0,
                                                      kTideyDragHandleWidth,
                                                      NSHeight(self.bounds));
    }

    const CGFloat fileTreeWidth = self.shouldShowTideyEditorFileTree ? self.tideyEditorFileTreeWidth : 0;
    self.tideyEditorFileTreeDragHandle.hidden = (_tideyEditorPanelView.hidden ||
                                                 !self.shouldShowTideyEditorFileTree ||
                                                 fileTreeWidth <= 0);
    [self updateTideyChromeToggleButtons];
}

- (void)updateTideyChromeToggleButtons {
    const CGFloat sidebarButtonY = floor((NSHeight(self.bounds) - kTideyChromeToggleButtonHeight) / 2.0);
    self.tideySidebarToggleButton.hidden = NO;
    self.tideySidebarToggleButton.title = self.shouldShowTideySidebar ? @"◀" : @"▶";
    const CGFloat sidebarButtonX = self.shouldShowTideySidebar
        ? MAX(0, self.tideySidebarWidth - kTideyChromeToggleButtonWidth - 1)
        : 0;
    self.tideySidebarToggleButton.frame = NSMakeRect(sidebarButtonX,
                                                     sidebarButtonY,
                                                     kTideyChromeToggleButtonWidth,
                                                     kTideyChromeToggleButtonHeight);

    const BOOL showTerminalToggle = self.shouldShowTideyEditorPanel;
    self.tideyTerminalToggleButton.hidden = !showTerminalToggle;
    if (showTerminalToggle) {
        self.tideyTerminalToggleButton.title = self.shouldShowTideyTerminal ? @"◀" : @"▶";
        const CGFloat terminalButtonX = self.shouldShowTideyTerminal
            ? MAX(0, NSMinX(_tideyEditorPanelView.frame) - kTideyChromeToggleButtonWidth - 1)
            : MAX(0, NSMinX(_tideyEditorPanelView.frame) + 1);
        self.tideyTerminalToggleButton.frame = NSMakeRect(terminalButtonX,
                                                          sidebarButtonY,
                                                          kTideyChromeToggleButtonWidth,
                                                          kTideyChromeToggleButtonHeight);
    }

    const BOOL showEditorToggle = !self.shouldShowTideyEditorPanel || self.shouldShowTideyTerminal;
    self.tideyEditorToggleButton.hidden = !showEditorToggle;
    if (showEditorToggle) {
        self.tideyEditorToggleButton.title = self.shouldShowTideyEditorPanel ? @"▶" : @"◀";
        const CGFloat editorButtonX = self.shouldShowTideyEditorPanel
            ? MAX(0, NSWidth(self.bounds) - self.tideyEditorPanelWidth + 1)
            : MAX(0, NSWidth(self.bounds) - kTideyChromeToggleButtonWidth - 1);
        self.tideyEditorToggleButton.frame = NSMakeRect(editorButtonX,
                                                        sidebarButtonY,
                                                        kTideyChromeToggleButtonWidth,
                                                        kTideyChromeToggleButtonHeight);
    }

    const BOOL showFileTreeToggle = self.shouldShowTideyEditorPanel;
    self.tideyEditorFileTreeToggleButton.hidden = !showFileTreeToggle;
    if (!showFileTreeToggle) {
        return;
    }
    self.tideyEditorFileTreeToggleButton.title = self.shouldShowTideyEditorFileTree ? @"▶" : @"◀";
    const CGFloat editorPanelWidth = NSWidth(_tideyEditorPanelView.bounds);
    const CGFloat fileTreeButtonX = self.shouldShowTideyEditorFileTree
        ? MAX(0, editorPanelWidth - self.tideyEditorFileTreeWidth + 1)
        : MAX(0, editorPanelWidth - kTideyChromeToggleButtonWidth - 1);
    const CGFloat fileTreeButtonY = floor((NSHeight(_tideyEditorPanelView.bounds) - kTideyChromeToggleButtonHeight) / 2.0);
    self.tideyEditorFileTreeToggleButton.frame = NSMakeRect(fileTreeButtonX,
                                                            fileTreeButtonY,
                                                            kTideyChromeToggleButtonWidth,
                                                            kTideyChromeToggleButtonHeight);
}

- (void)layoutSubviewsWithHiddenTabBarForWindow:(NSWindow *)thisWindow {
    if (!_tabBarControlOnLoan) {
        self.tabBarControl.hidden = YES;
    }
    if ([self.delegate rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar]) {
        [self layoutSubviewsTopTabBarVisible:NO forWindow:thisWindow];
        return;
    }

    [self removeLeftTabBarDragHandle];

    // Build inputs and calculate layout using the calculator
    iTermLayoutInputs inputs = [self layoutInputsForWindow:thisWindow];
    inputs.tabBarVisible = NO;  // Force hidden for this method
    iTermLayoutOutputs outputs = [iTermLayoutCalculator calculateLayoutWithInputs:inputs];
    outputs = [self layoutOutputsByApplyingTideyChromeOffsets:outputs];

    // Apply tab view frame
    DLog(@"repositionWidgets - Set tab view frame to %@", NSStringFromRect(outputs.tabViewFrame));
    [self.tabView setFrame:outputs.tabViewFrame];

    // Layout status bar using calculator outputs
    [self layoutStatusBarWithOutputs:outputs window:thisWindow];
    [self layoutTideyEditorPanelWithOutputs:outputs];

    [self updateDivisionViewAndWindowNumberLabel];

    // Even though it's not visible it needs an accurate number so we can compute the proper
    // window size when it appears.
    [self setLeftTabBarWidthFromPreferredWidth];

    if ([_delegate iTermTabBarWindowIsFullScreen]) {
        // When in full screen the insets must be reset even though the tab bar is not visible.
        self.tabBarControl.insets = [self.delegate tabBarInsets];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView == _tideyEditorWebView) {
        [self tideyEditorApplyPendingStateIfReady];
    }
}

- (void)layoutSubviewsTopTabBarVisible:(BOOL)topTabBarVisible forWindow:(NSWindow *)thisWindow {
    [self removeLeftTabBarDragHandle];

    // Build inputs and calculate layout using the calculator
    iTermLayoutInputs inputs = [self layoutInputsForWindow:thisWindow];
    inputs.tabBarVisible = topTabBarVisible;
    inputs.tabPosition = kLayoutTabPositionTop;
    iTermLayoutOutputs outputs = [iTermLayoutCalculator calculateLayoutWithInputs:inputs];
    outputs = [self layoutOutputsByApplyingTideyChromeOffsets:outputs];

    // Apply tab view frame
    DLog(@"repositionWidgets - Set tab view frame to %@", NSStringFromRect(outputs.tabViewFrame));
    [self.tabView setFrame:outputs.tabViewFrame];

    // Layout status bar using calculator outputs
    [self layoutStatusBarWithOutputs:outputs window:thisWindow];
    [self layoutTideyEditorPanelWithOutputs:outputs];

    [self updateDivisionViewAndWindowNumberLabel];

    if (!_tabBarControlOnLoan) {
        self.tabBarControl.insets = [self.delegate tabBarInsets];
        [self setTabBarFrame:outputs.tabBarFrame];
        [self setTabBarControlAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    }
}

- (void)setTabBarFrame:(NSRect)frame {
    assert(!_tabBarControlOnLoan);
    _tabBarBacking.frame = frame;
    self.tabBarControl.frame = _tabBarBacking.bounds;
}

- (void)layoutSubviewsWithVisibleBottomTabBarForWindow:(NSWindow *)thisWindow {
    assert(!_tabBarControlOnLoan);
    DLog(@"repositionWidgets - putting tabs at bottom");
    [self removeLeftTabBarDragHandle];

    // Build inputs and calculate layout using the calculator
    iTermLayoutInputs inputs = [self layoutInputsForWindow:thisWindow];
    inputs.tabBarVisible = YES;
    inputs.tabPosition = kLayoutTabPositionBottom;
    iTermLayoutOutputs outputs = [iTermLayoutCalculator calculateLayoutWithInputs:inputs];
    outputs = [self layoutOutputsByApplyingTideyChromeOffsets:outputs];

    // Apply tab bar frame and settings
    self.tabBarControl.insets = [self.delegate tabBarInsets];
    [self setTabBarFrame:outputs.tabBarFrame];
    [self setTabBarControlAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];

    // Apply tab view frame
    DLog(@"repositionWidgets - Set tab view frame to %@", NSStringFromRect(outputs.tabViewFrame));
    self.tabView.frame = outputs.tabViewFrame;

    // Layout status bar using calculator outputs
    [self layoutStatusBarWithOutputs:outputs window:thisWindow];
    [self layoutTideyEditorPanelWithOutputs:outputs];

    [self updateDivisionViewAndWindowNumberLabel];
}

- (void)setTabBarControlAutoresizingMask:(NSAutoresizingMaskOptions)mask {
    if (_tabBarBacking) {
        _tabBarBacking.autoresizingMask = mask;
        _tabBarControl.autoresizingMask = (NSViewWidthSizable | NSViewHeightSizable);
        return;
    }

    _tabBarControl.autoresizingMask = mask;
}

- (void)layoutSubviewsWithVisibleLeftTabBarAndInlineToolbelt:(BOOL)showToolbeltInline forWindow:(NSWindow *)thisWindow {
    assert(!_tabBarControlOnLoan);
    [self setLeftTabBarWidthFromPreferredWidth];

    // Build inputs and calculate layout using the calculator
    iTermLayoutInputs inputs = [self layoutInputsForWindow:thisWindow];
    inputs.tabBarVisible = YES;
    inputs.tabPosition = kLayoutTabPositionLeft;
    iTermLayoutOutputs outputs = [iTermLayoutCalculator calculateLayoutWithInputs:inputs];
    outputs = [self layoutOutputsByApplyingTideyChromeOffsets:outputs];

    // Apply tab bar frame and settings
    self.tabBarControl.insets = [self.delegate tabBarInsets];
    [self setTabBarFrame:outputs.tabBarFrame];
    [self setTabBarControlAutoresizingMask:(NSViewHeightSizable | NSViewMaxXMargin)];

    // Apply tab view frame
    DLog(@"repositionWidgets - Set tab view frame to %@", NSStringFromRect(outputs.tabViewFrame));
    self.tabView.frame = outputs.tabViewFrame;

    // Layout status bar using calculator outputs
    [self layoutStatusBarWithOutputs:outputs window:thisWindow];
    [self layoutTideyEditorPanelWithOutputs:outputs];

    [self updateDivisionViewAndWindowNumberLabel];

    // Handle left tab bar drag handle
    [self updateLeftTabBarDragHandleForTabBarFrame:outputs.tabBarFrame];
}

- (void)updateLeftTabBarDragHandleForTabBarFrame:(CGRect)tabBarFrame {
    if (CGRectIsEmpty(tabBarFrame)) {
        [self removeLeftTabBarDragHandle];
        return;
    }

    const CGFloat dragHandleWidth = 3;
    NSRect leftTabBarDragHandleFrame = NSMakeRect(NSMaxX(tabBarFrame) - dragHandleWidth,
                                                  0,
                                                  dragHandleWidth,
                                                  NSHeight(tabBarFrame));
    if (!self.leftTabBarDragHandle) {
        self.leftTabBarDragHandle = [[iTermDragHandleView alloc] initWithFrame:leftTabBarDragHandleFrame];
        self.leftTabBarDragHandle.delegate = self;
        [self addSubview:self.leftTabBarDragHandle];
    } else {
        self.leftTabBarDragHandle.frame = leftTabBarDragHandleFrame;
    }
}

- (void)layoutWindowPaneDecorations {
    [self updateTextColors];
    if (_windowTitleLabel.windowIcon) {
        [self setWindowTitleLabelToString:_windowTitleLabel.windowTitle
                                 subtitle:_windowTitleLabel.subtitle
                                     icon:_windowTitleLabel.windowIcon];
    }

    [self updateWindowNumberFont];

    if ([self.delegate enableStoplightHotbox]) {
        _stoplightHotbox.hidden = NO;
        _stoplightHotbox.alphaValue = 0;
        _standardWindowButtonsView.alphaValue = 0;
        [_stoplightHotbox setFrameOrigin:NSMakePoint(0, self.frame.size.height - _stoplightHotbox.frame.size.height)];
        if (_windowNumberLabel.superview != _stoplightHotbox) {
            [_stoplightHotbox addSubview:_windowNumberLabel];
        }
    } else {
        _stoplightHotbox.hidden = YES;
        _standardWindowButtonsView.alphaValue = 1;
        if (_windowNumberLabel.superview != self) {
            [self addSubview:_windowNumberLabel];
        }
        [_windowNumberLabel sizeToFit];
        _windowNumberLabel.frame = [self frameForWindowNumberLabel];
    }
    const BOOL hideWindowTitleLabel = ![self.delegate rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar];
    if (!hideWindowTitleLabel) {
        if (_windowTitleLabel.superview != self) {
            [self addSubview:_windowTitleLabel];
        }
        _windowTitleLabel.frame = [self frameForWindowTitleLabel];
    }
    _windowTitleLabel.hidden = hideWindowTitleLabel;
    self.window.movableByWindowBackground = !hideWindowTitleLabel;
    _windowNumberLabel.hidden = ![self.delegate rootTerminalViewWindowNumberLabelShouldBeVisible];
    _standardWindowButtonsView.frame = [self frameForStandardWindowButtons];
    [self updateTitleAndBorderViews];
}

- (void)layoutSubviews {
    DLog(@"Before:\n%@", [self iterm_recursiveDescription]);
    [self.delegate rootTerminalViewWillLayoutSubviews];

    if (@available(macOS 10.15, *)) { } else {
        _workaroundView.frame = NSMakeRect(0, self.bounds.size.height - 1, 1, 1);
    }
    const BOOL showToolbeltInline = self.shouldShowToolbelt;
    NSWindow *thisWindow = _delegate.window;
    if (!_tabBarControlOnLoan) {
        self.tabBarControl.height = [_delegate rootTerminalViewHeightOfTabBar:self];
    }

    _backgroundImage.frame = self.bounds;
    [self layoutTideySidebar];
    [self layoutWindowPaneDecorations];

    // The tab view frame (calculated below) is based on the toolbelt's width. If the toolbelt is
    // too big for the current window size, you could end up with a negative-width tab view frame.
    if (_shouldShowToolbelt) {
        [self constrainToolbeltWidth];
    }
    _tabViewFrameReduced = NO;
    if (![self tabBarShouldBeVisible]) {
        [self layoutSubviewsWithHiddenTabBarForWindow:thisWindow];
    } else {
        [self layoutSubviewsWithVisibleTabBarForWindow:thisWindow inlineToolbelt:showToolbeltInline];
    }
    if (@available(macOS 12.0, *)) {
        const CGFloat notchHeight = [self notchInset];
        _notchMask.hidden = (notchHeight == 0);
        _notchMask.frame = NSMakeRect(0, NSHeight(self.bounds) - notchHeight, NSWidth(self.bounds), notchHeight);
    }

    if (showToolbeltInline) {
        [self updateToolbeltFrameForWindow:thisWindow];
    }

    self.tabView.hidden = !self.shouldShowTideyTerminal;

    [self updateTideyChromeDragHandles];

    // Update the tab style.
    [self.tabBarControl setDisableTabClose:!iTermAdvancedSettingsModel.tabCloseButtonsAlwaysVisible];
    // Tidey: match terminal tab sizing to editor tabs (min 112, max 240)
    [self.tabBarControl setCellMinWidth:112];
    [self.tabBarControl setSizeCellsToFit:YES];
    [self.tabBarControl setStretchCellsToFit:NO];
    [self.tabBarControl setCellOptimumWidth:240];
    [self.tabBarControl setPinnedTabWidth:[iTermAdvancedSettingsModel pinnedTabWidth]];
    self.tabBarControl.smartTruncation = [iTermAdvancedSettingsModel tabTitlesUseSmartTruncation];

    DLog(@"repositionWidgets - redraw view");
    // Note: this used to call setNeedsDisplay on each session in the current tab.
    [self setNeedsDisplay:YES];

    DLog(@"repositionWidgets - update tab bar");
    if (!_tabBarControlOnLoan) {
        [self.tabBarControl updateFlashing];
    }
    DLog(@"After:\n%@", [self iterm_recursiveDescription]);
    [self.delegate rootTerminalViewDidLayoutSubviews];
}

- (CGFloat)minimumTabBarWidth {
    const iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
    switch (preferredStyle) {
        case TAB_STYLE_DARK:
        case TAB_STYLE_LIGHT:
        case TAB_STYLE_AUTOMATIC:
        case TAB_STYLE_DARK_HIGH_CONTRAST:
        case TAB_STYLE_LIGHT_HIGH_CONTRAST:
            return 50;
        case TAB_STYLE_MINIMAL:
        case TAB_STYLE_COMPACT:
            return 114;
    }
    assert(NO);
}

- (CGFloat)leftTabBarWidthForPreferredWidth:(CGFloat)preferredWidth contentWidth:(CGFloat)contentWidth {
    const CGFloat minimumWidth = [self minimumTabBarWidth];
    const CGFloat maximumWidth = MAX(1, contentWidth - [iTermPreferences intForKey:kPreferenceKeySideMargins] * 2 - 10);
    return MAX(MIN(maximumWidth, preferredWidth), minimumWidth);
}

- (CGFloat)leftTabBarWidthForPreferredWidth:(CGFloat)preferredWidth {
    return [self leftTabBarWidthForPreferredWidth:preferredWidth contentWidth:self.bounds.size.width];
}

- (void)setLeftTabBarWidthFromPreferredWidth {
    _leftTabBarWidth = [self leftTabBarWidthForPreferredWidth:_leftTabBarPreferredWidth];
}

- (void)willShowTabBar {
    _leftTabBarWidth = [self leftTabBarWidthForPreferredWidth:_leftTabBarPreferredWidth
                                                 contentWidth:self.bounds.size.width];
}

#pragma mark - Status Bar Layout

- (NSRect)frameForStatusBarInContainingFrame:(NSRect)containingFrame {
    switch ([iTermPreferences unsignedIntegerForKey:kPreferenceKeyStatusBarPosition]) {
        case iTermStatusBarPositionTop:
            return NSMakeRect(NSMinX(containingFrame),
                              NSMaxY(containingFrame) - iTermGetStatusBarHeight(),
                              NSWidth(containingFrame),
                              iTermGetStatusBarHeight());

        case iTermStatusBarPositionBottom:
            return NSMakeRect(NSMinX(containingFrame),
                              NSMinY(containingFrame),
                              NSWidth(containingFrame),
                              iTermGetStatusBarHeight());
    }
    return NSZeroRect;
}

- (NSAutoresizingMaskOptions)statusBarContainerAutoresizingMask {
    switch ([iTermPreferences unsignedIntegerForKey:kPreferenceKeyStatusBarPosition]) {
        case iTermStatusBarPositionTop:
            return NSViewWidthSizable | NSViewMinYMargin;

        case iTermStatusBarPositionBottom:
            return NSViewWidthSizable | NSViewMaxYMargin;
    }

    return NSViewWidthSizable | NSViewMinYMargin;
}

- (void)updateDecorationHeightsForStatusBar:(iTermDecorationHeights *)decorationHeights {
    switch ([iTermPreferences unsignedIntegerForKey:kPreferenceKeyStatusBarPosition]) {
        case iTermStatusBarPositionTop: {
            decorationHeights->top += iTermGetStatusBarHeight();
            break;
        }
        case iTermStatusBarPositionBottom:
            decorationHeights->bottom += iTermGetStatusBarHeight();
            break;
    }
}

#pragma mark - Tidey Sidebar Table View

#pragma mark - Tidey Editor File Tree

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (outlineView != _tideyEditorFileTreeView) {
        return 0;
    }
    TideyEditorFileNode *node = item ?: _tideyEditorFileTreeRootNode;
    return [node loadChildren].count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (outlineView != _tideyEditorFileTreeView) {
        return nil;
    }
    TideyEditorFileNode *node = item ?: _tideyEditorFileTreeRootNode;
    NSArray<TideyEditorFileNode *> *children = [node loadChildren];
    if (index < 0 || index >= (NSInteger)children.count) {
        return nil;
    }
    return children[index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    if (outlineView != _tideyEditorFileTreeView) {
        return NO;
    }
    return [(TideyEditorFileNode *)item directory];
}

- (NSView *)outlineView:(NSOutlineView *)outlineView
    viewForTableColumn:(NSTableColumn *)tableColumn
                  item:(id)item {
    if (outlineView != _tideyEditorFileTreeView) {
        return nil;
    }
    NSTableCellView *cellView = [outlineView makeViewWithIdentifier:@"TideyEditorFileTreeCell" owner:nil];
    if (!cellView) {
        cellView = [self newTideyEditorFileTreeCellView];
    }
    TideyEditorFileNode *node = item;
    cellView.textField.stringValue = node.displayName ?: node.path.lastPathComponent;
    if (@available(macOS 11.0, *)) {
        NSString *symbolName = node.directory ? @"folder.fill" : @"doc.text";
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        image.template = YES;
        cellView.imageView.image = image;
        cellView.imageView.contentTintColor = [NSColor colorWithWhite:0.78 alpha:1];
    }
    return cellView;
}

- (NSTableCellView *)newTideyEditorFileTreeCellView {
    NSTableCellView *cellView = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
    cellView.identifier = @"TideyEditorFileTreeCell";

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 2, 16, 16)];
    iconView.imageScaling = NSImageScaleProportionallyDown;
    iconView.autoresizingMask = NSViewMaxXMargin;
    cellView.imageView = iconView;
    [cellView addSubview:iconView];

    NSTextField *titleField = [NSTextField newLabelStyledTextField];
    titleField.frame = NSMakeRect(24, 2, 168, 18);
    titleField.autoresizingMask = NSViewWidthSizable;
    titleField.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    titleField.textColor = [NSColor colorWithWhite:0.92 alpha:1];
    titleField.drawsBackground = NO;
    titleField.backgroundColor = [NSColor clearColor];
    titleField.bezeled = NO;
    titleField.editable = NO;
    titleField.selectable = NO;
    cellView.textField = titleField;
    [cellView addSubview:titleField];

    return cellView;
}

- (NSMenu *)tideyEditorFileTreeMenuForNode:(TideyEditorFileNode *)node {
    if (node.path.length == 0) {
        return nil;
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tidey File Tree"];
    [menu addItem:[self tideyEditorFileTreeMenuItemWithTitle:@"Copy Path"
                                                      action:@selector(tideyEditorCopyFileTreePath:)
                                                        path:node.path]];
    [menu addItem:[self tideyEditorFileTreeMenuItemWithTitle:@"Copy Relative Path"
                                                      action:@selector(tideyEditorCopyFileTreeRelativePath:)
                                                        path:node.path]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self tideyEditorFileTreeMenuItemWithTitle:@"Open in External Editor"
                                                      action:@selector(tideyEditorOpenFileTreeItemInExternalEditor:)
                                                        path:node.path]];
    [menu addItem:[self tideyEditorFileTreeMenuItemWithTitle:@"Reveal in Finder"
                                                      action:@selector(tideyEditorRevealFileTreeItemInFinder:)
                                                        path:node.path]];
    return menu;
}

- (NSMenuItem *)tideyEditorFileTreeMenuItemWithTitle:(NSString *)title
                                              action:(SEL)action
                                                path:(NSString *)path {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = path;
    return item;
}

- (NSString *)tideyEditorRelativePathForPath:(NSString *)path {
    NSString *rootPath = [[self tideyEditorFileTreeRootPath] stringByStandardizingPath];
    NSString *normalizedPath = [path stringByStandardizingPath];
    if ([normalizedPath isEqualToString:rootPath]) {
        return @"~";
    }
    NSString *prefix = [rootPath stringByAppendingString:@"/"];
    if ([normalizedPath hasPrefix:prefix]) {
        return [normalizedPath substringFromIndex:prefix.length];
    }
    return normalizedPath.lastPathComponent ?: normalizedPath;
}

- (void)tideyEditorCopyFileTreePath:(id)sender {
    NSString *path = [sender representedObject];
    if (path.length == 0) {
        return;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:path forType:NSPasteboardTypeString];
}

- (void)tideyEditorCopyFileTreeRelativePath:(id)sender {
    NSString *path = [sender representedObject];
    if (path.length == 0) {
        return;
    }
    NSString *relativePath = [self tideyEditorRelativePathForPath:path];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:relativePath forType:NSPasteboardTypeString];
}

- (void)tideyEditorOpenFileTreeItemInExternalEditor:(id)sender {
    NSString *path = [sender representedObject];
    if (path.length == 0) {
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)tideyEditorRevealFileTreeItemInFinder:(id)sender {
    NSString *path = [sender representedObject];
    if (path.length == 0) {
        return;
    }
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
}

- (void)tideyEditorOpenSelectedFilePermanently:(id)sender {
    id item = [_tideyEditorFileTreeView itemAtRow:_tideyEditorFileTreeView.clickedRow >= 0 ? _tideyEditorFileTreeView.clickedRow : _tideyEditorFileTreeView.selectedRow];
    if (![item isKindOfClass:[TideyEditorFileNode class]]) {
        return;
    }
    TideyEditorFileNode *node = item;
    if (node.directory) {
        return;
    }
    [self tideyOpenEditorFileAtPath:node.path preview:NO];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != _tideyEditorFileTreeView) {
        return;
    }
    if (_tideyEditorIsRevealingSelection) {
        return;
    }
    id item = [_tideyEditorFileTreeView itemAtRow:_tideyEditorFileTreeView.selectedRow];
    if (![item isKindOfClass:[TideyEditorFileNode class]]) {
        return;
    }
    TideyEditorFileNode *node = item;
    if (node.directory) {
        if ([_tideyEditorFileTreeView isItemExpanded:node]) {
            [_tideyEditorFileTreeView collapseItem:node];
        } else {
            [_tideyEditorFileTreeView expandItem:node];
        }
        return;
    }
    [self tideyOpenEditorFileAtPath:node.path preview:YES];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [self.delegate rootTerminalViewNumberOfTideySidebarWorkspaces];
}

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView
                 pasteboardWriterForRow:(NSInteger)row {
    if (tableView != _tideySidebarTableView ||
        row < 0 ||
        row >= self.numberOfTideySidebarWorkspaces) {
        return nil;
    }
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)row]
            forType:iTermRootTerminalViewTideySidebarWorkspacePasteboardType];
    return item;
}

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    if (tableView != _tideySidebarTableView) {
        return NSDragOperationNone;
    }
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {
    if (tableView != _tideySidebarTableView) {
        return NO;
    }
    NSPasteboard *pasteboard = info.draggingPasteboard;
    NSString *rowString = [pasteboard stringForType:iTermRootTerminalViewTideySidebarWorkspacePasteboardType];
    if (rowString.length == 0) {
        return NO;
    }
    NSInteger fromIndex = rowString.integerValue;
    NSInteger toIndex = MAX(0, MIN(row, self.numberOfTideySidebarWorkspaces));
    return [self.delegate rootTerminalViewMoveTideySidebarWorkspaceFromIndex:fromIndex
                                                                     toIndex:toIndex];
}

- (void)tableView:(NSTableView *)tableView
  draggingSession:(NSDraggingSession *)session
   willBeginAtPoint:(NSPoint)screenPoint
    forRowIndexes:(NSIndexSet *)rowIndexes {
    if (tableView != _tideySidebarTableView) {
        return;
    }
    session.draggingFormation = NSDraggingFormationNone;
    __weak typeof(self) weakSelf = self;
    [session enumerateDraggingItemsWithOptions:0
                                       forView:tableView
                                       classes:@[[NSPasteboardItem class]]
                                 searchOptions:@{}
                                    usingBlock:^(NSDraggingItem *draggingItem,
                                                 NSInteger idx,
                                                 BOOL *stop) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSPasteboardItem *item = draggingItem.item;
        NSString *rowString = [item stringForType:iTermRootTerminalViewTideySidebarWorkspacePasteboardType];
        if (rowString.length == 0) {
            return;
        }
        NSInteger row = rowString.integerValue;
        if (row < 0 || row >= strongSelf.numberOfTideySidebarWorkspaces) {
            return;
        }
        // Capture the actual row view as the drag image for pixel-perfect match.
        NSTableRowView *rowView = [strongSelf->_tideySidebarTableView rowViewAtRow:row makeIfNecessary:NO];
        if (!rowView) {
            return;
        }
        NSRect rowBounds = rowView.bounds;
        NSBitmapImageRep *bitmap = [rowView bitmapImageRepForCachingDisplayInRect:rowBounds];
        [rowView cacheDisplayInRect:rowBounds toBitmapImageRep:bitmap];
        NSImage *image = [[NSImage alloc] initWithSize:rowBounds.size];
        [image addRepresentation:bitmap];
        draggingItem.imageComponentsProvider = ^NSArray<NSDraggingImageComponent *> * {
            NSDraggingImageComponent *comp = [[NSDraggingImageComponent alloc]
                initWithKey:NSDraggingImageComponentIconKey];
            comp.contents = image;
            comp.frame = NSMakeRect(0, 0, image.size.width, image.size.height);
            return @[comp];
        };
    }];
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (tableView != _tideySidebarTableView) {
        return tableView.rowHeight;
    }
    if (row < 0 || row >= self.numberOfTideySidebarWorkspaces) {
        return 60;
    }
    NSString *workspaceID = [self tideySidebarWorkspaceIdentifierAtIndex:row];
    TideyNotificationItem *notification = nil;
    if (workspaceID.length > 0) {
        notification = [[TideyNotificationStore sharedStore] latestNotificationForWorkspaceID:workspaceID];
    }
    if (notification && notification.body.length > 0) {
        return 90;
    }
    return 60;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    if (tableView != _tideySidebarTableView) {
        return [[NSTableRowView alloc] initWithFrame:NSZeroRect];
    }
    return [[TideySidebarRowView alloc] initWithFrame:NSZeroRect];
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
    if (row < 0 || row >= self.numberOfTideySidebarWorkspaces) {
        return nil;
    }

    NSTableCellView *cellView = [tableView makeViewWithIdentifier:@"TideySidebarSessionCell" owner:nil];
    if (!cellView) {
        cellView = [self newTideySidebarCellView];
    }
    [self configureTideySidebarCellView:cellView row:row];
    return cellView;
}

- (NSTableCellView *)newTideySidebarCellView {
    TideySidebarCellView *cellView = [[TideySidebarCellView alloc] initWithFrame:NSZeroRect];
    cellView.identifier = @"TideySidebarSessionCell";

    NSView *badgeView = [[NSView alloc] initWithFrame:NSMakeRect(12, 22, kTideySidebarBadgeSize, kTideySidebarBadgeSize)];
    badgeView.identifier = kTideySidebarBadgeViewIdentifier;
    badgeView.wantsLayer = YES;
    badgeView.layer.cornerRadius = kTideySidebarBadgeSize / 2.0;
    badgeView.hidden = YES;
    NSTextField *badgeLabel = [NSTextField labelWithString:@""];
    badgeLabel.tag = 1006;
    badgeLabel.frame = NSMakeRect(0, 1, kTideySidebarBadgeSize, 14);
    badgeLabel.font = [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold];
    badgeLabel.textColor = [NSColor whiteColor];
    badgeLabel.alignment = NSTextAlignmentCenter;
    [badgeView addSubview:badgeLabel];
    [cellView addSubview:badgeView];

    NSImageView *pinView = [[NSImageView alloc] initWithFrame:NSMakeRect(152, 34, 12, 12)];
    pinView.tag = 1003;
    pinView.autoresizingMask = NSViewMaxXMargin;
    pinView.imageScaling = NSImageScaleProportionallyDown;
    pinView.hidden = YES;
    if (@available(macOS 11.0, *)) {
        NSImage *pinImage = [NSImage imageWithSystemSymbolName:@"pin.fill" accessibilityDescription:nil];
        pinImage.template = YES;
        pinView.image = pinImage;
        pinView.contentTintColor = [NSColor colorWithWhite:0.90 alpha:1];
    }
    [cellView addSubview:pinView];

    NSTextField *titleField = [NSTextField newLabelStyledTextField];
    titleField.tag = 1001;
    titleField.frame = NSMakeRect(36, 30, 140, 20);
    titleField.autoresizingMask = NSViewWidthSizable;
    titleField.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    titleField.textColor = [NSColor whiteColor];
    titleField.drawsBackground = NO;
    titleField.backgroundColor = [NSColor clearColor];
    titleField.bezeled = NO;
    titleField.editable = NO;
    titleField.selectable = NO;
    cellView.textField = titleField;
    [cellView addSubview:titleField];

    NSTextField *subtitleField = [NSTextField newLabelStyledTextField];
    subtitleField.tag = 1002;
    subtitleField.frame = NSMakeRect(36, 12, 164, 16);
    subtitleField.autoresizingMask = NSViewWidthSizable;
    subtitleField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    subtitleField.textColor = [NSColor colorWithWhite:0.72 alpha:1];
    subtitleField.drawsBackground = NO;
    subtitleField.backgroundColor = [NSColor clearColor];
    subtitleField.bezeled = NO;
    subtitleField.editable = NO;
    subtitleField.selectable = NO;
    [cellView addSubview:subtitleField];

    NSTextField *bodyField = [NSTextField newLabelStyledTextField];
    bodyField.tag = 1007;
    bodyField.frame = NSMakeRect(36, 2, 164, 28);
    bodyField.autoresizingMask = NSViewWidthSizable;
    bodyField.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    bodyField.textColor = [NSColor secondaryLabelColor];
    bodyField.drawsBackground = NO;
    bodyField.backgroundColor = [NSColor clearColor];
    bodyField.bezeled = NO;
    bodyField.editable = NO;
    bodyField.selectable = NO;
    bodyField.maximumNumberOfLines = 2;
    bodyField.lineBreakMode = NSLineBreakByTruncatingTail;
    bodyField.hidden = YES;
    [cellView addSubview:bodyField];

    NSView *closeView = [[NSView alloc] initWithFrame:NSMakeRect(176, 32, 16, 16)];
    closeView.identifier = kTideySidebarCloseViewIdentifier;
    closeView.autoresizingMask = NSViewMinXMargin;
    closeView.hidden = YES;
    closeView.alphaValue = 0.0;
    NSTextField *closeSymbol = [NSTextField labelWithString:@"✕"];
    closeSymbol.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    closeSymbol.textColor = [NSColor tertiaryLabelColor];
    closeSymbol.frame = NSMakeRect(0, 0, 16, 16);
    closeSymbol.alignment = NSTextAlignmentCenter;
    [closeView addSubview:closeSymbol];
    [cellView addSubview:closeView];

    return cellView;
}

- (void)configureTideySidebarCellView:(NSTableCellView *)cellView row:(NSInteger)row {
    BOOL selected = (row == self.tideySidebarSelectedWorkspaceIndex);
    NSInteger unreadCount = [self tideySidebarWorkspaceUnreadCountAtIndex:row];
    NSView *badgeView = TideyFindSubviewWithIdentifier(cellView, kTideySidebarBadgeViewIdentifier);
    NSTextField *badgeLabel = (NSTextField *)[badgeView viewWithTag:1006];
    badgeView.hidden = (unreadCount <= 0);
    if (unreadCount > 0) {
        badgeView.layer.backgroundColor = (selected
                                           ? [NSColor colorWithWhite:1 alpha:0.25].CGColor
                                           : NSColor.controlAccentColor.CGColor);
        badgeLabel.stringValue = unreadCount > 9 ? @"9+" : [NSString stringWithFormat:@"%ld", (long)unreadCount];
    }
    NSImageView *pinView = (NSImageView *)[cellView viewWithTag:1003];
    pinView.hidden = ![self tideySidebarWorkspacePinnedAtIndex:row];
    CGFloat width = NSWidth(cellView.bounds);

    // Determine notification state for body display.
    NSString *workspaceID = [self tideySidebarWorkspaceIdentifierAtIndex:row];
    TideyNotificationItem *latestNotification = [self tideySidebarLatestUnreadNotificationAtIndex:row];
    TideyNotificationItem *anyNotification = nil;
    if (workspaceID.length > 0) {
        anyNotification = [[TideyNotificationStore sharedStore] latestNotificationForWorkspaceID:workspaceID];
    }
    BOOL hasBody = (anyNotification && anyNotification.body.length > 0);

    NSTextField *bodyField = (NSTextField *)[cellView viewWithTag:1007];
    if (hasBody) {
        // Expanded layout: title at top, subtitle (notification title) in middle, body at bottom.
        cellView.textField.stringValue = [self tideySidebarWorkspaceTitleAtIndex:row];
        cellView.textField.frame = NSMakeRect(36, 60, MAX(0, width - 88), 20);

        NSTextField *subtitleField = (NSTextField *)[cellView viewWithTag:1002];
        if (latestNotification) {
            subtitleField.stringValue = latestNotification.title;
            subtitleField.textColor = [NSColor controlAccentColor];
        } else {
            subtitleField.stringValue = anyNotification.title ?: @"";
            subtitleField.textColor = [NSColor colorWithWhite:0.72 alpha:1];
        }
        subtitleField.frame = NSMakeRect(36, 42, MAX(0, width - 48), 16);

        bodyField.stringValue = anyNotification.body;
        bodyField.hidden = NO;
        bodyField.frame = NSMakeRect(36, 4, MAX(0, width - 48), 36);

        pinView.frame = NSMakeRect(MAX(0, width - 48), 64, 12, 12);
        badgeView.frame = NSMakeRect(12, 52, kTideySidebarBadgeSize, kTideySidebarBadgeSize);

        NSView *closeView = TideyFindCloseView(cellView);
        closeView.frame = NSMakeRect(MAX(0, width - 28), 62, 16, 16);
        closeView.hidden = YES;
        closeView.alphaValue = 0.0;
    } else {
        // Normal layout (60pt row).
        cellView.textField.stringValue = [self tideySidebarWorkspaceTitleAtIndex:row];
        cellView.textField.frame = NSMakeRect(36, 30, MAX(0, width - 88), 20);

        NSTextField *subtitleField = (NSTextField *)[cellView viewWithTag:1002];
        if (latestNotification) {
            subtitleField.stringValue = latestNotification.title;
            subtitleField.textColor = [NSColor controlAccentColor];
        } else {
            subtitleField.stringValue = [self tideySidebarWorkspaceSubtitleAtIndex:row];
            subtitleField.textColor = [NSColor colorWithWhite:0.72 alpha:1];
        }
        subtitleField.frame = NSMakeRect(36, 12, MAX(0, width - 48), 16);

        bodyField.hidden = YES;
        bodyField.stringValue = @"";

        pinView.frame = NSMakeRect(MAX(0, width - 48), 34, 12, 12);
        badgeView.frame = NSMakeRect(12, 22, kTideySidebarBadgeSize, kTideySidebarBadgeSize);

        NSView *closeView = TideyFindCloseView(cellView);
        closeView.frame = NSMakeRect(MAX(0, width - 28), 32, 16, 16);
        closeView.hidden = YES;
        closeView.alphaValue = 0.0;
    }

    if ([_tideySidebarTableView isKindOfClass:[TideySidebarTableView class]]) {
        [(TideySidebarTableView *)_tideySidebarTableView updateTideyCloseButtonVisibility];
    }
}

- (NSView *)tideySidebarDragPreviewForRow:(NSInteger)row width:(CGFloat)width height:(CGFloat)height {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    container.wantsLayer = YES;
    container.layer.backgroundColor = NSColor.clearColor.CGColor;

    NSView *highlight = [[NSView alloc] initWithFrame:NSInsetRect(container.bounds, 6, 4)];
    highlight.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    highlight.wantsLayer = YES;
    highlight.layer.backgroundColor = [NSColor selectedContentBackgroundColor].CGColor;
    highlight.layer.cornerRadius = 8;
    [container addSubview:highlight];

    NSTableCellView *cellView = [self newTideySidebarCellView];
    cellView.frame = highlight.bounds;
    cellView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self configureTideySidebarCellView:cellView row:row];
    [highlight addSubview:cellView];
    return container;
}

- (NSImage *)tideySidebarDragPreviewImageForRow:(NSInteger)row width:(CGFloat)width height:(CGFloat)height {
    NSView *preview = [self tideySidebarDragPreviewForRow:row width:width height:height];
    [preview layoutSubtreeIfNeeded];
    NSRect bounds = preview.bounds;
    NSBitmapImageRep *bitmap = [preview bitmapImageRepForCachingDisplayInRect:bounds];
    [preview cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
    NSImage *image = [[NSImage alloc] initWithSize:bounds.size];
    [image addRepresentation:bitmap];
    return image;
}

- (NSMenuItem *)tideySidebarMenuItemWithTitle:(NSString *)title
                                       action:(SEL)action
                                          row:(NSInteger)row {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(row);
    return item;
}

- (NSInteger)tideySidebarWorkspaceIndexFromSender:(id)sender {
    if ([sender isKindOfClass:[NSView class]]) {
        NSInteger row = [_tideySidebarTableView rowForView:(NSView *)sender];
        if (row != -1) {
            return row;
        }
    }
    id representedObject = [sender representedObject];
    if (![representedObject isKindOfClass:[NSNumber class]]) {
        return NSNotFound;
    }
    return [representedObject integerValue];
}

- (NSMenu *)tideySidebarMenuForRow:(NSInteger)row {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tidey Sidebar"];
    [menu addItem:[self tideySidebarMenuItemWithTitle:@"New Workspace"
                                               action:@selector(tideySidebarNewWorkspace:)
                                                  row:row]];

    if (row < 0 || row >= self.numberOfTideySidebarWorkspaces) {
        return menu;
    }

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self tideySidebarMenuItemWithTitle:@"Rename Workspace…"
                                               action:@selector(tideySidebarRenameWorkspace:)
                                                  row:row]];

    {
        NSMenuItem *markRead = [self tideySidebarMenuItemWithTitle:@"Mark as Read"
                                                            action:@selector(tideySidebarMarkWorkspaceRead:)
                                                               row:row];
        markRead.enabled = ([self tideySidebarWorkspaceUnreadCountAtIndex:row] > 0);
        [menu addItem:markRead];

        NSMenuItem *markUnread = [self tideySidebarMenuItemWithTitle:@"Mark as Unread"
                                                              action:@selector(tideySidebarMarkWorkspaceUnread:)
                                                                 row:row];
        markUnread.enabled = [self tideySidebarHasReadNotificationsAtIndex:row];
        [menu addItem:markUnread];
    }

    NSString *pinTitle = [self tideySidebarWorkspacePinnedAtIndex:row] ? @"Unpin Workspace" : @"Pin Workspace";
    [menu addItem:[self tideySidebarMenuItemWithTitle:pinTitle
                                               action:@selector(tideySidebarTogglePinnedWorkspace:)
                                                  row:row]];

    if ([self.delegate rootTerminalViewTideySidebarWorkspaceHasCustomTitleAtIndex:row]) {
        [menu addItem:[self tideySidebarMenuItemWithTitle:@"Remove Custom Workspace Name"
                                                   action:@selector(tideySidebarRemoveCustomWorkspaceName:)
                                                      row:row]];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *moveUp = [self tideySidebarMenuItemWithTitle:@"Move Up"
                                                      action:@selector(tideySidebarMoveWorkspaceUp:)
                                                         row:row];
    moveUp.enabled = (row > 0);
    [menu addItem:moveUp];

    NSMenuItem *moveDown = [self tideySidebarMenuItemWithTitle:@"Move Down"
                                                        action:@selector(tideySidebarMoveWorkspaceDown:)
                                                           row:row];
    moveDown.enabled = (row + 1 < self.numberOfTideySidebarWorkspaces);
    [menu addItem:moveDown];

    NSMenuItem *moveToTop = [self tideySidebarMenuItemWithTitle:@"Move to Top"
                                                         action:@selector(tideySidebarMoveWorkspaceToTop:)
                                                            row:row];
    moveToTop.enabled = (row > 0);
    [menu addItem:moveToTop];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self tideySidebarMenuItemWithTitle:@"Close Workspace"
                                               action:@selector(tideySidebarCloseWorkspace:)
                                                  row:row]];

    NSMenuItem *closeOthers = [self tideySidebarMenuItemWithTitle:@"Close Other Workspaces"
                                                           action:@selector(tideySidebarCloseOtherWorkspaces:)
                                                              row:row];
    closeOthers.enabled = (self.numberOfTideySidebarWorkspaces > 1);
    [menu addItem:closeOthers];

    NSMenuItem *closeAbove = [self tideySidebarMenuItemWithTitle:@"Close Workspaces Above"
                                                          action:@selector(tideySidebarCloseWorkspacesAbove:)
                                                             row:row];
    closeAbove.enabled = (row > 0);
    [menu addItem:closeAbove];

    NSMenuItem *closeBelow = [self tideySidebarMenuItemWithTitle:@"Close Workspaces Below"
                                                          action:@selector(tideySidebarCloseWorkspacesBelow:)
                                                             row:row];
    closeBelow.enabled = (row + 1 < self.numberOfTideySidebarWorkspaces);
    [menu addItem:closeBelow];

    return menu;
}

- (void)tideySidebarNewWorkspace:(id)sender {
    [self.delegate rootTerminalViewCreateTideyWorkspace];
}

- (void)tideySidebarTogglePinnedWorkspace:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        BOOL pinned = [self tideySidebarWorkspacePinnedAtIndex:row];
        [self.delegate rootTerminalViewSetPinned:!pinned forTideySidebarWorkspaceAtIndex:row];
    }
}

- (void)tideySidebarRenameWorkspace:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewRenameTideySidebarWorkspaceAtIndex:row];
    }
}

- (void)tideySidebarMarkWorkspaceRead:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewMarkTideySidebarWorkspaceReadAtIndex:row];
    }
}

- (void)tideySidebarMarkWorkspaceUnread:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewMarkTideySidebarWorkspaceUnreadAtIndex:row];
    }
}

- (BOOL)tideySidebarHasReadNotificationsAtIndex:(NSInteger)index {
    NSString *workspaceID = [self tideySidebarWorkspaceIdentifierAtIndex:index];
    if (workspaceID.length == 0) {
        return NO;
    }
    return [[TideyNotificationStore sharedStore] hasReadNotificationsForWorkspaceID:workspaceID];
}

- (void)tideySidebarRemoveCustomWorkspaceName:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewRemoveCustomNameForTideySidebarWorkspaceAtIndex:row];
    }
}

- (void)tideySidebarMoveWorkspaceUp:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewMoveTideySidebarWorkspaceAtIndex:row byDelta:-1];
    }
}

- (void)tideySidebarMoveWorkspaceDown:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewMoveTideySidebarWorkspaceAtIndex:row byDelta:1];
    }
}

- (void)tideySidebarMoveWorkspaceToTop:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewMoveTideySidebarWorkspaceToTopAtIndex:row];
    }
}

- (void)tideySidebarCloseWorkspace:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    [self tideySidebarCloseWorkspaceAtIndex:row];
}

- (void)tideySidebarCloseWorkspaceAtIndex:(NSInteger)row {
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewCloseTideySidebarWorkspaceAtIndex:row];
    }
}

- (void)tideySidebarCloseOtherWorkspaces:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewCloseOtherTideySidebarWorkspacesExceptIndex:row];
    }
}

- (void)tideySidebarCloseWorkspacesAbove:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewCloseTideySidebarWorkspacesAboveIndex:row];
    }
}

- (void)tideySidebarCloseWorkspacesBelow:(id)sender {
    NSInteger row = [self tideySidebarWorkspaceIndexFromSender:sender];
    if (row != NSNotFound) {
        [self.delegate rootTerminalViewCloseTideySidebarWorkspacesBelowIndex:row];
    }
}

- (NSInteger)numberOfTideySidebarWorkspaces {
    return [self.delegate rootTerminalViewNumberOfTideySidebarWorkspaces];
}

- (BOOL)selectTideySidebarWorkspaceAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.numberOfTideySidebarWorkspaces) {
        return NO;
    }
    NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:index];
    [_tideySidebarTableView selectRowIndexes:indexSet byExtendingSelection:NO];
    [_tideySidebarTableView scrollRowToVisible:index];
    return YES;
}

- (void)reloadTideySidebar {
    [_tideySidebarTableView reloadData];
    [self syncTideySidebarSelection];
    [self layoutTideySidebar];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != _tideySidebarTableView) {
        return;
    }
    if (_tideyIgnoreNextSidebarSelection) {
        _tideyIgnoreNextSidebarSelection = NO;
        [_tideySidebarTableView setNeedsDisplay:YES];
        return;
    }
    const NSInteger selectedRow = _tideySidebarTableView.selectedRow;
    if (selectedRow < 0 || selectedRow >= self.numberOfTideySidebarWorkspaces) {
        return;
    }
    [self.delegate rootTerminalViewSelectTideySidebarWorkspaceAtIndex:selectedRow];
    [_tideySidebarTableView setNeedsDisplay:YES];
}

- (void)layoutIfStatusBarChanged {
    iTermStatusBarViewController *statusBarViewController = [_delegate rootTerminalViewSharedStatusBarViewController];
    if (statusBarViewController != _statusBarViewController ||
        _statusBarViewController.view != statusBarViewController.view ||
        statusBarViewController.view.superview != _statusBarContainer) {
        [self layoutSubviews];
    }
}

- (void)layoutStatusBar:(iTermDecorationHeights *)decorationHeights
                 window:(NSWindow *)thisWindow
                  frame:(NSRect)containingFrame {
    iTermStatusBarViewController *statusBarViewController = [_delegate rootTerminalViewSharedStatusBarViewController];
    NSRect statusBarFrame = [self frameForStatusBarInContainingFrame:containingFrame];
    if (statusBarViewController) {
        [self updateDecorationHeightsForStatusBar:decorationHeights];
    }
    if (_statusBarViewController.view != statusBarViewController.view ||
        _statusBarViewController.view.superview != _statusBarContainer) {
        if (!_statusBarContainer) {
            _statusBarContainer = [[iTermGenericStatusBarContainer alloc] initWithFrame:statusBarFrame];
            _statusBarContainer.autoresizesSubviews = YES;
            _statusBarContainer.delegate = self;
            NSInteger index = [self.subviews indexOfObject:_stoplightHotbox];
            if (index == NSNotFound) {
                [self addSubview:_statusBarContainer];
            } else {
                [self insertSubview:_statusBarContainer atIndex:index];
            }
        }
        if (_statusBarViewController.view.superview == _statusBarContainer) {
            [_statusBarViewController.view removeFromSuperview];
        }
        if (statusBarViewController.view.superview != _statusBarContainer) {
            [_statusBarContainer addSubview:statusBarViewController.view];
            statusBarViewController.view.autoresizingMask = (NSViewWidthSizable | NSViewHeightSizable);
            statusBarViewController.view.frame = _statusBarContainer.bounds;
        }
    }
    _statusBarContainer.autoresizingMask = [self statusBarContainerAutoresizingMask];
    _statusBarContainer.hidden = (statusBarViewController == nil);
    _statusBarViewController = statusBarViewController;
    _statusBarContainer.frame = statusBarFrame;
}

/// Layout status bar using pre-calculated outputs from iTermLayoutCalculator.
/// This is the new path that uses the calculator outputs directly.
- (void)layoutStatusBarWithOutputs:(iTermLayoutOutputs)outputs
                            window:(NSWindow *)thisWindow {
    iTermStatusBarViewController *statusBarViewController = [_delegate rootTerminalViewSharedStatusBarViewController];
    NSRect statusBarFrame = outputs.statusBarFrame;

    if (_statusBarViewController.view != statusBarViewController.view ||
        _statusBarViewController.view.superview != _statusBarContainer) {
        if (!_statusBarContainer) {
            _statusBarContainer = [[iTermGenericStatusBarContainer alloc] initWithFrame:statusBarFrame];
            _statusBarContainer.autoresizesSubviews = YES;
            _statusBarContainer.delegate = self;
            NSInteger index = [self.subviews indexOfObject:_stoplightHotbox];
            if (index == NSNotFound) {
                [self addSubview:_statusBarContainer];
            } else {
                [self insertSubview:_statusBarContainer atIndex:index];
            }
        }
        if (_statusBarViewController.view.superview == _statusBarContainer) {
            [_statusBarViewController.view removeFromSuperview];
        }
        if (statusBarViewController.view.superview != _statusBarContainer) {
            [_statusBarContainer addSubview:statusBarViewController.view];
            statusBarViewController.view.autoresizingMask = (NSViewWidthSizable | NSViewHeightSizable);
            statusBarViewController.view.frame = _statusBarContainer.bounds;
        }
    }
    _statusBarContainer.autoresizingMask = [self statusBarContainerAutoresizingMask];
    _statusBarContainer.hidden = (statusBarViewController == nil);
    _statusBarViewController = statusBarViewController;
    _statusBarContainer.frame = statusBarFrame;
}

#pragma mark - iTermTabBarControlViewDelegate

- (BOOL)iTermTabBarShouldFlashAutomatically {
    if (_tabBarControlOnLoan) {
        return NO;
    }
    return [_delegate iTermTabBarShouldFlashAutomatically];
}

- (void)iTermTabBarWillBeginFlash {
    [_delegate iTermTabBarWillBeginFlash];
}

- (void)iTermTabBarDidFinishFlash {
    [_delegate iTermTabBarDidFinishFlash];
}

- (BOOL)iTermTabBarWindowIsFullScreen {
    return [_delegate iTermTabBarWindowIsFullScreen];
}

- (BOOL)iTermTabBarCanDragWindow {
    return [_delegate iTermTabBarCanDragWindow];
}

- (BOOL)iTermTabBarShouldHideBacking {
    const iTermPreferencesTabStyle preferredStyle = [iTermPreferences intForKey:kPreferenceKeyTabStyle];
    if (preferredStyle != TAB_STYLE_MINIMAL) {
        return YES;
    }
    BOOL isTop = NO;
    switch ([iTermPreferences intForKey:kPreferenceKeyTabPosition]) {
        case PSMTab_BottomTab:
        case PSMTab_LeftTab:
            return YES;

        case PSMTab_TopTab:
            isTop = YES;
            break;
    }
    if ([_delegate lionFullScreen] || [_delegate enteringLionFullscreen]) {
        if (isTop) {
            if ([iTermPreferences boolForKey:kPreferenceKeyFlashTabBarInFullscreen]) {
                return YES;
            }
            if (![self tabBarShouldBeVisible] && !_tabBarControlOnLoan) {
                // Code path taken big Big Sur workaround for issue #9199
                return YES;
            }
        } else {
            return NO;
        }
    }

    return YES;
}

#pragma mark - iTermDragHandleViewDelegate

// For the left-side tab bar.
- (CGFloat)dragHandleView:(iTermDragHandleView *)dragHandle didMoveBy:(CGFloat)delta {
    if (dragHandle == self.tideySidebarDragHandle) {
        const CGFloat originalWidth = self.tideySidebarWidth;
        _tideySidebarPreferredWidth = originalWidth + delta;
        [self layoutSubviews];
        return self.tideySidebarWidth - originalWidth;
    }

    if (dragHandle == self.tideyEditorDragHandle) {
        const CGFloat originalWidth = self.tideyEditorPanelWidth;
        _tideyEditorPreferredWidth = originalWidth - delta;
        [self layoutSubviews];
        return originalWidth - self.tideyEditorPanelWidth;
    }

    if (dragHandle == self.tideyEditorFileTreeDragHandle) {
        const CGFloat originalWidth = self.tideyEditorFileTreeWidth;
        _tideyEditorFileTreePreferredWidth = originalWidth - delta;
        [self layoutSubviews];
        return originalWidth - self.tideyEditorFileTreeWidth;
    }

    CGFloat originalValue = _leftTabBarPreferredWidth;
    _leftTabBarPreferredWidth = round([self leftTabBarWidthForPreferredWidth:_leftTabBarPreferredWidth + delta]);
    [self layoutSubviews];  // This may modify _leftTabBarWidth if it's too big or too small.
    [[iTermUserDefaults userDefaults] setDouble:_leftTabBarPreferredWidth
                                              forKey:kPreferenceKeyLeftTabBarWidth];
    return _leftTabBarPreferredWidth - originalValue;
}

- (void)dragHandleViewDidFinishMoving:(iTermDragHandleView *)dragHandle {
    if (dragHandle == self.tideySidebarDragHandle ||
        dragHandle == self.tideyEditorDragHandle ||
        dragHandle == self.tideyEditorFileTreeDragHandle) {
        [self tideyPersistLayoutState];
    }
    [_delegate rootTerminalViewDidResizeContentArea];
}

- (void)dragHandleViewDidDoubleClick:(iTermDragHandleView *)dragHandle {
    if (dragHandle == self.tideySidebarDragHandle ||
        dragHandle == self.tideyEditorDragHandle ||
        dragHandle == self.tideyEditorFileTreeDragHandle) {
        // Reset all panels to default sizes
        _tideySidebarPreferredWidth = kTideySidebarWidth;
        _tideyEditorPreferredWidth = floor(NSWidth(self.bounds) / 2.0);
        _tideyEditorFileTreePreferredWidth = kTideyEditorFileTreeWidth;
    } else {
        return;
    }
    [self tideyPersistLayoutState];
    [self layoutSubviews];
    [_delegate rootTerminalViewDidResizeContentArea];
}

#pragma mark - iTermStoplightHotboxDelegate

- (void)stoplightHotboxMouseExit {
    [NSView animateWithDuration:0.25
                     animations:^{
                         self->_stoplightHotbox.animator.alphaValue = 0;
                         self->_standardWindowButtonsView.animator.alphaValue = 0;
                     }
                     completion:^(BOOL finished) {
                         if (!finished) {
                             return;
                         }
                     }];
}

- (BOOL)shouldRevealHotbox {
    if ([[iTermApplication sharedApplication] it_modifierFlags] & NSEventModifierFlagCommand) {
        return NO;
    }
    if (!self.window.isKeyWindow) {
        return YES;
    }
    if (!NSApp.isActive) {
        return YES;
    }
    NSView *firstResponder = [NSView castFrom:self.window.firstResponder];
    if (!firstResponder) {
        return YES;
    }
    const NSRect firstResponderFrame = [firstResponder convertRect:firstResponder.bounds toView:nil];
    const NSRect hotboxFrame = [_stoplightHotbox convertRect:_stoplightHotbox.bounds toView:nil];
    if (!NSIntersectsRect(firstResponderFrame, hotboxFrame)) {
        return YES;
    }
    if (![firstResponder respondsToSelector:@selector(delegate)]) {
        return YES;
    }
    id delegate = [(id)firstResponder delegate];
    if (![delegate conformsToProtocol:@protocol(iTermHotboxSuppressing)]) {
        return YES;
    }
    id<iTermHotboxSuppressing> suppressing = delegate;
    return ![suppressing supressesHotbox];
}

- (BOOL)stoplightHotboxMouseEnter {
    if (![self shouldRevealHotbox]) {
        return NO;
    }

    [_stoplightHotbox setNeedsDisplay:YES];
    _stoplightHotbox.alphaValue = 0;
    _standardWindowButtonsView.alphaValue = 0;
    [NSView animateWithDuration:0.25
                     animations:^{
                         self->_stoplightHotbox.animator.alphaValue = 1;
                         self->_standardWindowButtonsView.animator.alphaValue = 1;
                     }
                     completion:nil];
    return YES;
}

- (NSColor *)stoplightHotboxColor {
    return [NSColor windowBackgroundColor];
}

- (NSColor *)stoplightHotboxOutlineColor {
    return [NSColor grayColor];
}

- (BOOL)stoplightHotboxCanDrag {
    return ([self.delegate iTermTabBarCanDragWindow] &&
            ![self.delegate iTermTabBarWindowIsFullScreen]);
}

#pragma mark - iTermGenericStatusBarContainer

- (NSColor *)genericStatusBarContainerBackgroundColor {
    return [self.delegate rootTerminalViewTabBarBackgroundColorIgnoringTabColor:YES];
}

@end

BOOL PSMShouldExtendTransparencyIntoMinimalTabBar(void) {
    if (@available(macOS 10.16, *)) { } else {
        return NO;
    }
    switch ([iTermPreferences intForKey:kPreferenceKeyTabStyle]) {
        case TAB_STYLE_MINIMAL:
            return YES;

        case TAB_STYLE_AUTOMATIC:
        case TAB_STYLE_COMPACT:
        case TAB_STYLE_LIGHT:
        case TAB_STYLE_LIGHT_HIGH_CONTRAST:
        case TAB_STYLE_DARK:
        case TAB_STYLE_DARK_HIGH_CONTRAST:
            return NO;
    }
    return NO;
}
