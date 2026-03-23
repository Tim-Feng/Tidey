//
//  iTermRootTerminalView.h
//  iTerm2
//
//  Created by George Nachman on 7/3/15.
//
//

#import <Cocoa/Cocoa.h>
#import "SolidColorView.h"
#import "VT100GridTypes.h"

@class iTermImageView;
@class iTermRootTerminalView;
@class iTermStatusBarViewController;
@protocol iTermSwipeHandler;
@class iTermTabBarControlView;
@protocol iTermTabBarControlViewDelegate;
@class iTermToolbeltView;
@protocol iTermToolbeltViewDelegate;
@protocol PSMTabBarControlDelegate;
@protocol PSMPUAFontProvider;
@class PTYTabView;

@protocol iTermRootTerminalViewDelegate<iTermTabBarControlViewDelegate, iTermSwipeHandler>
- (void)repositionWidgets;
- (void)rootTerminalViewDidResizeContentArea;
- (BOOL)haveTopBorder;
- (BOOL)haveBottomBorder;
- (BOOL)haveLeftBorder;
- (BOOL)haveRightBorder;
- (BOOL)haveRightBorderRegardlessOfScrollBar;
- (BOOL)anyFullScreen;
- (BOOL)tabBarAlwaysVisible;
- (NSEdgeInsets)tabBarInsets;
- (BOOL)exitingLionFullscreen;
- (BOOL)enteringLionFullscreen;
- (BOOL)lionFullScreen;
- (BOOL)fullScreen;  // non-native full screen
- (BOOL)divisionViewShouldBeVisible;
- (NSWindow *)window;
- (BOOL)enableStoplightHotbox;
- (void)rootTerminalViewDidChangeEffectiveAppearance;
- (CGFloat)rootTerminalViewHeightOfTabBar:(iTermRootTerminalView *)sender;
- (CGFloat)rootTerminalViewStoplightButtonsOffset:(iTermRootTerminalView *)sender;
- (NSColor *)rootTerminalViewTabBarTextColorForTitle;
- (NSColor *)rootTerminalViewTabBarTextColorForWindowNumber;
- (NSColor *)rootTerminalViewTabBarBackgroundColorIgnoringTabColor:(BOOL)ignoreTabColor;
- (BOOL)rootTerminalViewWindowNumberLabelShouldBeVisible;
- (BOOL)rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar;
- (NSImage *)rootTerminalViewCurrentTabIcon;
- (BOOL)rootTerminalViewShouldDrawStoplightButtons;
- (BOOL)rootTerminalViewShouldRevealStandardWindowButtons;
- (iTermStatusBarViewController *)rootTerminalViewSharedStatusBarViewController;

// Returns YES when the tab bar is a titlebar accessory in fullscreen AND the window
// uses NSWindowStyleMaskFullSizeContentView, meaning the content view extends under
// the title bar. In this case, the tab bar accessory overlaps the content area and
// we must shrink frames to compensate.
- (BOOL)rootTerminalViewFullScreenTabBarAccessoryOverlapsContent;

// Returns YES when we should leave empty space at the top of the content area for
// where the tab bar WILL be, even though it's not currently visible or positioned there.
// This handles the transitional state when the tab bar is "on loan" to the titlebar
// accessory system but hasn't yet been positioned as an accessory.
- (BOOL)rootTerminalViewShouldLeaveEmptyAreaAtTop;
- (BOOL)rootTerminalViewShouldHideTabBarBackingWhenTabBarIsHidden;
- (VT100GridSize)rootTerminalViewCurrentSessionSize;
- (NSString *)rootTerminalViewWindowSizeViewDetailString;
- (void)rootTerminalViewWillLayoutSubviews;
- (void)rootTerminalViewDidLayoutSubviews;
- (NSString *)rootTerminalViewCurrentTabSubtitle;
- (NSString *)rootTerminalViewCurrentWorkingDirectory;
- (id<PSMPUAFontProvider>)rootTerminalViewPUAFontProvider;
- (NSInteger)rootTerminalViewNumberOfTideySidebarWorkspaces;
- (NSString *)rootTerminalViewTideySidebarWorkspaceTitleAtIndex:(NSInteger)index;
- (NSString *)rootTerminalViewTideySidebarWorkspaceSubtitleAtIndex:(NSInteger)index;
- (NSString *)rootTerminalViewTideySidebarWorkspaceIdentifierAtIndex:(NSInteger)index;
- (BOOL)rootTerminalViewTideySidebarWorkspaceIsPinnedAtIndex:(NSInteger)index;
- (NSInteger)rootTerminalViewSelectedTideySidebarWorkspaceIndex;
- (BOOL)rootTerminalViewSelectTideySidebarWorkspaceAtIndex:(NSInteger)index;
- (BOOL)rootTerminalViewMoveTideySidebarWorkspaceFromIndex:(NSInteger)fromIndex
                                                   toIndex:(NSInteger)toIndex;
- (void)rootTerminalViewCreateTideyWorkspace;
- (void)rootTerminalViewSetPinned:(BOOL)pinned forTideySidebarWorkspaceAtIndex:(NSInteger)index;
- (BOOL)rootTerminalViewTideySidebarWorkspaceHasCustomTitleAtIndex:(NSInteger)index;
- (void)rootTerminalViewRenameTideySidebarWorkspaceAtIndex:(NSInteger)index;
- (void)rootTerminalViewRemoveCustomNameForTideySidebarWorkspaceAtIndex:(NSInteger)index;
- (void)rootTerminalViewMoveTideySidebarWorkspaceAtIndex:(NSInteger)index byDelta:(NSInteger)delta;
- (void)rootTerminalViewMoveTideySidebarWorkspaceToTopAtIndex:(NSInteger)index;
- (void)rootTerminalViewCloseTideySidebarWorkspaceAtIndex:(NSInteger)index;
- (void)rootTerminalViewCloseOtherTideySidebarWorkspacesExceptIndex:(NSInteger)index;
- (void)rootTerminalViewCloseTideySidebarWorkspacesAboveIndex:(NSInteger)index;
- (void)rootTerminalViewCloseTideySidebarWorkspacesBelowIndex:(NSInteger)index;
- (void)rootTerminalViewMarkTideySidebarWorkspaceReadAtIndex:(NSInteger)index;
- (void)rootTerminalViewMarkTideySidebarWorkspaceUnreadAtIndex:(NSInteger)index;
- (IBAction)toggleTideySidebar:(id)sender;
- (IBAction)toggleTideyTerminal:(id)sender;
- (IBAction)toggleTideyEditorPanel:(id)sender;
- (IBAction)toggleTideyEditorFileTree:(id)sender;
- (CGFloat)rootTerminalViewSessionTitleBarHeight;
@end

extern const NSInteger iTermRootTerminalViewWindowNumberLabelMargin;
extern const NSInteger iTermRootTerminalViewWindowNumberLabelWidth;

@interface iTermRootTerminalView : SolidColorView

// TODO: Get rid of this
@property(nonatomic, weak) id<iTermRootTerminalViewDelegate> delegate;

// The tabview occupies almost the entire window. Each tab has an identifier
// which is a PTYTab.
@property(nonatomic, readonly) PTYTabView *tabView;

// This is a sometimes-visible control that shows the tabs and lets the user
// change which is visible.
@property(nonatomic, readonly) iTermTabBarControlView *tabBarControl;

// Gray line dividing tab/title bar from content. Will be nil if a division
// view isn't needed such as for fullscreen windows or windows without a
// title bar (e.g., top-of-screen).
@property(nonatomic, readonly) NSView<iTermSolidColorView> *divisionView;

// Toolbelt view. Goes on the right side of the terminal window, if visible.
@property(nonatomic, readonly) iTermToolbeltView *toolbelt;

// Should the toolbelt be visible?
@property(nonatomic) BOOL shouldShowToolbelt;

// Should the Tidey sidebar be visible?
@property(nonatomic) BOOL shouldShowTideySidebar;

// Should the Tidey editor panel be visible?
@property(nonatomic) BOOL shouldShowTideyEditorPanel;

// Should the Tidey terminal region be visible?
@property(nonatomic) BOOL shouldShowTideyTerminal;

// Should the Tidey editor file tree be visible?
@property(nonatomic) BOOL shouldShowTideyEditorFileTree;

// How wide the toolbelt should be. User may drag it to change.
// ALWAYS USE THE FLOOR OF THIS VALUE!
@property(nonatomic) CGFloat toolbeltWidth;

@property(nonatomic, readonly) BOOL scrollbarShouldBeVisible;

@property(nonatomic, readonly) BOOL tabBarShouldBeVisible;
@property(nonatomic, readonly) BOOL tabBarShouldBeVisibleEvenWhenOnLoan;

@property(nonatomic, readonly) CGFloat leftTabBarWidth;
@property(nonatomic, readonly) CGFloat leftTabBarPreferredWidth;

@property(nonatomic) BOOL useMetal;
@property(nonatomic, readonly) BOOL tabBarControlOnLoan NS_AVAILABLE_MAC(10_14);
@property(nonatomic, strong, readonly) iTermStatusBarViewController *statusBarViewController;
@property(nonatomic, readonly) iTermImageView *backgroundImage NS_AVAILABLE_MAC(10_14);
// Excludes the window number
@property(nonatomic, readonly) NSString *windowTitle;

- (instancetype)initWithFrame:(NSRect)frame
                        color:(NSColor *)color
               tabBarDelegate:(id<iTermTabBarControlViewDelegate, PSMTabBarControlDelegate>)tabBarDelegate
                     delegate:(id<iTermRootTerminalViewDelegate, iTermToolbeltViewDelegate>)delegate;  // TODO: This should hopefully go away

// Update the division view's frame and set it visible/hidden per |shouldBeVisible|.
- (void)updateDivisionViewAndWindowNumberLabel;

// Perform a layout pass on the toolbelt, and hide/show it as needed.
- (void)updateToolbeltFrameForWindow:(NSWindow *)thisWindow;
- (void)updateToolbeltForWindow:(NSWindow *)thisWindow;

// TODO: Don't expose this
- (void)constrainToolbeltWidth;

- (void)shutdown;

- (void)layoutSubviews;
- (void)layoutIfStatusBarChanged;

- (BOOL)tabBarShouldBeVisibleWithAdditionalTabs:(int)numberOfAdditionalTabs;

- (void)willShowTabBar;

- (void)didChangeCompactness;

- (void)windowTitleDidChangeTo:(NSString *)title;
- (void)windowNumberDidChangeTo:(NSNumber *)number;
- (void)setWindowTitleIcon:(NSImage *)icon;
- (iTermTabBarControlView *)borrowTabBarControl NS_AVAILABLE_MAC(10_14);
- (void)returnTabBarControlView:(iTermTabBarControlView *)tabBarControl NS_AVAILABLE_MAC(10_14);
- (CGFloat)maximumToolbeltWidthForViewWidth:(CGFloat)viewWidth;
- (void)updateToolbeltProportionsIfNeeded;
- (void)setToolbeltProportions:(NSDictionary *)proportions;
- (void)invalidateAutomaticTabBarBackingHiding;
- (void)setShowsWindowSize:(BOOL)showsWindowSize NS_AVAILABLE_MAC(10_14);
- (void)windowDidResize;
- (CGFloat)leftTabBarWidthForPreferredWidth:(CGFloat)preferredWidth contentWidth:(CGFloat)contentWidth;
- (void)updateTitleAndBorderViews NS_AVAILABLE_MAC(10_14);
- (void)setSubtitle:(NSString *)subtitle;
- (void)setCurrentSessionAlpha:(CGFloat)alpha;
- (BOOL)selectTideySidebarWorkspaceAtIndex:(NSInteger)index;
- (NSInteger)numberOfTideySidebarWorkspaces;
- (void)reloadTideySidebar;
- (void)openTideyEditorFileAtPath:(NSString *)path;
- (BOOL)saveTideyEditorCurrentTab;
- (BOOL)hasSaveableTideyEditorTab;
- (BOOL)tideyEditorHasFocus;
- (BOOL)closeCurrentTideyEditorTab;

@end
